// swift-tools-version: 6.0
import PackageDescription

// BeatScript for iPad: the script edition of the BeatScript app on the same Rust engine the Android app
// runs, through UniFFI. rust/dist/djmobileFFI.xcframework and Sources/BeatScriptEngine/djmobile.swift are
// made by scripts/build-xcframework.sh (run it first); the app is App/BeatScript.xcodeproj.
let package = Package(
  name: "beatscript-ios",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "BeatScriptUI", targets: ["BeatScriptUI"]),
    .library(name: "BeatScriptEngine", targets: ["BeatScriptEngine"]),
  ],
  targets: [
    .binaryTarget(name: "djmobileFFI", path: "rust/dist/djmobileFFI.xcframework"),
    // UniFFI's generated Swift (djmobile.swift) and a small face over it (Engine.swift).
    .target(
      name: "BeatScriptEngine", dependencies: ["djmobileFFI"],
      swiftSettings: [.swiftLanguageMode(.v5)],
      // a static lib doesn't carry its frameworks: cpal's CoreAudio backend needs these
      linkerSettings: [
        .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"),
        .linkedFramework("CoreFoundation"), .linkedFramework("Security"),
        .linkedFramework("SystemConfiguration"),
      ]),
    // The script edition's one screen, the link router and the beatscript.app client.
    .target(
      name: "BeatScriptUI", dependencies: ["BeatScriptEngine"],
      swiftSettings: [.swiftLanguageMode(.v5)]),
    // CID parity with the Android app (its btw_parity / generate_parity suites) and the site.
    .testTarget(
      name: "BeatScriptParityTests", dependencies: ["BeatScriptEngine", "BeatScriptUI"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
