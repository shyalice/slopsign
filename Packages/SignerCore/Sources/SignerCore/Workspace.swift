import Foundation
import ZIPFoundation

public final class Workspace: @unchecked Sendable {
  public let root: URL
  public let privateRoot: URL
  public let fm = FileManager.default
  public init(root: URL, privateRoot: URL? = nil) throws {
    self.root = try SafePath.canonical(root)
    self.privateRoot = try SafePath.canonical(
      privateRoot ?? root.appendingPathComponent(".private"))
    for path in [
      root, self.privateRoot, files, apps, signed, archives, logoCache, temporary, certificates, signedBundleCache,
    ] {
      try fm.createDirectory(at: path, withIntermediateDirectories: true)
    }
    for (old, destination) in [
      ("Files", self.root), ("Apps", apps), ("Signed", signed), ("Archives", archives),
    ] {
      let source = self.root.appendingPathComponent(old)
      guard fm.fileExists(atPath: source.path) else { continue }
      for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
        let target = destination.appendingPathComponent(item.lastPathComponent)
        if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: item, to: target) }
      }
      if try fm.contentsOfDirectory(atPath: source.path).isEmpty { try fm.removeItem(at: source) }
    }
  }
  public var files: URL { root }
  public var appFolder: URL { root.appendingPathComponent("YYYAppFolder") }
  public var logoCache: URL { appFolder.appendingPathComponent("LogoCache") }
  public var apps: URL { appFolder.appendingPathComponent("UnSignApps") }
  public var signed: URL { appFolder.appendingPathComponent("SignedApps") }
  public var archives: URL { signed }
  public var temporary: URL { privateRoot.appendingPathComponent("Work") }
  public var certificates: URL { privateRoot.appendingPathComponent("Certificates") }
  public var signedBundleCache: URL { privateRoot.appendingPathComponent("SignedAppCache") }
  private let cachePrefix = "@SignedApps/"
  public func relative(_ url: URL) -> String {
    let path = ((try? SafePath.canonical(url)) ?? url).path
    if path.hasPrefix(signedBundleCache.path + "/") {
      return cachePrefix + path.dropFirst(signedBundleCache.path.count + 1)
    }
    return String(path.dropFirst(root.path.count + 1))
  }
  public func resolve(_ path: String) throws -> URL {
    if path.hasPrefix(cachePrefix) {
      return try confined(signedBundleCache.appendingPathComponent(String(path.dropFirst(cachePrefix.count))), to: signedBundleCache)
    }
    let file = try confined(root.appendingPathComponent(path), to: root)
    // Resolve records from earlier builds if a storage migration was interrupted
    // after its atomic directory move but before its metadata save.
    if !fm.fileExists(atPath: file.path), file.deletingLastPathComponent().deletingLastPathComponent() == signed,
      UUID(uuidString: file.deletingLastPathComponent().lastPathComponent) != nil {
      let cached = signedBundleCache.appendingPathComponent(file.deletingLastPathComponent().lastPathComponent)
        .appendingPathComponent(file.lastPathComponent)
      if fm.fileExists(atPath: cached.path) { return try confined(cached, to: signedBundleCache) }
    }
    return file
  }
  public func confined(_ url: URL, to base: URL? = nil) throws -> URL {
    let url = try SafePath.canonical(url)
    let bases = try (base.map { [$0] } ?? [root, signedBundleCache]).map { try SafePath.canonical($0) }
    guard bases.contains(where: { url.path == $0.path || url.path.hasPrefix($0.path + "/") }) else {
      throw SignerError("The path is outside the document directory.")
    }
    return url
  }
  public func unique(_ name: String, in directory: URL) -> URL {
    let safe = URL(fileURLWithPath: name).lastPathComponent
    var result = directory.appendingPathComponent(safe)
    var n = 2
    while fm.fileExists(atPath: result.path) {
      let p = URL(fileURLWithPath: safe)
      result = directory.appendingPathComponent(
        p.deletingPathExtension().lastPathComponent + " \(n)"
          + (p.pathExtension.isEmpty ? "" : "." + p.pathExtension))
      n += 1
    }
    return result
  }
  public func children(_ directory: URL) throws -> [URL] {
    try fm.contentsOfDirectory(
      at: confined(directory),
      includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ).sorted {
      let a = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      let b = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      return a != b
        ? a
        : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
  }
  public func importFile(_ url: URL, into destination: URL? = nil, progress: Progress? = nil) throws -> URL {
    let source = try SafePath.canonical(url)
    guard source.path != temporary.path, !temporary.path.hasPrefix(source.path + "/") else {
      throw SignerError("This folder contains the import workspace.")
    }
    let directory = try confined(destination ?? files)
    guard source.path != directory.path, !directory.path.hasPrefix(source.path + "/") else {
      throw SignerError("A folder cannot be imported into itself.")
    }
    let staging = temporary.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    let stagedFile = staging.appendingPathComponent(url.lastPathComponent)
    try FileTransfer.copy(url, to: stagedFile, progress: progress)
    let dest = unique(url.lastPathComponent, in: directory)
    try fm.moveItem(at: stagedFile, to: dest)
    return dest
  }
  public func rename(_ url: URL, to name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
      !name.contains("\0")
    else { throw SignerError("Invalid file name.") }
    let source = try confined(url)
    try fm.moveItem(at: source, to: source.deletingLastPathComponent().appendingPathComponent(name))
  }
  private func removable(_ url: URL) throws -> URL {
    // Resolve ancestors, but delete a selected symlink itself, not its target.
    guard !["", ".", "..", "/"].contains(url.lastPathComponent) else {
      throw SignerError("This directory cannot be deleted.")
    }
    let parent = try confined(url.deletingLastPathComponent())
    let candidate = parent.appendingPathComponent(url.lastPathComponent)
    guard ![root, privateRoot, appFolder, logoCache, apps, signed, signedBundleCache,
      temporary, certificates].contains(where: { $0.path == candidate.path })
    else { throw SignerError("This directory cannot be deleted.") }
    return candidate
  }
  public func remove(_ url: URL, progress: Progress? = nil) throws {
    let target = try removable(url)
    try NativeFiles.remove(target, progress: progress)
  }
  /// Signed IPA files and imported bundles are the library's authoritative data.
  /// Private extracted caches must never keep a deleted IPA visible in Apps.
  public func reconcileAppRecords(_ records: [AppRecord]) throws -> [AppRecord] {
    var updated: [AppRecord] = []
    for record in records {
      let authoritative = try resolve(record.archivePath ?? record.relativePath)
      do { _ = try fm.attributesOfItem(atPath: authoritative.path); updated.append(record) }
      catch let error as NSError where error.domain == NSCocoaErrorDomain &&
        [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
        // Only discard an orphaned private cache belonging to this record.
        if record.archivePath != nil {
          let cache = signedBundleCache.appendingPathComponent(record.id.uuidString)
          if fm.fileExists(atPath: cache.path) { try remove(cache) }
        }
      }
    }
    return updated
  }
  public func removeAppFiles(_ record: AppRecord, progress: Progress? = nil) throws {
    let bundle = try resolve(record.relativePath)
    var targets: [URL] = []
    if let path = record.archivePath {
      let archive = try resolve(path)
      if fm.fileExists(atPath: archive.path) { targets.append(try removable(archive)) }
    }
    if fm.fileExists(atPath: bundle.path) {
      let parent = bundle.deletingLastPathComponent()
      let owned = parent.lastPathComponent == record.id.uuidString
        && [apps, signedBundleCache, signed].contains(parent.deletingLastPathComponent())
      let onlyBundle = try owned && fm.contentsOfDirectory(atPath: parent.path) == [bundle.lastPathComponent]
      targets.append(try removable(onlyBundle ? parent : bundle))
    }
    progress?.totalUnitCount = Int64(targets.count)
    for target in targets {
      let child = Progress(totalUnitCount: 1)
      progress?.addChild(child, withPendingUnitCount: 1)
      try NativeFiles.remove(target, progress: child)
      child.completedUnitCount = child.totalUnitCount
    }
  }
  public func copy(_ url: URL, to directory: URL, move: Bool, progress: Progress? = nil) throws {
    let url = try confined(url)
    let directory = try confined(directory)
    guard !directory.path.hasPrefix(url.path + "/"), url != directory else {
      throw SignerError("A folder cannot be moved or copied into itself.")
    }
    let dest = unique(url.lastPathComponent, in: directory)
    try FileTransfer.check(progress)
    if move { try fm.moveItem(at: url, to: dest) } else { try FileTransfer.copy(url, to: dest, progress: progress) }
  }
  public func size(_ url: URL) -> Int64 {
    if let s = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      s.isRegularFile == true
    {
      return Int64(s.fileSize ?? 0)
    }
    guard
      let e = fm.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return 0 }
    return e.reduce(Int64(0)) { total, item in
      guard let u = item as? URL,
        let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
        v.isRegularFile == true
      else { return total }
      return total + Int64(v.fileSize ?? 0)
    }
  }
  /// Preflight every member before extraction; reject symlinks and traversal.
  public func extract(_ archiveURL: URL, to destination: URL, progress: Progress? = nil) throws {
    try NativeFiles.extract(archiveURL, to: destination, progress: progress)
  }

  public func unpack(_ url: URL, progress: Progress? = nil) throws -> URL {
    let destination = unique(
      url.deletingPathExtension().lastPathComponent, in: url.deletingLastPathComponent())
    let staging = temporary.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    let extracted = staging.appendingPathComponent("Extracted")
    if ["ipa", "zip", "tipa"].contains(url.pathExtension.lowercased()) {
      try extract(url, to: extracted, progress: progress)
    } else { try ArchiveExtractor.extract(try confined(url), to: extracted, progress: progress) }
    try FileTransfer.check(progress)
    try fm.moveItem(at: extracted, to: destination)
    return destination
  }
  public func compress(_ url: URL, progress: Progress? = nil) throws -> URL {
    let destination = unique(url.lastPathComponent + ".zip", in: url.deletingLastPathComponent())
    do {
      try FileTransfer.check(progress)
      try fm.zipItem(at: confined(url), to: destination, compressionMethod: .deflate, progress: progress)
    } catch { try? fm.removeItem(at: destination); throw error }
    return destination
  }
  public func appInfo(_ app: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: app.appendingPathComponent("Info.plist"))
    guard
      let info = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any], info["CFBundleIdentifier"] is String,
      info["CFBundleExecutable"] is String
    else { throw SignerError("The app does not contain a valid Info.plist.") }
    return info
  }
  public func importApp(_ source: URL, progress: Progress? = nil) throws -> AppRecord {
    try FileTransfer.check(progress)
    progress?.totalUnitCount = 100
    let id = UUID()
    let work = temporary.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    let app: URL
    if source.pathExtension.lowercased() == "app" {
      app = source
    } else {
      let extraction = Progress(totalUnitCount: 1)
      progress?.totalUnitCount = 100
      progress?.addChild(extraction, withPendingUnitCount: 75)
      try extract(source, to: work.appendingPathComponent("Extracted"), progress: extraction)
      let payload = work.appendingPathComponent("Extracted/Payload")
      let candidates =
        (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).filter {
          $0.pathExtension == "app"
        }) ?? []
      guard candidates.count == 1, let candidate = candidates.first else {
        throw SignerError("The IPA must contain one Payload/Name.app bundle.")
      }
      app = candidate
    }
    let info = try appInfo(app)
    let dest = apps.appendingPathComponent(id.uuidString).appendingPathComponent(
      app.lastPathComponent)
    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
    let copying = Progress(totalUnitCount: 1)
    progress?.addChild(copying, withPendingUnitCount: source.pathExtension.lowercased() == "app" ? 100 : 25)
    do {
      if source.pathExtension.lowercased() == "app" {
        let local = (try? confined(source)) != nil
        try FileTransfer.copy(app, to: dest, progress: copying, preferClone: local)
      } else {
        // The extracted bundle is already independent of the input archive.
        try fm.moveItem(at: app, to: dest)
        copying.completedUnitCount = copying.totalUnitCount
      }
      try FileTransfer.check(progress)
    } catch {
      try? fm.removeItem(at: dest.deletingLastPathComponent())
      throw error
    }
    return AppRecord(
      id: id,
      name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
        ?? app.deletingPathExtension().lastPathComponent,
      bundleID: info["CFBundleIdentifier"] as? String ?? "",
      version: info["CFBundleShortVersionString"] as? String ?? "1.0", relativePath: relative(dest),
      sourcePath: (try? confined(source)) == nil ? nil : relative(source))
  }
  public func record(for app: URL) throws -> AppRecord {
    let app = try confined(app)
    let info = try appInfo(app)
    return AppRecord(name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
      bundleID: info["CFBundleIdentifier"] as? String ?? "", version: info["CFBundleShortVersionString"] as? String ?? "1.0",
      relativePath: relative(app))
  }
  public func packageApp(_ app: URL, progress: Progress? = nil) throws -> URL {
    let app = try confined(app)
    _ = try appInfo(app)
    let staging = temporary.appendingPathComponent(UUID().uuidString)
    let payload = staging.appendingPathComponent("Payload")
    try fm.createDirectory(at: payload, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    progress?.totalUnitCount = 100
    let copy = Progress(totalUnitCount: 1)
    progress?.addChild(copy, withPendingUnitCount: 40)
    try FileTransfer.copy(app, to: payload.appendingPathComponent(app.lastPathComponent), progress: copy)
    let zip = Progress(totalUnitCount: 1)
    progress?.addChild(zip, withPendingUnitCount: 60)
    let archive = staging.appendingPathComponent("Result.ipa")
    try fm.zipItem(at: payload, to: archive, compressionMethod: .deflate, progress: zip)
    try FileTransfer.check(progress)
    let destination = unique(app.deletingPathExtension().lastPathComponent + ".ipa", in: files)
    try fm.moveItem(at: archive, to: destination)
    return destination
  }
  public func save<T: Encodable>(_ value: T, name: String) throws {
    try JSONEncoder().encode(value).write(
      to: privateRoot.appendingPathComponent(name + ".json"), options: .atomic)
  }
  public func load<T: Decodable>(_ type: T.Type, name: String, fallback: T) throws -> T {
    let file = privateRoot.appendingPathComponent(name + ".json")
    guard fm.fileExists(atPath: file.path) else { return fallback }
    return try JSONDecoder().decode(type, from: Data(contentsOf: file))
  }
  /// Only the IPA is public in SignedApps. Expanded signed bundles are a private
  /// working cache for viewing contents/re-signing, and never file-list clutter.
  public func migrateSignedRecords(_ records: [AppRecord]) throws -> [AppRecord] {
    var updated = records
    for index in updated.indices {
      let record = updated[index]
      guard record.archivePath != nil, !record.relativePath.hasPrefix(cachePrefix) else { continue }
      let original = try confined(root.appendingPathComponent(record.relativePath), to: root)
      let folder = original.deletingLastPathComponent()
      guard folder.deletingLastPathComponent() == signed,
        let uuid = UUID(uuidString: folder.lastPathComponent), uuid == record.id else { continue }
      let destination = signedBundleCache.appendingPathComponent(folder.lastPathComponent)
      let bundle = destination.appendingPathComponent(original.lastPathComponent)
      if fm.fileExists(atPath: original.path) {
        if fm.fileExists(atPath: bundle.path) {
          throw SignerError("A signed-app cache already exists for \(record.name). Both copies were retained.")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.moveItem(at: original, to: bundle)
        if try fm.contentsOfDirectory(atPath: folder.path).isEmpty { try fm.removeItem(at: folder) }
      }
      if fm.fileExists(atPath: bundle.path) { updated[index].relativePath = relative(bundle) }
    }
    return updated
  }
}
