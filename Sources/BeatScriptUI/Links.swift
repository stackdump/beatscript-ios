import BeatScriptEngine
import Foundation

/// What a pasted, scanned or opened text is. Every way in (Open, a `beatscript://` URL, the launch
/// environment) goes through `classify`, so a code is never judged by the wrong flow.
public enum LinkKind: Equatable, Sendable {
  /// A self-sealing program: `CID.packed` (with its `~notes` / `.sig` tail, if any).
  case program(String)
  /// A CID alone: opens from the saved programs, else from beatscript.app.
  case cid(String)
  /// A beatscript.app pairing code (`https://<site>/pair#<id>.<token>`), whole.
  case pair(String)
  case unknown
}

public enum Links {
  public static let site = "https://beatscript.app"

  /// `https://beatscript.app/#CID.packed`, `/c/CID.packed`, `/p#…` (also beats.bitwrap.io and the old
  /// btw.bitwrap.io), `/p/CID` and `/c/CID` short links, a bare `CID.packed` or `CID`, a pairing code,
  /// and the same behind `beatscript://` (the app's own scheme: `beatscript://beatscript.app/#…`).
  public static func classify(_ raw: String) -> LinkKind {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.lowercased().hasPrefix("beatscript://") {
      s = "https://" + s.dropFirst("beatscript://".count)
    }
    guard !s.isEmpty else { return .unknown }
    if let u = URLComponents(string: s), let scheme = u.scheme?.lowercased(),
      scheme == "https" || scheme == "http", u.host != nil
    {
      let path = u.path
      let frag = u.fragment ?? ""
      if path == "/pair" || path == "/pair/" { return frag.isEmpty ? .unknown : .pair(s) }
      for prefix in ["/c/", "/p/", "/api/programs/"] where path.hasPrefix(prefix) {
        return bare(String(path.dropFirst(prefix.count)))
      }
      if !frag.isEmpty, ["", "/", "/p", "/p/", "/index.html"].contains(path) { return bare(frag) }
      return .unknown
    }
    return bare(s)
  }

  /// `CID.packed…` or `CID` (a trailing `/`, `.jsonld` or `.btw` dropped).
  static func bare(_ text: String) -> LinkKind {
    var t = text.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    for ext in [".jsonld", ".btw"] where t.hasSuffix(ext) { t = String(t.dropLast(ext.count)) }
    let head = t.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    guard isCID(head) else { return .unknown }
    return t.contains(".") ? .program(t) : .cid(t)
  }

  /// A BeatScript CID: base58btc, multibase `z`.
  public static func isCID(_ s: String) -> Bool {
    let alphabet = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    return s.hasPrefix("z") && (40...80).contains(s.count) && s.allSatisfy { alphabet.contains($0) }
  }

  /// The site's forms of a program's link: the self-sealing page link and the link for posts.
  public struct SiteForms: Equatable, Sendable {
    public let engine: String
    public let page: String
    public let posts: String
  }

  /// `text`'s links: the engine's own (`beats.bitwrap.io/p#…`) and the site's `/#` and `/c/` forms of it.
  public static func share(_ text: String, notes: Bool = false, storeDir: String? = nil) throws -> SiteForms {
    let engine = try btwShareLinkIn(text: text, notes: notes, storeDir: storeDir)
    guard let i = engine.firstIndex(of: "#") else { return SiteForms(engine: engine, page: engine, posts: engine) }
    let frag = String(engine[engine.index(after: i)...])
    return SiteForms(engine: engine, page: "\(site)/#\(frag)", posts: "\(site)/c/\(frag)")
  }
}

/// A program opened from a link or a CID: the text to put in the editor and where it came from.
public struct Opened: Equatable, Sendable {
  public let text: String
  public let cid: String
  public let from: String
  public let warnings: [String]
}

public enum OpenError: Error, Equatable, CustomStringConvertible {
  case notALink
  case pairing
  case refused(String)
  case notFound(String)
  case mismatch(asked: String, got: String?)
  case network(String)

  public var description: String {
    switch self {
    case .notALink: return "That isn't a BeatScript link or CID."
    case .pairing: return "That is a pairing code: use Menu › beatscript.app › Pair."
    case .refused(let why): return why
    case .notFound(let cid): return "beatscript.app has no program \(cid.prefix(12))…: only a self-sealing link opens anywhere."
    case .mismatch(let asked, let got):
      return "The program fetched for \(asked.prefix(12))… has another CID (\(got.map { String($0.prefix(12)) } ?? "none")): refused."
    case .network(let why): return "beatscript.app: \(why)"
    }
  }
}

/// Opens links and CIDs. The site is asked only for a bare CID the saved programs don't have, and the
/// CID of what it answers is recomputed here before anything plays.
public struct Opener: Sendable {
  public var site: String = Links.site
  public var storeDir: String?
  public var session: URLSession = .shared

  public init(storeDir: String? = nil, site: String = Links.site) {
    self.storeDir = storeDir
    self.site = site
  }

  public func open(_ raw: String) async throws -> Opened {
    switch Links.classify(raw) {
    case .unknown: throw OpenError.notALink
    case .pair: throw OpenError.pairing
    case .program(let frag): return try local(frag, from: "link")
    case .cid(let cid):
      if let o = try? local(cid, from: "saved") { return o }
      return try await fetch(cid)
    }
  }

  func local(_ link: String, from: String) throws -> Opened {
    let o = btwOpenLink(link: link, storeDir: storeDir)
    guard o.ok, let text = o.text, let cid = o.cid else {
      throw OpenError.refused(o.refused ?? "The link didn't open.")
    }
    return Opened(text: text, cid: cid, from: from, warnings: o.warnings)
  }

  /// `GET /api/programs/<cid>` (public: `{cid, text, meta}`), the CID recomputed from the text.
  public func fetch(_ cid: String) async throws -> Opened {
    guard let url = URL(string: "\(site)/api/programs/\(cid)") else { throw OpenError.notALink }
    var req = URLRequest(url: url, timeoutInterval: 15)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, resp): (Data, URLResponse)
    do { (data, resp) = try await session.data(for: req) } catch { throw OpenError.network(error.localizedDescription) }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 404 { throw OpenError.notFound(cid) }
    guard code == 200 else { throw OpenError.network("HTTP \(code)") }
    struct Answer: Decodable { let cid: String?; let text: String }
    guard let a = try? JSONDecoder().decode(Answer.self, from: data) else { throw OpenError.network("not a program") }
    let got = btwCid(text: a.text)
    guard got == cid else { throw OpenError.mismatch(asked: cid, got: got) }
    return Opened(text: a.text, cid: cid, from: "beatscript.app", warnings: [])
  }
}
