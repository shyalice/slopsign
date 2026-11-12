import CryptoKit
import SignerCore
import Foundation

/// Installs a separate local-server TLS identity; never reads signing P12s.
actor InstallationIdentityStore {
  struct Configuration: Codable { let host: String; let p12URL: URL; let password: String; let sha256: String }
  let directory: URL
  init(directory: URL) { self.directory = directory }
  func identity(host: String, configurationURL: String) async throws -> LocalInstallationIdentity {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("server.p12")
    let saved = directory.appendingPathComponent("configuration.json")
    if let data = try? Data(contentsOf: saved), let config = try? JSONDecoder().decode(Configuration.self, from: data), config.host == host,
      let valid = try? LocalInstallationIdentity(host: host, p12: file, password: config.password) { return valid }
    if host == "sign.killed.wtf", let bundled = Bundle.main.url(forResource: "server", withExtension: "p12", subdirectory: "Installation") ?? Bundle.main.url(forResource: "server", withExtension: "p12") {
      if let valid = try? LocalInstallationIdentity(host: host, p12: bundled, password: "ESignLocalTLS") { return valid }
    }
    guard !configurationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw SignerError("The TLS certificate for \(host) is unavailable or has expired. Import a valid TLS identity in Installation settings.")
    }
    guard let url = URL(string: configurationURL), url.scheme == "https" else { throw SignerError("The certificate update URL must use HTTPS.") }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 32_768 else { throw SignerError("The installation server configuration is unavailable.") }
    let config = try JSONDecoder().decode(Configuration.self, from: data)
    guard config.host == host, config.p12URL.scheme == "https" else { throw SignerError("The installation configuration does not match the selected domain.") }
    let (p12, p12Response) = try await URLSession.shared.data(from: config.p12URL)
    guard (p12Response as? HTTPURLResponse)?.statusCode == 200, p12.count < 1_000_000,
      SHA256.hash(data: p12).map({ String(format: "%02x", $0) }).joined() == config.sha256.lowercased() else { throw SignerError("The installation TLS download is invalid.") }
    let temporary = directory.appendingPathComponent(UUID().uuidString + ".p12")
    defer { try? fm.removeItem(at: temporary) }
    try p12.write(to: temporary, options: .atomic)
    _ = try LocalInstallationIdentity(host: host, p12: temporary, password: config.password)
    try p12.write(to: file, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try data.write(to: saved, options: .atomic)
    return try LocalInstallationIdentity(host: host, p12: file, password: config.password)
  }
  func importIdentity(_ source: URL, host: String, password: String) throws {
    _ = try LocalInstallationIdentity(host: host, p12: source, password: password)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try Data(contentsOf: source)
    try data.write(to: directory.appendingPathComponent("server.p12"), options: .atomic)
    let config = Configuration(host: host, p12URL: URL(string: "https://\(host)/server.p12")!, password: password, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("configuration.json"), options: .atomic)
  }
}
