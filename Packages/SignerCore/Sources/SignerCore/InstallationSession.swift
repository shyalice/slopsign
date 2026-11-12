import Combine
import Foundation

/// Shared installation transaction. Opening a URL or serving an IPA is not
/// proof of installation; only iOS knows the final installation result.
@MainActor
public final class InstallationSession: ObservableObject {
  public enum Phase: Equatable { case idle, preparing, waiting, transferring, served, failed, cancelled }
  @Published public private(set) var phase: Phase = .idle
  @Published public private(set) var status = ""
  @Published public private(set) var progress: Double = 0
  @Published public private(set) var payloadDelivered = false
  public let server = LocalFileServer()
  public var onStatus: ((String, Bool) -> Void)?
  private var observations = Set<AnyCancellable>()
  private var requestTimeout: Task<Void, Never>?
  private let transferIdleTimeout: Duration
  private var transferWatchdog: Task<Void, Never>?
  private var lastProgress = ContinuousClock.now
  public init(transferIdleTimeout: Duration = .seconds(90)) {
    self.transferIdleTimeout = transferIdleTimeout
    // The server publishes on the main queue. Re-enqueuing these updates could
    // deliver an old transaction's completion after a new session has started.
    server.$installationProgress.sink { [weak self] value in
      guard let self, [.waiting, .transferring].contains(self.phase) else { return }
      if value > self.progress { self.lastProgress = .now }
      self.progress = value
    }.store(in: &observations)
    server.$installationStatus.sink { [weak self] value in
      guard let self, [.waiting, .transferring].contains(self.phase) else { return }
      if value == "Sending IPA to iOS" { self.update(.transferring, "Sending IPA to iOS…") }
      else if value.hasPrefix("IPA transfer failed:") { self.fail(value) }
      else if value == "IPA sent to iOS" {
        self.payloadDelivered = true
        self.progress = 1
        // ESign closes its download HUD here. Delivery does not prove that iOS
        // accepted the app's code signature or provisioning profile.
        self.update(.served, "App downloaded. Check installation progress on the Home Screen.")
      }
    }.store(in: &observations)
  }
  private func update(_ phase: Phase, _ status: String, error: Bool = false) {
    guard self.phase != phase || self.status != status else { return }
    self.phase = phase; self.status = status
    if phase == .transferring, transferWatchdog == nil {
      lastProgress = .now
      transferWatchdog = Task { [weak self] in
        guard let self else { return }
        while !Task.isCancelled, self.phase == .transferring {
          do { try await Task.sleep(for: min(.seconds(1), transferIdleTimeout)) } catch { return }
          if ContinuousClock.now - lastProgress >= transferIdleTimeout {
            fail("The IPA download stopped advancing. Check the Home Screen, then retry if the app is missing.")
            return
          }
        }
      }
    } else if phase != .transferring {
      transferWatchdog?.cancel(); transferWatchdog = nil
    }
    if phase != .waiting { requestTimeout?.cancel(); requestTimeout = nil }
    onStatus?(status, error)
  }
  public static func fetchManifest(_ endpoint: URL) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 12
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: endpoint)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SignerError("The installation manifest is unavailable.") }
    return data
  }
  public func prepare(ipa: URL, icon: Data? = nil,
    identity: LocalInstallationIdentity? = nil, metadata: AppBundleMetadata? = nil,
    fetch: (URL) async throws -> Data = InstallationSession.fetchManifest,
    keepAlive: () throws -> Void = {}, requestDeadline: Duration = .seconds(60), open: (URL) async -> Bool
  ) async throws {
    guard phase != .preparing else { throw SignerError("An installation is already being prepared.") }
    requestTimeout?.cancel(); server.stop(); progress = 0; payloadDelivered = false
    update(.preparing, "Preparing installation…")
    do {
      guard FileManager.default.fileExists(atPath: ipa.path) else { throw SignerError("The IPA file no longer exists.") }
      var selected: URL?
      if let identity, let metadata {
        let transaction = UUID()
        let manifest = try InstallationManifest.data(metadata: metadata, baseURL: identity.baseURL, hasIcon: icon != nil, installationID: transaction)
        try server.startInstallation(ipa: ipa, icon: icon, manifest: manifest, tlsP12: identity.p12, tlsPassword: identity.password, installationID: transaction)
        var components = URLComponents(url: identity.baseURL.appendingPathComponent("manifest.plist"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "installation", value: transaction.uuidString)]
        selected = components.url
      } else {
      for endpoint in [InstallationManifest.primary, InstallationManifest.fallback] {
        try Task.checkCancellation()
        do {
          let data = try await fetch(endpoint)
          try Task.checkCancellation()
          try InstallationManifest.validate(data)
          selected = endpoint
          break
        } catch { try Task.checkCancellation() }
      }
      }
      guard let selected else { throw SignerError("Unable to fetch the installation manifest. Check your connection and try again.") }
      if identity == nil { try server.startInstallation(ipa: ipa, icon: icon) }
      let deadline = ContinuousClock.now + .seconds(5)
      while !server.running {
        guard ContinuousClock.now < deadline, server.status == "Stopped" || server.status == "Running" else {
          throw SignerError("Unable to start installation: " + server.status)
        }
        try await Task.sleep(for: .milliseconds(30))
      }
      try Task.checkCancellation()
      if let identity, let metadata {
        let data = try await fetch(selected)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let items = plist["items"] as? [[String: Any]], let actual = items.first?["metadata"] as? [String: Any],
          actual["bundle-identifier"] as? String == metadata.identifier, actual["title"] as? String == metadata.title else {
          throw SignerError("The local installation domain did not return this app's manifest. Check its DNS record.")
        }
      }
      try keepAlive()
      let url = try InstallationManifest.serviceURL(manifest: selected)
      update(.waiting, "Opening installation prompt…")
      guard await open(url) else { throw SignerError("iOS could not open the installation request.") }
      try Task.checkCancellation()
      if phase == .waiting {
        update(.waiting, "Installation requested. Waiting for iOS…")
        requestTimeout = Task { [weak self] in
          do { try await Task.sleep(for: requestDeadline) } catch { return }
          guard let self, self.phase == .waiting else { return }
          self.server.stop()
          self.update(.failed, "iOS did not request the IPA. Check the installation prompt and try again.", error: true)
        }
      }
    } catch {
      server.stop()
      if Task.isCancelled || error is CancellationError { update(.cancelled, "Installation cancelled.") }
      else { update(.failed, error.localizedDescription, error: true) }
      throw error
    }
  }
  public func stop() {
    requestTimeout?.cancel(); requestTimeout = nil
    server.stop()
    if [.preparing, .waiting, .transferring].contains(phase) { update(.cancelled, "Installation cancelled.") }
  }
  public func fail(_ message: String) { server.stop(); update(.failed, message, error: true) }
}
