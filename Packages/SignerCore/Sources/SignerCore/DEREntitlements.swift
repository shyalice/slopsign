import Foundation

/// Decode the versioned CoreEntitlements payload rather than merely hashing it.
/// A valid CMS can authenticate malformed DER, which iOS then refuses to use.
public enum DEREntitlements {
  public static func decode(_ data: Data) throws -> [String: Any] {
    guard data.count <= 1_048_576 else { throw SignerError("DER entitlements are too large.") }
    var outer = Reader(bytes: Array(data))
    let root = try outer.element()
    guard root.tag == 0x70, outer.finished else { throw invalid() }
    var body = Reader(bytes: root.bytes)
    let version = try body.element()
    guard version.tag == 0x02, version.bytes == [1],
      let dictionary = try body.value(depth: 0) as? [String: Any], body.finished else { throw invalid() }
    return dictionary
  }
  private static func invalid() -> SignerError { SignerError("Invalid DER entitlements in the code signature.") }
  private struct Reader {
    let bytes: [UInt8]
    var offset = 0
    var finished: Bool { offset == bytes.count }
    mutating func element() throws -> (tag: UInt8, bytes: [UInt8]) {
      guard offset + 2 <= bytes.count else { throw invalid() }
      let tag = bytes[offset]; offset += 1
      let first = Int(bytes[offset]); offset += 1
      var length = first
      if first & 0x80 != 0 {
        let count = first & 0x7f
        guard count > 0, count <= 4, count <= bytes.count - offset,
          bytes[offset] != 0 else { throw invalid() }
        length = 0
        for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
        guard length >= 128 else { throw invalid() }
      }
      guard length <= bytes.count - offset else { throw invalid() }
      let contents = Array(bytes[offset..<(offset + length)])
      offset += length
      return (tag, contents)
    }
    mutating func value(depth: Int) throws -> Any {
      guard depth < 32 else { throw invalid() }
      let element = try element()
      switch element.tag {
      case 0x01:
        guard element.bytes == [0] || element.bytes == [0xff] else { throw invalid() }
        return element.bytes[0] != 0
      case 0x02:
        let bytes = element.bytes
        guard !bytes.isEmpty, bytes.count <= 8 else { throw invalid() }
        if bytes.count > 1 {
          guard !(bytes[0] == 0 && bytes[1] & 0x80 == 0),
            !(bytes[0] == 0xff && bytes[1] & 0x80 != 0) else { throw invalid() }
        }
        var integer: UInt64 = bytes[0] & 0x80 == 0 ? 0 : UInt64.max
        for byte in bytes { integer = (integer << 8) | UInt64(byte) }
        return NSNumber(value: Int64(bitPattern: integer))
      case 0x04: return Data(element.bytes)
      case 0x0c:
        guard let string = String(bytes: element.bytes, encoding: .utf8) else { throw invalid() }
        return string
      case 0x30:
        var array = Reader(bytes: element.bytes)
        var values: [Any] = []
        while !array.finished { values.append(try array.value(depth: depth + 1)) }
        return values
      case 0xb0:
        var dictionary = Reader(bytes: element.bytes)
        var values: [String: Any] = [:]
        var lastKey: [UInt8]?
        while !dictionary.finished {
          let pair = try dictionary.element()
          guard pair.tag == 0x30 else { throw invalid() }
          var entry = Reader(bytes: pair.bytes)
          let encodedKey = try entry.element()
          guard encodedKey.tag == 0x0c,
            let key = String(bytes: encodedKey.bytes, encoding: .utf8), values[key] == nil,
            lastKey == nil || lastKey!.lexicographicallyPrecedes(encodedKey.bytes) else { throw invalid() }
          values[key] = try entry.value(depth: depth + 1)
          guard entry.finished else { throw invalid() }
          lastKey = encodedKey.bytes
        }
        return values
      default: throw invalid()
      }
    }
  }
}
