import Foundation

public struct DocumentImportResult: Sendable {
  public var imported: [URL] = []
  public var failures: [String] = []
}

/// Retains the access grant while a batch waits for an existing app operation.
public final class DocumentImportBatch: @unchecked Sendable {
  public let urls: [URL]
  public let destination: URL?
  private let scopedURLs: [URL]
  public init(urls: [URL], destination: URL? = nil) {
    self.urls = urls
    self.destination = destination
    scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
  }
  deinit { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
  public func importFiles(to workspace: Workspace) -> [String] {
    run(in: workspace).failures
  }
  public func run(in workspace: Workspace, progress: Progress? = nil) -> DocumentImportResult {
    var result = DocumentImportResult()
    progress?.totalUnitCount = Int64(urls.count)
    for url in urls {
      if progress?.isCancelled == true { break }
      let fileProgress = Progress(totalUnitCount: 1)
      progress?.addChild(fileProgress, withPendingUnitCount: 1)
      do { result.imported.append(try DocumentImport.copy(url, to: workspace, directory: destination, progress: fileProgress)) } catch {
        if FileTransfer.isCancelled(error) { break }
        result.failures.append(url.lastPathComponent + ": " + FileTransfer.message(for: error))
      }
    }
    return result
  }
}

public enum DocumentImport {
  @discardableResult
  public static func copy(_ url: URL, to workspace: Workspace, directory: URL? = nil, progress: Progress? = nil) throws -> URL
  {
    guard url.isFileURL else { throw SignerError("The shared item is not a file.") }
    var coordinationError: NSError?
    var result: Result<URL, Error>?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: url, options: .withoutChanges, error: &coordinationError
    ) { shared in
      result = Result { try workspace.importFile(shared, into: directory, progress: progress) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw SignerError("The file provider did not supply the file.") }
    let imported = try result.get()

    // The system's Open In inbox is a temporary copy. Never remove a provider's original.
    let inbox = workspace.files.appendingPathComponent("Inbox")
    if let source = try? SafePath.canonical(url),
      let inboxPath = try? workspace.confined(inbox),
      source.path.hasPrefix(inboxPath.path + "/")
    {
      try? workspace.fm.removeItem(at: source)
      if (try? workspace.fm.contentsOfDirectory(atPath: inboxPath.path).isEmpty) == true {
        try? workspace.fm.removeItem(at: inboxPath)
      }
    }
    return imported
  }
}
