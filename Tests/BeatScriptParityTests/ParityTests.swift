import BeatScriptEngine
import Foundation
import XCTest

@testable import BeatScriptUI

/// The fixtures scripts/build-xcframework.sh copies from the pinned engine crate: the same files the Android
/// app's `btw_parity` and `generate_parity` suites read, so a pass here means the iPad computes what the phone
/// (and the desktop checker that wrote the goldens) computes.
enum Fixtures {
  static var dir: URL { Bundle.module.resourceURL!.appendingPathComponent("Fixtures") }

  static func json(_ name: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name)))
  }

  static func program(_ name: String) throws -> String {
    try String(contentsOf: dir.appendingPathComponent("beatscript-examples/\(name).beatscript"), encoding: .utf8)
  }

  struct Golden {
    let name: String
    let program: String
    let nets: [String: String]
    let bars: Int?
  }

  static func goldens() throws -> [Golden] {
    let doc = try XCTUnwrap(json("beatscript_golden.json") as? [String: [String: Any]])
    return doc.keys.sorted().map { name in
      let v = doc[name]!
      return Golden(
        name: name, program: v["program"] as? String ?? "", nets: v["nets"] as? [String: String] ?? [:],
        bars: v["bars"] as? Int)
    }
  }
}

/// btw_parity: the iPad's checker gives the desktop's (and the phone's) program and net CIDs.
final class BeatscriptParityTests: XCTestCase {
  func testTheGoldenSetIsTheDocumentedOne() throws {
    let names = try Fixtures.goldens().map(\.name)
    for want in ["arrange-in-eight-lines", "hand-dubstep-140-v2", "hand-dubstep-140-v4", "matrix-130", "markers-demo", "trance-138"] {
      XCTAssertTrue(names.contains(want), "\(want) is in the parity set: \(names)")
    }
    XCTAssertEqual(names.count, 10, "\(names)")
  }

  func testTheCheckerGivesTheGoldenProgramAndNetCIDs() throws {
    for g in try Fixtures.goldens() {
      let text = try Fixtures.program(g.name)
      let ev = beatscriptCheck(text: text, storeDir: nil)
      XCTAssertTrue(ev.ok, "\(g.name) must check: \(ev.diagnostics.map(\.rendered))")
      XCTAssertEqual(ev.cid, g.program, "\(g.name): program CID")
      XCTAssertEqual(Dictionary(uniqueKeysWithValues: ev.nets.map { ($0.key, $0.cid) }), g.nets, "\(g.name): net CIDs")
      XCTAssertEqual(beatscriptCid(text: text), g.program, "\(g.name): btw_cid")
    }
  }

  func testFmtKeepsTheCIDAndIsAFixedPoint() throws {
    for g in try Fixtures.goldens() {
      let once = beatscriptFmt(text: try Fixtures.program(g.name))
      XCTAssertTrue(once.ok, "\(g.name): fmt")
      XCTAssertEqual(once.cid, g.program, "\(g.name): fmt keeps the CID")
      XCTAssertEqual(beatscriptCid(text: once.text), g.program, "\(g.name): the formatted text has the CID")
      XCTAssertEqual(beatscriptFmt(text: once.text).text, once.text, "\(g.name): fmt is a fixed point")
    }
  }

  /// A program's link opens to the same CID, through every form the site uses for it.
  func testShareLinksRoundTripThroughEverySiteForm() throws {
    for g in try Fixtures.goldens() {
      let text = try Fixtures.program(g.name)
      let forms = try Links.share(text)
      XCTAssertTrue(forms.page.hasPrefix("https://beatscript.app/#\(g.program)."), forms.page)
      XCTAssertTrue(forms.posts.hasPrefix("https://beatscript.app/c/\(g.program)."), forms.posts)
      for link in [forms.engine, forms.page, forms.posts, "beatscript://beatscript.app/#" + forms.page.split(separator: "#")[1]] {
        guard case .program(let frag) = Links.classify(link) else { return XCTFail("\(g.name): \(link) is a program link") }
        let o = beatscriptOpenLink(link: frag, storeDir: nil)
        XCTAssertTrue(o.ok, "\(g.name): \(o.refused ?? "")")
        XCTAssertEqual(o.cid, g.program, "\(g.name) via \(link.prefix(40))")
      }
    }
  }

  /// The examples the engine ships carry the CIDs it computes.
  func testBundledExamplesCarryTheirCIDs() {
    let ex = beatscriptExamples()
    XCTAssertGreaterThanOrEqual(ex.count, 9)
    for e in ex where !e.usesUnavailable {
      XCTAssertEqual(beatscriptCid(text: e.text), e.cid, e.name)
    }
  }
}

/// generate_parity: the iPad's seeded generator makes what MCP `generate` (and the phone) makes.
final class GenerateParityTests: XCTestCase {
  struct Fixture {
    let req: BeatscriptGenRequest
    let text, cid, name, generator: String
  }

  static func fixtures() throws -> [Fixture] {
    let arr = try XCTUnwrap(Fixtures.json("generate_fixtures.json") as? [[String: Any]])
    return arr.map { e in
      let i = e["input"] as? [String: Any] ?? [:]
      let s = { (d: [String: Any], k: String) in d[k] as? String ?? "" }
      return Fixture(
        req: BeatscriptGenRequest(genre: s(i, "genre"), seed: s(i, "seed"), bpm: (i["bpm"] as? NSNumber)?.doubleValue, key: s(i, "key"), length: s(i, "length")),
        text: s(e, "text"), cid: s(e, "cid"), name: s(e, "name"), generator: s(e, "generator"))
    }
  }

  func testTheIPadGeneratesWhatMCPGenerateDoes() throws {
    let fx = try Self.fixtures()
    if let have = fx.first?.generator, have != beatscriptGenerator() {
      // strict: once beatscript-app regenerates its fixtures at the engine's generator this passes, and the
      // expectation fails the run until it is removed. The fixtures are never re-blessed here.
      XCTExpectFailure(
        "beatscript-app's generate_fixtures.json is \(have); this engine (rust/PINS) generates \(beatscriptGenerator()). "
          + "testTheIPadGeneratesTheEnginesSeededVersion holds the iPad meanwhile")
    }
    XCTAssertGreaterThanOrEqual(fx.count, 7)
    XCTAssertTrue(fx.contains { $0.req.genre == "trap" && $0.req.seed == "54877" && $0.req.bpm == 140 && $0.req.key == "dm" })
    XCTAssertTrue(fx.contains { $0.req.genre == "dubstep" && $0.req.seed == "54876" })
    for f in fx {
      let label = "\(f.req.genre) \(f.req.seed) bpm=\(String(describing: f.req.bpm)) key=\(f.req.key) length=\(f.req.length)"
      let g = try beatscriptGenerate(req: f.req)
      XCTAssertEqual(g.text, f.text, "\(label): the text")
      XCTAssertEqual(g.cid, f.cid, "\(label): the CID")
      XCTAssertEqual(g.name, f.name, "\(label): the track name")
      XCTAssertEqual(g.generator, f.generator, label)
      XCTAssertEqual(beatscriptGenerator(), f.generator, "\(label): the build's generator is the fixtures'")
      let ev = beatscriptCheck(text: f.text, storeDir: nil)
      XCTAssertTrue(ev.ok, "\(label): \(ev.diagnostics.filter { $0.severity == "error" }.map(\.message))")
      XCTAssertEqual(ev.cid, f.cid, "\(label): btw_check")
      XCTAssertEqual(beatscriptCid(text: f.text), f.cid, "\(label): btw_cid")
      let h = try XCTUnwrap(beatscriptSeeded(text: f.text), "\(label): no seeded header")
      XCTAssertEqual(h.seed, f.req.seed, label)
      XCTAssertTrue(h.current, label)
      XCTAssertEqual(try beatscriptRegenerate(text: f.text, seed: f.req.seed).text, f.text, "\(label): made again from its own header")
    }
  }
}

extension GenerateParityTests {
  /// The engine's own rule (stackdump/beatscript crates/beatscript-api/tests/gen.rs): seeded@4 is seeded@3 with the
  /// acid genre's bass on the 303, so for every other genre a seeded@3 fixture is seeded@4's program but for its
  /// `#! generator:` line, which is a header and not in the canonical text (the CID is the same). This holds the iPad
  /// to the web's generator while beatscript-app's fixtures still name seeded@3. (acid 4411 short was compared with
  /// beatscript.app's MCP `generate` by hand: z4EBG9jDFzqUZFBiVQ8GozXtDqaNZGzsej5wyEp3UJW3DTzKiyK on both.)
  func testTheIPadGeneratesTheEnginesSeededVersion() throws {
    let fx = try Self.fixtures()
    guard fx.first?.generator == "seeded@3", beatscriptGenerator() == "seeded@4" else {
      throw XCTSkip("fixtures \(fx.first?.generator ?? "none"), engine \(beatscriptGenerator()): the fixture test holds them")
    }
    var compared = 0
    for f in fx where f.req.genre != "acid" {
      let label = "\(f.req.genre) \(f.req.seed) bpm=\(String(describing: f.req.bpm)) key=\(f.req.key) length=\(f.req.length)"
      let g = try beatscriptGenerate(req: f.req)
      XCTAssertEqual(g.text, f.text.replacingOccurrences(of: "#! generator: seeded@3", with: "#! generator: seeded@4"), "\(label): the text")
      XCTAssertEqual(g.cid, f.cid, "\(label): the CID")
      XCTAssertEqual(g.name, f.name, "\(label): the track name")
      XCTAssertEqual(g.generator, "seeded@4", label)
      let h = try XCTUnwrap(beatscriptSeeded(text: g.text), "\(label): no seeded header")
      XCTAssertTrue(h.current, label)
      XCTAssertEqual(try beatscriptRegenerate(text: g.text, seed: f.req.seed).text, g.text, "\(label): made again from its own header")
      compared += 1
    }
    XCTAssertGreaterThanOrEqual(compared, 6)
  }
}

/// The site: the trap 54877 program is stored on beatscript.app under the CID the fixtures name, and the app's
/// own fetch recomputes and accepts it. Needs the network (skipped without it).
final class SiteParityTests: XCTestCase {
  func testBeatscriptAppServesTheGeneratedTrapUnderTheSameCID() async throws {
    let trap = try XCTUnwrap(GenerateParityTests.fixtures().first { $0.req.genre == "trap" && $0.req.seed == "54877" })
    let o: Opened
    do { o = try await Opener().fetch(trap.cid) } catch OpenError.network(let why) {
      throw XCTSkip("no network: \(why)")
    }
    XCTAssertEqual(o.cid, trap.cid)
    XCTAssertEqual(beatscriptCid(text: o.text), trap.cid)
  }

  func testABareCIDOpensFromTheSite() async throws {
    let trap = try XCTUnwrap(GenerateParityTests.fixtures().first { $0.req.genre == "trap" })
    do {
      let o = try await Opener(storeDir: NSTemporaryDirectory()).open("https://beatscript.app/p/\(trap.cid)")
      XCTAssertEqual(o.cid, trap.cid)
      XCTAssertEqual(o.from, "beatscript.app")
    } catch OpenError.network(let why) { throw XCTSkip("no network: \(why)") }
  }
}

/// The link router: each way a code arrives goes to the flow it belongs to.
final class LinkTests: XCTestCase {
  let cid = "z4EBG9jAdboLqgkepUrCh9Q928jS3vgubQUZ3LyFz6f5fzSsgNj"

  func testForms() {
    XCTAssertEqual(Links.classify("https://beatscript.app/#\(cid).abc~n"), .program("\(cid).abc~n"))
    XCTAssertEqual(Links.classify("https://beatscript.app/c/\(cid).abc"), .program("\(cid).abc"))
    XCTAssertEqual(Links.classify("https://beats.bitwrap.io/p#\(cid).abc"), .program("\(cid).abc"))
    XCTAssertEqual(Links.classify("https://btw.bitwrap.io/p#\(cid).abc.sig"), .program("\(cid).abc.sig"))
    XCTAssertEqual(Links.classify("https://beatscript.app/p/\(cid)"), .cid(cid))
    XCTAssertEqual(Links.classify("https://beatscript.app/c/\(cid).jsonld"), .cid(cid))
    XCTAssertEqual(Links.classify("  \(cid)\n"), .cid(cid))
    XCTAssertEqual(Links.classify("beatscript://beatscript.app/#\(cid).x"), .program("\(cid).x"))
    XCTAssertEqual(Links.classify("https://beatscript.app/pair#abcdefghijklmnopqrstuv.abcdefghijklmnopqrstuv"),
                   .pair("https://beatscript.app/pair#abcdefghijklmnopqrstuv.abcdefghijklmnopqrstuv"))
    XCTAssertEqual(Links.classify("https://example.com/whatever"), .unknown)
    XCTAssertEqual(Links.classify("hello"), .unknown)
  }
}
