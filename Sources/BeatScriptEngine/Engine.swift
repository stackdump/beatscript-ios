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

  /// Check and stage `text`: it lands on the next bar (at once when nothing plays).
  public func eval(_ text: String) -> BtwEval { player.btwEval(text: text) }

  /// The app's Stop (beatscript.app's Stop): the program ends and nothing sounds, at once.
  /// The language's own `stop` (decks play on) is `player.btwStop()`; this is not that.
  public func stop() { player.btwStopSound() }

  public func status() -> BtwStatus { player.btwStatus() }
  public func marks() -> BtwMarks { player.btwMarks() }
  public func deck(_ d: String) -> DeckState? { try? player.state(deck: d) }

  /// The loudest deck's meter, 0 when nothing is loaded.
  public func level() -> Float {
    ["A", "B"].compactMap { deck($0) }.map { $0.playing || $0.level > 0 ? $0.level : 0 }.max() ?? 0
  }

  public func shutdown() { player.shutdown() }
}
