import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct DAVAccount: Codable, Identifiable, Hashable {
  public var id: UUID
  public var url: URL
  public var username: String
  public init(id: UUID = UUID(), url: URL, username: String) {
    self.id = id
    self.url = url
    self.username = username
  }
}
public struct DAVEntry: Identifiable, Hashable {
  public var id: URL { url }
  public let url: URL
  public let name: String
  public let isDirectory: Bool
  public let size: Int64
}
public actor WebDAVClient {
  private let account: DAVAccount
  private let password: String
  private let session = URLSession(configuration: .default)
  public init(account: DAVAccount, password: String) {
    self.account = account
    self.password = password
  }
  private func request(_ method: String, url: URL) throws -> URLRequest {
    guard ["http", "https"].contains(url.scheme ?? ""), url.host == account.url.host,
      url.port == account.url.port, url.scheme == account.url.scheme
    else { throw SignerError("The WebDAV URL is outside this account.") }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 45
    request.setValue(
      "Basic " + Data((account.username + ":" + password).utf8).base64EncodedString(),
      forHTTPHeaderField: "Authorization")
    return request
  }
  private func validate(_ response: URLResponse) throws {
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode)
    else {
      throw SignerError(
        "WebDAV request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
    }
  }
  public func list(_ url: URL) async throws -> [DAVEntry] {
    var req = try request("PROPFIND", url: url)
    req.setValue("1", forHTTPHeaderField: "Depth")
    req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(
      "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"
        .utf8)
    let (data, response) = try await session.data(for: req)
    try validate(response)
    guard data.count <= 20_000_000 else {
      throw SignerError("The WebDAV directory response is too large.")
    }
    let parser = DAVParser(base: url)
    let xml = XMLParser(data: data)
    xml.shouldProcessNamespaces = true
    xml.delegate = parser
    guard xml.parse() else { throw xml.parserError ?? SignerError("Invalid WebDAV XML response.") }
    return parser.entries.filter {
      $0.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        != url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }.sorted {
      $0.isDirectory != $1.isDirectory
        ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  public func download(_ url: URL, to destination: URL) async throws {
    let (file, response) = try await session.download(for: request("GET", url: url))
    defer { try? FileManager.default.removeItem(at: file) }
    try validate(response)
    try FileManager.default.moveItem(at: file, to: destination)
  }
  public func upload(_ file: URL, to url: URL) async throws {
    let (_, response) = try await session.upload(for: request("PUT", url: url), fromFile: file)
    try validate(response)
  }
  public func createFolder(_ name: String, in directory: URL) async throws {
    try validName(name)
    let (_, response) = try await session.data(
      for: request("MKCOL", url: directory.appendingPathComponent(name, isDirectory: true)))
    try validate(response)
  }
  public func remove(_ url: URL) async throws {
    let (_, response) = try await session.data(for: request("DELETE", url: url))
    try validate(response)
  }
  public func rename(_ url: URL, to name: String) async throws {
    try validName(name)
    var req = try request("MOVE", url: url)
    req.setValue(
      url.deletingLastPathComponent().appendingPathComponent(name).absoluteString,
      forHTTPHeaderField: "Destination")
    req.setValue("F", forHTTPHeaderField: "Overwrite")
    let (_, response) = try await session.data(for: req)
    try validate(response)
  }
  private func validName(_ name: String) throws {
    guard !name.isEmpty, ![".", ".."].contains(name), !name.contains("/"), !name.contains("\0")
    else { throw SignerError("Invalid file name.") }
  }
}
private final class DAVParser: NSObject, XMLParserDelegate {
  let base: URL
  var entries: [DAVEntry] = []
  private var href = "", name = "", size: Int64 = 0, directory = false, element = "", text = ""
  init(base: URL) { self.base = base }
  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String]
  ) {
    element = elementName
    text = ""
    if elementName == "response" {
      href = ""
      name = ""
      size = 0
      directory = false
    }
    if elementName == "collection" { directory = true }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    switch elementName {
    case "href": href = text.trimmingCharacters(in: .whitespacesAndNewlines)
    case "displayname": name = text
    case "getcontentlength": size = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    case "response":
      if let url = URL(string: href, relativeTo: base)?.absoluteURL, url.host == base.host,
        !href.isEmpty
      {
        entries.append(
          DAVEntry(
            url: url, name: name.isEmpty ? url.lastPathComponent : name, isDirectory: directory,
            size: size))
      }
    default: break
    }
    text = ""
  }
}
