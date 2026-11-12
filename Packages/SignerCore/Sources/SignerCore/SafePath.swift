import Foundation

public enum SafePath {
  /// Resolve every existing symlink, including ancestors of a not-yet-created file.
  public static func canonical(_ url: URL, hops: Int = 0) throws -> URL {
    guard hops < 40 else { throw SignerError("Too many symbolic links in the path.") }
    var result = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
      if component == "." { continue }
      if component == ".." {
        result = result.deletingLastPathComponent()
        continue
      }
      let candidate = result.appendingPathComponent(component)
      if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
        result = try canonical(
          target.hasPrefix("/")
            ? URL(fileURLWithPath: target) : result.appendingPathComponent(target), hops: hops + 1)
      } else {
        result = candidate
      }
    }
    return result
  }
}
