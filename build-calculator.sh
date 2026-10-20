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
swiftc -target "$(uname -m)-apple-macosx13.0" -parse-as-library CalculatorCore.swift AuthCore.swift ConnectionRecovery.swift CoreChecks.swift -o build/core-checks
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
TYPE=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; ds=json.load(sys.stdin)["devicetypes"]; print(next((d["identifier"] for d in ds if d["name"]=="iPhone 12 mini"),""))')
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; print(next(d["identifier"] for d in json.load(sys.stdin)["runtimes"] if d.get("isAvailable") and "iOS" in d["name"]))')
if [[ -n "$TYPE" ]]; then
  DEVICE=$(xcrun simctl create 'Calculator iPhone 12 mini' "$TYPE" "$RUNTIME")
else
  DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; ds=[d for a in json.load(sys.stdin)["devices"].values() for d in a]; print(next(d["udid"] for d in ds if d["name"].startswith("iPhone")))')
fi
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" build/Simulator/Build/Products/Debug-iphonesimulator/ScientificCalculator.app
xcrun simctl launch "$DEVICE" org.local.scientificcalculator.personal --calculator-self-check
CONTAINER=$(xcrun simctl get_app_container "$DEVICE" org.local.scientificcalculator.personal data)
for attempt in {1..30}; do
  [[ -f "$CONTAINER/Documents/mock-app-checks.txt" ]] && break
  sleep 2
done
cp "$CONTAINER/Documents/mock-app-checks.txt" build/mock-app-checks.txt
cat build/mock-app-checks.txt
grep -q '^PASS:' build/mock-app-checks.txt
xcrun simctl io "$DEVICE" screenshot build/calculator-simulator.png
xcrun simctl terminate "$DEVICE" org.local.scientificcalculator.personal
xcrun simctl launch "$DEVICE" org.local.scientificcalculator.personal --calculator-connection-check
for attempt in {1..45}; do
  [[ -f "$CONTAINER/Documents/connection-checks.txt" ]] && break
  sleep 2
done
cp "$CONTAINER/Documents/connection-checks.txt" build/connection-checks.txt
cat build/connection-checks.txt
grep -q '^PASS:' build/connection-checks.txt
xcrun simctl terminate "$DEVICE" org.local.scientificcalculator.personal
xcrun simctl launch "$DEVICE" org.local.scientificcalculator.personal --calculator-render-check
for attempt in {1..30}; do
  [[ -f "$CONTAINER/Documents/math-render-check.txt" ]] && break
  sleep 2
done
cp "$CONTAINER/Documents/math-render-check.txt" build/math-render-check.txt
cat build/math-render-check.txt
grep -q '^PASS:' build/math-render-check.txt
xcrun simctl io "$DEVICE" screenshot build/formula-simulator.png
xcrun simctl terminate "$DEVICE" org.local.scientificcalculator.personal
xcrun simctl launch "$DEVICE" org.local.scientificcalculator.personal --calculator-number-check
for attempt in {1..30}; do
  [[ -f "$CONTAINER/Documents/number-render-check.txt" ]] && break
  sleep 2
done
cp "$CONTAINER/Documents/number-render-check.txt" build/number-render-check.txt
cat build/number-render-check.txt
grep -q '^PASS:' build/number-render-check.txt
xcrun simctl io "$DEVICE" screenshot build/number-simulator.png
xcrun simctl terminate "$DEVICE" org.local.scientificcalculator.personal
xcrun simctl launch "$DEVICE" org.local.scientificcalculator.personal --calculator-draft-check
sleep 3
xcrun simctl io "$DEVICE" screenshot build/draft-simulator.png
echo 'Unsigned IPA and simulator launch completed. Real iPhone signing, gestures, login and inference remain unverified.'
