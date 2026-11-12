import Foundation
import SignerArchive

/// The MiniZip/zlib path used by ESign, with one native filesystem walk and
/// batched progress callbacks rather than Foundation metadata per ZIP member.
enum IPAArchive {
  static func write(payload: URL, to destination: URL, compressed: Bool, progress: Progress?) throws {
    let payload = try SafePath.canonical(payload)
    do {
      try NativeFiles.run(progress: progress) { callback, context, error, count in
        SGWriteZIP(payload.path, destination.path, compressed ? 1 : 0, callback, context, error, count)
      }
    } catch { try? FileManager.default.removeItem(at: destination); throw error }
  }
}
