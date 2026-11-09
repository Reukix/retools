#!/usr/bin/env python3
"""Create synthetic IPA + throwaway signing identities. Never uses a user certificate."""
from pathlib import Path
import subprocess
import tempfile
import plistlib
import datetime
import shutil
import zipfile

root = Path(__file__).resolve().parents[1]
output = root / "Tests" / "Fixtures"
output.mkdir(parents=True, exist_ok=True)
openssl = "/opt/homebrew/opt/openssl@3/bin/openssl"

def run(args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

with tempfile.TemporaryDirectory(prefix="retools-tests-") as directory:
    temp = Path(directory)
    source = temp / "fixture.c"
    source.write_text("int main(int argc, char **argv) { return 0; }\n")
    app = temp / "Payload" / "Fixture.app"
    app.mkdir(parents=True)
    run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-mios-version-min=17.0", "-Wl,-headerpad,0x4000", str(source), "-o", str(app / "Fixture")])
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleName": "Fixture", "CFBundleDisplayName": "测试应用", "CFBundleIdentifier": "com.retools.fixture", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.2.3", "MinimumOSVersion": "17.0"}))
    (app / "message.txt").write_text("Retools integration fixture\n")
    with zipfile.ZipFile(output / "Fixture.ipa", "w", zipfile.ZIP_DEFLATED) as archive:
        for file in app.rglob("*"):
            archive.write(file, file.relative_to(temp))
    for name, team in [("TestIdentity", "TESTTEAM01"), ("OtherIdentity", "OTHERTEAM1")]:
        key = temp / (name + ".key")
        cert = temp / (name + ".crt")
        run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "3650", "-subj", f"/CN=Retools Test Only/OU={team}/O=Retools Fixtures"])
        run([openssl, "pkcs12", "-export", "-out", str(output / (name + ".p12")), "-inkey", str(key), "-in", str(cert), "-certfile", str(cert), "-passout", "pass:test-only"])
        der = temp / "cert.der"
        run([openssl, "x509", "-in", str(cert), "-outform", "DER", "-out", str(der)])
        now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
        for suffix, days in [("", 3650), ("Expired", -1), ("Exact", 3650), ("Project", 3650), ("Renewed", 3650)]:
            payload = temp / "profile.plist"
            application_id = team + (".com.retools.profile-identity" if suffix == "Exact" else ".*")
            if suffix == "Project": application_id = team + ".com.retools.fixture"
            payload.write_bytes(plistlib.dumps({"Name": "Retools Updated Test Profile" if suffix == "Renewed" else "Retools Test Profile", "UUID": "00000000-0000-0000-0000-000000000002" if suffix == "Renewed" else "00000000-0000-0000-0000-000000000001", "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [team], "DeveloperCertificates": [der.read_bytes()], "CreationDate": now - datetime.timedelta(days=9 if suffix == "Renewed" else 10), "ExpirationDate": now + datetime.timedelta(days=days), "Entitlements": {"application-identifier": application_id, "com.apple.developer.team-identifier": team, "get-task-allow": True, "keychain-access-groups": [team + ".*"]}}))
            run([openssl, "cms", "-sign", "-binary", "-nodetach", "-in", str(payload), "-signer", str(cert), "-inkey", str(key), "-outform", "DER", "-out", str(output / (name + suffix + ".mobileprovision"))])
print("Created synthetic IPA and test-only certificates in Tests/Fixtures.")
