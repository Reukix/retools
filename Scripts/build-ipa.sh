#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
xcodegen generate
xcodebuild -project Retools.xcodeproj -scheme Retools -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Release \
  CODE_SIGNING_ALLOWED=NO build
python3 Scripts/check-bundle.py build/Release/Build/Products/Release-iphoneos/Retools.app
python3 Scripts/package-reference.py --output Artifacts/Retools-0.1.0-unsigned.ipa --report Artifacts/PublicPackage.json
python3 Scripts/package-reference.py
python3 Scripts/package-leadgram-style.py
