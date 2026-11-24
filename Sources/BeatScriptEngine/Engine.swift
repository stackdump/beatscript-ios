import Foundation

#if canImport(AVFAudio) && os(iOS)
  import AVFAudio
#endif

/// The BeatScript engine (the Android app's `djmobile` crate over stackdump/beatscript, through UniFFI)
/// behind a small Swift face. It owns the audio output (cpal → CoreAudio) and its own clocks: a
/// program evaluated here plays on the engine's decks A and B, exactly as on the phone.
public final class BeatScriptEngine: @unchecked Sendable {
  public let player: Player
  public let info: EngineInfo

  /// `soundFontDir`: a folder of .sf2 banks (missing is fine: synth voices play).
  /// `storeDir`: the saved programs (`import "name"` reads them; a bare CID opens from them first).
  public init(soundFontDir: String? = nil, storeDir: String? = nil) throws {
    BeatScriptEngine.startAudioSession()
    player = try Player(soundfontDir: soundFontDir ?? BeatScriptEngine.defaultDir("soundfonts"))
    info = player.info()
    let store = storeDir ?? BeatScriptEngine.defaultDir("programs")
    try? FileManager.default.createDirectory(atPath: store, withIntermediateDirectories: true)
    player.btwUseStore(dir: store)
  }

  /// Documents/<name>: visible in the Files app on an iPad.
  public static func defaultDir(_ name: String) -> String {
    let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent(name).path
  }

  /// iOS: the `.playback` category before the engine opens its output (background audio, the
  /// mute switch ignored, as a music app).
  public static func startAudioSession() {
    #if canImport(AVFAudio) && os(iOS)
      let s = AVAudioSession.sharedInstance()
      try? s.setCategory(.playback, mode: .default, options: [])
      try? s.setActive(true)
    #endif
  }

  public static let decks = ["A", "B"]

  /// The faders Stop pulled down, and the volume each goes back to on the next eval.
  private var faded: [String: Double] = [:]
  private let fadedLock = NSLock()

  /// Check and stage `text`: it lands on the next bar (at once when nothing plays). A deck Stop
  /// faded out gets its fader back first, so the program is heard from its first step.
  public func eval(_ text: String) -> BtwEval {
    restoreFaders()
    return player.btwEval(text: text)
  }

  /// The app's Stop (beatscript.app's Stop): the program ends and nothing sounds, at once.
  /// The language's own `stop` (decks play on) is `player.btwStop()`; this is not that.
  ///
  /// `btwStopSound` alone is neither at once nor silent. It queues the decks' stop for the render
  /// thread, and `state(deck).playing` is that thread's mirror, written at the end of its next
  /// block. And djrust's transport stop is all-notes-off (CC 123), not all-sound-off: "the tails ring
  /// out, as a deck's room does", so the strips stay above -60 dB for a second or more. So the
  /// faders go down too (the strip gain is ramped across one block: no click), the tails ring out
  /// behind them unheard, and this returns once the render thread has taken the stop (the mirrors
  /// read stopped), or after `wait` seconds with no audio running.
  public func stop(wait: TimeInterval = 0.25) {
    player.btwStopSound()
    // read after the stop: it has put back what the program's own `mixer` lines changed
    fadedLock.lock()
    for d in Self.decks {
      guard let s = deck(d), s.loaded else { continue }
      if faded[d] == nil { faded[d] = s.volume }
      try? player.setVolume(deck: d, volume: 0)
    }
    fadedLock.unlock()
    let end = Date().addingTimeInterval(wait)
    while Self.decks.contains(where: { deck($0)?.playing == true }), Date() < end {
      Thread.sleep(forTimeInterval: 0.002)
    }
  }

  /// The faders Stop pulled down, back where they were.
  private func restoreFaders() {
    fadedLock.lock()
    defer { fadedLock.unlock() }
    for (d, v) in faded { try? player.setVolume(deck: d, volume: v) }
    faded.removeAll()
  }

  public func status() -> BtwStatus { player.btwStatus() }
  public func marks() -> BtwMarks { player.btwMarks() }
  public func deck(_ d: String) -> DeckState? { try? player.state(deck: d) }

  /// The loudest deck as heard: its meter (the strip's peak, before the fader) times its fader.
  /// 0 when nothing is loaded.
  public func level() -> Float {
    Self.decks.compactMap { deck($0) }.map { $0.level * Float($0.volume) }.max() ?? 0
  }

  public func shutdown() { player.shutdown() }
}
