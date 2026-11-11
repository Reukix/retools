#!/usr/bin/env python3
"""Produce a re-signable, private-sandbox IPA with ad-hoc signatures."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", default="build/Release/Build/Products/Release-iphoneos/Retools.app")
parser.add_argument("--output", default="Artifacts/Retools-0.1.0-sandbox-reference.ipa")
parser.add_argument("--report", default="Artifacts/ReferencePackage.json")
arguments = parser.parse_args()
source = root / arguments.source
destination = root / arguments.output

def run(args):
    return subprocess.run(args, check=True, capture_output=True).stdout

with tempfile.TemporaryDirectory(prefix="retools-reference-") as temporary:
    work = Path(temporary)
    app = work / "Payload/Retools.app"
    shutil.copytree(source, app)
    for profile in app.rglob("embedded.mobileprovision"):
        profile.unlink()
    for library in app.rglob("*.dylib"):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(library)])
    for framework in sorted(app.rglob("*.framework"), key=lambda item: len(item.parts), reverse=True):
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(framework)])
    entitlements = work / "reference-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"get-task-allow": False}))
    info = plistlib.loads((app / "Info.plist").read_bytes())
    group = info["RetoolsFileToolsAppGroup"]
    shared_entitlements = work / "shared-entitlements.plist"
    shared_entitlements.write_bytes(plistlib.dumps({"get-task-allow": False, "com.apple.security.application-groups": [group]}))
    shared_bundles = [app]
    for extension in sorted((app / "PlugIns").glob("*.appex")):
        metadata = plistlib.loads((extension / "Info.plist").read_bytes())
        shared = metadata.get("RetoolsRequiresSharedAppGroup") is True
        if shared: shared_bundles.append(extension)
        run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", "--entitlements", str(shared_entitlements if shared else entitlements), str(extension)])
    run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--generate-entitlement-der", "--entitlements", str(shared_entitlements), str(app)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    for bundle in shared_bundles:
        actual = plistlib.loads(run(["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)]))
        assert actual.get("com.apple.security.application-groups") == [group]
        assert not actual.get("com.apple.developer.team-identifier")
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
report = {"bundle_id": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"], "minimum_ios": info["MinimumOSVersion"], "private_sandbox": True, "signature": "adhoc", "profile_count": 0, "personal_certificate_count": 0, "standalone_dependencies_verified": True, "final_archive_signatures_verified": True, "shared_app_group": group, "device_installation": "Requires re-signing before device installation", "sha256": digest}
report_path = root / arguments.report
report_path.parent.mkdir(parents=True, exist_ok=True)
report_path.write_text(json.dumps(report, indent=2) + "\n")
print("Created", destination)
