#!/usr/bin/env python3
"""Validate all public release locks without requiring private assets."""
import subprocess
from pathlib import Path
import offline


def main():
    patch = offline.ROOT / "installer/patches/onlyoffice/utils.py"
    if offline.digest(patch) != "900ba73c637ef3271770fb6fd22ee7b90644d293706457fed59a30c61b83a926":
        offline.fail("Public ONLYOFFICE patch differs from the imported baseline")
    for manifest in sorted((offline.ROOT / "releases").glob("*/manifest.json")):
        data = offline.load_manifest(offline.ROOT, manifest.parent.name)
        source = {}
        for e in data["files"]:
            if e["storage"] == "git":
                offline.check(offline.confined(offline.ROOT, e["source"]), e)
                source[e["path"]] = e
        sums = offline.parse_sums((manifest.parent / "SHA256SUMS").read_bytes())
        expected = {e["path"]: e["sha256"] for e in data["files"] if e["path"] != "SHA256SUMS"}
        if expected != sums:
            offline.fail("Release manifest disagrees with frozen SHA256SUMS")
        print(f"Public release sources and locks verified: {manifest.parent.name}")
    tracked = subprocess.run(["git", "ls-files", "-z"], cwd=offline.ROOT, check=True, capture_output=True).stdout
    for raw in tracked.split(b"\0"):
        if not raw:
            continue
        name = raw.decode("utf-8")
        p = Path(name)
        if (p.suffix.lower() in (".tar", ".zip", ".sql", ".tgz", ".7z") or
                p.name.startswith(".env") and p.name != ".env.example" or
                p.name in ("compose-resolved.yml", "containers-inspect.json", "docker-images-inspect.json") or
                p.parts[0] in ("dist", "private-assets", ".local")):
            offline.fail(f"Private/generated file tracked in Git: {name}")
        if (offline.ROOT / name).stat().st_size > 2 * 1024 * 1024:
            offline.fail(f"Unexpected large tracked file: {name}")
    print("Tracked file policy passed")


if __name__ == "__main__":
    main()
