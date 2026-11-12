import Foundation

/// ESign source[...] clipboard compatibility, recovered from shareSourceHandle
/// at 0x100304560. This is an encoding, not a security boundary.
public enum SourceShareCodec {
  public static func encode(_ urls: [URL]) -> String {
    let text = urls.map(\.absoluteString).joined(separator: "\n")
    return "source[" + transform(Data(text.utf8)).base64EncodedString() + "]"
  }
  public static func urls(from input: String) throws -> [URL] {
    var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.utf8.count <= 200_000 else { throw SignerError("The source list is too large.") }
    if text.hasPrefix("source[") {
      guard text.hasSuffix("]"),
        let data = Data(
          base64Encoded: String(text.dropFirst(7).dropLast()).filter { !$0.isWhitespace }),
        let decoded = String(data: transform(data), encoding: .utf8)
      else { throw SignerError("Invalid ESign source list.") }
      text = decoded
    }
    let lines = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard !lines.isEmpty, lines.count <= 1000 else {
      throw SignerError("Enter a source URL or paste an ESign source list.")
    }
    var urls: [URL] = []
    for line in lines {
      guard let url = URL(string: line),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
      else {
        throw SignerError("Enter a valid HTTP or HTTPS source URL.")
      }
      if !urls.contains(url) { urls.append(url) }
    }
    return urls
  }
  private static func transform(_ data: Data) -> Data {
    // Original RC4 KSA/PRGA and constant, used only for legacy interchange.
    let key = Array("source_share".utf8)
    var state = Array(UInt8.min...UInt8.max)
    var j = 0
    for i in 0..<256 {
      j = (j + Int(state[i]) + Int(key[i % key.count])) & 255
      state.swapAt(i, j)
    }
    var i = 0
    j = 0
    return Data(
      data.map { byte in
        i = (i + 1) & 255
        j = (j + Int(state[i])) & 255
        state.swapAt(i, j)
        return byte ^ state[(Int(state[i]) + Int(state[j])) & 255]
      })
  }
}
