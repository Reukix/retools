#!/usr/bin/env python3
"""Produce a re-signable, private-sandbox IPA with ad-hoc signatures."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
source = root / "build/Release/Build/Products/Release-iphoneos/Retools.app"
destination = root / "Artifacts/Retools-0.1.0-sandbox-reference.ipa"

def run(args):
    return subprocess.run(args, check=True, capture_output=True).stdout

with tempfile.TemporaryDirectory(prefix="retools-reference-") as temporary:
    work = Path(temporary)
    app = work / "Payload/Retools.app"
    shutil.copytree(source, app)
    for profile in app.rglob("embedded.mobileprovision"):
        profile.unlink()
    for framework in sorted((app / "Frameworks").glob("*.framework")):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(framework)])
    entitlements = work / "reference-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"get-task-allow": False}))
    for extension in sorted((app / "PlugIns").glob("*.appex")):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements", str(entitlements), str(extension)])
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", "--entitlements", str(entitlements), str(app)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    run(["python3", str(root / "Scripts/check-bundle.py"), str(app)])
    info = plistlib.loads((app / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "dev.retools.ios"
    assert info.get("RetoolsPrivateSandbox") is True
    output = work / destination.name
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted((work / "Payload").rglob("*")):
            archive.write(path, path.relative_to(work))
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
    verified = work / "verified"
    run(["ditto", "-x", "-k", str(output), str(verified)])
    run(["codesign", "--verify", "--deep", "--strict", str(verified / "Payload/Retools.app")])
    destination.parent.mkdir(parents=True, exist_ok=True)
    output.replace(destination)

digest = hashlib.sha256(destination.read_bytes()).hexdigest()
Path(str(destination) + ".sha256").write_text(digest + "  " + destination.name + "\n")
report = {"bundle_id": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"], "minimum_ios": info["MinimumOSVersion"], "private_sandbox": True, "signature": "adhoc", "profile_count": 0, "personal_certificate_count": 0, "standalone_dependencies_verified": True, "final_archive_signatures_verified": True, "device_installation": "Requires user re-signing", "sha256": digest}
(root / "Artifacts/ReferencePackage.json").write_text(json.dumps(report, indent=2) + "\n")
print("Created", destination)
