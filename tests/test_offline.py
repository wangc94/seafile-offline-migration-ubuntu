import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("offline", Path(__file__).resolve().parents[1] / "tools/offline.py")
offline = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(offline)


class ReproductionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.repo, self.assets = self.base / "repo", self.base / "assets"
        self.repo.mkdir()
        self.release = offline.DEFAULT_RELEASE
        self.data = {"schema_version": 1, "release": self.release,
                     "bundle_name": "Seafile-Offline-Migration", "files": []}
        payloads = {"install.sh": b"#!/bin/bash\necho synthetic-test\n", "03-database/data.tar": b"private synthetic test data"}
        sums = "".join(f"{hashlib.sha256(v).hexdigest()}  ./{k}\n" for k, v in sorted(payloads.items())).encode()
        payloads["SHA256SUMS"] = sums
        for name, content in payloads.items():
            e = {"path": name, "sha256": hashlib.sha256(content).hexdigest(), "size": len(content),
                 "mode": 0o755 if name == "install.sh" else 0o600,
                 "storage": "asset" if name.endswith(".tar") else "git"}
            if e["storage"] == "git":
                e["source"] = "installer/install.sh" if name == "install.sh" else f"releases/{self.release}/SHA256SUMS"
            p = offline.input_path(self.repo, self.assets, e)
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(content)
            self.data["files"].append(e)
        self.manifest = self.repo / "releases" / self.release / "manifest.json"
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        self.manifest.write_text(json.dumps(self.data), encoding="utf-8")

    def build(self, name="output"):
        return offline.build(self.repo, self.assets, self.data, self.base / name)

    def test_exact_rebuild_and_checksums(self):
        data = offline.load_manifest(self.repo, self.release)
        offline.verify_inputs(self.repo, self.assets, data)
        output = self.build()
        offline.verify_bundle(output, data)
        self.assertEqual(offline.inventory(output), {x["path"] for x in data["files"]})

    def test_missing_asset_fails_before_output(self):
        e = self.data["files"][1]
        offline.input_path(self.repo, self.assets, e).unlink()
        with self.assertRaises(offline.BundleError):
            self.build()
        self.assertFalse((self.base / "output").exists())

    def test_same_size_corruption_rejected(self):
        e = self.data["files"][1]
        offline.input_path(self.repo, self.assets, e).write_bytes(b"X" * e["size"])
        with self.assertRaisesRegex(offline.BundleError, "SHA256 mismatch"):
            self.build()
        self.assertFalse((self.base / "output").exists())

    def test_changed_source_rejected(self):
        offline.input_path(self.repo, self.assets, self.data["files"][0]).write_bytes(b"changed")
        with self.assertRaises(offline.BundleError):
            self.build()

    def test_existing_output_preserved(self):
        output = self.build()
        sentinel = output / "keep.txt"
        sentinel.write_text("keep")
        with self.assertRaises(offline.BundleError):
            self.build()
        self.assertEqual(sentinel.read_text(), "keep")

    def test_asset_overlap_rejected(self):
        with self.assertRaises(offline.BundleError):
            offline.build(self.repo, self.assets, self.data, self.assets / "output")

    def test_unlisted_file_rejected(self):
        output = self.build()
        (output / "extra").write_text("unexpected")
        with self.assertRaises(offline.BundleError):
            offline.verify_bundle(output, self.data)

    def test_missing_bundle_file_rejected(self):
        output = self.build()
        (output / "install.sh").unlink()
        with self.assertRaises(offline.BundleError):
            offline.verify_bundle(output, self.data)

    def test_unsafe_manifest_paths(self):
        original = copy.deepcopy(self.data)
        for name in ("../escape", "/absolute", "C:/escape", "a\\b", "a/../b", "./a", "a//b", "bad\nname"):
            self.data = copy.deepcopy(original)
            self.data["files"][0]["path"] = name
            self.save()
            with self.subTest(name=name), self.assertRaises(offline.BundleError):
                offline.load_manifest(self.repo, self.release)

    def test_duplicate_and_parent_collisions_rejected(self):
        for name in ("INSTALL.SH", "install.sh/child"):
            e = copy.deepcopy(self.data["files"][1])
            e["path"] = name
            self.data["files"].append(e)
            self.save()
            with self.assertRaises(offline.BundleError):
                offline.load_manifest(self.repo, self.release)
            self.data["files"].pop()

    def test_checksums_parser_rejects_traversal_and_duplicates(self):
        sha = "a" * 64
        for text in (f"{sha}  ../escape\n", f"{sha}  a\n{sha}  A\n", f"{sha}  SHA256SUMS\n", ""):
            with self.subTest(text=text), self.assertRaises(offline.BundleError):
                offline.parse_sums(text.encode())

    def test_symlinks_rejected(self):
        target = self.repo / "link"
        try:
            target.symlink_to(self.base, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink permission unavailable on this host")
        with self.assertRaises(offline.BundleError):
            offline.confined(self.repo, "link/escape")

    def test_deterministic_archive_ignores_mtime(self):
        output = self.build()
        a, b = self.base / "one.tar", self.base / "two.tar"
        sha = offline.pack(output, self.data, a)
        import os
        os.utime(output / "install.sh", (123456789, 123456789))
        self.assertEqual(sha, offline.pack(output, self.data, b))
        self.assertEqual(a.read_bytes(), b.read_bytes())
        with tarfile.open(a) as archive:
            self.assertTrue(all(x.mtime == x.uid == x.gid == 0 for x in archive))
        with self.assertRaises(offline.BundleError):
            offline.pack(output, self.data, a)

    def test_asset_store_never_replaces_corrupt_object(self):
        e = self.data["files"][1]
        obj = offline.input_path(self.repo, self.assets, e)
        before = b"X" * e["size"]
        src = self.base / "source"
        src.write_bytes(obj.read_bytes())
        obj.write_bytes(before)
        with self.assertRaises(offline.BundleError):
            offline.store_asset(src, self.assets, e)
        self.assertEqual(obj.read_bytes(), before)

    def test_private_asset_backup_is_independent_and_verified(self):
        output = self.base / "backup"
        offline.backup_assets(self.repo, self.assets, self.data, output)
        offline.verify_inputs(self.repo, output, self.data)
        e = self.data["files"][1]
        offline.input_path(self.repo, self.assets, e).write_bytes(b"corrupt original")
        offline.verify_inputs(self.repo, output, self.data)

    def test_private_backup_rejects_git_destination(self):
        with self.assertRaises(offline.BundleError):
            offline.backup_assets(self.repo, self.assets, self.data, self.repo / "private")

    def test_capture_locks_all_bytes_and_rejects_existing_release(self):
        package, repo, assets = self.base / "package", self.base / "new-repo", self.base / "new-assets"
        package.mkdir()
        repo.mkdir()
        payloads = {name: b"synthetic public source\n" for name in offline.SOURCE_MAP}
        image = [{"Id": "sha256:" + "b" * 64, "RepoTags": ["test:synthetic"], "Os": "linux", "Architecture": "amd64"}]
        payloads.update({f"09-manifests/{name}": json.dumps(image).encode() for name in ("docker-images-inspect.json", "seadoc-image-inspect.json")})
        payloads["03-database/private.tar"] = b"synthetic private input"
        for name, content in payloads.items():
            p = package / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(content)
        (package / "SHA256SUMS").write_text("".join(f"{hashlib.sha256(v).hexdigest()}  ./{k}\n" for k, v in sorted(payloads.items())), encoding="utf-8")
        offline.capture(repo, package, assets, self.release)
        data = offline.load_manifest(repo, self.release)
        output = self.base / "captured-rebuild"
        offline.build(repo, assets, data, output)
        self.assertEqual(offline.inventory(output), offline.inventory(package))
        for name in offline.inventory(package):
            self.assertEqual((package / name).read_bytes(), (output / name).read_bytes())
        # Editing the next installer must not mutate a frozen historical release.
        (repo / "installer/install.sh").write_bytes(b"a future installer revision\n")
        offline.build(repo, assets, data, self.base / "captured-after-edit")
        self.assertEqual((self.base / "captured-after-edit/install.sh").read_bytes(), payloads["install.sh"])
        with self.assertRaises(offline.BundleError):
            offline.capture(repo, package, assets, self.release)

    def test_failed_pack_never_publishes_archive(self):
        output = self.build()
        (output / "install.sh").write_bytes(b"changed")
        archive = self.base / "failed.tar"
        with self.assertRaises(offline.BundleError):
            offline.pack(output, self.data, archive)
        self.assertFalse(archive.exists())


if __name__ == "__main__":
    unittest.main()
