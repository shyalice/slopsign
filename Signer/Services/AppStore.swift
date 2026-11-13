import Foundation
import SignerCore
import SwiftUI
import UIKit
import OSLog

@MainActor
final class OperationStatus: ObservableObject {
  @Published var title = ""
  @Published var fraction: Double = 0
  @Published var stageFraction: Double = 0
  var currentTaskTitle: String { "\(title) (\(Int(min(1, max(0, stageFraction)) * 100))%)" }
  @Published var cancelling = false
  @Published var signingLog: [SigningLogLine] = []
}

struct SigningLogLine: Identifiable {
  let id = UUID()
  let text: String
  let isError: Bool
}

struct OperationNotice: Equatable, Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

@MainActor
final class AppStore: ObservableObject {
  let workspace: Workspace
  let engine: SigningEngine
  @Published var apps: [AppRecord] = []
  @Published var certificates: [CertificateRecord] = []
  @Published var sources: [SourceRecord] = []
  @Published var davAccounts: [DAVAccount] = []
  @Published var error: String?
  @Published var notice: OperationNotice?
  @Published private(set) var progressInDialog = true
  var showsProgress: Bool { busy && progressInDialog }
  @Published var busy = false {
    didSet { if !busy { startNextImport(); startNextAction() } }
  }
  @Published private(set) var operationID: UUID?
  private var pendingImports: [DocumentImportBatch] = []
  private var pendingActions: [() -> Void] = []
  private var libraryRefresh: Task<Void, Never>?
  private var importingURLs = Set<URL>()
  private var recentlyReceived: [URL: ContinuousClock.Instant] = [:]
  private let importLog = Logger(subsystem: "io.alicehatesyou.signer", category: "Import")
  @Published var importedFiles: [URL] = []
  let operationStatus = OperationStatus()
  var operation: String { get { operationStatus.title } set { operationStatus.title = newValue } }
  var progress: Double { get { operationStatus.fraction } set { operationStatus.fraction = newValue } }
  var cancelling: Bool { get { operationStatus.cancelling } set { operationStatus.cancelling = newValue } }
  private var operationProgress: Progress?
  private var progressObservation: NSKeyValueObservation?
  private var operationErrors: [String] = []
  private var progressPresented = false
  private var dismissalWaiters: [CheckedContinuation<Void, Never>] = []
  func progressPresentationBegan() { progressPresented = true }
  func progressPresentationEnded() {
    progressPresented = false
    let waiting = dismissalWaiters
    dismissalWaiters.removeAll()
    waiting.forEach { $0.resume() }
  }
  private func waitForProgressDismissal() async {
    guard progressPresented else { return }
    await withCheckedContinuation { dismissalWaiters.append($0) }
  }
  @Published var revision = 0
  @Published var lastResult: AppRecord?
  @Published var clipboard: (url: URL, move: Bool)?
  @Published var selectedTab = 0
  @Published var appsSegment = 0
  @Published var signingTab: Int?
  @Published var fileSelectionTab: Int?
  @Published var fileNavigationPath = NavigationPath()
  @Published var appNavigationPath = NavigationPath()
  @Published var sourceNavigationPath = NavigationPath()
  @AppStorage("appearance") var appearance = 0
  @AppStorage("defaultCertificate") var defaultCertificate = ""
  @AppStorage("defaultSigningOptions") private var optionsData = Data()
  let transfers = DownloadCenter()
  let server = LocalFileServer()
  let udidServer = LocalFileServer()
  let installer: InstallationCoordinator
  func install(_ app: AppRecord) {
    do {
      guard let archive = app.archivePath, app.signedAt != nil else { throw SignerError("Sign the app before installing it.") }
      beginInstallation(InstallationTarget(ipa: try workspace.resolve(archive), icon: try? workspace.resolve(app.relativePath), name: app.name))
    } catch { self.error = error.localizedDescription }
  }
  func installArchive(_ url: URL) {
    let app = apps.first { $0.archivePath.flatMap { try? workspace.resolve($0) } == url }
    beginInstallation(InstallationTarget(ipa: url, icon: app.flatMap { try? workspace.resolve($0.relativePath) }, name: app?.name ?? url.deletingPathExtension().lastPathComponent))
  }
  private func beginInstallation(_ target: InstallationTarget) {
    guard !installer.active else { return }
    udidServer.stop()
    let showErrorsInOutput = signingTab != nil
    if !showErrorsInOutput { operationStatus.signingLog = [] }
    installer.install(target, showsProgress: !showErrorsInOutput) { [weak self] text, error in
      self?.operationStatus.signingLog.append(SigningLogLine(text: text, isError: error))
    }
  }
  var defaultOptions: SigningOptions {
    get { (try? JSONDecoder().decode(SigningOptions.self, from: optionsData)) ?? SigningOptions() }
    set { optionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
  }
  init(workspace suppliedWorkspace: Workspace? = nil, installer: InstallationCoordinator? = nil) {
    self.installer = installer ?? InstallationCoordinator()
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: "installation.removedPlaceholderURL") {
      if defaults.string(forKey: "installation.configurationURL") == "https://killed.wtf/esign/installation.json" {
        defaults.removeObject(forKey: "installation.configurationURL")
      }
      defaults.set(true, forKey: "installation.removedPlaceholderURL")
    }
    let fm = FileManager.default
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let support = suppliedWorkspace?.privateRoot ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Signer")
    // These are app-container locations; failure means the app cannot operate.
    do { workspace = try suppliedWorkspace ?? Workspace(root: docs, privateRoot: support) } catch {
      fatalError("Cannot create app workspace: \(error)")
    }
    engine = SigningEngine(workspace: workspace)
    do {
      apps = try workspace.load([AppRecord].self, name: "apps", fallback: [])
      for i in apps.indices {
        apps[i].relativePath = migratePath(apps[i].relativePath)
        apps[i].archivePath = apps[i].archivePath.map(migratePath)
      }
      certificates = try workspace.load(
        [CertificateRecord].self, name: "certificates", fallback: [])
      sources = try workspace.load([SourceRecord].self, name: "sources", fallback: [])
      davAccounts = try workspace.load([DAVAccount].self, name: "davAccounts", fallback: [])
      let migrated = try workspace.migrateSignedRecords(apps)
      if migrated != apps { try workspace.save(migrated, name: "apps"); apps = migrated }
    } catch {
      self.error =
        "Unable to read the library: \(error.localizedDescription). Your files remain in Documents."
    }
    var excluded = support
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? excluded.setResourceValues(values)
    transfers.destination = workspace.files
    transfers.onComplete = { [weak self] in self?.revision += 1 }
  }
  func persist() throws {
    try workspace.save(apps, name: "apps")
    try workspace.save(certificates, name: "certificates")
    try workspace.save(sources, name: "sources")
    try workspace.save(davAccounts, name: "davAccounts")
    revision += 1
  }
  private func beginOperation(_ label: String, inDialog: Bool = true) -> Progress? {
    guard !busy else { return nil }
    let current = Progress(totalUnitCount: 100)
    operationID = UUID()
    operationProgress = current
    operation = label
    progressInDialog = inDialog
    progress = 0
    operationStatus.stageFraction = 0
    cancelling = false
    let delivery = ProgressDelivery()
    progressObservation = current.observe(\.fractionCompleted, options: [.new]) { [weak self] value, _ in
      let fraction = value.fractionCompleted
      guard delivery.shouldDeliver(fraction) else { return }
      Task { @MainActor in
        guard let self, self.operationProgress === value else { return }
        if abs(self.progress - fraction) >= 0.005 || fraction >= 1 { self.progress = fraction }
      }
    }
    busy = true
    return current
  }
  func cancelOperation() {
    guard let operationProgress, !cancelling else { return }
    cancelling = true
    operationProgress.cancel()
  }
  private func finishOperation(_ failure: Error? = nil) {
    if let failure, !FileTransfer.isCancelled(failure) { operationErrors.append(FileTransfer.message(for: failure)) }
    progressObservation = nil
    operationProgress = nil
    refreshAppLibrary(whileBusy: true)
    busy = false
  }
  func presentOperationErrors() {
    guard !busy, !operationErrors.isEmpty else { return }
    error = operationErrors.joined(separator: "\n")
    operationErrors.removeAll()
  }
  func perform(_ label: String, inDialog: Bool = true, _ action: @escaping @Sendable (Progress) throws -> Void) {
    if deferUntilCancellationFinishes({ [weak self] in self?.perform(label, inDialog: inDialog, action) }) { return }
    guard let current = beginOperation(label, inDialog: inDialog) else { return }
    Task {
      var failure: Error?
      do {
        try await Task.detached(priority: .userInitiated) { try action(current) }.value
        revision += 1
      } catch { failure = error; revision += 1 }
      finishOperation(failure)
    }
  }
  private func deferUntilCancellationFinishes(_ action: @escaping () -> Void) -> Bool {
    guard busy else { return false }
    if cancelling { pendingActions.append(action) }
    else { error = "Another operation is still running." }
    return true
  }
  private func startNextAction() {
    guard !busy, !pendingActions.isEmpty else { return }
    pendingActions.removeFirst()()
  }
  func importFiles(_ urls: [URL], to folder: URL? = nil) {
    let incoming = urls.filter { importingURLs.insert($0).inserted }
    guard !incoming.isEmpty else { return }
    installer.leavePresentationForImport()
    // Imports from Settings and other apps are revealed in the root file list.
    if folder == nil {
      fileNavigationPath = NavigationPath()
      selectedTab = 0
    }
    importLog.info("Accepted \(incoming.count) file(s) for import")
    pendingImports.append(DocumentImportBatch(urls: incoming, destination: folder))
    startNextImport()
  }
  private func startNextImport() {
    guard !busy, !pendingImports.isEmpty else { return }
    let batch = pendingImports.removeFirst()
    let ws = workspace
    guard let current = beginOperation("Importing Files") else { return }
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        batch.run(in: ws, progress: current)
      }.value
      importingURLs.subtract(batch.urls)
      importedFiles = result.imported
      revision += 1
      importLog.info("Copied \(result.imported.count) file(s); failures: \(result.failures.count)")
      if !result.failures.isEmpty {
        let message = "Imported \(result.imported.count) file(s).\n" + result.failures.joined(separator: "\n")
        importLog.error("Import failed: \(message, privacy: .private)")
        operationErrors.append(message)
      } else if !current.isCancelled {
        notice = OperationNotice(title: "Import Complete", message: result.imported.map(\.lastPathComponent).joined(separator: "\n"))
      }
      finishOperation()
    }
  }
  func receive(_ url: URL) {
    if url.scheme == "signer" {
      selectedTab = 4
      return
    }
    guard url.isFileURL else { return }
    let now = ContinuousClock.now
    recentlyReceived = recentlyReceived.filter { now - $0.value < .seconds(2) }
    let key = (try? SafePath.canonical(url)) ?? url.standardizedFileURL
    guard recentlyReceived[key] == nil else { return }
    recentlyReceived[key] = now
    importLog.info("Received Open In file URL")
    importFiles([url])
  }
  /// Recover copies delivered by Open In even when the sending app only activates
  /// the existing scene. Pending URLs are deduplicated against onOpenURL delivery.
  func recoverInbox() {
    let inbox = workspace.files.appendingPathComponent("Inbox", isDirectory: true)
    guard let urls = try? workspace.fm.contentsOfDirectory(
      at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]), !urls.isEmpty
    else { return }
    urls.forEach(receive)
  }
  func importApp(_ url: URL, copyIncoming: Bool = false) {
    if deferUntilCancellationFinishes({ [weak self] in self?.importApp(url, copyIncoming: copyIncoming) }) { return }
    guard let current = beginOperation("Importing App") else { return }
    let ws = workspace
    let access = DocumentImportBatch(urls: [url])
    Task {
      do {
        let result = try await Task.detached {
          let source: URL
          let appProgress: Progress
          if copyIncoming {
            current.totalUnitCount = 100
            let copying = Progress(totalUnitCount: 1)
            current.addChild(copying, withPendingUnitCount: 25)
            source = try DocumentImport.copy(access.urls[0], to: ws, progress: copying)
            appProgress = Progress(totalUnitCount: 1)
            current.addChild(appProgress, withPendingUnitCount: 75)
          } else { source = access.urls[0]; appProgress = current }
          return try ws.importApp(source, progress: appProgress)
        }.value
        apps.insert(result, at: 0)
        try persist()
        selectedTab = 1
        notice = OperationNotice(title: "Added to Apps", message: result.name)
        finishOperation()
      } catch { finishOperation(error) }
    }
  }
  func stageResources(_ batch: DocumentImportBatch) async -> [URL]? {
    if busy {
      guard cancelling else { error = "Another operation is still running."; return nil }
      return await withCheckedContinuation { continuation in
        pendingActions.append { [self] in
          Task { continuation.resume(returning: await stageResources(batch)) }
        }
      }
    }
    guard let current = beginOperation("Importing Resources") else { return nil }
    let ws = workspace
    let result = await Task.detached { batch.run(in: ws, progress: current) }.value
    revision += 1
    finishOperation(result.failures.isEmpty ? nil : SignerError(result.failures.joined(separator: "\n")))
    return current.isCancelled ? nil : result.imported
  }
  func packageApp(_ url: URL) {
    if deferUntilCancellationFinishes({ [weak self] in self?.packageApp(url) }) { return }
    guard let current = beginOperation("Creating IPA") else { return }
    let ws = workspace
    Task {
      do {
        let archive = try await Task.detached { try ws.packageApp(url, progress: current) }.value
        notice = OperationNotice(title: "IPA Created", message: archive.lastPathComponent)
        revision += 1
        finishOperation()
      } catch { finishOperation(error) }
    }
  }
  func dumpClasses(_ url: URL) {
    if deferUntilCancellationFinishes({ [weak self] in self?.dumpClasses(url) }) { return }
    guard let current = beginOperation("Reading Classes") else { return }
    let ws = workspace
    Task {
      do {
        let output = try await Task.detached { try ws.dumpClasses(url, progress: current) }.value
        notice = OperationNotice(title: "Class Dump Created", message: output.lastPathComponent)
        revision += 1
        finishOperation()
      } catch { finishOperation(error) }
    }
  }
  func sign(_ app: AppRecord, options: SigningOptions, certificate: CertificateRecord?, onFailure: ((String) -> Void)? = nil) async
    -> AppRecord?
  {
    if busy {
      guard cancelling else { onFailure?("Another operation is still running."); return nil }
      return await withCheckedContinuation { continuation in
        pendingActions.append { [self] in
          Task { continuation.resume(returning: await sign(app, options: options, certificate: certificate, onFailure: onFailure)) }
        }
      }
    }
    guard let current = beginOperation("Preparing", inDialog: false) else { return nil }
    operationStatus.signingLog = []
    let delivery = SigningLogDelivery { [weak self] lines in
      guard let self, self.operationProgress === current else { return }
      self.operationStatus.signingLog.append(contentsOf: lines)
    }
    do {
      let result = try await engine.sign(app, options: options, certificate: certificate, control: current, log: { message, error in
        delivery.append(message, error: error)
      }) {
        [weak self] value, label in
        Task { @MainActor in
          guard let self, self.operationProgress === current else { return }
          self.operation = label
          self.operationStatus.stageFraction = value
        }
      }
      delivery.flush()
      apps.insert(result, at: 0)
      try persist()
      lastResult = result
      let completion = result.modifiedOnly ? "Changes saved." : "Signing complete."
      if operationStatus.signingLog.last?.text != completion {
        operationStatus.signingLog.append(SigningLogLine(text: completion, isError: false))
      }
      finishOperation()
      await waitForProgressDismissal()
      return result
    } catch {
      delivery.flush()
      finishOperation(onFailure == nil ? error : nil)
      await waitForProgressDismissal()
      if !FileTransfer.isCancelled(error) { onFailure?(FileTransfer.message(for: error)) }
      return nil
    }
  }
  func refreshAppLibrary(whileBusy: Bool = false) {
    guard (!busy || whileBusy), libraryRefresh == nil else { return }
    let snapshot = apps, ws = workspace
    libraryRefresh = Task {
      do {
        let updated = try await Task.detached(priority: .userInitiated) { try ws.reconcileAppRecords(snapshot) }.value
        guard apps == snapshot else {
          libraryRefresh = nil
          refreshAppLibrary(whileBusy: whileBusy)
          return
        }
        if updated != apps {
          try ws.save(updated, name: "apps")
          withAnimation { apps = updated }
          revision += 1
        }
      } catch { self.error = error.localizedDescription }
      libraryRefresh = nil
    }
  }
  func waitForLibraryRefresh() async { await libraryRefresh?.value }
  func deleteApp(_ app: AppRecord) { deleteApps([app.id]) }
  func deleteApps(_ ids: Set<UUID>) {
    if deferUntilCancellationFinishes({ [weak self] in self?.deleteApps(ids) }) { return }
    let targets = apps.filter { ids.contains($0.id) }
    guard !targets.isEmpty, let current = beginOperation("Deleting Apps") else { return }
    let ws = workspace
    Task {
      let result = await Task.detached(priority: .userInitiated) {
        var removed = Set<UUID>(), failures: [String] = []
        current.totalUnitCount = Int64(targets.count)
        for app in targets {
          if current.isCancelled { break }
          let itemProgress = Progress(totalUnitCount: 1)
          current.addChild(itemProgress, withPendingUnitCount: 1)
          do { try ws.removeAppFiles(app, progress: itemProgress); removed.insert(app.id) }
          catch {
            if FileTransfer.isCancelled(error) { break }
            failures.append(app.name + ": " + error.localizedDescription)
          }
          itemProgress.completedUnitCount = itemProgress.totalUnitCount
        }
        return (removed, failures)
      }.value
      withAnimation { apps.removeAll { result.0.contains($0.id) } }
      do { try persist() } catch { operationErrors.append(error.localizedDescription) }
      operationErrors.append(contentsOf: result.1)
      finishOperation()
    }
  }
  func deleteCertificate(_ cert: CertificateRecord) {
    do {
      try workspace.fm.removeItem(
        at: workspace.certificates.appendingPathComponent(cert.relativePath))
      PasswordVault.remove(cert.id)
      certificates.removeAll { $0.id == cert.id }
      try persist()
    } catch { self.error = error.localizedDescription }
  }
  func addSource(_ url: URL) async throws {
    guard ["https", "http"].contains(url.scheme ?? "") else {
      throw SignerError("Enter an HTTP or HTTPS URL.")
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      data.count < 20_000_000
    else { throw SignerError("The source did not return valid JSON.") }
    var source = try SourceParser.parse(data, from: url)
    var updated = sources
    if let index = updated.firstIndex(where: { $0.url == url }) {
      source.id = updated[index].id
      updated[index] = source
    } else {
      updated.append(source)
    }
    try workspace.save(updated, name: "sources")
    sources = updated
  }
  func deleteSources(_ ids: Set<UUID>) throws {
    let remaining = sources.filter { !ids.contains($0.id) }
    try workspace.save(remaining, name: "sources")
    sources = remaining
  }
}

private func migratePath(_ path: String) -> String {
  for (old, new) in [
    ("Apps/", "YYYAppFolder/UnSignApps/"), ("Signed/", "YYYAppFolder/SignedApps/"),
    ("Archives/", "YYYAppFolder/SignedApps/"), ("Files/", ""),
  ] {
    if path.hasPrefix(old) { return new + path.dropFirst(old.count) }
  }
  return path
}
