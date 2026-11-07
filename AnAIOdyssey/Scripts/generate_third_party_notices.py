#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
# Additional permission for app store distribution: see LICENSE.appstore.
"""Regenerates ThirdPartyNotices/ (bundled into the app and shown under
Settings > About > Acknowledgements) and THIRD_PARTY_NOTICES.md from the
resolved Swift packages, so the in-app list and the repo's notices file come
from the same source and cannot drift.

Usage (after Xcode has resolved packages):
    Scripts/generate_third_party_notices.py <path/to/SourcePackages/checkouts>

The list of packages comes from the app's Package.resolved. Each package's
license (and NOTICE, where it has one) is copied verbatim from its checkout.
Components vendored inside a package that are compiled into the app (MLX's
C++ core and its bundled libraries) are listed under that package.
"""
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)
ROOT = os.path.dirname(APP)  # OpenSource/
OUT = os.path.join(APP, "ThirdPartyNotices")
RESOLVED = os.path.join(APP, "AnAIOdyssey.xcodeproj", "project.xcworkspace",
                        "xcshareddata", "swiftpm", "Package.resolved")

# identity -> (display name, SPDX license, linked into the app?, note, vendored)
PACKAGES = {
    "eventsource": ("EventSource", "MIT", True, "", []),
    "mlx-swift": ("mlx-swift", "MIT", True,
                  "Includes MLX, mlx-c, metal-cpp, {fmt} and nlohmann/json, compiled into the app.",
                  [("MLX", "MIT", "Source/Cmlx/mlx/LICENSE"),
                   ("mlx-c", "MIT", "Source/Cmlx/mlx-c/LICENSE"),
                   ("metal-cpp", "Apache-2.0", "Source/Cmlx/metal-cpp/LICENSE.txt"),
                   ("{fmt}", "MIT", "Source/Cmlx/fmt/LICENSE"),
                   ("nlohmann/json", "MIT", "Source/Cmlx/json/LICENSE.MIT")]),
    "mlx-swift-lm": ("mlx-swift-lm", "MIT", True, "", []),
    "swift-argument-parser": ("swift-argument-parser", "Apache-2.0", False,
                              "Resolved for mlx-swift's command-line tools; not linked into the app.", []),
    "swift-asn1": ("swift-asn1", "Apache-2.0", False,
                   "Resolved for swift-crypto's _CryptoExtras; not linked into the app.", []),
    "swift-collections": ("swift-collections", "Apache-2.0", True, "", []),
    "swift-crypto": ("swift-crypto", "Apache-2.0", True,
                     "On Apple platforms the Crypto module is a thin layer over Apple's CryptoKit. "
                     "Its vendored BoringSSL and XKCP sources are only compiled for Linux, Android, "
                     "Windows, WASI and OpenBSD, so they are not part of the app.", []),
    "swift-huggingface": ("swift-huggingface", "Apache-2.0", True, "", []),
    "swift-jinja": ("swift-jinja", "Apache-2.0", True, "", []),
    "swift-numerics": ("swift-numerics", "Apache-2.0", True, "", []),
    "swift-transformers": ("swift-transformers", "Apache-2.0", True, "", []),
    "yyjson": ("yyjson", "MIT", True, "", []),
}

LICENSE_NAMES = ["LICENSE", "LICENSE.txt", "LICENSE.md"]
NOTICE_NAMES = ["NOTICE", "NOTICE.txt", "NOTICE.md"]


def first_existing(base, names):
    for n in names:
        p = os.path.join(base, n)
        if os.path.exists(p):
            return p
    return None


def main(checkouts):
    pins = json.load(open(RESOLVED))["pins"]
    if os.path.isdir(OUT):
        for f in os.listdir(OUT):
            if f != "odysseus-LICENSE.txt":
                os.remove(os.path.join(OUT, f))
    else:
        os.makedirs(OUT)

    def copy(src, name):
        shutil.copyfile(src, os.path.join(OUT, name))
        return name

    entries = []
    # Our own MIT packages and the MIT-licensed text adapted from Odysseus.
    entries.append({"id": "aiconnect", "name": "AIConnect (AIConnect, AIConnectUI, AIModelOptions)",
                    "license": "MIT", "linked": True, "note": "",
                    "files": [copy(os.path.join(ROOT, "AIConnect", "LICENSE"), "aiconnect-LICENSE.txt")]})
    entries.append({"id": "aiconnectvoice", "name": "AIConnectVoice", "license": "MIT",
                    "linked": True, "note": "",
                    "files": [copy(os.path.join(ROOT, "AIConnectVoice", "LICENSE"), "aiconnectvoice-LICENSE.txt")]})
    entries.append({"id": "odysseus", "name": "Odysseus v1.0 (adapted prompt and tool-format text)",
                    "license": "MIT", "linked": True,
                    "note": "https://github.com/pewdiepie-archdaemon/odysseus at commit e5c99a5e.",
                    "files": ["odysseus-LICENSE.txt"]})

    for pin in sorted(pins, key=lambda p: p["identity"]):
        ident = pin["identity"]
        if ident not in PACKAGES:
            sys.exit(f"error: {ident} is in Package.resolved but has no license entry in {__file__}")
        name, spdx, linked, note, vendored = PACKAGES[ident]
        base = os.path.join(checkouts, os.path.basename(pin["location"]).removesuffix(".git"))
        if not os.path.isdir(base):
            base = os.path.join(checkouts, name)
        lic = first_existing(base, LICENSE_NAMES)
        if lic is None:
            sys.exit(f"error: no license file in {base}")
        files = [copy(lic, f"{ident}-LICENSE.txt")]
        notice = first_existing(base, NOTICE_NAMES)
        if notice:
            files.append(copy(notice, f"{ident}-NOTICE.txt"))
        for vname, vspdx, vpath in vendored:
            safe = "".join(c for c in vname.lower() if c.isalnum())
            files.append(copy(os.path.join(base, vpath), f"{ident}-{safe}-LICENSE.txt"))
        entries.append({"id": ident, "name": name, "license": spdx, "linked": linked,
                        "version": pin["state"].get("version") or pin["state"].get("revision", ""),
                        "url": pin["location"], "note": note,
                        "vendored": [{"name": v[0], "license": v[1]} for v in vendored],
                        "files": files})

    app = {"id": "anaiodyssey", "name": "An AI Odyssey", "license": "AGPL-3.0-or-later",
           "files": [copy(os.path.join(APP, "LICENSE"), "anaiodyssey-LICENSE.txt"),
                     copy(os.path.join(APP, "LICENSE.appstore"), "anaiodyssey-LICENSE.appstore.txt")]}
    manifest = {"packages": entries, "app": app}
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
        f.write("\n")
    write_markdown(manifest)


def write_markdown(m):
    lines = ["# Third-party notices", "",
             "Generated by `Scripts/generate_third_party_notices.py` from the same files the app",
             "shows under Settings > About > Acknowledgements (`ThirdPartyNotices/`). Do not edit",
             "by hand. No model weights are bundled; models are downloaded by the user at run time.", "",
             "| Component | License | In the app binary | Notes |", "|---|---|---|---|"]
    for e in m["packages"]:
        ver = f" {e['version']}" if e.get("version") else ""
        lines.append(f"| {e['name']}{ver} | {e['license']} | {'yes' if e['linked'] else 'no'} | {e['note']} |")
        for v in e.get("vendored", []):
            lines.append(f"| &nbsp;&nbsp;↳ {v['name']} (vendored in {e['name']}) | {v['license']} | yes | |")
    lines += ["", "No component is GPL, LGPL or AGPL licensed, so the App Store permission in",
              "LICENSE.appstore never needs to cover third-party code.", ""]
    for e in m["packages"]:
        lines += ["---", "", f"## {e['name']}", ""]
        for fn in e["files"]:
            lines += [f"### {fn}", "", "```", open(os.path.join(OUT, fn)).read().rstrip("\n"), "```", ""]
    with open(os.path.join(APP, "THIRD_PARTY_NOTICES.md"), "w") as f:
        f.write("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
