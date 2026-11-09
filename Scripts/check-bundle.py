#!/usr/bin/env python3
"""Check standalone framework dependencies and exclude personal signing assets."""
import subprocess
import sys
from pathlib import Path
import plistlib

app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / "Info.plist").read_bytes())
executables = [app / info["CFBundleExecutable"]]
for extension in (app / "PlugIns").glob("*.appex"):
    metadata = plistlib.loads((extension / "Info.plist").read_bytes())
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
