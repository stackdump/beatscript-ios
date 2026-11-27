import BeatScriptEngine
import Foundation
import Observation
import Security

/// Pairing with beatscript.app (`btw-pair/1`, stackdump/beatscript site/PAIRING.md): scan the code the site's
/// phone panel shows, and the site (or an assistant over its MCP) can send programs here; they land in the
/// editor and play on the next bar. The protocol core (parse, the device key, every signature, reading the
/// events) is the engine's (`btw_pair_*`); this file is only the transport: HTTPS, the SSE stream, the report.
///
/// The device key's 32-byte seed lives in the Keychain (this device only, never synced or backed up) and
/// never leaves the iPad. Nothing else here is secret: the device id, origin and fingerprint are public.
@MainActor @Observable
public final class Pairing {
  public enum State: Equatable {
    case unpaired, claiming, connecting, connected, retrying(seconds: Int), failed(String)
  }

  public private(set) var state: State = .unpaired
  public private(set) var deviceID: String?
  public private(set) var origin: String?
  public private(set) var host: String?
  public private(set) var fingerprint: String?
  public private(set) var user: String?
  public var available: Bool { beatscriptPairBuilt() }

  private weak var model: ScriptModel?
  private var stream: Task<Void, Never>?
  private var lastReport: (key: String, at: Date)?
  private let defaults = UserDefaults.standard
  private let session: URLSession = {
    let c = URLSessionConfiguration.default
    c.timeoutIntervalForRequest = 3600  // the event stream stays open
    return URLSession(configuration: c)
  }()

  init() {
    deviceID = defaults.string(forKey: "pair.device")
    origin = defaults.string(forKey: "pair.origin")
    host = defaults.string(forKey: "pair.host")
    fingerprint = defaults.string(forKey: "pair.fingerprint")
  }

  func attach(_ model: ScriptModel) {
    self.model = model
    if deviceID != nil, (try? Keychain.seed()) != nil { connect() }
  }

  public var paired: Bool { deviceID != nil }

  /// The hosts this app pairs with: the site and its old name.
  static let hosts: Set<String> = ["beatscript.app", "btw.bitwrap.io"]

  /// A scanned or opened `https://<site>/pair#<id>.<token>`.
  public func pair(_ link: String) async {
    guard available else { state = .failed("This build has no network."); return }
    let offer: BeatscriptPairOffer
    do { offer = try beatscriptPairParse(link: link) } catch {
      state = .failed("That isn't a pairing code (\(error)).")
      return
    }
    guard Pairing.hosts.contains(offer.host) || offer.host.hasPrefix("localhost") || offer.host.hasPrefix("127.0.0.1") else {
      state = .failed("Not pairing with \(offer.host): only beatscript.app.")
      return
    }
    state = .claiming
    do {
      let seed = try Keychain.seed() ?? { let s = try beatscriptPairNewKey(); try Keychain.store(s); return s }()
      let name = Pairing.deviceName
      let body = try beatscriptPairClaimBody(offer: offer, seed: seed, name: name, tsMs: Pairing.now)
      var req = URLRequest(url: URL(string: "\(offer.origin)/api/pair/claim")!)
      req.httpMethod = "POST"
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
      req.httpBody = Data(body.utf8)
      let (data, resp) = try await session.data(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      guard code == 200, let hello = try? JSONDecoder().decode(Hello.self, from: data), let id = hello.device_id else {
        state = .failed(Pairing.serverWords(data) ?? "The site refused the code (HTTP \(code)): show a new one and scan again.")
        return
      }
      deviceID = id
      origin = offer.origin
      host = offer.host
      fingerprint = hello.fingerprint ?? (try? beatscriptPairFingerprint(seed: seed))
      user = hello.user ?? hello.address
      defaults.set(id, forKey: "pair.device")
      defaults.set(offer.origin, forKey: "pair.origin")
      defaults.set(offer.host, forKey: "pair.host")
      defaults.set(fingerprint, forKey: "pair.fingerprint")
      log.info("paired as \(id, privacy: .public) on \(offer.host, privacy: .public)")
      connect()
    } catch {
      state = .failed("Pairing failed: \(error.localizedDescription)")
    }
  }

  /// Unpair here and on the site (`DELETE /api/device`), and forget the key.
  public func unpair() async {
    if let req = try? signed("DELETE", "/api/device", body: Data()) {
      _ = try? await session.data(for: req)
    }
    forget("unpaired on the iPad")
  }

  private func forget(_ why: String) {
    stream?.cancel()
    stream = nil
    deviceID = nil
    user = nil
    for k in ["pair.device", "pair.origin", "pair.host", "pair.fingerprint"] { defaults.removeObject(forKey: k) }
    Keychain.delete()
    state = .unpaired
    log.info("pairing forgotten: \(why, privacy: .public)")
  }

  // MARK: the event stream

  private func connect() {
    stream?.cancel()
    stream = Task { [weak self] in
      var backoff = 2
      while !Task.isCancelled {
        guard let self else { return }
        self.state = .connecting
        let ended = await self.listen()
        if ended == .gone || Task.isCancelled { return }
        if ended == .opened { backoff = 2 }
        self.state = .retrying(seconds: backoff)
        try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
        backoff = backoff >= 16 ? 30 : backoff * 2
      }
    }
  }

  private enum Ended { case opened, failed, gone }

  private func listen() async -> Ended {
    guard let req = try? signed("GET", "/api/device/events", body: Data()) else { return .failed }
    do {
      let (bytes, resp) = try await session.bytes(for: req)
      let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
      if code == 410 || code == 401 && deviceID == nil { forget("the site has no record of this iPad"); return .gone }
      guard code == 200 else { return .failed }
      state = .connected
      var event = "message"
      var data = ""
      for try await line in bytes.lines {
        if line.hasPrefix("event:") {
          event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
          data += (data.isEmpty ? "" : "\n") + line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        } else if line.isEmpty || line.hasPrefix(":") {
          if !data.isEmpty || event != "message" {
            if handle(event, data) == .gone { return .gone }
          }
          event = "message"
          data = ""
        }
      }
      return .opened
    } catch {
      return .failed
    }
  }

  private func handle(_ name: String, _ data: String) -> Ended {
    guard let e = try? beatscriptPairEvent(event: name, data: data) else { return .opened }
    log.info("pair event \(e.kind, privacy: .public)")
    switch e.kind {
    case "hello":
      user = e.user ?? e.address
      if let f = e.fingerprint { fingerprint = f }
    case "eval", "load":
      guard let model, let text = e.text else { break }
      // the CID is recomputed here: the program that plays is the one the site named
      if let cid = e.cid, beatscriptCid(text: text) != cid {
        model.note = "The site sent a program whose CID doesn't match: not played."
        break
      }
      model.text = text
      if e.kind == "eval" || e.play { model.eval() }
    case "stop":
      model?.stop()
    case "get":
      if let rid = e.requestId { Task { await self.reply(rid) } }
    case "unpaired":
      forget(e.reason ?? "unpaired on the site")
      return .gone
    case "private":
      model?.note = "The site sent a private program: this app doesn't open those yet."
    default:
      break
    }
    return .opened
  }

  // MARK: reports

  /// What plays, about once a second and only when it changed (the server allows ≤ 1/s).
  func report() {
    guard state == .connected, let st = currentState() else { return }
    let key = "\(st.cid)|\(st.playing)|\(st.section)|\(st.bar)"
    if let last = lastReport, last.key == key, Date().timeIntervalSince(last.at) < 10 { return }
    if let last = lastReport, Date().timeIntervalSince(last.at) < 1 { return }
    lastReport = (key, Date())
    guard let body = try? JSONEncoder().encode(st), let req = try? signed("POST", "/api/device/report", body: body) else { return }
    Task { _ = try? await session.data(for: req) }
  }

  private func reply(_ requestID: String) async {
    guard let st = currentState() else { return }
    struct Reply: Encodable { let request_id: String; let state: Report }
    guard let body = try? JSONEncoder().encode(Reply(request_id: requestID, state: st)),
      let req = try? signed("POST", "/api/device/reply", body: body)
    else { return }
    _ = try? await session.data(for: req)
  }

  /// The site's `SessionState`, the fields a phone knows.
  struct Report: Encodable {
    let id: String
    let text: String
    let cid: String
    let playing: Bool
    let source: String
    let section: String
    let section_num: Int64
    let sections_total: Int64
    let bar: Int64
    let bars_in_section: Int64
    let phase: Int64
    let ts: String
  }

  private func currentState() -> Report? {
    guard let model else { return nil }
    let s = model.status
    let playing = model.running
    return Report(
      id: "", text: playing ? (s?.text ?? "") : model.text, cid: s?.cid ?? "", playing: playing, source: "engine",
      section: s?.section ?? "", section_num: Int64(s?.sectionIndex ?? 0), sections_total: Int64(s?.sectionCount ?? 0),
      bar: Int64(s?.sectionBar ?? 0), bars_in_section: Int64(s?.sectionBars ?? 0), phase: Int64(s?.barInPhrase ?? 0),
      ts: ISO8601DateFormatter().string(from: Date()))
  }

  // MARK: signing

  private func signed(_ method: String, _ path: String, body: Data) throws -> URLRequest {
    guard let seed = try Keychain.seed(), let deviceID, let origin, let host else { throw URLError(.userAuthenticationRequired) }
    let auth = try beatscriptPairAuth(
      seed: seed, host: host, deviceId: deviceID, method: method, path: path, tsMs: Pairing.now, body: body)
    var req = URLRequest(url: URL(string: origin + path)!)
    req.httpMethod = method
    req.setValue(auth, forHTTPHeaderField: "Authorization")
    if !body.isEmpty {
      req.httpBody = body
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if path.hasSuffix("/events") { req.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
    return req
  }

  struct Hello: Decodable {
    let device_id: String?
    let fingerprint: String?
    let user: String?
    let address: String?
  }

  static func serverWords(_ data: Data) -> String? {
    struct E: Decodable { let error: String?; let message: String? }
    guard let e = try? JSONDecoder().decode(E.self, from: data) else { return nil }
    return e.message ?? e.error
  }

  static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
  static var deviceName: String { "BeatScript iPad" }
}

/// The device key's seed in the Keychain: this device only, after first unlock, never synced.
enum Keychain {
  static let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "app.beatscript.pair",
    kSecAttrAccount as String: "device-key",
  ]

  static func seed() throws -> Data? {
    var q = query
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let st = SecItemCopyMatching(q as CFDictionary, &out)
    if st == errSecItemNotFound { return nil }
    guard st == errSecSuccess, let d = out as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    return d
  }

  static func store(_ seed: Data) throws {
    delete()
    var q = query
    q[kSecValueData as String] = seed
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let st = SecItemAdd(q as CFDictionary, nil)
    guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
  }

  static func delete() { SecItemDelete(query as CFDictionary) }
}
