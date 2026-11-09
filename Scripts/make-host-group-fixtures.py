#!/usr/bin/env python3
"""Generate App Group signing fixtures using a new, disposable identity only."""
import datetime
import plistlib
import subprocess
import tempfile
from pathlib import Path

output = Path(__file__).resolve().parents[1] / "Tests" / "Fixtures"
output.mkdir(parents=True, exist_ok=True)
openssl = "/opt/homebrew/opt/openssl@3/bin/openssl"
team = "GROUPTEAM1"
group = "group.dev.retools.filetools." + team


def run(args):
    subprocess.run([openssl, *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


with tempfile.TemporaryDirectory(prefix="retools-group-fixtures-") as directory:
    temp = Path(directory)
    key, cert, der = [temp / name for name in ("key.pem", "cert.pem", "cert.der")]
    run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(key), "-out", str(cert),
         "-days", "3650", "-subj", f"/CN=Retools App Group Test Only/OU={team}/O=Retools Fixtures"])
    run(["pkcs12", "-export", "-out", str(output / "HostGroupIdentity.p12"), "-inkey", str(key),
         "-in", str(cert), "-certfile", str(cert), "-passout", "pass:test-only"])
    run(["x509", "-in", str(cert), "-outform", "DER", "-out", str(der)])
    for suffix, bundle, groups in [
        ("", "com.retools.fixture", [group, "group.unrelated", "group.dev.retools.filetools.OTHERTEAM"]),
        ("Host", "dev.retools.ios", [group]),
        ("Extension", "dev.retools.ios.pairing", []),
        ("NoGroup", "com.retools.fixture", []),
    ]:
        now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
        entitlements = {"application-identifier": team + "." + bundle,
                        "com.apple.developer.team-identifier": team, "get-task-allow": True,
                        "keychain-access-groups": [team + ".*"]}
        if groups:
            entitlements["com.apple.security.application-groups"] = groups
        payload = temp / "profile.plist"
        payload.write_bytes(plistlib.dumps({"Name": "Retools App Group Test Only", "UUID": "HOST-GROUP-TEST-" + (suffix or "Fixture"),
            "TeamIdentifier": [team], "ApplicationIdentifierPrefix": [team], "DeveloperCertificates": [der.read_bytes()],
            "CreationDate": now - datetime.timedelta(days=1), "ExpirationDate": now + datetime.timedelta(days=3650),
            "Entitlements": entitlements}))
        run(["cms", "-sign", "-binary", "-nodetach", "-in", str(payload), "-signer", str(cert), "-inkey", str(key),
             "-outform", "DER", "-out", str(output / ("HostGroupIdentity" + suffix + ".mobileprovision"))])

print("Created disposable App Group fixtures in Tests/Fixtures.")
