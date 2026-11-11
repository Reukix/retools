#!/usr/bin/env python3
"""Check standalone framework dependencies and exclude personal signing assets."""
import subprocess
import sys
from pathlib import Path
import plistlib
import hashlib
import json

app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / "Info.plist").read_bytes())
assert (app / "Frameworks/TweakLoader.dylib").is_file(), "Container TweakLoader is missing"
if info.get("DTPlatformName") == "iphoneos":
    assert (app / "Frameworks/CydiaSubstrate.framework/CydiaSubstrate").is_file(), "Substrate-compatible runtime is missing"
store_module = app / "Frameworks/IPadnKit.framework"
assert store_module.is_dir(), "Store browser module is missing"
runtime = store_module / "SAPRuntime"
manifest = json.loads((runtime / "manifest.json").read_text())
for name, expected in manifest["files"].items():
    assert Path(name).name == name
    assert hashlib.sha256((runtime / name).read_bytes()).hexdigest() == expected, "Store runtime mismatch: " + name
assert (store_module / "IPadnLicense.txt").is_file(), "Store browser license is missing"
assert not any("gestalt" in path.name.lower() for path in app.rglob("*")), "Removed GestaltX files remain in the bundle"
document_types = {value for item in info.get("CFBundleDocumentTypes", []) for value in item.get("LSItemContentTypes", [])}
assert {"com.apple.itunes.ipa", "public.zip-archive"} <= document_types, "IPA document import registration is missing"
assert not {"com.apple.property-list", "public.xml"} & document_types, "Removed document handlers remain registered"
assert all("gestaltx" not in item.get("CFBundleURLSchemes", []) for item in info.get("CFBundleURLTypes", [])), "Removed URL scheme remains registered"
executables = [app / info["CFBundleExecutable"]]
executables += list((app / "Frameworks").glob("*.dylib"))
for extension in (app / "PlugIns").glob("*.appex"):
    metadata = plistlib.loads((extension / "Info.plist").read_bytes())
    assert metadata.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.share-services", "A removed share extension is still embedded"
    assert metadata["CFBundleIdentifier"].startswith(info["CFBundleIdentifier"] + "."), "Extension identifier must be nested under the host"
    executables.append(extension / metadata["CFBundleExecutable"])
for framework in (app / "Frameworks").glob("*.framework"):
    metadata = plistlib.loads((framework / "Info.plist").read_bytes())
    executables.append(framework / metadata["CFBundleExecutable"])
missing = set()
for executable in executables:
    result = subprocess.run(["otool", "-L", str(executable)], check=True, capture_output=True, text=True)
    for line in result.stdout.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith("@rpath/") and ".framework/" in dependency:
            relative = dependency.removeprefix("@rpath/")
            if not (app / "Frameworks" / relative).exists(): missing.add(relative)
assert not missing, "Missing embedded frameworks: " + ", ".join(sorted(missing))
assert not (app / "embedded.mobileprovision").exists(), "Public bundle must not contain a personal profile"
assert not list(app.rglob("*.p12")), "Public bundle must not contain a signing private key"
print(f"Checked {info['CFBundleIdentifier']}: {len(executables)} executables; no personal signing assets.")
