#!/usr/bin/env python3
"""Build the FrSky Suite install ZIP: dist/RotorRescue-<version>.zip

The ZIP follows FrSky's Lua package format (ethos_lua_manifest.json,
manifestVersion 1): the script files sit at the ZIP root and the manifest
lists every one of them, because Suite installs only the listed files into
RADIO:/scripts/RotorRescue/. On an upgrade Suite first removes the files the
previously installed manifest listed, so stale files from older versions go.
The repository's LICENSE travels with it as LICENSE.txt.

    python3 tools/build_release.py
"""
import json
import os
import re
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "RotorRescue")
PACKAGING = os.path.join(ROOT, "packaging")
KEY = "io.github.bliatun-code.rotorrescue"


def main():
    with open(os.path.join(SCRIPT, "main.lua"), encoding="utf-8") as f:
        version = re.search(r'local VERSION = "(\d+\.\d+\.\d+)"', f.read()).group(1)
    files = ["main.lua", "icon.png"]
    files += sorted((f"sounds/{name}" for name in os.listdir(os.path.join(SCRIPT, "sounds"))
                     if name.endswith(".wav")), key=lambda p: (len(p), p))
    sources = {path: os.path.join(SCRIPT, *path.split("/")) for path in files}
    sources["INSTALL.txt"] = os.path.join(PACKAGING, "INSTALL.txt")
    sources["LICENSE.txt"] = os.path.join(ROOT, "LICENSE")
    with open(os.path.join(PACKAGING, "release-notes.md"), encoding="utf-8") as f:
        notes = f.read()
    manifest = {
        "manifestVersion": 1,
        "name": "Rotor Rescue",
        "key": KEY,
        "version": version,
        "folder": "RotorRescue",
        "files": files + ["INSTALL.txt", "LICENSE.txt"],
        "introduction": "A two-stick helicopter landing game for FrSky ETHOS radios.",
        "releaseNotes": notes,
    }
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"RotorRescue-{version}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in manifest["files"]:
            z.write(sources[path], path)
        z.writestr("ethos_lua_manifest.json", json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"{out}: {len(manifest['files'])} files, version {version}")


if __name__ == "__main__":
    main()
