import SignerCore
import UIKit

actor AppIconCache {
  static let shared = AppIconCache()
  private var cache: [String: Data] = [:]
  func data(for url: URL) -> Data? {
    let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let key = url.path + ":" + String(attributes?.fileSize ?? 0) + ":" + String(attributes?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    if let value = cache[key] { return value }
    var icon = try? AppBundleMetadata.read(url).icon
    if icon == nil, let bundle = Bundle(url: url),
      let info = bundle.infoDictionary {
      let primary = (info["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
      let names = [primary?["CFBundleIconName"] as? String, info["CFBundleIconName"] as? String, "AppIcon"].compactMap { $0 }
      for name in names {
        if let image = UIImage(named: name, in: bundle, compatibleWith: nil), let data = image.pngData() { icon = data; break }
      }
    }
    guard let icon else { return nil }
    if cache.count >= 32 { cache.removeAll(keepingCapacity: true) }
    cache[key] = icon
    return icon
  }
}
