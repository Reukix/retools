#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
export IPHONEOS_DEPLOYMENT_TARGET=17.0
cargo build --manifest-path Rust/AppleSigning/Cargo.toml --release --target aarch64-apple-ios
cargo build --manifest-path Rust/AppleSigning/Cargo.toml --release --target aarch64-apple-ios-sim
output="$project_root/Vendor/AppleSigningFFI.xcframework"
wrapper_dir="$(mktemp -d /tmp/retools-apple-wrapper.XXXXXX)"
if [ -d "$output" ]; then mv "$output" "$output.previous"; fi
trap 'rm -rf "$output.previous" "$wrapper_dir"' EXIT
for platform in aarch64-apple-ios aarch64-apple-ios-sim; do
  framework_dir="$wrapper_dir/$platform/AppleSigningFFI.framework"
  mkdir -p "$framework_dir/Headers" "$framework_dir/Modules"
  cp "Rust/AppleSigning/target/$platform/release/libretools_apple_signing.a" "$framework_dir/AppleSigningFFI"
  cp Rust/AppleSigning/include/AppleSigningFFI.h "$framework_dir/Headers/"
  cat > "$framework_dir/Modules/module.modulemap" <<'MAP'
framework module AppleSigningFFI {
    umbrella header "AppleSigningFFI.h"
    export *
}
MAP
  cat > "$framework_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AppleSigningFFI</string>
<key>CFBundleIdentifier</key><string>dev.retools.ios.apple-signing</string>
<key>CFBundleName</key><string>AppleSigningFFI</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
</dict></plist>
PLIST
done
xcodebuild -create-xcframework \
  -framework "$wrapper_dir/aarch64-apple-ios/AppleSigningFFI.framework" \
  -framework "$wrapper_dir/aarch64-apple-ios-sim/AppleSigningFFI.framework" \
  -output "$output"
