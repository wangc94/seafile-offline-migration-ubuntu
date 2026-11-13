#!/usr/bin/env python3
"""Offline, standard-library-only capture and reproduction of migration bundles."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_RELEASE = "v0.8.0-baseline.1"
SOURCE_MAP = {
    "install.sh": "installer/install.sh",
    "README.md": "installer/README.md",
    **{f"02-config/ubuntu/{name}": f"installer/compose/{name}" for name in (
        "README.md", "seafile-server.yml", "caddy.yml", "onlyoffice.yml", "seadoc.yml"
    )},
}
HEX = re.compile(r"[0-9a-f]{64}\Z")
VERSION = re.compile(r"v[0-9][A-Za-z0-9._-]*\Z")
CHUNK = 4 * 1024 * 1024


class BundleError(Exception):
    pass


def fail(message):
    raise BundleError(message)


def safe_relative(value):
    if not isinstance(value, str) or not value or any(c in value for c in "\\:\r\n\0"):
        fail(f"Unsafe relative path: {value!r}")
    p = PurePosixPath(value)
    if p.is_absolute() or any(x in (".", "..") for x in p.parts) or str(p) != value:
        fail(f"Unsafe relative path: {value!r}")
    return value


def linked(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def confined(root, relative):
    safe_relative(relative)
    root = Path(root).absolute()
    p = root
    for part in ("", *PurePosixPath(relative).parts):
        p = p / part
        if linked(p):
            fail(f"Symlink/junction is not allowed: {p}")
    if not p.resolve().is_relative_to(root.resolve()):
        fail(f"Path escapes its root: {p}")
    return p


def inventory(root):
    root = Path(root)
    if linked(root) or not root.is_dir():
        fail(f"Not a regular directory: {root}")
    result = set()
    for current, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            p = Path(current) / name
            if linked(p):
                fail(f"Symlink/junction is not allowed: {p}")
        for name in files:
            p = Path(current) / name
            if not p.is_file():
                fail(f"Not a regular file: {p}")
            result.add(safe_relative(p.relative_to(root).as_posix()))
    return result


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def check(path, entry):
    if not path.is_file() or path.stat().st_size != entry["size"]:
        fail(f"Missing file or wrong size: {entry['path']}")
    if digest(path) != entry["sha256"]:
        fail(f"SHA256 mismatch: {entry['path']}")


def copy_checked(src, dst, entry):
    dst.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    h, size = hashlib.sha256(), 0
    with src.open("rb") as inp, dst.open("xb") as out:
        while chunk := inp.read(CHUNK):
            size += len(chunk)
            h.update(chunk)
            out.write(chunk)
    if size != entry["size"] or h.hexdigest() != entry["sha256"]:
        fail(f"SHA256 mismatch during copy: {entry['path']}")
    dst.chmod(entry.get("mode", 0o600))


def parse_sums(raw):
    result = {}
    for line in raw.decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *](.+)", line)
        if not match:
            fail("Invalid SHA256SUMS line")
        sha, name = match.groups()
        if name.startswith("./"):
            name = name[2:]
        safe_relative(name)
        if name == "SHA256SUMS" or name.casefold() in {x.casefold() for x in result}:
            fail(f"Duplicate/self-referencing SHA256SUMS entry: {name}")
        result[name] = sha.lower()
    if not result:
        fail("Empty SHA256SUMS")
    return result


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8", newline="\n") as out:
        json.dump(value, out, ensure_ascii=False, indent=2)
        out.write("\n")


def release_dir(root, release):
    if not VERSION.fullmatch(release):
        fail("Invalid release name")
    return confined(root, f"releases/{release}")


def load_manifest(root, release):
    path = release_dir(root, release) / "manifest.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or data.get("release") != release:
        fail("Unsupported manifest schema or release mismatch")
    if data.get("bundle_name") != "Seafile-Offline-Migration":
        fail("Unexpected bundle name")
    seen, sources = set(), set()
    for e in data["files"]:
        safe_relative(e["path"])
        key = e["path"].casefold()
        if key in seen:
            fail("Duplicate manifest path")
        seen.add(key)
        if not isinstance(e["size"], int) or isinstance(e["size"], bool) or e["size"] < 0:
            fail("Invalid file size")
        if not isinstance(e["sha256"], str) or not HEX.fullmatch(e["sha256"]):
            fail("Invalid SHA256")
        if e.get("mode") not in (0o600, 0o644, 0o755):
            fail("Invalid file mode")
        if e["storage"] == "git":
            safe_relative(e["source"])
            if e["source"] in sources:
                fail("Duplicate Git source")
            sources.add(e["source"])
        elif e["storage"] != "asset":
            fail("Invalid storage type")
    if not seen or "sha256sums" not in seen:
        fail("Manifest must include SHA256SUMS")
    for name in seen:
        if any(str(p) in seen for p in PurePosixPath(name).parents if str(p) != "."):
            fail("Manifest file/directory collision")
    return data


def object_path(assets, sha):
    return confined(assets, f"objects/sha256/{sha}")


def input_path(root, assets, e):
    return confined(root, e["source"]) if e["storage"] == "git" else object_path(assets, e["sha256"])


def store_asset(src, assets, e):
    obj = object_path(assets, e["sha256"])
    if obj.exists():
        check(obj, e)
        return
    obj.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=".incoming-", dir=obj.parent)
    os.close(fd)
    tmp = Path(tmp_name)
    tmp.unlink()
    try:
        copy_checked(src, tmp, e)
        # Atomic no-clobber publication; do not overwrite an existing object.
        try:
            os.link(tmp, obj)
        except FileExistsError:
            check(obj, e)
    finally:
        tmp.unlink(missing_ok=True)


def capture(root, package, assets, release):
    root, package, assets = Path(root).resolve(), Path(package).resolve(), Path(assets).absolute()
    target = release_dir(root, release)
    if target.exists():
        fail("Release already exists; use a new release name")
    if assets.resolve().is_relative_to(root):
        fail("Private assets must be outside the Git repository")
    sums_file = confined(package, "SHA256SUMS")
    sums = parse_sums(sums_file.read_bytes())
    if inventory(package) != set(sums) | {"SHA256SUMS"}:
        fail("Package has missing or unlisted files")
    if not set(SOURCE_MAP).issubset(sums):
        fail("Package does not contain the expected v0.8 installer sources")
    entries = []
    for name in sorted(set(sums) | {"SHA256SUMS"}):
        src = confined(package, name)
        sha = sums.get(name) or digest(src)
        e = {"path": name, "size": src.stat().st_size, "sha256": sha,
             "mode": 0o755 if name == "install.sh" else 0o600}
        source = SOURCE_MAP.get(name)
        if name == "SHA256SUMS":
            source = f"releases/{release}/SHA256SUMS"
        if source:
            e.update(storage="git", source=source, mode=0o755 if name == "install.sh" else 0o644)
            dst = confined(root, source)
            check(src, e)
            if dst.exists():
                check(dst, e)
            else:
                copy_checked(src, dst, e)
        else:
            e["storage"] = "asset"
            store_asset(src, assets, e)
        entries.append(e)
        print(f"Locked: {name}", flush=True)
    images = {}
    for name in ("docker-images-inspect.json", "seadoc-image-inspect.json"):
        raw = json.loads((package / "09-manifests" / name).read_text(encoding="utf-8"))
        for item in raw if isinstance(raw, list) else [raw]:
            images[item["Id"]] = {k: item.get(k) for k in (
                "Id", "RepoTags", "RepoDigests", "Architecture", "Os")}
    write_json(target / "images.lock.json", {"provenance": "recorded Docker inspect metadata; not a registry lookup",
                                             "images": sorted(images.values(), key=lambda x: x["Id"])})
    manifest = {"schema_version": 1, "release": release, "bundle_name": "Seafile-Offline-Migration",
                "status": "reproduced; Ubuntu restore and upgrade acceptance pending",
                "upstream_installer": "v0.8", "platform": "linux/amd64", "files": entries}
    # The manifest is the completion marker for capture.
    write_json(target / "manifest.json", manifest)
    print(f"Captured {len(entries)} files, {sum(e['size'] for e in entries)} bytes")
    return manifest


def verify_inputs(root, assets, data):
    for e in data["files"]:
        check(input_path(root, assets, e), e)
    print(f"Verified all {len(data['files'])} locked inputs")


def verify_bundle(bundle, data):
    expected = {e["path"] for e in data["files"]}
    if inventory(bundle) != expected:
        fail("Bundle has missing or unlisted files")
    for e in data["files"]:
        check(confined(bundle, e["path"]), e)
    sums = parse_sums(confined(bundle, "SHA256SUMS").read_bytes())
    actual = {e["path"]: e["sha256"] for e in data["files"] if e["path"] != "SHA256SUMS"}
    if sums != actual:
        fail("Bundle SHA256SUMS disagrees with the release manifest")
    print(f"Verified exact bundle: {len(expected)} files")


def disjoint_output(output, protected):
    if output.exists() or output.is_symlink():
        fail(f"Output already exists; refusing to overwrite: {output}")
    for p in protected:
        p = Path(p).resolve()
        if output.is_relative_to(p) or p.is_relative_to(output):
            fail(f"Output overlaps protected input: {p}")


def build(root, assets, data, output):
    output = Path(output).absolute()
    if linked(output.parent):
        fail("Output parent cannot be a symlink/junction")
    output = output.resolve()
    # dist/ inside this repo is intentionally allowed; installer and releases are not.
    protected = [Path(assets), Path(root) / "installer", Path(root) / "releases", Path(root) / ".git"]
    disjoint_output(output, protected)
    if output == Path(root).resolve():
        fail("Output cannot be the repository root")
    # Fail before copying any files if even one input is unavailable.
    for e in data["files"]:
        p = input_path(root, assets, e)
        if not p.is_file() or p.stat().st_size != e["size"]:
            fail(f"Missing input or wrong size: {e['path']}")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{output.name}.partial-", dir=output.parent))
    stage.chmod(0o700)
    try:
        for e in data["files"]:
            copy_checked(input_path(root, assets, e), confined(stage, e["path"]), e)
        verify_bundle(stage, data)
        # A non-empty directory is never replaced. A concurrent output is an error.
        if output.exists():
            fail("Output was created by another process")
        stage.rename(output)
    except Exception:
        print(f"Incomplete staging retained for inspection: {stage}", file=sys.stderr)
        raise
    print(f"Built: {output}")
    return output


def backup_assets(root, assets, data, output):
    output = Path(output).absolute().resolve()
    disjoint_output(output, [Path(root), Path(assets)])
    output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{output.name}.partial-", dir=output.parent))
    stage.chmod(0o700)
    try:
        for e in data["files"]:
            if e["storage"] == "asset":
                dst = object_path(stage, e["sha256"])
                if not dst.exists():
                    copy_checked(input_path(root, assets, e), dst, e)
        verify_inputs(root, stage, data)
        if output.exists():
            fail("Backup output was created by another process")
        stage.rename(output)
    except Exception:
        print(f"Incomplete backup retained: {stage}", file=sys.stderr)
        raise
    print(f"Private asset backup verified: {output}")


def pack(bundle, data, output):
    bundle, output = Path(bundle).resolve(), Path(output).absolute()
    if linked(output.parent):
        fail("Output parent cannot be a symlink/junction")
    output = output.resolve()
    disjoint_output(output, [bundle])
    sums_path = Path(str(output) + ".sha256")
    if sums_path.exists():
        fail("Archive checksum output already exists")
    verify_bundle(bundle, data)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{output.name}.partial-", dir=output.parent)
    os.close(fd)
    temp_archive = Path(temp_name)
    # Fixed order, timestamps, owner and modes; no current time or host paths.
    # Publish the final filename only after the archived bytes have been verified.
    with temp_archive.open("wb") as raw, tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for e in sorted(data["files"], key=lambda x: x["path"]):
            info = tarfile.TarInfo(f"{data['bundle_name']}/{e['path']}")
            info.size, info.mode, info.mtime = e["size"], e["mode"], 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            src = confined(bundle, e["path"])
            with src.open("rb") as f:
                archive.addfile(info, f)
    temp_archive.chmod(0o600)
    sha = digest(temp_archive)
    # Verify the bytes actually archived as well (detect changed inputs during packing).
    with tarfile.open(temp_archive, "r:") as archive:
        members = archive.getmembers()
        expected = sorted(data["files"], key=lambda x: x["path"])
        if len(members) != len(expected):
            fail("Archive entry count mismatch; discard the incomplete archive")
        for member, e in zip(members, expected):
            if member.name != f"{data['bundle_name']}/{e['path']}" or not member.isfile():
                fail("Archive layout mismatch")
            h = hashlib.sha256()
            with archive.extractfile(member) as f:
                while chunk := f.read(CHUNK):
                    h.update(chunk)
            if h.hexdigest() != e["sha256"]:
                fail(f"Archived bytes changed: {e['path']}; discard archive")
    try:
        os.link(temp_archive, output)
    finally:
        temp_archive.unlink(missing_ok=True)
    with sums_path.open("x", encoding="ascii", newline="\n") as f:
        f.write(f"{sha}  {output.name}\n")
    print(f"Packed: {output}\nSHA256: {sha}")
    return sha


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", default=DEFAULT_RELEASE)
    parser.add_argument("--assets", type=Path, default=Path(os.environ.get(
        "SEAFILE_ASSET_DIR", str(ROOT.parent / "seafile-offline-assets"))))
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("verify-inputs", help="Hash all Git sources and private objects")
    backup = sub.add_parser("backup-assets", help="Copy and verify this release's private objects to separate storage")
    backup.add_argument("--output", type=Path, required=True)
    cap = sub.add_parser("capture", help="Capture an existing checksummed migration package")
    cap.add_argument("--package", type=Path, required=True)
    bld = sub.add_parser("build", help="Reproduce the exact directory, without network or Docker")
    bld.add_argument("--output", type=Path, required=True)
    ver = sub.add_parser("verify", help="Verify exact file set and all SHA256 values")
    ver.add_argument("--bundle", type=Path, required=True)
    archive = sub.add_parser("pack", help="Write a deterministic, uncompressed delivery TAR")
    archive.add_argument("--bundle", type=Path, required=True)
    archive.add_argument("--output", type=Path, required=True)
    opts = parser.parse_args()
    try:
        if opts.command == "capture":
            capture(ROOT, opts.package, opts.assets, opts.release)
        else:
            data = load_manifest(ROOT, opts.release)
            if opts.command == "verify-inputs":
                verify_inputs(ROOT, opts.assets, data)
            elif opts.command == "backup-assets":
                backup_assets(ROOT, opts.assets, data, opts.output)
            elif opts.command == "build":
                build(ROOT, opts.assets, data, opts.output)
            elif opts.command == "verify":
                verify_bundle(opts.bundle, data)
            elif opts.command == "pack":
                pack(opts.bundle, data, opts.output)
    except (BundleError, OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
