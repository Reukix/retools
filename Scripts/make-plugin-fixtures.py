#!/usr/bin/env python3
"""Create benign dynamic-library and Debian fixtures without user material."""
from pathlib import Path
import io, tarfile, subprocess, tempfile, gzip, lzma, plistlib, datetime, uuid

root = Path(__file__).resolve().parents[1]
output = root / "Tests/Fixtures"
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="retools-plugin-fixture-") as tmp:
    source = Path(tmp) / "plugin.c"
    source.write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <limits.h>\n__attribute__((constructor)) static void loaded(void) { const char *home = getenv("HOME"); if (!home) return; char path[PATH_MAX]; snprintf(path, sizeof(path), "%s/Library/Caches/retools-plugin-test.marker", home); FILE *file = fopen(path, "w"); if (file) { fputs("Retools fixture plugin loaded", file); fclose(file); } }\nint RetoolsPluginFixture(void) { return 42; }\n')
    library = output / "FixturePlugin.dylib"
    subprocess.run(["xcrun", "--sdk", "iphoneos", "clang", "-arch", "arm64", "-mios-version-min=17.0", "-dynamiclib", "-install_name", "@rpath/FixturePlugin.dylib", str(source), "-o", str(library)], check=True)
    def tar(entries):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w") as archive:
            for name, body, link in entries:
                info = tarfile.TarInfo(name); info.mode = 0o644
                if link:
                    info.type = tarfile.SYMTYPE; info.linkname = link; archive.addfile(info)
                else:
                    info.size = len(body); archive.addfile(info, io.BytesIO(body))
        return buffer.getvalue()
    def ar(entries):
        data = bytearray(b"!<arch>\n")
        for name, body in entries:
            data.extend(f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(body):<10}`\n".encode())
            data.extend(body)
            if len(body) % 2: data.extend(b"\n")
        return bytes(data)
    control = gzip.compress(tar([("./control", b"Package: retools.fixture\nVersion: 1.0\n", None), ("./postinst", b"#!/bin/sh\nexit 99\n", None)]))
    filters = plistlib.dumps({"Filter": {"Bundles": ["com.retools.fixture"], "Executables": ["Fixture"]}})
    payload = tar([("./Library/MobileSubstrate/DynamicLibraries/FixturePlugin.dylib", library.read_bytes(), None), ("./Library/MobileSubstrate/DynamicLibraries/FixturePlugin.plist", filters, None), ("./Library/Application Support/Fixture/message.txt", b"fixture resource", None)])
    for suffix, compress in [("xz", lzma.compress), ("gz", gzip.compress)]:
        name = "FixturePlugin.deb" if suffix == "xz" else "FixturePluginGzip.deb"
        (output / name).write_bytes(ar([("debian-binary", b"2.0\n"), ("control.tar.gz", control), ("data.tar." + suffix, compress(payload))]))
    for name, entries in [("UnsafePlugin.deb", [("../../escape.dylib", library.read_bytes(), None)]), ("SymlinkPlugin.deb", [("Library/link", b"", "/tmp/escape")])]:
        (output / name).write_bytes(ar([("debian-binary", b"2.0\n"), ("data.tar.gz", gzip.compress(tar(entries)))]))
    # A throwaway identity with an explicit code-signing purpose lets macOS verify
    # the complete injected IPA as well as the in-process signing assertions.
    openssl = "/opt/homebrew/opt/openssl@3/bin/openssl"
    def run(args):
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    key, cert, der = [Path(tmp) / name for name in ["identity.key", "identity.crt", "identity.der"]]
    run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
         "-subj", "/CN=Retools Plugin Test Only/OU=TESTTEAM01/O=Retools Fixtures",
         "-addext", "basicConstraints=critical,CA:TRUE",
         "-addext", "keyUsage=critical,digitalSignature,keyCertSign",
         "-addext", "extendedKeyUsage=codeSigning", "-keyout", str(key), "-out", str(cert)])
    run([openssl, "x509", "-in", str(cert), "-outform", "DER", "-out", str(der)])
    run([openssl, "pkcs12", "-export", "-in", str(cert), "-inkey", str(key), "-certfile", str(cert),
         "-out", str(output / "PluginIdentity.p12"), "-passout", "pass:test-only"])
    now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
    profile = Path(tmp) / "profile.plist"
    profile.write_bytes(plistlib.dumps({
        "Name": "Retools Plugin Test Profile", "UUID": str(uuid.uuid4()).upper(),
        "TeamIdentifier": ["TESTTEAM01"], "ApplicationIdentifierPrefix": ["TESTTEAM01"],
        "DeveloperCertificates": [der.read_bytes()], "CreationDate": now,
        "ExpirationDate": now + datetime.timedelta(days=3650),
        "Entitlements": {"application-identifier": "TESTTEAM01.*", "com.apple.developer.team-identifier": "TESTTEAM01",
                         "get-task-allow": True, "keychain-access-groups": ["TESTTEAM01.*"]}}))
    run([openssl, "cms", "-sign", "-binary", "-nodetach", "-in", str(profile), "-signer", str(cert),
         "-inkey", str(key), "-outform", "DER", "-out", str(output / "PluginIdentity.mobileprovision")])
print("Created benign plugins, malformed archives and a throwaway code-signing identity")
