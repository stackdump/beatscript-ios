# BeatScript for iPad

The script edition of the BeatScript app, the way [beatscript.app](https://beatscript.app) lays it out: one
screen with the code, Follow, Eval / Stop / Fmt, Examples, Share and Open, and pairing with beatscript.app.
It runs the same Rust engine as the Android app (`app.beatscript`), through UniFFI. The CIDs are equal on every
device: the XCTests hold the iPad to the Android app's goldens and to what beatscript.app serves.

Bundle id `app.beatscript`, iPadOS 18+, arm64.

## Layout

| path | what |
|---|---|
| `scripts/build-xcframework.sh` | builds the engine: static libs for iOS device, iOS simulator and macOS, packed as `rust/dist/djmobileFFI.xcframework`, plus the UniFFI Swift bindings `Sources/BeatScriptEngine/djmobile.swift` and the parity fixtures. Nothing it makes is committed |
| `rust/PINS` | the two revisions it builds: the Android app's UniFFI crate (`djmobile`, in `stackdump/beatscript-app` `rust/`) and the engine, public [stackdump/beatscript](https://github.com/stackdump/beatscript), which every `beatscript` git dependency of the crate is set to |
| `Sources/BeatScriptEngine` | `Engine.swift`: a small face over the bindings (the audio session, Eval, Stop, status, marks, levels) |
| `Sources/BeatScriptUI` | the screen (`ScriptView`), the editor (`CodeEditor`: the engine's highlighting, the lit lines, Follow), the model, the link router and the CID fetch (`Links`), the pairing transport (`Pairing`) |
| `Tests/BeatScriptParityTests` | XCTest: CID parity (`btw_parity`, `generate_parity`), the site, the link forms, and a playback check |
| `App/BeatScript.xcodeproj` | the iPad app target over the package's `BeatScriptUI` |

## Build

Needs Xcode (with the iOS platform and a simulator runtime), rustup, and read access to the crate's repository
(set `BEATSCRIPT_APP_URL` to use another clone).

```sh
make engine           # scripts/build-xcframework.sh (about 10 minutes cold)
make test             # swift test on the Mac (the playback check skips: it would use the speakers)
make sim-test         # the XCTests on an iPad simulator (SIM="iPad mini (A20 Pro)")
make sim              # build, install and launch the app on that simulator
```

`UPDATE=1 make engine` re-pins both revisions to their `main`. The engine is built with the crate's `network`
feature (pairing). The device app is about 17 MB and links nothing but system frameworks.

Launch environment (debug aids; `SIMCTL_CHILD_` prefix on the simulator): `BEATSCRIPT_EXAMPLE=<name>`,
`BEATSCRIPT_TEXT=<program>`, `BEATSCRIPT_OPEN=<link or CID>`, `BEATSCRIPT_AUTOPLAY=1` (Eval at launch),
`BEATSCRIPT_STOP_AFTER=<seconds>`. The app's log is subsystem `app.beatscript`, category `script`.

## What it does

- **Eval** stages the editor's text: it lands on the next bar (at once when nothing plays). With an error,
  nothing changes and the last good program plays on.
- **Stop** is beatscript.app's Stop (`btw_stop_sound`): the program ends and both decks stop before the call
  returns, and nothing staged lands afterwards. It is never the language's `stop`, which leaves the decks
  playing.
- **Follow** keeps the line that plays in view. The lit lines and hits come from the engine's marks.
- **Open** takes every form a program travels in: `https://beatscript.app/#CID.packed`, `/c/CID.packed`,
  `beats.bitwrap.io/p#…`, a bare `CID.packed`, and a CID alone (`/p/CID` or bare). A CID opens from the saved
  programs, else from `GET https://beatscript.app/api/programs/<CID>`, whose text must have that CID.
  `beatscript://…` URLs open in the app too.
- **Share** gives the self-sealing link, the link for posts, the beats.bitwrap.io link and the stream link.
- **Pairing** (`btw-pair/1`, stackdump/beatscript `site/PAIRING.md`). Paste or open a pairing code from
  beatscript.app's phone panel; the site can then send programs here and sees what plays. The device key's seed is
  kept in the Keychain (this device only) and never leaves the iPad.

## Licence

Code is MIT ([LICENSE](LICENSE)). BeatScript programs and content (this README, fixtures and goldens) are
CC0-1.0, the same as stackdump/beatscript. `REUSE.toml` says which is which.
