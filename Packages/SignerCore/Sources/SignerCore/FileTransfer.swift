import Foundation
import ZIPFoundation
import Darwin

public enum FileTransfer {
  public static func check(_ progress: Progress?) throws {
    if progress?.isCancelled == true { throw CancellationError() }
  }
  public static func isCancelled(_ error: Error) -> Bool {
    error is CancellationError || (error as? Archive.ArchiveError) == .cancelledOperation
  }
  /// Read provider data instead of cloning a potentially unmaterialized placeholder.
  /// The original coordinated URL, including its access grant, is used for reads.
  public static func copy(_ source: URL, to destination: URL, progress: Progress? = nil, preferClone: Bool = false) throws {
    let fm = FileManager.default
    try check(progress)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    let root = try source.resourceValues(forKeys: keys)
    if preferClone {
      guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
      try NativeFiles.clone(try SafePath.canonical(source), to: destination, progress: progress)
      return
    }
    let sourcePaths = [source.path, try SafePath.canonical(source).path]
    func suffix(_ entry: URL) throws -> String {
      if entry == source { return "" }
      guard let prefix = sourcePaths.first(where: { entry.path.hasPrefix($0 + "/") }) else {
        throw SignerError("A copied item is outside its source directory.")
      }
      return String(entry.path.dropFirst(prefix.count))
    }
    var entries = [source]
    if root.isDirectory == true, root.isSymbolicLink != true {
      var enumerationError: Error?
      guard let iterator = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys),
        errorHandler: { _, error in enumerationError = error; return false })
      else { throw SignerError("Unable to read the selected folder.") }
      entries += iterator.compactMap { $0 as? URL }
      if let enumerationError { throw enumerationError }
    }
    progress?.totalUnitCount = max(1, try entries.reduce(Int64(0)) { sum, entry in
      let v = try entry.resourceValues(forKeys: keys)
      return sum + (v.isDirectory == true || v.isSymbolicLink == true ? 1 : max(1, Int64(v.fileSize ?? 0)))
    })
    guard (try? fm.attributesOfItem(atPath: destination.path)) == nil else {
      throw CocoaError(.fileWriteFileExists)
    }
    do {
      for entry in entries {
        try check(progress)
        let relative = try suffix(entry)
        let target = relative.isEmpty ? destination : destination.appendingPathComponent(String(relative.dropFirst()))
        let v = try entry.resourceValues(forKeys: keys)
        if v.isSymbolicLink == true {
          try fm.copyItem(at: entry, to: target)
          progress?.completedUnitCount += 1
        } else if v.isDirectory == true {
          try fm.createDirectory(at: target, withIntermediateDirectories: true)
          progress?.completedUnitCount += 1
        } else {
          // Provider imports must read materialized bytes; only app-owned
          // sources opt into copy-on-write cloning.
          if preferClone && clonefile(entry.path, target.path, 0) == 0 {
            progress?.completedUnitCount += max(1, Int64(v.fileSize ?? 0))
            try check(progress)
            continue
          }
          let input = try FileHandle(forReadingFrom: entry)
          defer { try? input.close() }
          guard fm.createFile(atPath: target.path, contents: nil) else {
            throw SignerError("Unable to create the imported file.")
          }
          let output = try FileHandle(forWritingTo: target)
          defer { try? output.close() }
          var written: Int64 = 0
          while true {
            try check(progress)
            let data = try input.read(upToCount: 512 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            written += Int64(data.count)
            progress?.completedUnitCount += Int64(data.count)
          }
          if let expected = v.fileSize, written != Int64(expected) {
            throw SignerError("The file provider returned an incomplete file. Download it fully and try importing again.")
          }
          if written == 0 { progress?.completedUnitCount += 1 }
        }
        if let permissions = try fm.attributesOfItem(atPath: entry.path)[.posixPermissions],
          v.isSymbolicLink != true, v.isDirectory != true {
          try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
      }
      for entry in entries.reversed() {
        let v = try entry.resourceValues(forKeys: keys)
        guard v.isDirectory == true, v.isSymbolicLink != true else { continue }
        let relative = try suffix(entry)
        let target = relative.isEmpty ? destination : destination.appendingPathComponent(String(relative.dropFirst()))
        if let permissions = try fm.attributesOfItem(atPath: entry.path)[.posixPermissions] {
          try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
        }
      }
      try check(progress)
    } catch {
      try? fm.removeItem(at: destination)
      throw error
    }
  }
  public static func message(for error: Error) -> String {
    if let archive = error as? Archive.ArchiveError {
      switch archive {
      case .missingEndOfCentralDirectoryRecord, .unreadableArchive:
        return "The ZIP or IPA is incomplete or cannot be read. Import the complete file again."
      case .invalidCRC32: return "The archive contains damaged data (checksum mismatch)."
      case .invalidCompressionMethod: return "This archive uses an unsupported compression method."
      default: return "Unable to read the ZIP or IPA archive."
      }
    }
    return error.localizedDescription
  }
}
