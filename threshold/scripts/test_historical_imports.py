"""Real Git fixtures for the bounded historical-import path (Python 3.10+)."""
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
import historical_imports as hi

SCRIPTS = Path(__file__).resolve().parent


def run(repo, *args, data=None, accept=(0,)):
    result = subprocess.run(["git", "-C", str(repo), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode not in accept:
        raise AssertionError(result.stderr.decode(errors="replace"))
    return result.stdout


def write(repo, name, data):
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def save(repo, message):
    run(repo, "add", "-A")
    run(repo, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message)
    return run(repo, "rev-parse", "HEAD").decode().strip()


class HistoricalImportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.shared = tempfile.TemporaryDirectory(prefix="threshold-history-fixture-")
        cls.reference = Path(cls.shared.name) / "reference"
        cls.reference.mkdir()
        run(cls.reference, "init", "--quiet", "-b", "main")
        run(cls.reference, "config", "user.name", "Threshold Fixture")
        run(cls.reference, "config", "user.email", "fixture@example.invalid")
        run(cls.reference, "config", "core.autocrlf", "false")
        run(cls.reference, "config", "core.longpaths", "true")
        run(cls.reference, "config", "core.filemode", "false")
        run(cls.reference, "config", "core.symlinks", "false")
        shutil.copytree(SCRIPTS, cls.reference / "threshold/scripts",
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        write(cls.reference, "threshold/leases/current.yaml", b"""leaseName: fixture
branch: main
baseRef: origin/main
mergeAllowed: true
allowedPaths:
  - src/main/**
forbiddenPaths:
  - forbidden/**
forbiddenActions:
  - deploy
""")
        write(cls.reference, "threshold/lease-state/current-run.json", b"{}\n")
        write(cls.reference, "src/main/java/demo/App.java", b"class App { int value = 0; }\n")
        write(cls.reference, "docs/old-evidence.bin", b"old\x00\xff\r\n")
        cls.fork = save(cls.reference, "Fixture source fork")
        run(cls.reference, "switch", "--quiet", "-c", "historical-source")
        write(cls.reference, "src/main/java/demo/App.java", b"class App { int value = 1; }\n")
        write(cls.reference, "threshold/leases/current.yaml",
              (cls.reference / "threshold/leases/current.yaml").read_bytes() + b"# old source lease\n")
        write(cls.reference, "docs/new-evidence.bin", b"new\x00\xff\r\n\x80")
        (cls.reference / "docs/old-evidence.bin").unlink()
        cls.original = save(cls.reference, "Historical source with modification, addition and deletion")
        run(cls.reference, "switch", "--quiet", "main")
        write(cls.reference, "src/main/java/demo/App.java", b"class App { int value = 2; }\n")
        write(cls.reference, "threshold/leases/current.yaml",
              (cls.reference / "threshold/leases/current.yaml").read_bytes() + b"# current main lease\n")
        cls.base = save(cls.reference, "Current active source")
        run(cls.reference, "switch", "--quiet", "-c", "inert-import", cls.original)
        run(cls.reference, "merge", "--no-commit", "--no-ff", cls.base, accept=(0, 1))
        run(cls.reference, "restore", "--source=" + cls.base, "--staged", "--worktree", "--", ".")
        cls.directory = hi.capture(cls.reference, cls.original, cls.base, 9001)
        cls.valid_head = save(cls.reference, "Import immutable historical bytes only")

    @classmethod
    def tearDownClass(cls):
        cls.shared.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="threshold-history-test-")
        self.repo = Path(self.temp.name) / "repo"
        subprocess.run(["git", "-c", "core.autocrlf=false", "clone", "--quiet", "--no-hardlinks", str(self.reference), str(self.repo)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for key, value in (("user.name", "Threshold Fixture"), ("user.email", "fixture@example.invalid"),
                           ("core.autocrlf", "false"), ("core.longpaths", "true"),
                           ("core.filemode", "false"), ("core.symlinks", "false")):
            run(self.repo, "config", key, value)
        self.archive = self.repo / self.directory

    def tearDown(self):
        self.temp.cleanup()

    def manifest(self):
        return json.loads((self.archive / "manifest.json").read_text(encoding="utf-8"))

    def put_manifest(self, value):
        (self.archive / "manifest.json").write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def assert_invalid(self):
        with self.assertRaises(hi.InvalidImport):
            hi.validate(self.repo, self.base, "HEAD")

    def commit(self, message="Adversarial fixture"):
        return save(self.repo, message)

    def gate(self):
        executable = shutil.which("pwsh") or shutil.which("powershell")
        if executable is None:
            self.skipTest("PowerShell not available")
        return subprocess.run(
            [executable, "-NoProfile", "-File", str(self.repo / "threshold/scripts/test-pr-governance.ps1"),
             "-BaseRef", "origin/main"], cwd=self.repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def test_positive_preserves_complete_original_bytes_and_active_tree(self):
        result = hi.validate(self.repo, self.base, "HEAD")
        self.assertEqual(result["status"], "verified_inert_historical_import")
        self.assertFalse(result["activeTreeChanged"])
        self.assertFalse(result["executionAuthorized"])
        manifest = self.manifest()
        self.assertTrue(any(c["before"] is None for c in manifest["changes"]))
        self.assertTrue(any(c["after"] is None for c in manifest["changes"]))
        self.assertEqual(manifest["originalMergeBase"], self.fork)
        expected_diff = run(self.repo, "diff", "--binary", "--full-index", "--no-ext-diff",
                            "--no-textconv", "--no-renames", "--no-relative", "--ignore-submodules=none",
                            "--src-prefix=a/", "--dst-prefix=b/", "--no-color", "--diff-algorithm=myers",
                            "--no-indent-heuristic", self.fork, self.original)
        self.assertEqual((self.archive / "original.diff").read_bytes(), expected_diff)
        for change in manifest["changes"]:
            for side in ("before", "after"):
                if change[side] is not None:
                    self.assertEqual((self.archive / change[side]["archive"]).read_bytes(),
                                     run(self.repo, "cat-file", "blob", change[side]["blob"]))
        self.assertEqual(run(self.repo, "show", "HEAD:src/main/java/demo/App.java"),
                         run(self.repo, "show", self.base + ":src/main/java/demo/App.java"))

    def test_actual_powershell_governance_uses_the_bounded_path(self):
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(b"thresholdHistoricalImportOnly=true", result.stdout)
        self.assertIn(b"historical_only_not_reasserted", result.stdout)

    def test_ordinary_policy_change_is_not_an_inert_import(self):
        run(self.repo, "checkout", "--quiet", "--detach", self.base)
        write(self.repo, "threshold/scripts/policy-canary.ps1", b"# ordinary policy change\n")
        self.commit()
        self.assertIsNone(hi.validate(self.repo, self.base, "HEAD"))

    def test_ordinary_governance_still_requires_explicit_merge_authority(self):
        run(self.repo, "checkout", "--quiet", "--detach", self.base)
        lease = self.repo / "threshold/leases/current.yaml"
        lease.write_bytes(lease.read_bytes().replace(b"mergeAllowed: true", b"mergeAllowed: false"))
        write(self.repo, "threshold/scripts/policy-canary.ps1", b"# policy change\n")
        self.commit()
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"requires explicit merge authority", result.stderr)
        self.assertNotIn(b"thresholdHistoricalImportOnly=true", result.stdout)

    def test_ordinary_product_change_still_requires_original_receipts(self):
        run(self.repo, "checkout", "--quiet", "--detach", self.base)
        write(self.repo, "src/main/java/demo/App.java", b"class App { int value = 3; }\n")
        self.commit()
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Missing Threshold receipt", result.stderr)
        self.assertNotIn(b"thresholdHistoricalImportOnly=true", result.stdout)

    def test_source_policy_and_lease_changes_cannot_use_the_exception(self):
        for path in ("src/main/java/demo/App.java", "threshold/scripts/test-pr-governance.ps1",
                     "threshold/leases/current.yaml"):
            with self.subTest(path=path):
                run(self.repo, "reset", "--hard", self.valid_head)
                write(self.repo, path, (self.repo / path).read_bytes() + b"\n# changed\n")
                self.commit()
                self.assert_invalid()

    def test_powershell_also_rejects_product_change_with_valid_archive(self):
        write(self.repo, "src/main/java/demo/App.java", b"class App { int forbidden = 99; }\n")
        self.commit()
        result = self.gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"thresholdHistoricalImportOnly=true", result.stdout)

    def test_blob_tampering_and_wrong_digest_are_rejected(self):
        original_manifest = self.manifest()
        entry = next(c["after"] for c in original_manifest["changes"] if c["after"] is not None)
        write(self.repo, self.directory + "/" + entry["archive"], b"tampered original")
        self.commit()
        self.assert_invalid()
        run(self.repo, "reset", "--hard", self.valid_head)
        manifest = self.manifest()
        next(c["after"] for c in manifest["changes"] if c["after"] is not None)["sha256"] = "0" * 64
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()

    def test_missing_blob_and_omitted_change_are_rejected(self):
        manifest = self.manifest()
        entry = next(c["before"] for c in manifest["changes"] if c["before"] is not None)
        (self.archive / entry["archive"]).unlink()
        self.commit()
        self.assert_invalid()
        run(self.repo, "reset", "--hard", self.valid_head)
        manifest = self.manifest()
        removed = manifest["changes"].pop()
        for side in ("before", "after"):
            if removed[side] is not None:
                (self.archive / removed[side]["archive"]).unlink()
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()

    def test_full_diff_cannot_be_replaced_by_a_summary_even_with_updated_digest(self):
        data = b"Historical change summary only\n"
        (self.archive / "original.diff").write_bytes(data)
        manifest = self.manifest()
        manifest["originalDiff"]["sha256"] = hi.digest(data)
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()

    def test_path_escape_and_extra_archive_files_are_rejected(self):
        manifest = self.manifest()
        next(c["after"] for c in manifest["changes"] if c["after"] is not None)["archive"] = "../escaped.bin"
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()
        run(self.repo, "reset", "--hard", self.valid_head)
        write(self.repo, self.directory + "/extra.json", b"{}\n")
        self.commit()
        self.assert_invalid()

    def test_executable_and_symlink_git_modes_are_rejected(self):
        path = self.directory + "/original.diff"
        for mode in ("100755", "120000"):
            with self.subTest(mode=mode):
                run(self.repo, "reset", "--hard", self.valid_head)
                oid = run(self.repo, "rev-parse", "HEAD:" + path).decode().strip()
                run(self.repo, "update-index", "--cacheinfo", mode + "," + oid + "," + path)
                run(self.repo, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "Invalid archive mode")
                self.assert_invalid()

    def test_wrong_original_merge_base_and_target_are_rejected(self):
        for key, value in (("originalMergeBase", self.base), ("originalTargetBase", self.original)):
            with self.subTest(key=key):
                run(self.repo, "reset", "--hard", self.valid_head)
                manifest = self.manifest()
                manifest[key] = value
                self.put_manifest(manifest)
                self.commit()
                self.assert_invalid()

    def test_original_head_must_be_in_final_ancestry(self):
        original_tree = run(self.repo, "rev-parse", self.original + "^{tree}").decode().strip()
        sibling = run(self.repo, "commit-tree", original_tree, "-p", self.original,
                      "-m", "Historical head not imported").decode().strip()
        manifest = self.manifest()
        manifest["originalHead"] = sibling
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()

    def test_authority_runtime_and_qualification_promotions_are_rejected(self):
        for key, value in (("historicalValidationReasserted", True), ("runtimeAuthority", "CURRENT"),
                           ("executionAuthorized", True), ("authorityCreated", True),
                           ("qualificationGranted", True), ("disposition", "approved")):
            with self.subTest(key=key):
                run(self.repo, "reset", "--hard", self.valid_head)
                manifest = self.manifest()
                manifest[key] = value
                self.put_manifest(manifest)
                self.commit()
                self.assert_invalid()

    def test_missing_extra_and_duplicate_manifest_fields_are_rejected(self):
        manifest = self.manifest()
        del manifest["runtimeAuthority"]
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()
        run(self.repo, "reset", "--hard", self.valid_head)
        manifest = self.manifest()
        manifest["approval"] = True
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()
        run(self.repo, "reset", "--hard", self.valid_head)
        path = self.archive / "manifest.json"
        text = path.read_text(encoding="utf-8")
        path.write_text(text.replace("{", '{"runtimeAuthority":"NONE",', 1), encoding="utf-8")
        self.commit()
        self.assert_invalid()

    def test_deletion_representation_and_extra_import_directories_are_rejected(self):
        manifest = self.manifest()
        deletion = next(c for c in manifest["changes"] if c["after"] is None)
        deletion["after"] = copy.deepcopy(deletion["before"])
        self.put_manifest(manifest)
        self.commit()
        self.assert_invalid()
        run(self.repo, "reset", "--hard", self.valid_head)
        write(self.repo, hi.PREFIX + "pr-9002/manifest.json", b"{}\n")
        self.commit()
        self.assert_invalid()

    def test_existing_import_is_immutable(self):
        write(self.repo, self.directory + "/new-file.bin", b"no rewrite\n")
        self.commit()
        with self.assertRaises(hi.InvalidImport):
            hi.validate(self.repo, self.valid_head, "HEAD")

    def test_custom_git_attributes_and_tracked_checkout_drift_are_rejected(self):
        (self.archive / ".gitattributes").write_bytes(b"* filter=custom\n")
        self.commit()
        self.assert_invalid()
        run(self.repo, "reset", "--hard", self.valid_head)
        write(self.repo, "src/main/java/demo/App.java", b"uncommitted active change\n")
        self.assert_invalid()

    def test_cli_invalid_manifest_fails_closed_without_not_applicable_fallback(self):
        (self.archive / "manifest.json").write_bytes(b"{broken json")
        self.commit()
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPTS / "historical_imports.py"), "validate",
             "--repository", str(self.repo), "--base", self.base],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b"not_applicable", result.stdout)
        self.assertIn(b"invalid_historical_import", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
