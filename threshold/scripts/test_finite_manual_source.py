"""Real-Git adversarial fixtures for the finite current-source candidate verifier."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import finite_manual_source as manual
import historical_imports as gitdata


class FiniteSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fm-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name, "repo").resolve()
        if hasattr(type(self), "reference"):
            shutil.copytree(type(self).reference, self.repo)
            for name, value in type(self).reference_values.items():
                setattr(self, name, copy.deepcopy(value))
            hooks = Path(self.temp.name, "empty-hooks")
            hooks.mkdir()
            self.g("config", "core.hooksPath", str(hooks))
            return
        self.repo.mkdir()
        self.g("init", "-b", "main")
        self.g("config", "user.name", "Finite Source Fixture")
        self.g("config", "user.email", "fixture@example.invalid")
        self.g("config", "core.longpaths", "true")
        self.g("config", "core.autocrlf", "false")
        self.g("config", "core.filemode", "false")
        self.g("config", "core.symlinks", "false")
        self.g("config", "commit.gpgsign", "false")
        hooks = Path(self.temp.name, "empty-hooks")
        hooks.mkdir()
        self.g("config", "core.hooksPath", str(hooks))
        self.write(manual.FILES[0], b"class Extractor { /* before */ }\n")
        for p in manual.TEST_INPUTS[1:]:
            self.write(p + "/jvm.config" if p == ".mvn" else p, b"fixture\n")
        self.initial = self.commit("initial source")
        self.g("checkout", "-b", "witness")
        self.write(manual.FILES[0], b"class Extractor { /* after */ }\n")
        self.write(manual.FILES[1], b"class ExtractorTests {}\n")
        self.witness = self.commit("published tested witness")
        self.g("checkout", "main")
        self.proposal_path = "threshold/docs/source-requalification/pr-184/proposal.json"
        self.prefix = self.proposal_path.rsplit("/", 1)[0] + "/"
        patch = gitdata.diff_bytes(self.repo, self.initial, self.witness, manual.FILES)
        log = b"Fixture only: Tests run: 126, Failures: 0, Errors: 0, Skipped: 0\nBUILD SUCCESS\n"
        self.proposal = {
            "schemaVersion": "threshold.finite_source_requalification.proposal.v1",
            "status": "PROPOSAL_ONLY_NOT_ADMISSION", "proposalBase": self.initial,
            "originalHead": "a867b4933bfa24fa5cdb02bea328a382ce570298",
            "historicalAdmission": manual.LITERALS["historicalAdmission"],
            "publishedWitness": {"head": self.witness},
            "files": [{"path": p, "before": self.blob(self.initial, p), "after": self.blob(self.witness, p)} for p in manual.FILES],
            "testInputObjects": [{"path": p, "proposalBaseObject": manual.object_at(self.repo, self.initial, p), "testedWitnessObject": manual.object_at(self.repo, self.witness, p)} for p in manual.TEST_INPUTS],
            "productPatch": {"path": "product-delta.diff", "base": self.initial, "head": self.witness,
                             "limitedToExactPaths": list(manual.FILES), "sha256": self.digest(patch), "bytes": len(patch)},
            "observedValidation": {"sourceHead": self.witness, "status": "ACTUAL_LOCAL_OBSERVATION_NOT_HISTORICAL_ADMISSION",
                                   "freshCurrentSourceCiRequired": True, "result": "BUILD SUCCESS", "testsRun": 126,
                                   "failures": 0, "errors": 0, "skipped": 0,
                                   "logPath": "maven-test.log", "logSha256": self.digest(log), "logBytes": len(log)},
        }
        self.proposal_bytes = self.json_bytes(self.proposal)
        self.write(self.proposal_path, self.proposal_bytes)
        self.write(self.prefix + "product-delta.diff", patch)
        self.write(self.prefix + "maven-test.log", log)
        self.proposal_commit = self.commit("normal documentary proposal")
        self.registration = dict(manual.LITERALS, proposalCommit=self.proposal_commit,
                                 proposalPath=self.proposal_path, proposalSha256=self.digest(self.proposal_bytes),
                                 proposalBase=self.initial, witnessHead=self.witness,
                                 allowedFiles=list(manual.FILES), requiredTestInputs=list(manual.TEST_INPUTS))
        self.write(manual.REGISTRATION, self.json_bytes(self.registration))
        self.base = self.commit("normal accepted finite registration")
        self.g("checkout", "witness")
        self.g("merge", "--no-ff", "--no-edit", "main")
        self.source = self.g("rev-parse", "HEAD").decode().strip()
        # Copy an immutable real-Git reference fixture. Each test gets independent
        # refs/index/worktree; expensive initial object creation happens only once.
        shared = tempfile.TemporaryDirectory(prefix="fm-ref-")
        type(self).addClassCleanup(shared.cleanup)
        type(self).reference = Path(shared.name, "reference")
        shutil.copytree(self.repo, type(self).reference)
        names = ("initial", "witness", "proposal_path", "prefix", "proposal", "proposal_bytes",
                 "proposal_commit", "registration", "base", "source")
        type(self).reference_values = {name: copy.deepcopy(getattr(self, name)) for name in names}

    def g(self, *args, data=None):
        return gitdata.git(self.repo, *args, data=data)

    def write(self, path, data):
        dest = self.repo / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)

    def commit(self, message):
        self.g("add", "-A")
        self.g("commit", "-m", message)
        return self.g("rev-parse", "HEAD").decode().strip()

    @staticmethod
    def json_bytes(value):
        return (json.dumps(value, sort_keys=True) + "\n").encode()

    @staticmethod
    def digest(data):
        return hashlib.sha256(data).hexdigest()

    def blob(self, revision, path):
        entry = gitdata.tree(self.repo, revision, path).get(path)
        if entry is None:
            return None
        data = gitdata.blob(self.repo, entry[2])
        return {"gitBlob": entry[2], "mode": entry[0], "bytes": len(data), "sha256": self.digest(data)}

    def event(self):
        repo = {"full_name": manual.LITERALS["repository"]}
        return {"number": 184, "repository": repo, "pull_request": {"number": 184,
                "base": {"sha": self.base, "ref": "main", "repo": repo}, "head": {"sha": self.source, "repo": repo}}}

    def verify(self, event=None):
        return manual.validate_event(self.repo, self.base, self.event() if event is None else event)

    def reject(self, event=None):
        with self.assertRaises((ValueError, KeyError, TypeError)):
            self.verify(event)

    def change_base(self, path, data):
        self.g("checkout", "main")
        self.write(path, data)
        self.base = self.commit("changed accepted base fixture")
        self.g("checkout", "witness")
        self.g("merge", "--no-ff", "--no-edit", "main")
        self.source = self.g("rev-parse", "HEAD").decode().strip()

    def test_positive_source_and_no_external_pass_claims(self):
        result = self.verify()
        self.assertEqual(result["currentSourceHead"], self.source)
        self.assertTrue(result["freshCiRequired"] and result["independentExactHeadReviewRequired"])
        self.assertFalse(result["executionAuthorized"] or result["learningEligible"])
        self.assertNotIn("ciPassed", result)
        self.assertNotIn("reviewPassed", result)

    def test_real_synthetic_merge_checkout_preserves_event_source_identity(self):
        self.g("checkout", "main")
        self.g("merge", "--no-ff", "--no-edit", "witness")
        result = self.verify()
        self.assertNotEqual(result["checkoutHead"], result["currentSourceHead"])

    def test_merge_with_changed_tree_rejected(self):
        self.write("unexpected.txt", b"not the proposed source tree")
        self.g("add", "-A")
        tree = self.g("write-tree").decode().strip()
        bad = self.g("commit-tree", tree, "-p", self.base, "-p", self.source, data=b"different synthetic tree\n").decode().strip()
        self.g("reset", "--hard", bad)
        self.reject()

    def test_event_head_mismatch(self):
        event = self.event(); event["pull_request"]["head"]["sha"] = self.witness
        self.reject(event)

    def test_event_base_mismatch(self):
        event = self.event(); event["pull_request"]["base"]["sha"] = self.initial
        self.reject(event)

    def test_foreign_head_repository(self):
        event = copy.deepcopy(self.event()); event["pull_request"]["head"]["repo"]["full_name"] = "foreign/repo"
        self.reject(event)

    def test_other_pr_cannot_use_registration(self):
        event = self.event(); event["number"] = event["pull_request"]["number"] = 203
        self.assertIsNone(self.verify(event))

    def test_extra_path(self):
        self.write("extra.txt", b"extra"); self.source = self.commit("extra")
        self.reject()

    def test_registration_changed_by_source(self):
        self.write(manual.REGISTRATION, self.json_bytes(dict(self.registration, candidateOnly=False)))
        self.source = self.commit("source self registration")
        self.reject()

    def test_missing_registration_in_target(self):
        self.base = self.proposal_commit
        self.reject()

    def test_different_source_blob(self):
        self.write(manual.FILES[0], b"substitution\n"); self.source = self.commit("source substitute")
        self.reject()

    def test_omitted_test(self):
        self.g("rm", manual.FILES[1]); self.source = self.commit("omit regression tests")
        self.reject()

    def test_source_mode_changed(self):
        oid = self.blob(self.source, manual.FILES[0])["gitBlob"]
        self.g("update-index", "--cacheinfo", "100755," + oid + "," + manual.FILES[0])
        self.g("commit", "-m", "mode drift")
        self.source = self.g("rev-parse", "HEAD").decode().strip()
        self.reject()

    def test_registry_cannot_widen_scope_or_relax_current_checks(self):
        self.change_base(manual.REGISTRATION, self.json_bytes(dict(self.registration, freshCiRequired=False)))
        self.reject()

    def test_witness_object_must_exist(self):
        self.change_base(manual.REGISTRATION, self.json_bytes(dict(self.registration, witnessHead="f" * 40)))
        self.reject()

    def test_witness_must_be_an_ancestor_not_only_matching_bytes(self):
        self.g("checkout", "main")
        for path in manual.FILES:
            oid = self.blob(self.witness, path)["gitBlob"]
            self.write(path, gitdata.blob(self.repo, oid))
        self.source = self.commit("source copy without published witness ancestry")
        self.reject()

    def test_test_input_mode_drift_even_with_same_blob(self):
        self.g("checkout", "main")
        oid = manual.object_at(self.repo, self.base, "mvnw")
        self.g("update-index", "--cacheinfo", "100755," + oid + ",mvnw")
        self.g("commit", "-m", "test input mode drift")
        self.base = self.g("rev-parse", "HEAD").decode().strip()
        self.g("checkout", "witness")
        self.g("merge", "--no-ff", "--no-edit", "main")
        self.source = self.g("rev-parse", "HEAD").decode().strip()
        self.reject()

    def test_exact_source_pull_request_number(self):
        event = self.event(); event["pull_request"]["number"] = 201
        self.reject(event)

    def test_actual_main_branch_required(self):
        event = self.event(); event["pull_request"]["base"]["ref"] = "alternate"
        self.reject(event)

    def test_dirty_worktree(self):
        self.write(manual.FILES[0], b"uncommitted substitution")
        self.reject()

    def test_dirty_index_worktree_reverted(self):
        original = (self.repo / manual.FILES[0]).read_bytes()
        self.write(manual.FILES[0], b"staged substitution"); self.g("add", manual.FILES[0])
        self.write(manual.FILES[0], original)
        self.reject()

    def test_untracked_java_input(self):
        self.write("src/main/java/Extra.java", b"class Extra {}")
        self.reject()

    def test_ignored_java_input(self):
        self.write(".git/info/exclude", b"src/main/java/Extra.java\n")
        self.write("src/main/java/Extra.java", b"class Extra {}")
        self.reject()

    def test_untracked_maven_configuration(self):
        self.write(".mvn/local.config", b"untracked Maven input")
        self.reject()

    def test_ignored_maven_configuration(self):
        self.write(".git/info/exclude", b".mvn/local.config\n")
        self.write(".mvn/local.config", b"ignored Maven input")
        self.reject()

    def test_changed_log(self):
        self.change_base(self.prefix + "maven-test.log", b"invented success")
        self.reject()

    def test_changed_patch(self):
        self.change_base(self.prefix + "product-delta.diff", b"partial patch")
        self.reject()

    def test_changed_proposal_counts(self):
        data = copy.deepcopy(self.proposal); data["observedValidation"]["testsRun"] = 0
        self.change_base(self.proposal_path, self.json_bytes(data))
        self.reject()

    def test_baseline_maven_input_drift(self):
        self.change_base("pom.xml", b"changed Maven input")
        self.reject()

    def test_duplicate_registration_json_key(self):
        value = self.json_bytes(self.registration).rstrip()[:-1] + b',"candidateOnly":true}\n'
        self.change_base(manual.REGISTRATION, value)
        self.reject()

    def test_real_powershell_production_wrapper(self):
        shell = shutil.which("pwsh") or shutil.which("powershell.exe")
        if shell is None:
            self.skipTest("PowerShell unavailable")
        event_path = Path(self.temp.name, "event.json")
        event_path.write_bytes(self.json_bytes(self.event()))
        helper = Path(__file__).resolve().parent / "lib/finite-manual-source.ps1"
        quote = lambda p: "'" + str(p).replace("'", "''") + "'"
        command = "$ErrorActionPreference='Stop'; Set-Location -LiteralPath " + quote(self.repo) + "; . " + quote(helper)
        command += "; $env:GITHUB_EVENT_PATH=" + quote(event_path) + "; if(-not (Test-ThresholdFiniteManualSourceCandidate -BaseRef '" + self.base + "')){throw 'candidate rejected'}"
        result = subprocess.run([shell, "-NoProfile", "-Command", command], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        self.assertIn(b"verified_current_source_candidate", result.stdout)


if __name__ == "__main__":
    unittest.main()
