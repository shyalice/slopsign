import Foundation

/// Count distinct successfully sent bytes across overlapping/retried ranges.
public final class PayloadTransfer: @unchecked Sendable {
  public let id = UUID()
  public let size: UInt64
  private let lock = NSLock()
  private var intervals: [Range<UInt64>] = []
  public init(size: UInt64) { self.size = size }
  public func sent(_ interval: Range<UInt64>) -> (fraction: Double, complete: Bool) {
    lock.lock(); defer { lock.unlock() }
    let bounded = min(interval.lowerBound, size)..<min(interval.upperBound, size)
    if !bounded.isEmpty { intervals.append(bounded) }
    intervals.sort { $0.lowerBound < $1.lowerBound }
    var merged: [Range<UInt64>] = []
    for range in intervals {
      if let previous = merged.last, range.lowerBound <= previous.upperBound {
        merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
      } else { merged.append(range) }
    }
    intervals = merged
    let bytes = merged.reduce(UInt64(0)) { $0 + $1.upperBound - $1.lowerBound }
    return (size == 0 ? 1 : Double(bytes) / Double(size), bytes == size)
  }
}
