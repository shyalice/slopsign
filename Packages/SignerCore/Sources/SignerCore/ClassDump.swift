import Foundation

/// Reads Objective-C metadata without loading or executing the inspected code.
/// Swift-only types and types stripped from the binary cannot be reconstructed.
public enum ClassDump {
  public static func headers(for executable: URL, progress: Progress? = nil) throws -> String {
    guard try !MachOInspector.isEncrypted(executable) else { throw SignerError("Class Dump requires a decrypted executable.") }
    let image = try Image(data: Data(contentsOf: executable, options: .mappedIfSafe))
    let classes = image.sections.filter { $0.name == "__objc_classlist" }
    var declarations: [String] = []
    for section in classes {
      for offset in stride(from: section.offset, to: section.offset + section.size, by: 8) {
        try FileTransfer.check(progress)
        guard let pointer = image.u64(offset), let cls = image.fileOffset(pointer),
          let ro = image.classRO(cls), let namePointer = image.u64(ro + 24),
          let name = image.string(namePointer), !name.isEmpty else { continue }
        var superclass = "NSObject"
        if let sup = image.u64(cls + 8), let target = image.fileOffset(sup), let supRO = image.classRO(target),
          let name = image.u64(supRO + 24).flatMap(image.string) { superclass = name }
        var lines = ["@interface \(name) : \(superclass)"]
        if let methods = image.u64(ro + 32) { lines += image.methods(methods, prefix: "-") }
        if let isa = image.u64(cls), let meta = image.fileOffset(isa), let metaRO = image.classRO(meta),
          let methods = image.u64(metaRO + 32) { lines += image.methods(methods, prefix: "+") }
        if let properties = image.u64(ro + 64), let p = image.fileOffset(properties),
          let size = image.u32(p), let count = image.u32(p + 4), size >= 16, size <= 1024, count < 100_000 {
          for index in 0..<Int(count) {
            let entry = p + 8 + index * Int(size)
            if let name = image.u64(entry).flatMap(image.string), let attributes = image.u64(entry + 8).flatMap(image.string) {
              lines.append("// property \(name): \(attributes)")
            }
          }
        }
        lines.append("@end")
        declarations.append(lines.joined(separator: "\n"))
      }
    }
    guard !declarations.isEmpty else { throw SignerError("No readable Objective-C classes were found in this executable.") }
    return "// Objective-C metadata from \(executable.lastPathComponent)\n// Type encodings are preserved in comments; id is used for unresolved types.\n\n#import <Foundation/Foundation.h>\n\n" + declarations.sorted().joined(separator: "\n\n") + "\n"
  }

  private struct Image {
    struct Segment { let address: UInt64; let offset: Int; let size: Int }
    struct Section { let name: String; let offset: Int; let size: Int }
    let data: Data
    var base = 0
    var segments: [Segment] = []
    var sections: [Section] = []
    init(data: Data) throws {
      self.data = data
      guard let magic = u32(0) else { throw SignerError("Invalid Mach-O.") }
      if magic == 0xbeba_feca || magic == 0xbfba_feca {
        guard let n = u32(4, big: true), n > 0, n <= 64 else { throw SignerError("Invalid Fat Mach-O.") }
        var chosen: Int?
        for index in 0..<Int(n) {
          let p = 8 + index * (magic == 0xbfba_feca ? 32 : 20)
          guard let cpu = u32(p, big: true), let high = u32(p + 8, big: true) else { continue }
          let offset: UInt64
          if magic == 0xbfba_feca { offset = UInt64(high) << 32 | UInt64(u32(p + 12, big: true) ?? 0) }
          else { offset = UInt64(high) }
          guard offset < data.count else { continue }
          if chosen == nil || cpu == 0x100000c { chosen = Int(offset) }
          if cpu == 0x100000c { break }
        }
        guard let chosen else { throw SignerError("No supported Mach-O architecture.") }
        base = chosen
      }
      guard u32(base) == 0xfeedfacf, let count = u32(base + 16), let size = u32(base + 20), count <= 100_000,
        base + 32 + Int(size) <= data.count else { throw SignerError("Class Dump currently supports 64-bit little-endian Mach-O binaries.") }
      var p = base + 32
      let end = p + Int(size)
      for _ in 0..<count {
        guard let cmd = u32(p), let size = u32(p + 4), size >= 8, p + Int(size) <= end else { throw SignerError("Invalid Mach-O load commands.") }
        if cmd == 0x19, size >= 72, let address = u64(p + 24), let offset = u64(p + 40), let fileSize = u64(p + 48),
          offset <= data.count, fileSize <= data.count, offset + fileSize <= data.count - base {
          segments.append(Segment(address: address, offset: base + Int(offset), size: Int(fileSize)))
          if let n = u32(p + 64), n <= (size - 72) / 80 {
            for i in 0..<Int(n) {
              let s = p + 72 + i * 80
              let name = String(decoding: data[s..<s + 16].prefix { $0 != 0 }, as: UTF8.self)
              if let length = u64(s + 40), let off = u32(s + 48), length <= data.count,
                base + Int(off) + Int(length) <= data.count {
                sections.append(Section(name: name, offset: base + Int(off), size: Int(length)))
              }
            }
          }
        }
        p += Int(size)
      }
    }
    func u32(_ p: Int, big: Bool = false) -> UInt32? {
      guard p >= 0, p <= data.count - 4 else { return nil }
      return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[p + $1]) << (big ? (3 - $1) * 8 : $1 * 8) }
    }
    func u64(_ p: Int) -> UInt64? {
      guard let low = u32(p), let high = u32(p + 4) else { return nil }
      return UInt64(low) | UInt64(high) << 32
    }
    func fileOffset(_ raw: UInt64) -> Int? {
      guard raw != 0 else { return nil }
      // dyld chained rebases retain the target in the low 36 bits. Bind entries
      // refer to external symbols and must not be interpreted as local addresses.
      if raw & (1 << 63) != 0 { return nil }
      let target = raw & 0x0000000fffffffff
      for candidate in [raw, target, target + (segments.first?.address ?? 0)] {
        for segment in segments where candidate >= segment.address && candidate - segment.address < UInt64(segment.size) {
          return segment.offset + Int(candidate - segment.address)
        }
      }
      return nil
    }
    func string(_ pointer: UInt64) -> String? {
      guard let offset = fileOffset(pointer) else { return nil }
      let bytes = data[offset..<min(data.count, offset + 8192)].prefix { $0 != 0 }
      return String(data: Data(bytes), encoding: .utf8)
    }
    func stringAt(_ offset: Int) -> String? {
      guard offset >= 0, offset < data.count else { return nil }
      return String(data: Data(data[offset..<min(data.count, offset + 8192)].prefix { $0 != 0 }), encoding: .utf8)
    }
    func classRO(_ offset: Int) -> Int? { u64(offset + 32).flatMap { fileOffset($0 & ~UInt64(7)) } }
    func methods(_ pointer: UInt64, prefix: String) -> [String] {
      guard let p = fileOffset(pointer), let flags = u32(p), let count = u32(p + 4), count < 100_000 else { return [] }
      let relative = flags & 0x80000000 != 0
      let direct = flags & 0x40000000 != 0
      let size = Int(flags & 0x0000fffc)
      guard size >= (relative ? 12 : 24), size < 1024 else { return [] }
      var result: [String] = []
      for index in 0..<Int(count) {
        let entry = p + 8 + index * size
        let name: String?; let encoding: String?
        if relative {
          guard let delta = u32(entry), let typeDelta = u32(entry + 4) else { continue }
          let target = entry + Int(Int32(bitPattern: delta))
          name = direct ? stringAt(target) : u64(target).flatMap(string)
          encoding = stringAt(entry + 4 + Int(Int32(bitPattern: typeDelta)))
        } else { name = u64(entry).flatMap(string); encoding = u64(entry + 8).flatMap(string) }
        guard let name, !name.isEmpty else { continue }
        let parts = name.split(separator: ":", omittingEmptySubsequences: false)
        let declaration = parts.count == 1 ? name : parts.dropLast().enumerated().map { "\($0.element):(id)arg\($0.offset + 1)" }.joined(separator: " ")
        result.append("\(prefix) (id)\(declaration); // \(encoding ?? "unknown type encoding")")
      }
      return result
    }
  }
}

extension Workspace {
  public func dumpClasses(_ url: URL, progress: Progress? = nil) throws -> URL {
    let source = try confined(url)
    let executable = FileBehavior.executable(in: source) ?? source
    _ = try confined(executable, to: source == executable ? root : source)
    let headers = try ClassDump.headers(for: executable, progress: progress)
    try FileTransfer.check(progress)
    let target = unique(source.deletingPathExtension().lastPathComponent + "-Headers.h", in: source.deletingLastPathComponent())
    try Data(headers.utf8).write(to: target, options: .atomic)
    return target
  }
}
