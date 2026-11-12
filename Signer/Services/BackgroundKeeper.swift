import AVFoundation
import Foundation

@MainActor
final class BackgroundKeeper {
  static let shared = BackgroundKeeper()
  private var player: AVAudioPlayer?
  private var owners = Set<String>()
  func set(_ enabled: Bool, owner: String) throws {
    if enabled { owners.insert(owner) } else { owners.remove(owner) }
    guard !owners.isEmpty else {
      player?.stop()
      player = nil
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      return
    }
    if player != nil { return }
    let rate: UInt32 = 8000
    let bytes: UInt32 = 16000
    var wav = Data("RIFF".utf8)
    func append32(_ n: UInt32) {
      var n = n.littleEndian
      withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) }
    }
    func append16(_ n: UInt16) {
      var n = n.littleEndian
      withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) }
    }
    append32(bytes + 36)
    wav.append(Data("WAVEfmt ".utf8))
    append32(16)
    append16(1)
    append16(1)
    append32(rate)
    append32(rate * 2)
    append16(2)
    append16(16)
    wav.append(Data("data".utf8))
    append32(bytes)
    wav.append(Data(repeating: 0, count: Int(bytes)))
    try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
    try AVAudioSession.sharedInstance().setActive(true)
    let audio = try AVAudioPlayer(data: wav)
    audio.numberOfLoops = -1
    audio.volume = 0.01
    guard audio.play() else {
      throw NSError(
        domain: "Signer.Background", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to start background session."])
    }
    player = audio
  }
}
