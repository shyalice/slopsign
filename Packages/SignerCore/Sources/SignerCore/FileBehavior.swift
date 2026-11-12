import Foundation

/// File dispatch is based on bundle/executable contents as in ESign's
/// YYYSourceManager fileTypeWithPath:, rather than treating every directory alike.
public enum WorkspaceFileKind: String, Codable, Sendable {
  case folder, app, framework, dylib, ipa, archive, profile, identity, plist, text, preview, binary
}

public enum FileBehavior {
  public static func executable(in bundle: URL) -> URL? {
    let candidates = [bundle.appendingPathComponent("Info.plist"), bundle.appendingPathComponent("Resources/Info.plist"), bundle.appendingPathComponent("Versions/Current/Resources/Info.plist")]
    for info in candidates {
      if let data = try? Data(contentsOf: info),
        let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
        let name = dict["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), name != ".." {
        for file in [bundle.appendingPathComponent(name), bundle.appendingPathComponent("Versions/Current/" + name)] {
          if FileManager.default.fileExists(atPath: file.path) { return file }
        }
      }
    }
    return nil
  }
  public static func kind(of url: URL) -> WorkspaceFileKind {
    let ext = url.pathExtension.lowercased()
    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      if ext == "framework", let file = executable(in: url), MachOInspector.hasMachOMagic(file) { return .framework }
      if ["app", "appex"].contains(ext), let file = executable(in: url), MachOInspector.hasMachOMagic(file) { return .app }
      return .folder
    }
    if MachOInspector.hasMachOMagic(url) { return .dylib }
    if url.lastPathComponent.lowercased().hasSuffix(".ipa.rename") { return .ipa }
    switch ext {
    case "ipa", "tipa": return .ipa
    case "zip", "deb", "tar", "gz", "xz", "bz2", "7z", "rar": return .archive
    case "mobileprovision", "provisionprofile": return .profile
    case "p12", "pfx": return .identity
    case "plist", "xml", "entitlements": return .plist
    case "txt", "md", "json", "strings", "log", "swift", "h", "m", "html", "css", "js", "yml", "yaml": return .text
    case "png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp", "pdf", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "flac",
      "doc", "docx", "rtf", "ppt", "pptx", "pps", "ppsx", "xls", "xlsx", "pages", "numbers", "key": return .preview
    default:
      guard let file = try? FileHandle(forReadingFrom: url) else { return .binary }
      defer { try? file.close() }
      guard let data = try? file.read(upToCount: 16384) else { return .binary }
      let bytes = [UInt8](data.prefix(8))
      if bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) || bytes.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])
        || bytes.starts(with: [0x52, 0x61, 0x72, 0x21]) || bytes.starts(with: [0x1f, 0x8b])
        || bytes.starts(with: [0x42, 0x5a, 0x68]) || bytes.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00])
        || bytes.starts(with: Array("!<arch>\n".utf8)) { return .archive }
      if data.count >= 262, data[257..<262] == Data("ustar".utf8) { return .archive }
      if bytes.starts(with: [0xff, 0xfe]) || bytes.starts(with: [0xfe, 0xff]) { return .text }
      if !data.contains(0), let value = String(data: data, encoding: .utf8),
        value.unicodeScalars.allSatisfy({ $0.value >= 32 || [9, 10, 13].contains($0.value) }) { return .text }
      return .binary
    }
  }
}
