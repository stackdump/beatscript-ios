import BeatScriptEngine
import Foundation
import Observation
import os

let log = Logger(subsystem: "app.beatscript", category: "script")

/// The script edition's state: the editor's text, what the checker says about it, the running program
/// (polled from the engine), and the tools row's actions. One engine, made at launch.
@MainActor @Observable
public final class ScriptModel {
  public private(set) var engine: BeatScriptEngine?
  public private(set) var engineError: String?
  public let storeDir: String

  /// The editor's text. Every change is checked (debounced) for the problems line.
  public var text: String = "" { didSet { if text != oldValue { scheduleCheck() } } }
  public private(set) var check: BeatscriptEval?
  public private(set) var lastEval: BeatscriptEval?
  public private(set) var status: BeatscriptStatus?
  public private(set) var marks: BeatscriptMarks?
  public private(set) var tempo: Double = 0
  public private(set) var level: Float = 0
  public var follow = true
  /// A note for the person, shown in the card that did the thing (DESIGN: no toasts).
  public var note: String?
  public private(set) var examples: [BeatscriptExample] = []
  public private(set) var share: Links.SiteForms?
  public let pairing: Pairing

  private var checkTask: Task<Void, Never>?
  private var timer: Timer?
  private var tick = 0

  private let soundFontDir: String?

  public init(storeDir: String? = nil, soundFontDir: String? = nil) {
    let store = storeDir ?? BeatScriptEngine.defaultDir("programs")
    self.storeDir = store
    self.soundFontDir = soundFontDir
    pairing = Pairing()
    examples = beatscriptExamples()
    if let first = examples.first(where: { $0.name == "arrange-in-eight-lines" }) ?? examples.first {
      text = first.text
    }
    pairing.attach(self)
    start()
  }

  // MARK: the transport

  /// The engine opens the audio output, so it is made at the first Eval, not at launch: the editor, the
  /// checker, Open and Share work before (and without) a sound card.
  @discardableResult
  public func startEngine() -> BeatScriptEngine? {
    if let engine { return engine }
    do {
      let e = try BeatScriptEngine(soundFontDir: soundFontDir, storeDir: storeDir)
      engine = e
      engineError = nil
      log.info("engine up: \(e.info.sampleRate) Hz, \(e.info.soundFonts) soundfonts")
    } catch {
      engineError = "The engine didn't start: \(error)"
      log.error("engine failed: \(String(describing: error), privacy: .public)")
    }
    return engine
  }

  public var running: Bool { status?.running == true && status?.ended != true }

  /// Eval: check and stage the editor's text (lands on the next bar; at once when nothing plays).
  public func eval() {
    guard let engine = startEngine() else { note = engineError; return }
    let t = text
    Task.detached(priority: .userInitiated) {
      let ev = engine.eval(t)
      await MainActor.run {
        self.lastEval = ev
        self.check = ev
        if ev.ok {
          self.note = nil
          log.info("eval ok \(ev.cid ?? "-", privacy: .public) lands \(ev.landsAt, privacy: .public)")
        } else {
          self.note = ev.kept
          log.error("eval: \(ev.errors) errors: \(ev.diagnostics.first?.rendered ?? "", privacy: .public)")
        }
        self.poll(all: true)
      }
    }
  }

  /// Stop: the program ends and nothing sounds, at once (beatscript.app's Stop). Never the language's
  /// `stop`, which leaves the decks playing.
  public func stop() {
    guard let engine else { return }
    engine.stop()
    log.info("stop: level after \(engine.level(), privacy: .public)")
    poll(all: true)
  }

  public func fmt() {
    let f = beatscriptFmt(text: text)
    if f.ok { text = f.text } else { check = check.map { $0 } }
  }

  /// Open a link, a fragment or a CID into the editor, and Eval it.
  public func open(_ raw: String, play: Bool = true) async {
    if case .pair = Links.classify(raw) {
      await pairing.pair(raw)
      return
    }
    do {
      let o = try await Opener(storeDir: storeDir).open(raw)
      text = o.text
      note = o.warnings.isEmpty ? "Opened \(o.cid.prefix(14))… from \(o.from)." : o.warnings.joined(separator: " ")
      log.info("opened \(o.cid, privacy: .public) from \(o.from, privacy: .public)")
      if play { eval() }
    } catch {
      note = "\(error)"
      log.error("open refused: \(String(describing: error), privacy: .public)")
    }
  }

  public func load(example: BeatscriptExample) {
    text = example.text
    note = nil
  }

  public func makeShare() {
    do {
      share = try Links.share(text, storeDir: storeDir)
      note = nil
    } catch {
      share = nil
      note = "\(error)"
    }
  }

  // MARK: what the header and the editor show

  /// The program's name: its `#! name:` header, else the example's name, else "untitled".
  public var name: String {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12) {
      let l = line.trimmingCharacters(in: .whitespaces)
      if l.hasPrefix("#! name:") { return l.dropFirst("#! name:".count).trimmingCharacters(in: .whitespaces) }
    }
    return examples.first(where: { $0.text == text })?.name ?? "untitled"
  }

  /// Time into the song, from the program bar and the tempo heard.
  public var elapsed: TimeInterval {
    guard let s = status, s.running, tempo > 0 else { return 0 }
    return (Double(s.bar) + s.barFrac) * 4 * 60 / tempo
  }

  /// The marks apply only while the editor holds the text the program was evaluated from.
  public var liveMarks: BeatscriptMarks? {
    guard let m = marks, m.running, m.source == text else { return nil }
    return m
  }

  /// The problems line: the latest check of the editor's text.
  public var problems: [BeatscriptDiag] { check?.diagnostics ?? [] }

  // MARK: polling

  private func start() {
    let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll(all: false) }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  /// Marks about 30 times a second, the status and the decks about 10.
  func poll(all: Bool) {
    guard let engine else { return }
    tick &+= 1
    marks = engine.marks()
    if all || tick % 3 == 0 {
      status = engine.status()
      let decks = ["A", "B"].compactMap { engine.deck($0) }
      tempo = decks.first(where: { $0.playing })?.tempo ?? decks.first?.tempo ?? tempo
      level = engine.level()
    }
    if tick % 30 == 0, running {
      log.debug("playing bar \(self.status?.bar ?? -1) level \(self.level)")
    }
    if tick % 15 == 0 { pairing.report() }
  }

  private func scheduleCheck() {
    checkTask?.cancel()
    let t = text
    let store = storeDir
    checkTask = Task.detached(priority: .utility) { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      if Task.isCancelled { return }
      let ev = beatscriptCheck(text: t, storeDir: store)
      await MainActor.run { [weak self] in
        guard let self, self.text == t else { return }
        self.check = ev
      }
    }
  }
}
