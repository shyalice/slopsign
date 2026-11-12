import Combine
import Darwin
import Foundation
import Network
import Security

/// Small streaming HTTP/WebDAV server. Credentials and private keys are outside its document root.
public final class LocalFileServer: ObservableObject, @unchecked Sendable {
  @Published public private(set) var running = false
  @Published public private(set) var status = "Stopped"
  @Published public private(set) var tlsEnabled = false
  @Published public private(set) var port: UInt16 = 8080
  public let username = "signer"
  public let password = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
    .description
  public let token = UUID().uuidString + UUID().uuidString
  @Published public private(set) var deviceUDID: String?
  @Published public private(set) var installationProgress: Double = 0
  @Published public private(set) var installationStatus = ""
  private var installationFile: URL?
  private var installationIcon: Data?
  private var installationManifest: Data?
  private var installationTransfer: PayloadTransfer?
  private var installationID: UUID?
  public func startInstallation(ipa: URL, icon: Data? = nil, manifest: Data? = nil, tlsP12: URL? = nil, tlsPassword: String = "", installationID: UUID? = nil) throws {
    stop()
    guard (try ipa.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
      throw SignerError("The signed IPA is missing.")
    }
    enrollment = false
    installationProgress = 0
    installationStatus = "Waiting for iOS"
    try start(root: ipa.deletingLastPathComponent(), port: 14302, tlsP12: tlsP12, tlsPassword: tlsPassword, loopbackOnly: true)
    installationFile = ipa
    installationIcon = icon
    installationManifest = manifest
    self.installationID = installationID
    installationTransfer = PayloadTransfer(size: (try fm.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.uint64Value ?? 0)
  }
  private var enrollment = false
  private var enrollmentChallenge = UUID().uuidString
  public init() {}
  public func startEnrollment() throws {
    enrollment = true
    enrollmentChallenge = UUID().uuidString
    try start(root: fm.temporaryDirectory, port: 14302, loopbackOnly: true)
  }

  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private let queue = DispatchQueue(label: "io.alicehatesyou.signer.webdav")
  private var root: URL?
  private let fm = FileManager.default
  public var onChange: (() -> Void)?
  public var wifiAddress: String {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return "127.0.0.1" }
    defer { freeifaddrs(head) }
    var current = head
    while let entry = current {
      defer { current = entry.pointee.ifa_next }
      guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
        String(cString: entry.pointee.ifa_name) == "en0"
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      getnameinfo(
        addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
      return String(cString: host)
    }
    return "127.0.0.1"
  }
  public func start(
    root: URL, port: UInt16 = 8080, tlsP12: URL? = nil, tlsPassword: String = "",
    loopbackOnly: Bool = false
  ) throws {
    stop()
    let parameters: NWParameters
    if let tlsP12 {
      var items: CFArray?
      let status = SecPKCS12Import(
        try Data(contentsOf: tlsP12) as CFData,
        [kSecImportExportPassphrase as String: tlsPassword] as CFDictionary, &items)
      guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
        let raw = first[kSecImportItemIdentity as String]
      else { throw SignerError("Unable to read TLS P12: \(status).") }
      let identity = raw as! SecIdentity
      let chain = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
      guard let secIdentity = sec_identity_create_with_certificates(identity, chain as CFArray) else {
        throw SignerError("The TLS P12 does not contain a private key.")
      }
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
      parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
      tlsEnabled = true
    } else {
      parameters = .tcp
      tlsEnabled = false
    }
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw SignerError("Invalid port.")
    }
    if loopbackOnly {
      parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
    }
    let listener = try loopbackOnly ? NWListener(using: parameters) : NWListener(using: parameters, on: nwPort)
    self.root = try SafePath.canonical(root)
    self.port = port
    self.listener = listener
    if !loopbackOnly { listener.service = NWListener.Service(name: "ESign", type: "_http._tcp") }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      DispatchQueue.main.async {
        guard let self, let listener, self.listener === listener else { return }
        switch state {
        case .ready:
          self.running = true
          self.status = "Running"
        case .failed(let error):
          self.running = false
          self.status = error.localizedDescription
        case .cancelled:
          self.running = false
          self.status = "Stopped"
        default: break
        }
      }
    }
    listener.newConnectionHandler = { [weak self, weak listener] connection in
      guard let self, let listener, self.listener === listener else { connection.cancel(); return }
      self.connections[ObjectIdentifier(connection)] = connection
      connection.stateUpdateHandler = { [weak self, weak connection] state in
        if case .cancelled = state, let connection {
          self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        }
      }
      connection.start(queue: self.queue)
      self.read(connection, request: Request())
    }
    listener.start(queue: queue)
  }
  public func stop() {
    installationFile = nil
    installationIcon = nil
    installationManifest = nil
    installationTransfer = nil
    installationID = nil
    listener?.cancel()
    listener = nil
    queue.async {
      for connection in self.connections.values { connection.cancel() }
      self.connections.removeAll()
    }
    running = false
    status = "Stopped"
  }
  private final class Request {
    var buffer = Data()
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var expected = 0
    var received = 0
    var upload: URL?
    var handle: FileHandle?
    var parsed = false
    deinit {
      try? handle?.close()
      if let upload { try? FileManager.default.removeItem(at: upload) }
    }
  }
  private func read(_ connection: NWConnection, request: Request) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, complete, error in
      guard let self else {
        connection.cancel()
        return
      }
      do {
        if let data {
          if !request.parsed {
            request.buffer.append(data)
            if let range = request.buffer.range(of: Data("\r\n\r\n".utf8)) {
              guard range.lowerBound <= 65536,
                let header = String(data: request.buffer[..<range.lowerBound], encoding: .utf8)
              else {
                self.respond(connection, code: 400)
                return
              }
              let lines = header.components(separatedBy: "\r\n")
              let first = lines[0].split(separator: " ")
              guard first.count == 3 else {
                self.respond(connection, code: 400)
                return
              }
              request.method = String(first[0])
              request.path = String(first[1])
              for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") {
                  request.headers[String(line[..<colon]).lowercased()] = line[
                    line.index(after: colon)...
                  ].trimmingCharacters(in: .whitespaces)
                }
              }
              let component = URLComponents(string: "http://localhost" + request.path)
              let queryToken = component?.queryItems?.first(where: { $0.name == "token" })?.value
              let basic =
                "Basic " + Data((self.username + ":" + self.password).utf8).base64EncodedString()
              let enrollmentPath = component?.path ?? ""
              let enrollmentRequest =
                self.enrollment
                && ["/", "/signed_en.mobileconfig", "/udid", "/success"].contains(enrollmentPath)
              let installationRequest = self.installationFile != nil
                && (["/app0.ipa", "/app0.png"].contains(enrollmentPath) || (enrollmentPath == "/manifest.plist" && self.installationManifest != nil))
                && ["GET", "HEAD"].contains(request.method)
              guard
                enrollmentRequest || installationRequest || request.headers["authorization"] == basic
                  || queryToken == self.token
              else {
                self.respond(
                  connection, code: 401, headers: ["WWW-Authenticate": "Basic realm=\"Signer\""])
                return
              }
              guard request.headers["transfer-encoding"] == nil else {
                self.respond(connection, code: 411)
                return
              }
              if let raw = request.headers["content-length"] {
                guard let n = Int(raw), n >= 0, n <= 2 * 1024 * 1024 * 1024 else {
                  self.respond(connection, code: 413)
                  return
                }
                request.expected = n
              }
              request.parsed = true
              let remainder = Data(request.buffer[range.upperBound...])
              request.buffer = Data()
              if request.method == "PUT" {
                let temp = self.fm.temporaryDirectory.appendingPathComponent(
                  "SignerUpload_" + UUID().uuidString)
                self.fm.createFile(atPath: temp.path, contents: nil)
                request.upload = temp
                request.handle = try FileHandle(forWritingTo: temp)
              }
              if request.headers["expect"]?.lowercased() == "100-continue" {
                connection.send(
                  content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                  completion: .contentProcessed({ _ in }))
              }
              try self.consume(remainder, request)
            } else if request.buffer.count > 65536 {
              self.respond(connection, code: 431)
              return
            }
          } else {
            try self.consume(data, request)
          }
        }
        if request.parsed && request.received >= request.expected {
          try request.handle?.synchronize()
          try request.handle?.close()
          request.handle = nil
          try self.route(connection, request)
          return
        }
        if complete || error != nil {
          connection.cancel()
          return
        }
        self.read(connection, request: request)
      } catch { self.respond(connection, code: 400, body: Data(error.localizedDescription.utf8)) }
    }
  }
  private func consume(_ data: Data, _ request: Request) throws {
    guard data.count <= request.expected - request.received else {
      throw SignerError("Body exceeds Content-Length.")
    }
    request.received += data.count
    if let handle = request.handle {
      try handle.write(contentsOf: data)
    } else if request.buffer.count + data.count <= 1_048_576 {
      request.buffer.append(data)
    } else {
      throw SignerError("Request too large.")
    }
  }
  private func file(_ target: String) throws -> URL {
    guard let root,
      let components = URLComponents(
        string: target.hasPrefix("http") ? target : "http://localhost" + target)
    else { throw SignerError("Invalid URL.") }
    let decoded = components.path
    guard !decoded.contains("\0"), !decoded.contains("\\") else {
      throw SignerError("Invalid path.")
    }
    let url = try SafePath.canonical(
      root.appendingPathComponent(
        decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
    guard url == root || url.path.hasPrefix(root.path + "/"), !url.lastPathComponent.hasPrefix(".")
    else { throw SignerError("Path is not accessible.") }
    return url
  }
  private func route(_ c: NWConnection, _ r: Request) throws {
    if let ipa = installationFile {
      let components = URLComponents(string: r.path)
      let path = components?.path ?? r.path
      if let installationID, components?.queryItems?.first(where: { $0.name == "installation" })?.value != installationID.uuidString {
        respond(c, code: 404); return
      }
      guard ["GET", "HEAD"].contains(r.method) else { respond(c, code: 405); return }
      if path == "/manifest.plist", let manifest = installationManifest {
        if r.method == "HEAD" {
          let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: \(manifest.count)\r\nContent-Type: application/xml\r\nConnection: close\r\n\r\n".utf8)
          c.send(content: headers, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        } else { respond(c, code: 200, body: manifest, type: "application/xml") }
      } else if path == "/app0.ipa" {
        try sendFile(c, url: ipa, head: r.method == "HEAD", range: r.headers["range"], installation: true)
      } else if path == "/app0.png", let icon = installationIcon {
        if r.method == "HEAD" {
          let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: \(icon.count)\r\nContent-Type: image/png\r\nConnection: close\r\n\r\n".utf8)
          c.send(content: headers, completion: .contentProcessed { _ in c.cancel() })
        } else { respond(c, code: 200, body: icon, type: "image/png") }
      } else { respond(c, code: 404) }
      return
    }
    if enrollment {
      try routeEnrollment(c, r)
      return
    }
    let url = try file(r.path)
    switch r.method {
    case "OPTIONS":
      respond(
        c, code: 200,
        headers: [
          "DAV": "1", "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, MOVE, COPY",
        ])
    case "GET", "HEAD":
      var dir: ObjCBool = false
      guard fm.fileExists(atPath: url.path, isDirectory: &dir) else {
        respond(c, code: 404)
        return
      }
      if dir.boolValue {
        let files = try fm.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        let items = files.map { u -> String in
          let p = href(u)
          return "<li><a href=\"\(p)\">\(escape(u.lastPathComponent))</a></li>"
        }.joined()
        let html = """
          <!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Signer · File</title><style>body{font:17px system-ui;max-width:800px;margin:8vh auto;padding:24px;background:#f1f6f7;color:#102c31}a{color:#078b92}li{padding:12px;border-bottom:1px solid #d7e4e5}button,input{font:inherit;padding:10px}small{color:#567}</style><h1>ESign</h1><p>WiFi Transfer</p><a href="../">← Back</a><ul>\(items)</ul><input type="file" multiple id="files"><button onclick="upload()">Upload Files</button><p id="status"></p><small>Files transfer directly to this device. Keep ESign open.</small><script>async function upload(){for(const f of document.querySelector('#files').files){document.querySelector('#status').textContent='Uploading '+f.name;const p=location.pathname.replace(/\\/?$/,'/')+encodeURIComponent(f.name);const r=await fetch(p,{method:'PUT',body:f});if(!r.ok){document.querySelector('#status').textContent='Error '+r.status;return}}location.reload()}</script></html>
          """
        respond(c, code: 200, body: Data(html.utf8), type: "text/html; charset=utf-8")
      } else {
        try sendFile(c, url: url, head: r.method == "HEAD")
      }
    case "PUT":
      guard url != root, let temp = r.upload else {
        respond(c, code: 403)
        return
      }
      guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else {
        respond(c, code: 409)
        return
      }
      if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: temp)
      } else {
        try fm.moveItem(at: temp, to: url)
      }
      changed()
      respond(c, code: 201)
    case "MKCOL":
      try fm.createDirectory(at: url, withIntermediateDirectories: false)
      changed()
      respond(c, code: 201)
    case "DELETE":
      guard url != root else {
        respond(c, code: 403)
        return
      }
      try fm.removeItem(at: url)
      changed()
      respond(c, code: 204)
    case "MOVE", "COPY":
      guard url != root, let raw = r.headers["destination"] else {
        respond(c, code: 400)
        return
      }
      let destination = try file(raw)
      guard destination != root, !destination.path.hasPrefix(url.path + "/"), destination != url
      else {
        respond(c, code: 403)
        return
      }
      if fm.fileExists(atPath: destination.path) {
        guard r.headers["overwrite"]?.uppercased() == "T" else {
          respond(c, code: 412)
          return
        }
        try fm.removeItem(at: destination)
      }
      if r.method == "MOVE" {
        try fm.moveItem(at: url, to: destination)
      } else {
        try fm.copyItem(at: url, to: destination)
      }
      changed()
      respond(c, code: 201)
    case "PROPFIND":
      guard fm.fileExists(atPath: url.path) else {
        respond(c, code: 404)
        return
      }
      var files = [url]
      let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if r.headers["depth"] != "0" && isDir {
        files += try fm.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      }
      let rows = files.map { item -> String in
        let value = try? item.resourceValues(forKeys: [
          .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        let collection = value?.isDirectory == true
        return
          "<d:response><d:href>\(escape(href(item)+(collection ? "/":"")))</d:href><d:propstat><d:prop><d:displayname>\(escape(item.lastPathComponent))</d:displayname><d:resourcetype>\(collection ? "<d:collection/>":"")</d:resourcetype><d:getcontentlength>\(value?.fileSize ?? 0)</d:getcontentlength><d:getlastmodified>\(httpDate(value?.contentModificationDate ?? Date()))</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
      }.joined()
      respond(
        c, code: 207,
        body: Data(
          ("<?xml version=\"1.0\" encoding=\"utf-8\"?><d:multistatus xmlns:d=\"DAV:\">" + rows
            + "</d:multistatus>").utf8), type: "application/xml; charset=utf-8",
        headers: ["DAV": "1"])
    default: respond(c, code: 405)
    }
  }
  private func routeEnrollment(_ connection: NWConnection, _ request: Request) throws {
    let path = URLComponents(string: "http://localhost" + request.path)?.path ?? ""
    if request.method == "GET" && path == "/signed_en.mobileconfig" {
      let callback = URL(string: "http://127.0.0.1:14302/udid")!
      let profile = try DeviceEnrollment.profile(callback: callback, challenge: enrollmentChallenge)
      respond(
        connection, code: 200, body: profile, type: "application/x-apple-aspen-config",
        headers: ["Content-Disposition": "attachment; filename=ESign.mobileconfig"])
    } else if request.method == "POST" && path == "/udid" {
      let udid = try DeviceEnrollment.response(request.buffer, challenge: enrollmentChallenge)
      DispatchQueue.main.async { self.deviceUDID = udid }
      respond(connection, code: 303, headers: ["Location": "http://127.0.0.1:14302/success"])
    } else if request.method == "GET" && (path == "/" || path == "/success") {
      let done = path == "/success"
      let body =
        "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>body{font:17px system-ui;padding:32px;color:#172a30;background:#f4f6f8}a{display:block;padding:16px;color:#008ca0}</style><h1>\(done ? "UDID Obtained Successfully" : "Get Device UDID")</h1><p>\(done ? "Return to ESign. The device identifier has been saved locally." : "Download the profile, then open Settings → Profile Downloaded and install it.")</p><a href=\"\(done ? "signer://udid" : "/signed_en.mobileconfig")\">\(done ? "Return to ESign" : "Download Profile")</a></html>"
      respond(connection, code: 200, body: Data(body.utf8), type: "text/html; charset=utf-8")
    } else {
      respond(connection, code: 404)
    }
  }
  private func changed() { DispatchQueue.main.async { self.onChange?() } }
  private func href(_ url: URL) -> String {
    guard let root else { return "/" }
    let path = String(url.path.dropFirst(root.path.count))
    return path.split(separator: "/", omittingEmptySubsequences: false).map {
      String($0).addingPercentEncoding(
        withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%&")))
        ?? ""
    }.joined(separator: "/")
  }
  private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  private func httpDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return f.string(from: d)
  }
  private func respond(
    _ c: NWConnection, code: Int, body: Data = Data(), type: String = "text/plain; charset=utf-8",
    headers: [String: String] = [:]
  ) {
    let reasons = [
      200: "OK", 303: "See Other", 201: "Created", 204: "No Content", 207: "Multi-Status",
      400: "Bad Request",
      401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
      409: "Conflict", 411: "Length Required", 412: "Precondition Failed", 413: "Payload Too Large",
      431: "Request Header Fields Too Large",
    ]
    var head =
      "HTTP/1.1 \(code) \(reasons[code] ?? "Error")\r\nContent-Length: \(body.count)\r\nContent-Type: \(type)\r\nConnection: close\r\n"
    for (key, value) in headers { head += "\(key): \(value)\r\n" }
    head += "\r\n"
    c.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
  }
  private func sendFile(_ c: NWConnection, url: URL, head: Bool, range: String? = nil, installation: Bool = false) throws {
    let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    let type =
      url.pathExtension == "plist"
      ? "application/xml"
      : url.pathExtension == "ipa" ? "application/octet-stream" : "application/octet-stream"
    var start: UInt64 = 0
    var end = size > 0 ? size - 1 : 0
    if let range {
      guard range.hasPrefix("bytes="), !range.contains(",") else { respond(c, code: 416); return }
      let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
      guard parts.count == 2, size > 0 else { respond(c, code: 416); return }
      if parts[0].isEmpty {
        guard let suffix = UInt64(parts[1]), suffix > 0 else { respond(c, code: 416); return }
        start = size > suffix ? size - suffix : 0
      } else {
        guard let value = UInt64(parts[0]), value < size else { respond(c, code: 416); return }
        start = value
        if !parts[1].isEmpty {
          guard let value = UInt64(parts[1]), value >= start else { respond(c, code: 416); return }
          end = min(end, value)
        }
      }
    }
    let count = size == 0 ? 0 : end - start + 1
    let rangeHeader = range == nil ? "" : "Content-Range: bytes \(start)-\(end)/\(size)\r\n"
    let headers = Data(
      "HTTP/1.1 \(range == nil ? "200 OK" : "206 Partial Content")\r\nContent-Length: \(count)\r\nContent-Type: \(type)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\n\(rangeHeader)Connection: close\r\n\r\n"
        .utf8)
    if head {
      c.send(content: headers, completion: .contentProcessed { _ in c.cancel() })
      return
    }
    let file = try FileHandle(forReadingFrom: url)
    try file.seek(toOffset: start)
    let transfer = installation ? installationTransfer : nil
    if let transfer { DispatchQueue.main.async { [weak self] in
      guard self?.installationTransfer === transfer else { return }
      self?.installationStatus = "Sending IPA to iOS"
    } }
    c.send(
      content: headers,
      completion: .contentProcessed { [weak self] error in
        if error != nil {
          try? file.close()
          c.cancel()
        } else {
          self?.sendChunk(c, file: file, remaining: count, offset: start, transfer: transfer)
        }
      })
  }
  private var lastTransferUpdate: TimeInterval = 0
  private func updateTransfer(_ transfer: PayloadTransfer, interval: Range<UInt64>, force: Bool) {
    let state = transfer.sent(interval)
    let now = ProcessInfo.processInfo.systemUptime
    guard force || state.complete || now - lastTransferUpdate >= 0.08 else { return }
    lastTransferUpdate = now
    DispatchQueue.main.async { [weak self] in
      guard self?.installationTransfer === transfer else { return }
      self?.installationProgress = state.fraction
      if state.complete { self?.installationStatus = "IPA sent to iOS" }
    }
  }
  private func sendChunk(_ c: NWConnection, file: FileHandle, remaining: UInt64, offset: UInt64, transfer: PayloadTransfer?) {
    if remaining == 0 {
      try? file.close()
      c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
      return
    }
    do {
      // Keep four bounded chunks in flight. A single 256 KiB send followed by
      // waiting for its callback stalled the producer between every TLS write.
      var chunks: [(Data, UInt64)] = []
      var nextOffset = offset, left = remaining
      for _ in 0..<4 where left > 0 {
        let bytes = try file.read(upToCount: Int(min(1_048_576, left))) ?? Data()
        guard !bytes.isEmpty else { throw SignerError("The IPA ended before its declared size.") }
        chunks.append((bytes, nextOffset))
        nextOffset += UInt64(bytes.count); left -= UInt64(bytes.count)
      }
      let next = nextOffset, rest = left
      let group = DispatchGroup()
      var failed = false
      c.batch {
        for (bytes, position) in chunks {
          group.enter()
          c.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if error != nil { failed = true }
            else if let transfer { self?.updateTransfer(transfer, interval: position..<(position + UInt64(bytes.count)), force: rest == 0) }
            group.leave()
          })
        }
      }
      group.notify(queue: queue) { [weak self] in
        guard let self, !failed else { try? file.close(); c.cancel(); return }
        self.sendChunk(c, file: file, remaining: rest, offset: next, transfer: transfer)
      }
    } catch {
      try? file.close(); c.cancel()
      if let transfer { DispatchQueue.main.async { [weak self] in
        guard self?.installationTransfer === transfer else { return }
        self?.installationStatus = "IPA transfer failed: " + error.localizedDescription
      } }
    }
  }
}
