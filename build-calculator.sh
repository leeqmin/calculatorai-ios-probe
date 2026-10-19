#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS and Xcode required'; exit 1; }
mkdir -p build ScientificCalculator.xcodeproj Assets.xcassets/AppIcon.appiconset
cp ScientificCalculator.pbxproj ScientificCalculator.xcodeproj/project.pbxproj
unzip -oq KaTeX-vendor.zip
swift MakeIcon.swift Assets.xcassets/AppIcon.appiconset/Icon.png
printf '%s\n' '{"images":[{"filename":"Icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}' > Assets.xcassets/AppIcon.appiconset/Contents.json
printf '%s\n' '{"info":{"author":"xcode","version":1}}' > Assets.xcassets/Contents.json
swiftc -parse-as-library CalculatorCore.swift AuthCore.swift CoreChecks.swift -o build/core-checks
build/core-checks | tee build/core-checks.txt
plutil -lint CalculatorInfo.plist ScientificCalculator.xcodeproj/project.pbxproj
xcodebuild -project ScientificCalculator.xcodeproj -scheme ScientificCalculator -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build > build/device-build.log 2>&1 || { tail -100 build/device-build.log; exit 1; }
mkdir -p build/Payload
ditto build/DerivedData/Build/Products/Release-iphoneos/ScientificCalculator.app build/Payload/ScientificCalculator.app
ditto -c -k --keepParent build/Payload build/ScientificCalculator-unsigned.ipa
shasum -a 256 build/ScientificCalculator-unsigned.ipa | tee build/ipa-sha256.txt
# Simulator boot is independent of personal accounts and uses synthetic/offline data only.
xcodebuild -project ScientificCalculator.xcodeproj -scheme ScientificCalculator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/Simulator CODE_SIGNING_ALLOWED=NO build > build/simulator-build.log 2>&1 || { tail -100 build/simulator-build.log; exit 1; }
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; ds=[d for a in json.load(sys.stdin)["devices"].values() for d in a]; print(next((d["udid"] for d in ds if d["name"]=="iPhone 17 Pro"),ds[0]["udid"]))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" build/Simulator/Build/Products/Debug-iphonesimulator/ScientificCalculator.app
xcrun simctl launch "$DEVICE" org.local.scientificcalculator.personal
sleep 3
xcrun simctl io "$DEVICE" screenshot build/calculator-simulator.png
echo 'Unsigned IPA and simulator launch completed. Real iPhone signing, gestures, login and inference remain unverified.'
