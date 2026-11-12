import Foundation

public struct SignerError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct AppRecord: Codable, Identifiable, Hashable {
  public var id: UUID
  public var name: String
  public var bundleID: String
  public var version: String
  public var relativePath: String
  public var importedAt: Date
  public var signedAt: Date?
  public var certificateName: String?
  public var archivePath: String?
  public var modifiedOnly: Bool
  public var sourcePath: String?
  public init(
    id: UUID = UUID(), name: String, bundleID: String, version: String, relativePath: String,
    signedAt: Date? = nil, certificateName: String? = nil, archivePath: String? = nil,
    modifiedOnly: Bool = false, sourcePath: String? = nil
  ) {
    self.id = id
    self.name = name
    self.bundleID = bundleID
    self.version = version
    self.relativePath = relativePath
    self.importedAt = Date()
    self.signedAt = signedAt
    self.certificateName = certificateName
    self.archivePath = archivePath
    self.modifiedOnly = modifiedOnly
    self.sourcePath = sourcePath
  }
}

public struct CertificateRecord: Codable, Identifiable, Hashable {
  public var id: UUID
  public var name: String
  public var teamID: String
  public var teamName: String
  public var appIdentifier: String
  public var expires: Date
  public var certificateExpires: Date
  public var created: Date
  public var devices: [String]
  public var allDevices: Bool
  public var profileName: String
  public var profileUUID: String
  public var relativePath: String
  public var isExpired: Bool { min(expires, certificateExpires) <= Date() }
  public func allows(_ bundleID: String) -> Bool {
    let prefix = teamID + "."
    let pattern =
      appIdentifier.hasPrefix(prefix)
      ? String(appIdentifier.dropFirst(prefix.count)) : appIdentifier
    return pattern == "*" || pattern == bundleID
      || (pattern.hasSuffix(".*") && bundleID.hasPrefix(String(pattern.dropLast())))
  }
}

public struct SigningOptions: Codable, Equatable {
  public var name = ""
  public var bundleID = ""
  public var version = ""
  public var outputName = ""
  public var modifyOnly = false
  public var installAfterSigning: Bool?
  public var removeExtensions = false
  public var removeWatch = false
  public var removeURLSchemes = false
  public var fileSharing = false
  public var documentBrowser = false
  public var removeSupportedDevices = true
  public var minimumOS = ""
  public var enableProMotion = false
  public var removeProvision = false
  public var compression = true
  public var weakInjection = false
  public var useRPath = false
  public var injectInFrameworks = true
  public var libraries: [String] = []
  public var removeLibraries: [String] = []
  public var entitlementsPath: String?
  public var iconPath: String?
  /// XML property-list dictionary, preserving actual value types.
  public var plistOverrides: Data?
  public init() {}
}

public struct SourceRecord: Codable, Identifiable, Hashable {
  public var id: UUID
  public var url: URL
  public var name: String
  public var apps: [SourceApp]
  public var updated: Date
  public init(url: URL, name: String, apps: [SourceApp]) {
    id = UUID()
    self.url = url
    self.name = name
    self.apps = apps
    updated = Date()
  }
}
public struct SourceApp: Codable, Identifiable, Hashable {
  public var id: String { bundleID + downloadURL.absoluteString }
  public var name: String
  public var bundleID: String
  public var version: String
  public var subtitle: String
  public var downloadURL: URL
  public var iconURL: URL?
}
public enum SourceParser {
  public static func parse(_ data: Data, from url: URL) throws -> SourceRecord {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = root["apps"] as? [[String: Any]]
    else {
      throw SignerError("The source must contain an apps array in AltStore or ESign JSON format.")
    }
    let apps: [SourceApp] = raw.compactMap { item in
      let v = (item["versions"] as? [[String: Any]])?.first ?? item
      guard let name = item["name"] as? String, let link = v["downloadURL"] as? String,
        let download = URL(string: link, relativeTo: url)?.absoluteURL,
        ["https", "http"].contains(download.scheme ?? "")
      else { return nil }
      return SourceApp(
        name: name, bundleID: item["bundleIdentifier"] as? String ?? "",
        version: v["version"] as? String ?? "—",
        subtitle: item["subtitle"] as? String ?? item["localizedDescription"] as? String ?? "",
        downloadURL: download,
        iconURL: (item["iconURL"] as? String).flatMap {
          URL(string: $0, relativeTo: url)?.absoluteURL
        })
    }
    return SourceRecord(
      url: url, name: root["name"] as? String ?? url.host ?? "Source", apps: apps)
  }
}
