SIM ?= iPad mini (A20 Pro)
DEST = platform=iOS Simulator,name=$(SIM)

.PHONY: engine test sim-test sim device

engine:
	scripts/build-xcframework.sh

test:
	swift test

sim-test:
	xcodebuild test -scheme beatscript-ios-Package -destination "$(DEST)" -derivedDataPath .build/xcode-test

sim:
	xcodebuild -project App/BeatScript.xcodeproj -scheme BeatScript -destination "$(DEST)" -derivedDataPath .build/xcode-sim build
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	xcrun simctl install "$(SIM)" .build/xcode-sim/Build/Products/Debug-iphonesimulator/BeatScript.app
	xcrun simctl launch "$(SIM)" app.beatscript

# a plugged-in iPad: make device ID=<devicectl id> TEAM=<your team id>
device:
	xcodebuild -project App/BeatScript.xcodeproj -scheme BeatScript -destination "id=$(ID)" -derivedDataPath .build/xcode-dev DEVELOPMENT_TEAM=$(TEAM) -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(ID) .build/xcode-dev/Build/Products/Debug-iphoneos/BeatScript.app
