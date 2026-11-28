# The adopter tier: native iPad, Android and desktop

The PWA (R15) is BeatScript's front door. People who stay will want an app for their device: the iPad (this
repo), Android (the BeatScript Android app) and the desktop. Nothing here retires the PWA, and adoption is never a
measure. Native apps exist for what a browser can't do well: MIDI in, background audio, touch DJ pages, local
soundfonts and HEOS. All of them run one engine, pinned by one rev, and give the same CIDs as beatscript.app
(BeatScript #7: the web and Android ship as a pair, and native follows the same engine).

**The PWA gate.** R15 ships when the PWA passes a real-device playback check (iPad mini Safari, a mid-range
Android in Chrome, desktop). "After the gate" means don't start before that. "Any time" means the item touches
nothing the PWA defines (the manifest, share_target, App Links / site association), so it can land whenever.
Native code never edits those files. When a native item needs one of them, it asks the PWA's owner.

Sizes: S is one run, M is a few runs, L is a milestone.

## Where it stands (2026-11-28, R19 milestone 1)

- The engine pin follows stackdump/beatscript `main` (9f74d11). Every engine crate is built at that one rev.
  djrust (2aeffaf) and windwheel follow the engine's root `Cargo.toml`, and the build fails if the lock holds two
  revs of any git source (`scripts/build-xcframework.sh`).
- Parity, in `swift test` and `make sim-test`:
  - The Android goldens: program and net CIDs, fmt and share links.
  - The engine's own `cid-pins.json` at the pin: 96 programs, 91 program CIDs and 73 net sets compared, all
    equal.
  - beatscript.app's live `POST /api/check`: 20 programs, all equal.
  - The generator: seeded@4, the same CIDs as beatscript.app's `generate`.
- The script edition (one screen: code, Follow, Eval / Stop / Fmt, Examples, Share, Open, pairing) builds for
  the simulator.

## iPad (this repo)

| # | Item | Size | Gate |
|---|---|---|---|
| I1 | Engine pin at beatscript `main`, one rev, parity suites. Done on `roadmap/r19-adopter-tier` | S | any time |
| I2 | Real-device playback on the iPad mini: the PlaybackTests on the device, then by ear. Needs Matt: signing, an unlocked device | S | with R15's iPad mini check (same device, same session) |
| I3 | Background audio: the `playback` audio session and the `audio` background mode, so a set keeps playing with the screen off | S | after the gate |
| I4 | The DJ pages, as the Android app has them: Deck (sections ring, roles, next track), Mix (crossfader, levels, Sync, auto level), Perform (moves on the bar), Effects (tricks and macros), Vox (vocoder). SwiftUI over the same `djmobile` calls the Android pages make. One page per run, Mix first | L | after the gate |
| I5 | MIDI in over CoreMIDI: the controllers Android's R17 maps (MPK mini, Inpulse 200 MK3, APC mini mk2). The mapping lives in the shared crate, not per platform | M | after the gate, and after R17 lands in the shared crate |
| I6 | Local soundfonts: import an `.sf2` from Files onto a palette (the `sf2` feature is already built in) | S | after the gate |
| I7 | HEOS: find and play to Denon/HEOS speakers on the LAN (`network` builds) | M | after the gate |
| I8 | Universal Links for `https://beatscript.app/p/<cid>`. Needs the site's association file, which the PWA owns, and the associated-domains entitlement, which is a signing change for Matt | M | after the gate, coordinated with the PWA |

## Android (the pair to the web)

These items come from what this run measured. They live in the shared UniFFI crate, so fixing them fixes the
iPad too.

| # | Item | Size | Gate |
|---|---|---|---|
| A1 | Bump the app's engine pin to beatscript `main`, and djrust with it (7420204 to 2aeffaf). Carry `GenRequest.ending` (this repo patches it in meanwhile: `rust/patches/0001`). Regenerate `generate_fixtures.json` at seeded@4: the app's fixtures say seeded@3 while beatscript.app generates seeded@4 | S | any time (pair parity, not adopter work) |
| A2 | The device registry refuses programs the web plays: `trick … source=` (11 of the engine's pinned programs), `freeze`, performed input (`knob(…)`), `control: macro …`, and `gen@N` / station references at check time (4). The CIDs agree; the device just can't run these | M | any time |
| A3 | Feature parity of the script edition with beatscript.app's editor (Grammar page, cheatsheet, docs), already partly in the Android app | M | after the gate |

## Desktop

| # | Item | Size | Gate |
|---|---|---|---|
| D1 | Taste call: what shell the desktop uses. (a) the installed PWA is the desktop app, with native only for MIDI / HEOS / soundfonts. (b) a macOS app from this package (the macOS slice already builds for `swift test`). (c) a Rust-native shell (egui, like pflow-native) that also covers Linux. Suggested default: (a), plus (b) on the Mac only if MIDI in Safari falls short | S (the decision) | after the gate |
| D2 | Package the chosen shell: a signed Mac build (Matt signs), and a Linux build on gir (ALSA, `djhost` `audio`) if (c) | M | after D1 |

## Never automatic (Matt)

TestFlight, App Store and Play publishes; signing, provisioning and entitlements (I2, I8, D2); licensing
changes; deletes; new syntax; purchases; real-device playback on the iPad mini.
