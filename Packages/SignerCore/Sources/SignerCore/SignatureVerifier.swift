import CryptoKit
import Foundation
import SignerCrypto

/// Validates page hashes, special slots and the detached CMS. Device trust is enforced by iOS at install.
public enum SignatureVerifier {
  public static func verify(executable: URL, infoPlist: URL?, resources: URL?, certificate: Data)
    throws
  {
    let data = try Data(contentsOf: executable, options: .mappedIfSafe)
    func read(_ p: Int, big: Bool = false) throws -> UInt32 {
      guard p >= 0, p <= data.count - 4 else { throw SignerError("Invalid Mach-O structure.") }
      return (0..<4).reduce(UInt32(0)) {
        $0 | UInt32(data[p + $1]) << (big ? (3 - $1) * 8 : $1 * 8)
      }
    }
    func slice(base: Int, length: Int) throws {
      let magic = try read(base)
      let big = magic == 0xcffa_edfe || magic == 0xcefa_edfe
      guard [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe].contains(magic) else {
        throw SignerError("Unsupported Mach-O format.")
      }
      let n = try read(base + 16, big: big)
      let commands = try read(base + 20, big: big)
      var p = base + ((magic == 0xfeed_facf || magic == 0xcffa_edfe) ? 32 : 28)
      let end = p + Int(commands)
      guard end <= base + length, n < 100_000 else { throw SignerError("Invalid Mach-O file.") }
      var signature: (Int, Int)?
      for _ in 0..<n {
        let cmd = try read(p, big: big)
        let size = Int(try read(p + 4, big: big))
        guard size >= 8, p + size <= end else { throw SignerError("Invalid Mach-O load commands.") }
        if cmd == 0x1d {
          guard size >= 16 else { throw SignerError("Invalid LC_CODE_SIGNATURE.") }
          signature = (Int(try read(p + 8, big: big)), Int(try read(p + 12, big: big)))
        }
        p += size
      }
      guard let (offset, size) = signature, offset >= 0, size >= 12, offset + size <= length else {
        throw SignerError("The Mach-O signature is missing.")
      }
      let start = base + offset
      guard try read(start, big: true) == 0xfade_0cc0 else {
        throw SignerError("Invalid signature container.")
      }
      let total = Int(try read(start + 4, big: true))
      let count = Int(try read(start + 8, big: true))
      guard total <= size, count < 1000, 12 + count * 8 <= total else {
        throw SignerError("Invalid signature container.")
      }
      var slots: [UInt32: Data] = [:]
      for i in 0..<count {
        let type = try read(start + 12 + i * 8, big: true)
        let relative = Int(try read(start + 16 + i * 8, big: true))
        guard relative >= 12 + count * 8, relative <= total - 8 else {
          throw SignerError("Invalid signature slot.")
        }
        let length = Int(try read(start + relative + 4, big: true))
        guard length >= 8, relative + length <= total, slots[type] == nil else {
          throw SignerError("Invalid signature slot.")
        }
        slots[type] = data.subdata(in: start + relative..<start + relative + length)
      }
      guard let primary = slots[0], let cms = slots[0x10000], cms.count > 8 else {
        throw SignerError("CMS or CodeDirectory is missing.")
      }
      if let der = slots[7] {
        guard let xml = slots[5],
          let expected = try PropertyListSerialization.propertyList(from: Data(xml.dropFirst(8)), format: nil) as? [String: Any],
          NSDictionary(dictionary: try DEREntitlements.decode(Data(der.dropFirst(8)))).isEqual(to: expected) else {
          throw SignerError("XML and DER entitlements do not match.")
        }
      } else if try read(base + 12, big: big) == 2 {
        throw SignerError("The executable is missing DER entitlements.")
      }
      var error: NSError?
      guard let plist = SGVerifyCodeCMS(Data(cms.dropFirst(8)), primary, certificate, &error),
        let hashes =
          (try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])?[
            "cdhashes"] as? [Data]
      else { throw error ?? SignerError("Error CMS.") as NSError }
      let directories = slots.filter { $0.key == 0 || (0x1000...0x1005).contains($0.key) }.sorted {
        $0.key < $1.key
      }
      for (type, cd) in directories {
        func r(_ p: Int) throws -> Int {
          guard p >= 0, p <= cd.count - 4 else { throw SignerError("Invalid CodeDirectory.") }
          return (0..<4).reduce(0) { ($0 << 8) | Int(cd[p + $1]) }
        }
        guard cd.count >= 44, try r(0) == 0xfade_0c02 else {
          throw SignerError("Invalid CodeDirectory.")
        }
        let hashOffset = try r(16)
        let special = try r(24)
        let pages = try r(28)
        let limit = try r(32)
        let hashSize = Int(cd[36])
        let hashType = cd[37]
        let pagePower = Int(cd[39])
        guard [1, 2].contains(hashType), hashSize == (hashType == 1 ? 20 : 32), special < 1000,
          pages < 10_000_000, pagePower <= 20, limit <= offset, hashOffset >= special * hashSize,
          hashOffset + pages * hashSize <= cd.count
        else { throw SignerError("Invalid CodeDirectory parameters.") }
        func hash(_ d: Data) -> Data {
          hashType == 1 ? Data(Insecure.SHA1.hash(data: d)) : Data(SHA256.hash(data: d))
        }
        let cdHash = Data(
          hashType == 1
            ? Data(Insecure.SHA1.hash(data: cd)) : Data(SHA256.hash(data: cd)).prefix(20))
        guard hashes.contains(cdHash) else {
          throw SignerError("CodeDirectory does not match authenticated CMS cdhashes (\(type)).")
        }
        let pageSize = 1 << pagePower
        guard pages == (limit + pageSize - 1) / pageSize else {
          throw SignerError("Invalid signature page count.")
        }
        for page in 0..<pages {
          let expected = cd.subdata(
            in: hashOffset + page * hashSize..<hashOffset + (page + 1) * hashSize)
          let actual = hash(
            data.subdata(in: base + page * pageSize..<base + min(limit, (page + 1) * pageSize)))
          guard expected == actual else {
            throw SignerError("Signature page hash mismatch at page \(page).")
          }
        }
        for (slot, payload) in [
          (1, try infoPlist.map { try Data(contentsOf: $0) }), (2, slots[2]),
          (3, try resources.map { try Data(contentsOf: $0) }), (5, slots[5]), (7, slots[7]),
        ] {
          guard let payload, slot <= special else { continue }
          let expected = cd.subdata(
            in: hashOffset - slot * hashSize..<hashOffset - (slot - 1) * hashSize)
          guard expected == hash(payload) else {
            throw SignerError("Signature special slot hash mismatch at slot \(slot).")
          }
        }
      }
    }
    let magic = try read(0)
    if magic == 0xbeba_feca || magic == 0xbfba_feca {
      let count = Int(try read(4, big: true))
      let is64 = magic == 0xbfba_feca
      guard count > 0, count <= 64 else { throw SignerError("Invalid Fat Mach-O.") }
      for i in 0..<count {
        let p = 8 + i * (is64 ? 32 : 20)
        let offset: Int
        let length: Int
        if is64 {
          guard try read(p + 8, big: true) == 0, try read(p + 16, big: true) == 0 else {
            throw SignerError("Mach-O is too large.")
          }
          offset = Int(try read(p + 12, big: true))
          length = Int(try read(p + 20, big: true))
        } else {
          offset = Int(try read(p + 8, big: true))
          length = Int(try read(p + 12, big: true))
        }
        guard offset >= 0, length > 0, offset + length <= data.count else {
          throw SignerError("Invalid Fat Mach-O.")
        }
        try slice(base: offset, length: length)
      }
    } else {
      try slice(base: 0, length: data.count)
    }
  }
}
