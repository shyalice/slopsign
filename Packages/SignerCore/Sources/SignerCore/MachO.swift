import Foundation

public enum MachOInspector {
  /// Matches ESign checkIsDylibFile:, which checks Mach-O magic, not MH_DYLIB.
  /// This also exposes executable Mach-O files to Class Dump/dependency tools.
  public static func hasMachOMagic(_ url: URL) -> Bool {
    guard let file = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 4), data.count == 4 else { return false }
    let magic = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[$1]) << ($1 * 8) }
    return [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic)
  }
  public static func isEncrypted(_ url: URL) throws -> Bool {
    let d = try Data(contentsOf: url, options: .mappedIfSafe)
    func u32(_ p: Int, _ big: Bool = false) -> UInt32? {
      guard p >= 0, p + 4 <= d.count else { return nil }
      return (0..<4).reduce(UInt32(0)) { r, i in r | UInt32(d[p + i]) << (big ? (3 - i) * 8 : i * 8)
      }
    }
    func slice(_ base: Int) throws -> Bool {
      guard let magic = u32(base) else { throw SignerError("Invalid Mach-O file.") }
      let big = magic == 0xcefa_edfe || magic == 0xcffa_edfe
      let is64 = magic == 0xfeed_facf || magic == 0xcffa_edfe
      guard [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe].contains(magic),
        let n = u32(base + 16, big), let size = u32(base + 20, big), n < 100_000
      else { throw SignerError("The executable is not a valid Mach-O file.") }
      var p = base + (is64 ? 32 : 28)
      let end = p + Int(size)
      guard end <= d.count else { throw SignerError("Invalid Mach-O load commands.") }
      for _ in 0..<n {
        guard let cmd = u32(p, big), let length = u32(p + 4, big), length >= 8,
          p + Int(length) <= end
        else { throw SignerError("Invalid Mach-O load commands.") }
        if cmd == 0x21 || cmd == 0x2c {
          guard length >= 20, let crypt = u32(p + 16, big) else {
            throw SignerError("Invalid encryption load command.")
          }
          if crypt != 0 { return true }
        }
        p += Int(length)
      }
      return false
    }
    guard let magic = u32(0) else { throw SignerError("The executable is empty.") }
    if magic == 0xbeba_feca || magic == 0xbfba_feca {
      guard let count = u32(4, true), count > 0, count <= 64 else {
        throw SignerError("Invalid Fat Mach-O.")
      }
      let is64 = magic == 0xbfba_feca
      for i in 0..<Int(count) {
        let p = 8 + i * (is64 ? 32 : 20)
        guard let off = u32(p + 8, true) else { throw SignerError("Invalid Fat Mach-O.") }
        let offset: Int
        if is64 {
          guard let low = u32(p + 12, true), off == 0 else {
            throw SignerError("Mach-O exceeds the supported size.")
          }
          offset = Int(low)
        } else {
          offset = Int(off)
        }
        if try slice(offset) { return true }
      }
      return false
    }
    return try slice(0)
  }
}
