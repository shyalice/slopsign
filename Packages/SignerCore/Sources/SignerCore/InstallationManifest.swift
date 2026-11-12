import Foundation

/// ESign's pre-published manifest points only at the device's loopback server.
/// It never uploads IPA data, signing identities or passwords to a server.
public enum InstallationManifest {
  public static func data(metadata: AppBundleMetadata, baseURL: URL, hasIcon: Bool, installationID: UUID? = nil) throws -> Data {
    func asset(_ path: String) -> String {
      var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
      if let installationID { components.queryItems = [URLQueryItem(name: "installation", value: installationID.uuidString)] }
      return components.url!.absoluteString
    }
    var assets: [[String: Any]] = [["kind": "software-package", "url": asset("app0.ipa")]]
    if hasIcon {
      for kind in ["display-image", "full-size-image"] { assets.append(["kind": kind, "url": asset("app0.png")]) }
    }
    return try PropertyListSerialization.data(fromPropertyList: ["items": [[
      "assets": assets, "metadata": ["kind": "software", "bundle-identifier": metadata.identifier, "bundle-version": metadata.build, "title": metadata.title]
    ]]], format: .xml, options: 0)
  }
  public static let primary = URL(string: "https://raw.githubusercontent.com/276523923/plist/2/app0.plist")!
  public static let fallback = URL(string: "https://gitee.com/yyyue/plist/raw/2/app0.plist")!
  public static func validate(_ data: Data) throws {
    guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let items = plist["items"] as? [[String: Any]], items.count == 1,
      let assets = items[0]["assets"] as? [[String: Any]],
      assets.contains(where: { $0["kind"] as? String == "software-package" && $0["url"] as? String == "http://127.0.0.1:14302/app0.ipa" }) else {
      throw SignerError("The installation manifest is unavailable or has changed.")
    }
    for asset in assets {
      guard let value = asset["url"] as? String, let url = URL(string: value), url.scheme == "http",
        url.host == "127.0.0.1", url.port == 14302, ["/app0.ipa", "/app0.png"].contains(url.path), url.query == nil else {
        throw SignerError("The installation manifest contains an unexpected asset URL.")
      }
    }
  }
  public static func serviceURL(manifest: URL) throws -> URL {
    guard manifest.scheme == "https", manifest.host != nil else { throw SignerError("Invalid installation manifest URL.") }
    var url = URLComponents()
    url.scheme = "itms-services"
    // An empty authority is significant: iOS expects itms-services://?…
    url.host = ""
    url.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: manifest.absoluteString)]
    guard let result = url.url else { throw SignerError("Unable to create the installation URL.") }
    return result
  }
}
