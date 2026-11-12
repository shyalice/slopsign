import SignerCore
import UIKit

actor AppIconCache {
  static let shared = AppIconCache()
  private var cache: [String: Data] = [:]
  func data(for url: URL) -> Data? {
    let attributes = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let key = url.path + ":" + String(attributes?.fileSize ?? 0) + ":" + String(attributes?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    if let value = cache[key] { return value }
    guard let icon = try? AppBundleMetadata.read(url).icon else { return nil }
    if cache.count >= 32 { cache.removeAll(keepingCapacity: true) }
    cache[key] = icon
    return icon
  }
}
