import BeatScriptEngine
import SwiftUI

/// The script edition's one screen, laid out like beatscript.app: the top bar, the tools row (Examples ▾,
/// Share, Open, Docs), the name line (name, tempo, time), the header strip with Follow, the editor, the
/// problems line, and Eval / Stop / Fmt.
public struct ScriptView: View {
  @Bindable var model: ScriptModel
  @State private var sheet: Sheet?
  @State private var openText = ""
  @State private var problemsOpen = false

  enum Sheet: String, Identifiable {
    case share, open, pairing, about
    var id: String { rawValue }
  }

  public init(model: ScriptModel) { self.model = model }

  public var body: some View {
    VStack(spacing: 0) {
      topBar
      toolsRow
      nameLine
      header
      CodeEditor(text: $model.text, marks: model.liveMarks, follow: model.follow)
      problemsLine
      transport
    }
    .background(Palette.background)
    .foregroundStyle(Palette.text)
    .preferredColorScheme(.dark)
    .sheet(item: $sheet) { s in
      switch s {
      case .share: ShareSheet(model: model)
      case .open: openSheet
      case .pairing: PairingSheet(pairing: model.pairing)
      case .about: AboutSheet()
      }
    }
  }

  // MARK: rows

  private var topBar: some View {
    HStack {
      Text("BeatScript").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(Palette.accent)
      Spacer()
      if model.pairing.available {
        Button { sheet = .pairing } label: {
          Label(pairLabel, systemImage: model.pairing.state == .connected ? "link.circle.fill" : "link.circle")
        }
        .accessibilityIdentifier("pairing")
      }
      Button { sheet = .about } label: { Image(systemName: "info.circle") }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(Palette.panel)
  }

  private var pairLabel: String {
    switch model.pairing.state {
    case .connected: return "beatscript.app"
    case .unpaired: return "Pair"
    case .claiming, .connecting: return "Connecting…"
    case .retrying: return "Reconnecting…"
    case .failed: return "Pair"
    }
  }

  private var toolsRow: some View {
    HStack(spacing: 18) {
      Menu {
        ForEach(model.examples, id: \.name) { ex in
          Button("\(ex.name)  \(ex.blurb)") { model.load(example: ex) }
        }
      } label: { Label("Examples", systemImage: "chevron.down") }
        .accessibilityIdentifier("examples")
      Button { model.makeShare(); sheet = .share } label: { Label("Share", systemImage: "square.and.arrow.up") }
      Button {
        openText = UIPasteboardText.current ?? ""
        sheet = .open
      } label: { Label("Open", systemImage: "link") }
      Link(destination: URL(string: "\(Links.site)/docs/cheatsheet.md")!) { Label("Docs", systemImage: "book") }
      Spacer()
    }
    .font(.subheadline)
    .padding(.horizontal, 16).padding(.vertical, 8)
  }

  private var nameLine: some View {
    HStack {
      Text(model.name).font(.headline).lineLimit(1)
      Spacer()
      if model.tempo > 0 { Text("\(Int(model.tempo.rounded())) BPM").monospacedDigit().foregroundStyle(Palette.dim) }
      Text(Self.clock(model.elapsed)).monospacedDigit().foregroundStyle(Palette.dim)
    }
    .padding(.horizontal, 16).padding(.bottom, 4)
  }

  private var header: some View {
    let s = model.status
    return VStack(spacing: 4) {
      HStack(spacing: 10) {
        Text(headerWords(s)).font(.caption.monospaced()).lineLimit(1).accessibilityIdentifier("header")
        HStack(spacing: 3) {
          ForEach(1...8, id: \.self) { i in
            Circle().fill(model.running && Int(s?.barInPhrase ?? 0) >= i ? Palette.accent : Palette.dim.opacity(0.3))
              .frame(width: 7, height: 7)
          }
        }
        Spacer()
        Toggle("⇣ Follow", isOn: $model.follow).toggleStyle(.button).font(.caption)
          .accessibilityIdentifier("follow")
      }
      ProgressView(value: progress(s)).tint(Palette.accent)
    }
    .padding(.horizontal, 16).padding(.vertical, 6)
    .background(Palette.panel)
  }

  private func headerWords(_ s: BeatscriptStatus?) -> String {
    guard let s, s.running || s.ended else { return "nothing plays" }
    var w: [String] = []
    if let sec = s.section { w.append(sec) }
    if let b = s.sectionBar, let n = s.sectionBars { w.append("bar \(b)/\(n)") } else { w.append("bar \(s.bar + 1)") }
    w.append("phrase \(s.phrase)")
    if let g = s.generation { w.append("gen \(g)") }
    if s.ended { w.append("ended") } else if s.loops { w.append("loops") }
    if s.stagedCid != nil { w.append("staged") }
    return w.joined(separator: " · ")
  }

  private func progress(_ s: BeatscriptStatus?) -> Double {
    guard let s, s.running else { return 0 }
    if let b = s.songBar, let n = s.songBars, n > 0 { return min(1, Double(b) / Double(n)) }
    return model.liveMarks?.headerProgress ?? s.barFrac
  }

  private var problemsLine: some View {
    let p = model.problems
    let errors = p.filter { $0.severity == "error" }
    return Button { problemsOpen.toggle() } label: {
      HStack(spacing: 8) {
        Circle().fill(errors.isEmpty ? (p.isEmpty ? Palette.ok : Palette.accent) : Palette.error).frame(width: 8, height: 8)
        if let first = errors.first ?? p.first {
          Text("\(p.count) · \(first.span.line):\(first.span.col) \(first.message)").lineLimit(problemsOpen ? 12 : 1)
        } else if let note = model.note {
          Text(note).lineLimit(2)
        } else {
          Text(model.check?.cid.map { "CID \($0.prefix(16))… · CC0-1.0 when saved" } ?? "no problems").lineLimit(1)
        }
        Spacer()
      }
      .font(.caption).foregroundStyle(Palette.dim)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 16).padding(.vertical, 6)
    .accessibilityIdentifier("problems")
  }

  private var transport: some View {
    HStack(spacing: 12) {
      Button { model.eval() } label: { Label("Eval", systemImage: "play.fill").frame(minWidth: 90) }
        .buttonStyle(.borderedProminent).tint(Palette.accent).foregroundStyle(.black)
        .accessibilityIdentifier("eval")
      Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 90) }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("stop")
      Button { model.fmt() } label: { Text("Fmt").frame(minWidth: 50) }.buttonStyle(.bordered)
      Spacer()
      LevelMeter(level: model.level)
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(Palette.panel)
  }

  private var openSheet: some View {
    NavigationStack {
      Form {
        Section("A beatscript.app link, its fragment, or a CID") {
          TextField("https://beatscript.app/#…", text: $openText, axis: .vertical)
            .lineLimit(3...8).font(.caption.monospaced())
            .plainInput()
        }
        if let note = model.note { Section { Text(note).font(.caption) } }
      }
      .navigationTitle("Open")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { sheet = nil } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Open") {
            let t = openText
            Task {
              await model.open(t)
              if model.note?.hasPrefix("Opened") == true { sheet = nil }
            }
          }
        }
      }
    }
  }

  static func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}

struct LevelMeter: View {
  var level: Float
  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Palette.dim.opacity(0.25))
        Capsule().fill(level > 0.9 ? Palette.error : Palette.ok)
          .frame(width: g.size.width * CGFloat(min(1, max(0, level))))
      }
    }
    .frame(width: 90, height: 6)
    .accessibilityIdentifier("level")
    .accessibilityValue("\(level)")
  }
}

enum UIPasteboardText {
  static var current: String? {
    #if canImport(UIKit)
      return UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil
    #else
      return nil
    #endif
  }
}

struct ShareSheet: View {
  @Bindable var model: ScriptModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if let f = model.share {
          row("Self-sealing link", f.page)
          row("Link for posts", f.posts)
          row("beats.bitwrap.io", f.engine)
          if let cid = model.check?.cid {
            row("Stream (opus)", "\(Links.site)/api/render/\(f.page.split(separator: "#").last ?? Substring(cid))?format=opus")
          }
        } else {
          Text(model.note ?? "Nothing to share: the program doesn't check.").font(.caption)
        }
      }
      .navigationTitle("Share")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }

  private func row(_ title: String, _ link: String) -> some View {
    Section(title) {
      Text(link).font(.caption2.monospaced()).lineLimit(3).textSelection(.enabled)
      HStack {
        Button("Copy") {
          #if canImport(UIKit)
            UIPasteboard.general.string = link
          #endif
        }
        Spacer()
        if let u = URL(string: link) { ShareLink(item: u) }
      }
    }
  }
}

struct PairingSheet: View {
  @Bindable var pairing: Pairing
  @State private var code = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("beatscript.app") {
          Text(words).font(.callout)
          if let f = pairing.fingerprint { LabeledContent("Key", value: f) }
          if let u = pairing.user { LabeledContent("Account", value: u) }
        }
        Section("Pair") {
          Text("On beatscript.app, signed in: Mobile › Show a pairing code. Open its link here, or paste it.")
            .font(.caption)
          TextField("https://beatscript.app/pair#…", text: $code).font(.caption.monospaced())
            .plainInput()
          Button("Pair") { let c = code; Task { await pairing.pair(c) } }.disabled(code.isEmpty)
        }
        if pairing.paired {
          Section { Button("Unpair", role: .destructive) { Task { await pairing.unpair() } } }
        }
      }
      .navigationTitle("Pairing")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }

  private var words: String {
    switch pairing.state {
    case .unpaired: return "Not paired."
    case .claiming: return "Pairing…"
    case .connecting: return "Connecting to \(pairing.host ?? "the site")…"
    case .connected: return "Connected: the site can send programs here."
    case .retrying(let s): return "The stream dropped: trying again in \(s) s."
    case .failed(let why): return why
    }
  }
}

struct AboutSheet: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
          LabeledContent("Generator", value: beatscriptGenerator())
        }
        Section("Licences") {
          Text("App code: MIT. BeatScript programs and content: CC0-1.0. The engine: stackdump/beatscript (MIT).")
            .font(.caption)
        }
        Section {
          Link("Privacy", destination: URL(string: "\(Links.site)/privacy")!)
          Link("beatscript.app", destination: URL(string: Links.site)!)
        }
      }
      .navigationTitle("About")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}

extension View {
  /// No capitals, no autocorrect: links and code.
  func plainInput() -> some View {
    #if os(iOS)
      return self.textInputAutocapitalization(.never).autocorrectionDisabled()
    #else
      return self.autocorrectionDisabled()
    #endif
  }
}
