import Foundation

/// Coalesce native diagnostic callbacks before they enqueue UI work. Flush at
/// operation completion so the final messages cannot be lost behind cleanup.
final class SigningLogDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [SigningLogLine] = []
  private var scheduled = false
  private let deliver: @MainActor ([SigningLogLine]) -> Void
  init(deliver: @escaping @MainActor ([SigningLogLine]) -> Void) { self.deliver = deliver }
  func append(_ message: String, error: Bool) {
    let cleaned = message.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    let lines = cleaned.split(whereSeparator: \.isNewline).map { SigningLogLine(text: String($0), isError: error) }
    guard !lines.isEmpty else { return }
    lock.lock()
    pending.append(contentsOf: lines)
    let schedule = !scheduled
    scheduled = true
    lock.unlock()
    if schedule {
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(50))
        self?.flush()
      }
    }
  }
  @MainActor func flush() {
    let lines = takePending()
    if !lines.isEmpty { deliver(lines) }
  }
  private func takePending() -> [SigningLogLine] {
    lock.lock(); defer { lock.unlock() }
    let lines = pending
    pending = []; scheduled = false
    return lines
  }
}
