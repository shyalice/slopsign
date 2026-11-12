import Foundation

/// Bound KVO delivery before scheduling main-actor work, not after it has queued.
final class ProgressDelivery: @unchecked Sendable {
  private let lock = NSLock()
  private var lastTime = -Double.infinity
  private var lastValue = -1.0
  func shouldDeliver(_ fraction: Double) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard fraction != lastValue else { return false }
    let now = ProcessInfo.processInfo.systemUptime
    guard fraction >= 1 || now - lastTime >= 0.08 else { return false }
    lastTime = now
    lastValue = fraction
    return true
  }
}
