#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
xcodegen generate
xcodebuild -project Retools.xcodeproj -scheme Retools -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Release \
  CODE_SIGNING_ALLOWED=NO build
python3 Scripts/check-bundle.py build/Release/Build/Products/Release-iphoneos/Retools.app
package_dir="$(mktemp -d /tmp/retools-package.XXXXXX)"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload" Artifacts
ditto build/Release/Build/Products/Release-iphoneos/Retools.app "$package_dir/Payload/Retools.app"
artifact_path="$project_root/Artifacts/Retools-0.1.0-unsigned.ipa"
rm -f "$artifact_path"
(cd "$package_dir" && /usr/bin/zip -qry "$artifact_path" Payload)
echo "Created $artifact_path"
python3 Scripts/package-reference.py
python3 Scripts/package-leadgram-style.py
