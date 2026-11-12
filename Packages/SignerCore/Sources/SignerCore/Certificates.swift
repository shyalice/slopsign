import Foundation
import Security
import SignerCrypto

public enum PasswordVault {
  private static let service = "io.alicehatesyou.signer.certificates"
  public static func set(_ password: String, for id: UUID) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: id.uuidString,
    ]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = Data(password.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw SignerError("Unable to save the password in Keychain (\(status)).")
    }
  }
  public static func get(_ id: UUID) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
      let password = String(data: data, encoding: .utf8)
    else { throw SignerError("The certificate password is unavailable. Import the certificate again.") }
    return password
  }
  public static func remove(_ id: UUID) {
    SecItemDelete(
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: id.uuidString,
      ] as CFDictionary)
  }
}

public enum Certificates {
  public static func identityInfo(p12: URL, password: String) throws -> (name: String, created: Date, expires: Date) {
    var error: NSError?
    guard let identity = SGReadIdentity(try Data(contentsOf: p12), password, &error) as? [String: Any],
      let name = identity["name"] as? String, let created = identity["created"] as? Date,
      let expires = identity["expires"] as? Date else { throw error ?? SignerError("Unable to read the certificate.") as NSError }
    return (name, created, expires)
  }
  public static func certificateData(p12: URL, password: String) throws -> Data {
    var error: NSError?
    guard
      let identity = SGReadIdentity(try Data(contentsOf: p12), password, &error) as? [String: Any],
      let data = identity["certificate"] as? Data
    else {
      throw error ?? SignerError("Unable to read the certificate.") as NSError
    }
    return data
  }

  public static func profile(at url: URL) throws -> [String: Any] {
    try signedPropertyList(Data(contentsOf: url))
  }
  public static func signedPropertyList(_ data: Data) throws -> [String: Any] {
    var error: NSError?
    guard let content = SGDecodeProfile(data, &error) else {
      throw error ?? SignerError("Invalid mobileprovision") as NSError
    }
    guard
      let result = try PropertyListSerialization.propertyList(from: content, format: nil)
        as? [String: Any]
    else { throw SignerError("Invalid mobileprovision.") }
    return result
  }
  public static func inspect(p12: URL, profile: URL, password: String, id: UUID = UUID()) throws
    -> CertificateRecord
  {
    var error: NSError?
    guard
      let identity = SGReadIdentity(try Data(contentsOf: p12), password, &error) as? [String: Any],
      let der = identity["certificate"] as? Data
    else { throw error ?? SignerError("Invalid P12") as NSError }
    let p = try self.profile(at: profile)
    guard let certs = p["DeveloperCertificates"] as? [Data], certs.contains(der) else {
      throw SignerError("The P12 certificate is not included in this profile's DeveloperCertificates.")
    }
    guard let team = (p["TeamIdentifier"] as? [String])?.first,
      let ent = p["Entitlements"] as? [String: Any],
      let appID = ent["application-identifier"] as? String,
      let expires = p["ExpirationDate"] as? Date, let certExpires = identity["expires"] as? Date
    else {
      throw SignerError("The profile is missing Team ID, application-identifier, or expiration date.")
    }
    guard expires > Date(), certExpires > Date(),
      (identity["created"] as? Date ?? .distantPast) <= Date(),
      (p["CreationDate"] as? Date ?? .distantPast) <= Date()
    else { throw SignerError("The certificate or profile is expired or not yet valid.") }
    return CertificateRecord(
      id: id, name: identity["name"] as? String ?? "Cert", teamID: team,
      teamName: p["TeamName"] as? String ?? team, appIdentifier: appID, expires: expires,
      certificateExpires: certExpires, created: p["CreationDate"] as? Date ?? Date(),
      devices: p["ProvisionedDevices"] as? [String] ?? [],
      allDevices: p["ProvisionsAllDevices"] as? Bool ?? false,
      profileName: p["Name"] as? String ?? "Mobileprovision",
      profileUUID: p["UUID"] as? String ?? "",
      relativePath: id.uuidString)
  }
  public static func importPair(p12: URL, profile: URL, password: String, workspace: Workspace)
    throws -> CertificateRecord
  {
    let record = try inspect(p12: p12, profile: profile, password: password)
    let directory = workspace.certificates.appendingPathComponent(record.relativePath)
    try workspace.fm.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try workspace.fm.copyItem(at: p12, to: directory.appendingPathComponent("identity.p12"))
      try workspace.fm.copyItem(
        at: profile, to: directory.appendingPathComponent("profile.mobileprovision"))
      try PasswordVault.set(password, for: record.id)
      #if os(iOS)
        try workspace.fm.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: directory.path)
      #endif
    } catch {
      try? workspace.fm.removeItem(at: directory)
      PasswordVault.remove(record.id)
      throw error
    }
    return record
  }
}
