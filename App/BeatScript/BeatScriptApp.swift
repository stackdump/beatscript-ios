import BeatScriptUI
import SwiftUI

// BeatScript for iPad: the script edition on the BeatScript engine (rust/dist/djmobileFFI.xcframework,
// linked statically). See the README.

@main
struct BeatScriptApp: App {
  @State private var model = ScriptModel()

  var body: some Scene {
    WindowGroup {
      ScriptView(model: model)
        .onOpenURL { url in Task { await model.open(url.absoluteString) } }
        .task { await Launch.run(model) }
    }
  }
}

/// Debug aids read from the launch environment (`SIMCTL_CHILD_…` on the simulator):
/// BEATSCRIPT_EXAMPLE=<name> puts a bundled example in the editor, BEATSCRIPT_TEXT=<program> a program,
/// BEATSCRIPT_OPEN=<link or CID> opens it, BEATSCRIPT_AUTOPLAY=1 evaluates the editor (after the open, if any),
/// BEATSCRIPT_STOP_AFTER=<seconds> presses Stop that long after.
@MainActor
enum Launch {
  static func run(_ model: ScriptModel) async {
    let env = ProcessInfo.processInfo.environment
    if let name = env["BEATSCRIPT_EXAMPLE"], let ex = model.examples.first(where: { $0.name == name }) {
      model.load(example: ex)
    }
    if let text = env["BEATSCRIPT_TEXT"] { model.text = text }
    let play = env["BEATSCRIPT_AUTOPLAY"] == "1"
    if let link = env["BEATSCRIPT_OPEN"] {
      await model.open(link, play: play)
    } else if play {
      model.eval()
    }
    if let s = env["BEATSCRIPT_STOP_AFTER"].flatMap(Double.init) {
      try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
      model.stop()
    }
  }
}
