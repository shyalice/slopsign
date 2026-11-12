import Foundation
import SignerArchive

/// Extracts tar/compressed tar/ar/7z using the OS libarchive, into staging only.
/// Archive names never become unchecked paths, links or device nodes.
public enum ArchiveExtractor {
  public static func extract(_ source: URL, to destination: URL, progress: Progress? = nil) throws {
    guard let reader = archive_read_new() else { throw SignerError("Unable to open archive.") }
    defer { archive_read_free(reader) }
    archive_read_support_filter_all(reader)
    archive_read_support_format_all(reader)
    func failure() -> SignerError {
      SignerError(archive_error_string(reader).map { String(cString: $0) } ?? "Unable to read archive.")
    }
    guard archive_read_open_filename(reader, source.path, 65536) == 0 else { throw failure() }
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    var successful = false
    defer { if !successful { try? fm.removeItem(at: destination) } }
    var entry: OpaquePointer?
    var total: Int64 = 0
    var count = 0
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      try FileTransfer.check(progress)
      let code = archive_read_next_header(reader, &entry)
      if code == 1 { break }
      guard code == 0, let entry, let raw = archive_entry_pathname(entry) else { throw failure() }
      let name = String(cString: raw)
      let parts = name.split(separator: "/", omittingEmptySubsequences: true)
      guard !name.hasPrefix("/"), !name.contains("\\"), !parts.contains(".."),
        archive_entry_symlink(entry) == nil, archive_entry_hardlink(entry) == nil else {
        throw SignerError("The archive contains an unsafe path or link: \(name)")
      }
      count += 1
      guard count <= 200_000 else { throw SignerError("The archive contains too many files.") }
      let path = destination.appendingPathComponent(parts.filter { $0 != "." }.joined(separator: "/"))
      let type = archive_entry_filetype(entry) & 0xf000
      if type == 0x4000 { try fm.createDirectory(at: path, withIntermediateDirectories: true); continue }
      guard type == 0x8000 else { throw SignerError("Unsupported archive member: \(name)") }
      let expected = archive_entry_size(entry)
      guard expected >= 0, expected <= 20_000_000_000, total <= 20_000_000_000 - expected else {
        throw SignerError("The archive is too large to extract.")
      }
      total += expected
      try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard fm.createFile(atPath: path.path, contents: nil) else { throw SignerError("Unable to create \(name).") }
      let file = try FileHandle(forWritingTo: path)
      do {
        var written: Int64 = 0
        while true {
          try FileTransfer.check(progress)
          let bytes = archive_read_data(reader, &buffer, buffer.count)
          guard bytes >= 0 else { throw failure() }
          if bytes == 0 { break }
          written += Int64(bytes)
          guard written <= expected else { throw SignerError("Invalid archive member size.") }
          try file.write(contentsOf: Data(buffer.prefix(bytes)))
        }
        try file.close()
        guard written == expected else { throw SignerError("Truncated archive member: \(name)") }
      } catch { try? file.close(); throw error }
    }
    successful = true
  }
}

extension Workspace {
  public func libraries(inDeb source: URL, staging: URL, progress: Progress? = nil) throws -> [URL] {
    let ar = staging.appendingPathComponent("ar")
    try ArchiveExtractor.extract(source, to: ar, progress: progress)
    guard let data = try fm.contentsOfDirectory(at: ar, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("data.tar") }) else {
      throw SignerError("The DEB package has no data archive.")
    }
    let payload = staging.appendingPathComponent("data")
    try ArchiveExtractor.extract(data, to: payload, progress: progress)
    var libraries: [URL] = []
    if let entries = fm.enumerator(at: payload, includingPropertiesForKeys: [.isDirectoryKey]) {
      for case let url as URL in entries {
        try FileTransfer.check(progress)
        let kind = FileBehavior.kind(of: url)
        if kind == .framework { libraries.append(url); entries.skipDescendants() }
        else if kind == .dylib { libraries.append(url) }
      }
    }
    guard !libraries.isEmpty else { throw SignerError("No dynamic libraries or frameworks were found in this DEB package.") }
    return libraries.sorted { $0.path < $1.path }
  }
}
