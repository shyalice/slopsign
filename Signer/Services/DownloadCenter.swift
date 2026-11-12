import Combine
import Foundation
import SignerCore

struct DownloadItem: Identifiable {
  let id: UUID
  var name: String
  let url: URL
  var progress: Double = 0
  var received: Int64 = 0
  var expected: Int64 = 0
  var state = "Downloading"
  var file: URL?
  var finished = false
}
@MainActor
final class DownloadCenter: NSObject, ObservableObject, URLSessionDownloadDelegate {
  @Published var items: [DownloadItem] = []
  var destination: URL?
  var onComplete: (() -> Void)?
  private var mapping: [Int: UUID] = [:]
  private var tasks: [UUID: URLSessionDownloadTask] = [:]
  private lazy var session = URLSession(
    configuration: .default, delegate: self, delegateQueue: .main)
  func start(_ url: URL, name: String? = nil) {
    guard ["https", "http"].contains(url.scheme ?? "") else { return }
    let id = UUID()
    let task = session.downloadTask(with: url)
    items.insert(DownloadItem(id: id, name: name ?? url.lastPathComponent, url: url), at: 0)
    mapping[task.taskIdentifier] = id
    tasks[id] = task
    task.resume()
  }
  func cancel(_ id: UUID) { tasks[id]?.cancel() }
  func retry(_ item: DownloadItem) { start(item.url, name: item.name) }
  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    Task { @MainActor in
      guard let id = self.mapping[downloadTask.taskIdentifier],
        let i = self.items.firstIndex(where: { $0.id == id })
      else { return }
      self.items[i].received = totalBytesWritten
      self.items[i].expected = totalBytesExpectedToWrite
      self.items[i].progress =
        totalBytesExpectedToWrite > 0
        ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
    }
  }
  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // The temporary URL only lives for this delegate callback.
    let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stagingError: Error?
    do {
      try FileManager.default.moveItem(at: location, to: staged)
      stagingError = nil
    } catch { stagingError = error }
    Task { @MainActor in
      defer { try? FileManager.default.removeItem(at: staged) }
      guard let id = self.mapping[downloadTask.taskIdentifier],
        let i = self.items.firstIndex(where: { $0.id == id }), let directory = self.destination
      else { return }
      defer {
        self.mapping.removeValue(forKey: downloadTask.taskIdentifier)
        self.tasks.removeValue(forKey: id)
      }
      do {
        if let stagingError { throw stagingError }
        guard let response = downloadTask.response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode)
        else {
          throw SignerError(
            "Download rejected by server (\((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0))."
          )
        }
        let suggested = downloadTask.response?.suggestedFilename ?? self.items[i].name
        let name = URL(fileURLWithPath: suggested).lastPathComponent
        var dest = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
          dest = directory.appendingPathComponent(UUID().uuidString.prefix(6) + "_" + name)
        }
        try FileManager.default.moveItem(at: staged, to: dest)
        self.items[i].file = dest
        self.items[i].name = dest.lastPathComponent
        self.items[i].state = "Saved to File List"
        self.items[i].finished = true
        self.items[i].progress = 1
        self.onComplete?()
      } catch {
        self.items[i].state = error.localizedDescription
        self.items[i].finished = true
      }
    }
  }
  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let error else { return }
    Task { @MainActor in
      guard let id = self.mapping.removeValue(forKey: task.taskIdentifier) else { return }
      self.tasks.removeValue(forKey: id)
      if let i = self.items.firstIndex(where: { $0.id == id }) {
        self.items[i].state =
          (error as NSError).code == NSURLErrorCancelled ? "Cancelled" : error.localizedDescription
        self.items[i].finished = true
      }
    }
  }
}
