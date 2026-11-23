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
    try String(contentsOf: dir.appendingPathComponent("btw-examples/\(name).btw"), encoding: .utf8)
  }

  struct Golden {
    let name: String
    let program: String
    let nets: [String: String]
    let bars: Int?
  }

  static func goldens() throws -> [Golden] {
    let doc = try XCTUnwrap(json("btw_golden.json") as? [String: [String: Any]])
    return doc.keys.sorted().map { name in
      let v = doc[name]!
      return Golden(
        name: name, program: v["program"] as? String ?? "", nets: v["nets"] as? [String: String] ?? [:],
        bars: v["bars"] as? Int)
    }
  }
}

/// btw_parity: the iPad's checker gives the desktop's (and the phone's) program and net CIDs.
final class BtwParityTests: XCTestCase {
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
      let ev = btwCheck(text: text, storeDir: nil)
      XCTAssertTrue(ev.ok, "\(g.name) must check: \(ev.diagnostics.map(\.rendered))")
      XCTAssertEqual(ev.cid, g.program, "\(g.name): program CID")
      XCTAssertEqual(Dictionary(uniqueKeysWithValues: ev.nets.map { ($0.key, $0.cid) }), g.nets, "\(g.name): net CIDs")
      XCTAssertEqual(btwCid(text: text), g.program, "\(g.name): btw_cid")
    }
  }

  func testFmtKeepsTheCIDAndIsAFixedPoint() throws {
    for g in try Fixtures.goldens() {
      let once = btwFmt(text: try Fixtures.program(g.name))
      XCTAssertTrue(once.ok, "\(g.name): fmt")
      XCTAssertEqual(once.cid, g.program, "\(g.name): fmt keeps the CID")
      XCTAssertEqual(btwCid(text: once.text), g.program, "\(g.name): the formatted text has the CID")
      XCTAssertEqual(btwFmt(text: once.text).text, once.text, "\(g.name): fmt is a fixed point")
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
        let o = btwOpenLink(link: frag, storeDir: nil)
        XCTAssertTrue(o.ok, "\(g.name): \(o.refused ?? "")")
        XCTAssertEqual(o.cid, g.program, "\(g.name) via \(link.prefix(40))")
      }
    }
  }

  /// The examples the engine ships carry the CIDs it computes.
  func testBundledExamplesCarryTheirCIDs() {
    let ex = btwExamples()
    XCTAssertGreaterThanOrEqual(ex.count, 9)
    for e in ex where !e.usesUnavailable {
      XCTAssertEqual(btwCid(text: e.text), e.cid, e.name)
    }
  }
}

/// generate_parity: the iPad's seeded generator makes what MCP `generate` (and the phone) makes.
final class GenerateParityTests: XCTestCase {
  struct Fixture {
    let req: BtwGenRequest
    let text, cid, name, generator: String
  }

  static func fixtures() throws -> [Fixture] {
    let arr = try XCTUnwrap(Fixtures.json("generate_fixtures.json") as? [[String: Any]])
    return arr.map { e in
      let i = e["input"] as? [String: Any] ?? [:]
      let s = { (d: [String: Any], k: String) in d[k] as? String ?? "" }
      return Fixture(
        req: BtwGenRequest(genre: s(i, "genre"), seed: s(i, "seed"), bpm: (i["bpm"] as? NSNumber)?.doubleValue, key: s(i, "key"), length: s(i, "length")),
        text: s(e, "text"), cid: s(e, "cid"), name: s(e, "name"), generator: s(e, "generator"))
    }
  }

  func testTheIPadGeneratesWhatMCPGenerateDoes() throws {
    let fx = try Self.fixtures()
    XCTAssertGreaterThanOrEqual(fx.count, 7)
    XCTAssertTrue(fx.contains { $0.req.genre == "trap" && $0.req.seed == "54877" && $0.req.bpm == 140 && $0.req.key == "dm" })
    XCTAssertTrue(fx.contains { $0.req.genre == "dubstep" && $0.req.seed == "54876" })
    for f in fx {
      let label = "\(f.req.genre) \(f.req.seed) bpm=\(String(describing: f.req.bpm)) key=\(f.req.key) length=\(f.req.length)"
      let g = try btwGenerate(req: f.req)
      XCTAssertEqual(g.text, f.text, "\(label): the text")
      XCTAssertEqual(g.cid, f.cid, "\(label): the CID")
      XCTAssertEqual(g.name, f.name, "\(label): the track name")
      XCTAssertEqual(g.generator, f.generator, label)
      XCTAssertEqual(btwGenerator(), f.generator, "\(label): the build's generator is the fixtures'")
      let ev = btwCheck(text: f.text, storeDir: nil)
      XCTAssertTrue(ev.ok, "\(label): \(ev.diagnostics.filter { $0.severity == "error" }.map(\.message))")
      XCTAssertEqual(ev.cid, f.cid, "\(label): btw_check")
      XCTAssertEqual(btwCid(text: f.text), f.cid, "\(label): btw_cid")
      let h = try XCTUnwrap(btwSeeded(text: f.text), "\(label): no seeded header")
      XCTAssertEqual(h.seed, f.req.seed, label)
      XCTAssertTrue(h.current, label)
      XCTAssertEqual(try btwRegenerate(text: f.text, seed: f.req.seed).text, f.text, "\(label): made again from its own header")
    }
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
    XCTAssertEqual(btwCid(text: o.text), trap.cid)
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
