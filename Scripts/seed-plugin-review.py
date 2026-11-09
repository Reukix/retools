#!/usr/bin/env python3
"""Seed only the dedicated Retools Review simulator with a benign plugin."""
from pathlib import Path
import subprocess, json, uuid, hashlib, datetime, io, tarfile, shutil

simulator = "3E16A60D-76BA-463E-AD21-3B8E5E4169D4"
repo = Path(__file__).resolve().parents[1]
root = Path(subprocess.check_output(["xcrun", "simctl", "get_app_container", simulator, "dev.retools.ios", "data"], text=True).strip())
subprocess.run(["xcrun", "simctl", "terminate", simulator, "dev.retools.ios"], capture_output=True)
support = root / "Library/Application Support/Retools"
state_file = support / "workspace.json"
state = json.loads(state_file.read_text())
assert state["packages"] and all(p["name"] == "测试应用" for p in state["packages"]), "Use the dedicated synthetic review workspace"
shutil.copy2(state_file, state_file.with_suffix(".review-backup"))
plugin_id = "33333333-3333-3333-3333-333333333333"
payload = support / "Plugins" / plugin_id / "Payload"
payload.mkdir(parents=True, exist_ok=True)
data = (repo / "Tests/Fixtures/FixturePlugin.deb").read_bytes()
cursor = 8
while cursor < len(data):
    header = data[cursor:cursor+60]; size = int(header[48:58]); name = header[:16].decode().strip().rstrip("/")
    body = data[cursor+60:cursor+60+size]; cursor += 60 + size + size % 2
    if name.startswith("data.tar"):
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:*") as archive:
            for member in archive:
                assert member.isfile() and ".." not in Path(member.name).parts and not member.name.startswith("/")
                target = payload / member.name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(member).read())
record = {"id": plugin_id, "name": "FixturePlugin", "kind": "deb", "sourceFileName": "FixturePlugin.deb", "executablePaths": ["Library/MobileSubstrate/DynamicLibraries/FixturePlugin.dylib"], "fingerprint": hashlib.sha256(data).hexdigest(), "byteCount": sum(f.stat().st_size for f in payload.rglob("*") if f.is_file()), "importedAt": (datetime.datetime.now(datetime.UTC) - datetime.datetime(2001, 1, 1, tzinfo=datetime.UTC)).total_seconds(), "resourceCount": 2}
state["plugins"] = [record]
for package in state["packages"]:
    package["pluginIDs"] = []; package["pluginInjections"] = []
    package.pop("signingOptions", None)
state_file.write_text(json.dumps(state))
print("Seeded benign Debian plugin in the dedicated simulator; previous workspace backed up.")
