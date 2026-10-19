#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Requires macOS and Xcode. No build performed.' >&2
  exit 1
fi
mkdir -p build
swiftc -parse-as-library ProbeCore.swift CoreTests.swift -o build/core-tests
build/core-tests
plutil -lint Info.plist CalculatorProbe.xcodeproj/project.pbxproj
xcodebuild -project CalculatorProbe.xcodeproj -scheme CalculatorProbe \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
mkdir -p build/Payload
ditto build/DerivedData/Build/Products/Release-iphoneos/CalculatorProbe.app build/Payload/CalculatorProbe.app
ditto -c -k --keepParent build/Payload build/CalculatorProbe-unsigned.ipa
echo 'UNSIGNED IPA created. Not directly installable; signing and device trust are separate steps.'
