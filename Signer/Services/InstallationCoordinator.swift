import Combine
import SignerCore
import UIKit

struct InstallationTarget: Hashable {
  let ipa: URL
  let icon: URL?
  let name: String
}

@MainActor
final class InstallationCoordinator: ObservableObject {
  let session = InstallationSession()
  @Published private(set) var preparing = false
  @Published private(set) var showsProgress = false
  @Published var feedback: OperationNotice?
  var active: Bool { preparing || [.waiting, .transferring].contains(session.phase) }
  let identities = InstallationIdentityStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Signer/InstallationTLS"))
  private var observation: AnyCancellable?
  private var task: Task<Void, Never>?
  private var lifetime: Task<Void, Never>?
  private var attempt: UUID?
  private(set) var presentsFeedback = true
  private let requestDeadline: Duration
  private let open: (URL) async -> Bool
  private(set) var report = ""
  init(requestDeadline: Duration = .seconds(60), open: @escaping (URL) async -> Bool = { await UIApplication.shared.open($0) }) {
    self.requestDeadline = requestDeadline
    self.open = open
    observation = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
  }
  func install(_ target: InstallationTarget, showsProgress: Bool, log: @escaping (String, Bool) -> Void) {
    guard !active else { return }
    let id = UUID()
    attempt = id
    preparing = true
    self.showsProgress = showsProgress
    presentsFeedback = true
    feedback = nil
    report = "ESign installation\nApp: \(target.name)\n"
    let previous = task
    task?.cancel(); lifetime?.cancel()
    session.onStatus = nil
    session.stop()
    try? BackgroundKeeper.shared.set(false, owner: "installation")
    task = Task { [weak self] in
      await previous?.value
      guard let self, attempt == id, !Task.isCancelled else { return }
      session.onStatus = { [weak self] text, error in
        guard let self, attempt == id else { return }
        report += text + "\n"
        log(text, error)
        if error || session.phase == .served {
          try? BackgroundKeeper.shared.set(false, owner: "installation")
          if presentsFeedback {
            feedback = OperationNotice(title: error ? "Installation Failed" : "App Downloaded", message: text)
          }
        }
      }
      defer { if attempt == id { preparing = false } }
      do {
        let metadata = try await Task.detached { try AppBundleMetadata.read(target.ipa) }.value
        try Task.checkCancellation()
        guard attempt == id else { return }
        report += "Bundle ID: \(metadata.identifier)\nBundle version: \(metadata.build)\n"
        if let profile = metadata.profile, let decoded = try? Certificates.signedPropertyList(profile),
          let entitlements = decoded["Entitlements"] as? [String: Any], let pattern = entitlements["application-identifier"] as? String {
          report += "Profile application identifier: \(pattern)\n"
        } else { report += "Embedded provisioning profile: absent\n" }
        let host = UserDefaults.standard.string(forKey: "installation.domain") ?? "sign.killed.wtf"
        let configuration = UserDefaults.standard.string(forKey: "installation.configurationURL") ?? ""
        let identity = try await identities.identity(host: host, configurationURL: configuration)
        try Task.checkCancellation()
        guard attempt == id else { return }
        try await session.prepare(ipa: target.ipa, icon: metadata.icon, identity: identity, metadata: metadata, keepAlive: {
          try BackgroundKeeper.shared.set(true, owner: "installation")
        }, requestDeadline: requestDeadline, open: open)
        // Keep bytes available for system retries, without replaying HUD callbacks.
        lifetime = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(600)) } catch { return }
          guard let self, attempt == id else { return }
          session.stop()
          try? BackgroundKeeper.shared.set(false, owner: "installation")
        }
      } catch {
        guard attempt == id else { return }
        if !(error is CancellationError), !Task.isCancelled, session.phase != .failed { session.fail(error.localizedDescription) }
        try? BackgroundKeeper.shared.set(false, owner: "installation")
      }
    }
  }
  /// A shared document is a separate operation. Keep serving an existing iOS
  /// download, but never interrupt the import with that installation's timeout.
  func leavePresentationForImport() {
    presentsFeedback = false
    showsProgress = false
    feedback = nil
  }
  func cancel() {
    attempt = nil
    task?.cancel(); lifetime?.cancel()
    session.onStatus = nil
    session.stop()
    preparing = false
    showsProgress = false
    feedback = nil
    try? BackgroundKeeper.shared.set(false, owner: "installation")
  }
}
