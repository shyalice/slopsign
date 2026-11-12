import Foundation
import ZIPFoundation

/// Read the main bundle directly; never expand the whole IPA to draw a row.
public struct AppBundleMetadata: Sendable {
  public let identifier: String
  public let title: String
  public let build: String
  public let version: String
  public let icon: Data?
  public let profile: Data?
  public static func read(_ url: URL) throws -> Self {
    let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    let archive: Archive? = directory ? nil : try Archive(url: url, accessMode: .read, pathEncoding: nil)
    // Build the index once: Terminal contains 62k entries, and each missing icon
    // candidate used to rescan the complete ZIP directory.
    var index: [String: Entry] = [:]
    if let archive { for entry in archive { index[entry.path] = entry } }
    let prefix: String
    if directory { prefix = "" }
    else {
      guard archive != nil else { throw SignerError("Unable to read the IPA archive.") }
      let main = index.values.filter { entry in
        let parts = entry.path.split(separator: "/")
        return parts.count == 3 && parts[0] == "Payload" && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
      }
      guard main.count == 1 else { throw SignerError("The IPA must contain one main app bundle.") }
      prefix = String(main[0].path.dropLast("Info.plist".count))
    }
    func read(_ relative: String, limit: Int = 8_000_000) throws -> Data? {
      guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
      if let archive {
        guard let entry = index[prefix + relative] else { return nil }
        guard entry.uncompressedSize <= limit else { throw SignerError("App metadata is too large.") }
        var data = Data()
        _ = try archive.extract(entry) { bytes in
          guard data.count + bytes.count <= limit else { throw SignerError("App metadata is too large.") }
          data.append(bytes)
        }
        return data
      }
      let file = url.appendingPathComponent(relative)
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= limit else { throw SignerError("App metadata is too large.") }
      return try Data(contentsOf: file)
    }
    guard let data = try read("Info.plist", limit: 1_000_000),
      let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { throw SignerError("The app's Info.plist is invalid.") }
    var names = ["SignerIcon.png"]
    for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
      if let icons = info[key] as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any], let files = primary["CFBundleIconFiles"] as? [String] { names += files.reversed() }
    }
    names += (info["CFBundleIconFiles"] as? [String] ?? []).reversed()
    if let name = info["CFBundleIconFile"] as? String { names.append(name) }
    names += ["AppIcon60x60", "AppIcon", "Icon", "icon"]
    var icon: Data?
    for name in names {
      let base = name.hasSuffix(".png") ? String(name.dropLast(4)) : name
      for candidate in [base + "@3x.png", base + "@2x.png", base + ".png"] {
        if let data = try read(candidate) { icon = data; break }
      }
      if icon != nil { break }
    }
    return Self(identifier: identifier,
      title: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
      build: info["CFBundleVersion"] as? String ?? "1",
      version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "1",
      icon: icon, profile: try read("embedded.mobileprovision"))
  }
}
