import Foundation
import ZIPFoundation
import SignerArchive

/// Native file loops report in batches, avoiding a Progress/KVO object per file.
enum NativeFiles {
  private final class Context {
    let progress: Progress?
    init(_ progress: Progress?) { self.progress = progress }
  }
  static func run(progress: Progress?, _ operation: (SGArchiveProgress, UnsafeMutableRawPointer, UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
    try FileTransfer.check(progress)
    let context = Unmanaged.passRetained(Context(progress))
    defer { context.release() }
    var error = [CChar](repeating: 0, count: 1024)
    let result = operation({ done, total, opaque in
      guard let opaque else { return 1 }
      let progress = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue().progress
      if progress?.isCancelled == true { return 1 }
      if total > 0 {
        progress?.totalUnitCount = Int64(total)
        progress?.completedUnitCount = Int64(done)
      }
      return progress?.isCancelled == true ? 1 : 0
    }, context.toOpaque(), &error, error.count)
    if result == 2 { throw CancellationError() }
    if result == 3 { throw Archive.ArchiveError.invalidCRC32 }
    if result != 0 { throw SignerError(String(cString: error)) }
    try FileTransfer.check(progress)
  }
  static func clone(_ source: URL, to destination: URL, progress: Progress?) throws {
    do {
      try run(progress: progress) { callback, context, error, count in
        SGCloneTree(source.path, destination.path, callback, context, error, count)
      }
    } catch { try? FileManager.default.removeItem(at: destination); throw error }
  }
  static func remove(_ source: URL, progress: Progress?) throws {
    try run(progress: progress) { callback, context, error, count in
      SGRemoveTree(source.path, callback, context, error, count)
    }
  }
  static func extract(_ source: URL, to destination: URL, progress: Progress?) throws {
    do {
      try run(progress: progress) { callback, context, error, count in
        SGExtractZIP(source.path, destination.path, callback, context, error, count)
      }
    } catch { try? FileManager.default.removeItem(at: destination); throw error }
  }
}
