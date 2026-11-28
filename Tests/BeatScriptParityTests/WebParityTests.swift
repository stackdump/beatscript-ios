import BeatScriptEngine
import Foundation
import XCTest

/// The engine's own pins: `crates/beatscript-api/tests/cid-pins.json` at the pinned stackdump/beatscript rev, the
/// program and net CIDs beatscript.app computes for every program in that repository (its `cid_pins` test holds
/// the server to them). scripts/build-xcframework.sh copies the file and the programs it names into
/// Fixtures/engine-pins. A pass means the iPad compiles each of them to the same CIDs as the web.
final class EnginePinParityTests: XCTestCase {
  struct Pin {
    let path: String
    let ok: Bool
    let cid: String?
    let nets: [String: String]
  }

  static var dir: URL { Fixtures.dir.appendingPathComponent("engine-pins") }

  static func pins() throws -> [Pin] {
    let doc = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("cid-pins.json")))
        as? [String: [String: Any]])
    return doc.keys.sorted().map { k in
      let v = doc[k]!
      return Pin(path: k, ok: v["ok"] as? Bool ?? false, cid: v["cid"] as? String, nets: v["nets"] as? [String: String] ?? [:])
    }
  }

  func testEveryPinnedProgramHasTheWebsProgramAndNetCIDs() throws {
    let pins = try Self.pins()
    XCTAssertGreaterThanOrEqual(pins.count, 40, "the engine pins every program in its repository")
    var programs = 0, nets = 0
    var cannotRun: [String] = []
    for p in pins {
      let text = try String(contentsOf: Self.dir.appendingPathComponent(p.path), encoding: .utf8)
      let ev = beatscriptCheck(text: text, storeDir: nil)
      if let want = p.cid {
        XCTAssertEqual(beatscriptCid(text: text), want, "\(p.path): program CID")
        if ev.ok { XCTAssertEqual(ev.cid, want, "\(p.path): the check's program CID") }
        programs += 1
      }
      if p.ok && ev.ok {
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: ev.nets.map { ($0.key, $0.cid) }), p.nets, "\(p.path): net CIDs")
        nets += 1
      } else if p.ok != ev.ok {
        // the phone's registry (its voices, no samples) can refuse what the desktop runs; the CIDs above still hold
        cannotRun.append("\(p.path) web ok=\(p.ok) ipad ok=\(ev.ok) \(ev.diagnostics.filter { $0.severity == "error" }.map(\.message).prefix(1))")
      }
    }
    print("PARITY engine-pins: \(pins.count) pinned, \(programs) program CIDs and \(nets) net sets compared, \(cannotRun.count) checked differently: \(cannotRun)")
    XCTAssertGreaterThanOrEqual(nets, 40, "most of the pinned programs compare net by net")
  }
}

/// The deployed site: beatscript.app's `POST /api/check` gives the iPad's program and net CIDs for the golden set
/// and the bundled examples. Needs the network (skipped without it).
final class SiteCheckParityTests: XCTestCase {
  struct WebCheck: Decodable {
    let ok: Bool
    let cid: String?
    let nets: [String: String]?
  }

  func webCheck(_ text: String) async throws -> WebCheck {
    var req = URLRequest(url: URL(string: "https://beatscript.app/api/check")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "content-type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
    req.timeoutInterval = 20
    let data: Data, resp: URLResponse
    do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw XCTSkip("no network: \(error)") }
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
      throw XCTSkip("beatscript.app answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    return try JSONDecoder().decode(WebCheck.self, from: data)
  }

  func testTheSiteChecksTheGoldensAndExamplesToTheIPadsCIDs() async throws {
    var programs: [(String, String)] = try Fixtures.goldens().map { ($0.name, try Fixtures.program($0.name)) }
    programs += beatscriptExamples().filter { !$0.usesUnavailable }.map { ("example \($0.name)", $0.text) }
    var compared = 0
    for (name, text) in programs {
      let web = try await webCheck(text)
      let ev = beatscriptCheck(text: text, storeDir: nil)
      XCTAssertEqual(ev.ok, web.ok, "\(name): ok")
      XCTAssertEqual(beatscriptCid(text: text), web.cid, "\(name): program CID")
      if ev.ok && web.ok {
        XCTAssertEqual(ev.cid, web.cid, "\(name): the check's program CID")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: ev.nets.map { ($0.key, $0.cid) }), web.nets ?? [:], "\(name): net CIDs")
      }
      compared += 1
    }
    print("PARITY site: \(compared) programs checked on beatscript.app and here")
  }
}
