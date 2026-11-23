import BeatScriptEngine
import BeatScriptUI
import Foundation
import XCTest

/// The engine playing for real, on the device's output: an `arrange { } loop` program plays past its first
/// section (6687: the old engine refused the block), and Stop silences at once (beatscript.app's Stop, not the
/// language's `stop`, which leaves the decks playing). Runs on the iOS simulator / an iPad; on a Mac only with
/// BEATSCRIPT_AUDIO_TESTS=1 (it plays on the speakers).
final class PlaybackTests: XCTestCase {
  /// Our own arrangement with mutations between sections and a loop (the shape of 6687).
  static let arrangeLoop = """
    #! name: arrange loop check
    tempo 132
    key am
    let acid = a1! ~ a1 ~ c2^ ~ a1 e2 ~ a1 ~ ~ g1 ~ a1 ~
    let lift = a3 ~ c4 ~ e4 ~ ~ ~
    section intro 2 bars {
      deck A: kick x ~ x ~ | hihat ~ x ~ x
    }
    section drop 2 bars {
      deck A: kick x ~ x ~ | snare ~ x ~ x | hihat x x x x
      deck B: bass acid inst=fm-bass | melody lift
    }
    section outro 2 bars {
      deck A: kick x ~ ~ ~
    }
    arrange {
      intro drop
      ~ acid rot 2, lift up 2
      drop
    } loop 2 then outro end

    """

  static var engine: BeatScriptEngine?

  override func setUpWithError() throws {
    #if !os(iOS)
      guard ProcessInfo.processInfo.environment["BEATSCRIPT_AUDIO_TESTS"] == "1" else {
        throw XCTSkip("plays on the speakers: BEATSCRIPT_AUDIO_TESTS=1")
      }
    #endif
    if Self.engine == nil {
      Self.engine = try BeatScriptEngine(storeDir: NSTemporaryDirectory() + "beatscript-tests")
    }
  }

  func wait(_ seconds: Double, until ok: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      if ok() { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return ok()
  }

  func testAnArrangeLoopChecksPlaysPastItsFirstSectionAndStopSilencesAtOnce() throws {
    let e = try XCTUnwrap(Self.engine)
    let ck = btwCheck(text: Self.arrangeLoop, storeDir: nil)
    XCTAssertTrue(ck.ok, "\(ck.diagnostics.map(\.rendered))")
    XCTAssertTrue(ck.unavailable.isEmpty, "\(ck.unavailable)")

    let ev = e.eval(Self.arrangeLoop)
    XCTAssertTrue(ev.ok, "\(ev.diagnostics.map(\.rendered))")
    XCTAssertTrue(wait(5) { e.status().running }, "the program runs")

    var seen: [String] = []
    var loud: Float = 0
    _ = wait(12) {
      if let s = e.status().section, seen.last != s { seen.append(s) }
      loud = max(loud, e.level())
      return seen.contains("drop") && loud > 0.01
    }
    print("PLAYBACK sections \(seen) peak level \(loud) plays \(e.status().plays)")
    XCTAssertEqual(seen.first, "intro", "\(seen)")
    XCTAssertTrue(seen.contains("drop"), "the arrangement plays past its first section: \(seen)")
    XCTAssertGreaterThan(loud, 0.01, "it is heard")

    let t0 = Date()
    e.stop()
    let decksStopped = !(["A", "B"].compactMap { e.deck($0) }.contains { $0.playing })
    XCTAssertTrue(decksStopped, "Stop stops every deck before it returns")
    let quiet = wait(1.0) { e.level() < 0.001 }
    let took = Date().timeIntervalSince(t0)
    print("PLAYBACK stop: decks stopped \(decksStopped), level \(e.level()) after \(Int(took * 1000)) ms, running \(e.status().running)")
    XCTAssertTrue(quiet, "silent after Stop: level \(e.level())")
    XCTAssertLessThan(took, 0.25, "silent at once")
    XCTAssertFalse(e.status().running, "the program ended")
    // and nothing starts again: no staged program lands after the stop
    Thread.sleep(forTimeInterval: 2.5)
    XCTAssertLessThan(e.level(), 0.001, "still silent two bars later")
    XCTAssertFalse(["A", "B"].compactMap { e.deck($0) }.contains { $0.playing })
  }
}

/// The arrange-loop program's site links (printed for the simulator check) open back to its CID.
final class ArrangeLoopLinkTests: XCTestCase {
  func testItsSiteLinkOpensToItsCID() throws {
    let cid = try XCTUnwrap(btwCid(text: PlaybackTests.arrangeLoop))
    let forms = try Links.share(PlaybackTests.arrangeLoop)
    print("ARRANGE_LOOP_LINK \(forms.page)")
    print("ARRANGE_LOOP_CID \(cid)")
    guard case .program(let frag) = Links.classify(forms.page) else { return XCTFail(forms.page) }
    XCTAssertEqual(btwOpenLink(link: frag, storeDir: nil).cid, cid)
  }
}
