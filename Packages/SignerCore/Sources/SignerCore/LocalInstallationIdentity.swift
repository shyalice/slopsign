import Foundation
import Security

public struct LocalInstallationIdentity: Sendable {
  public let host: String
  public let p12: URL
  public let password: String
  public init(host: String, p12: URL, password: String, checkTrust: Bool = true) throws {
    guard !host.isEmpty, host == host.lowercased(), !host.contains(":"), !host.contains("/"), !host.contains(" ") else { throw SignerError("Enter a hostname without a scheme or port.") }
    var items: CFArray?
    let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
    guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
      first[kSecImportItemIdentity as String] != nil,
      let chain = first[kSecImportItemCertChain as String] as? [SecCertificate], !chain.isEmpty else { throw SignerError("Unable to read the installation TLS identity (\(status)).") }
    if checkTrust {
      var trust: SecTrust?
      guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess, let trust else { throw SignerError("Unable to verify the installation TLS certificate.") }
      var error: CFError?
      guard SecTrustEvaluateWithError(trust, &error) else {
        throw SignerError("The TLS certificate is not trusted for \(host): \(error.map { CFErrorCopyDescription($0) as String } ?? "unknown error")")
      }
    }
    self.host = host; self.p12 = p12; self.password = password
  }
  public var baseURL: URL { URL(string: "https://\(host):14302")! }
}
