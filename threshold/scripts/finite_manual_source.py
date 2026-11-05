"""Verify a finite current-source candidate; never attest CI, review or runtime authority."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

import historical_imports as evidence

REGISTRATION = "threshold/authority/manual-source-qualifications/pr-184.json"
QUALIFICATION_ID = "pr184-current-user-directed-source-v1"
FILES = (
    "src/main/java/org/springframework/samples/petclinic/repository/jdbc/OneToManyResultSetExtractor.java",
    "src/test/java/org/springframework/samples/petclinic/repository/jdbc/OneToManyResultSetExtractorTests.java",
)
TEST_INPUTS = ("src", "pom.xml", ".mvn", "mvnw", "mvnw.cmd")
LITERALS = {
    "schemaVersion": "threshold.finite_manual_source.v1",
    "repository": "formatunitedandreas-code/spring-framework-petclinic",
    "qualificationId": QUALIFICATION_ID,
    "sourcePullRequest": 184,
    "candidateOnly": True,
    "freshCiRequired": True,
    "independentExactHeadReviewRequired": True,
    "historicalAdmission": "HOLD_MISSING_ORIGINAL_QUALIFICATION",
    "historicalValidationReasserted": False,
    "runtimeAuthority": "NONE",
    "executionAuthorized": False,
    "learningEligible": False,
}
REG_KEYS = set(LITERALS) | {"proposalCommit", "proposalPath", "proposalSha256", "proposalBase", "witnessHead", "allowedFiles", "requiredTestInputs"}


def require(condition, message):
    if not condition:
        raise evidence.InvalidImport(message)


def regular_blob(repo, revision, path):
    evidence.path_name(path)
    entry = evidence.tree(repo, revision, path).get(path)
    require(entry is not None and entry[:2] == ("100644", "blob"), "Missing or nonregular evidence: " + path)
    return evidence.blob(repo, entry[2])


def object_at(repo, revision, path):
    # Missing input paths are explicit null in the accepted witness.
    entries = evidence.git(repo, "ls-tree", "-z", revision, "--", path).split(b"\0")
    entries = [entry for entry in entries if entry]
    if not entries:
        return None
    require(len(entries) == 1, "Ambiguous test input path")
    metadata, actual_path = entries[0].split(b"\t", 1)
    require(actual_path.decode("utf-8") == path, "Test input spelling mismatch")
    mode, kind, oid = metadata.decode("ascii").split()
    require((mode, kind) in (("040000", "tree"), ("100644", "blob"), ("100755", "blob")), "Invalid test input mode")
    return oid


def verify_file(repo, revision, path, expected):
    entry = evidence.tree(repo, revision, path).get(path)
    if expected is None:
        require(entry is None, "Expected absent source path: " + path)
        return
    evidence.exact_keys(expected, {"gitBlob", "sha256", "bytes", "mode"}, "source blob")
    require(type(expected["bytes"]) is int and expected["bytes"] >= 0, "Invalid source byte count")
    require(entry is not None and entry == (expected["mode"], "blob", expected["gitBlob"]), "Source Git blob/mode mismatch: " + path)
    require(entry[0] == "100644", "Source must be a regular nonexecutable file")
    data = evidence.blob(repo, entry[2])
    require(len(data) == expected["bytes"] and hashlib.sha256(data).hexdigest() == expected["sha256"], "Source byte identity mismatch: " + path)


def validate(repo, base_ref, head_ref, pull_request):
    if pull_request != 184:
        return None
    base, head = evidence.commit(repo, base_ref), evidence.commit(repo, head_ref)
    changed = evidence.changed_paths(repo, base, head)
    product = [p for p in changed if p.startswith(("src/main/", "src/test/")) or p == "pom.xml"]
    if not product:
        return None
    require(evidence.ancestor(repo, base, head), "Actual target base must be an ancestor of current source head")
    require(changed == sorted(FILES), "Finite source final delta must contain exactly the two registered files")
    registration = evidence.load_json(regular_blob(repo, base, REGISTRATION))
    evidence.exact_keys(registration, REG_KEYS, "finite source registration")
    for key, value in LITERALS.items():
        require(type(registration[key]) is type(value) and registration[key] == value, "Invalid finite source literal: " + key)
    require(registration["allowedFiles"] == list(FILES) and registration["requiredTestInputs"] == list(TEST_INPUTS), "Finite scope must not widen")
    proposal_commit = evidence.commit(repo, registration["proposalCommit"])
    proposal_base = evidence.commit(repo, registration["proposalBase"])
    witness = evidence.commit(repo, registration["witnessHead"])
    require(evidence.ancestor(repo, proposal_base, proposal_commit) and evidence.ancestor(repo, proposal_commit, base), "Proposal is not accepted in target ancestry")
    require(evidence.ancestor(repo, witness, head), "Published tested witness must be an ancestor of current source head")
    proposal_path = evidence.path_name(registration["proposalPath"])
    require(proposal_path == "threshold/docs/source-requalification/pr-184/proposal.json", "Unexpected proposal path")
    proposal_bytes = regular_blob(repo, base, proposal_path)
    require(proposal_bytes == regular_blob(repo, proposal_commit, proposal_path), "Accepted proposal bytes changed")
    require(hashlib.sha256(proposal_bytes).hexdigest() == registration["proposalSha256"], "Proposal digest mismatch")
    proposal = evidence.load_json(proposal_bytes)
    require(proposal["status"] == "PROPOSAL_ONLY_NOT_ADMISSION" and proposal["schemaVersion"] == "threshold.finite_source_requalification.proposal.v1", "Invalid witness proposal")
    require(proposal["proposalBase"] == proposal_base and proposal["publishedWitness"]["head"] == witness, "Proposal base/witness mismatch")
    require(proposal["originalHead"] == "a867b4933bfa24fa5cdb02bea328a382ce570298" and proposal["historicalAdmission"] == LITERALS["historicalAdmission"], "Historical HOLD must remain unchanged")
    require([record["path"] for record in proposal["files"]] == list(FILES), "Proposal file scope mismatch")
    for record in proposal["files"]:
        path = record["path"]
        verify_file(repo, proposal_base, path, record["before"])
        verify_file(repo, base, path, record["before"])
        verify_file(repo, witness, path, record["after"])
        verify_file(repo, head, path, record["after"])
    records = proposal["testInputObjects"]
    require([record["path"] for record in records] == list(TEST_INPUTS), "Complete Maven test-input set required")
    for record in records:
        path = record["path"]
        require(object_at(repo, proposal_base, path) == record["proposalBaseObject"] == object_at(repo, base, path), "Actual base test-input tree drift: " + path)
        require(object_at(repo, witness, path) == record["testedWitnessObject"] == object_at(repo, head, path), "Source test-input tree differs from tested witness: " + path)
    prefix = proposal_path.rsplit("/", 1)[0] + "/"
    patch_record = proposal["productPatch"]
    require(patch_record["path"] == "product-delta.diff" and patch_record["base"] == proposal_base and patch_record["head"] == witness, "Patch scope mismatch")
    require(patch_record["limitedToExactPaths"] == list(FILES), "Patch path scope mismatch")
    patch = regular_blob(repo, base, prefix + patch_record["path"])
    require(len(patch) == patch_record["bytes"] and hashlib.sha256(patch).hexdigest() == patch_record["sha256"], "Patch artifact tampered")
    require(patch == evidence.diff_bytes(repo, proposal_base, witness, FILES) == evidence.diff_bytes(repo, base, head, FILES), "Complete canonical source patch mismatch")
    validation = proposal["observedValidation"]
    require(validation["sourceHead"] == witness and validation["status"] == "ACTUAL_LOCAL_OBSERVATION_NOT_HISTORICAL_ADMISSION", "Test witness binding mismatch")
    require(validation["freshCurrentSourceCiRequired"] is True and validation["result"] == "BUILD SUCCESS", "Current CI must remain required")
    require(tuple(validation[key] for key in ("testsRun", "failures", "errors", "skipped")) == (126, 0, 0, 0), "Unexpected witnessed test summary")
    require(validation["logPath"] == "maven-test.log", "Unexpected test log path")
    log = regular_blob(repo, base, prefix + validation["logPath"])
    require(len(log) == validation["logBytes"] and hashlib.sha256(log).hexdigest() == validation["logSha256"], "Test log artifact tampered")
    require(re.search(rb"Tests run: 126, Failures: 0, Errors: 0, Skipped: 0", log) is not None and b"BUILD SUCCESS" in log, "Witnessed test output missing")
    # A candidate record is intentionally not a statement about current external checks.
    return {"status": "verified_finite_current_source_candidate", "qualificationId": QUALIFICATION_ID,
            "pullRequest": 184, "actualTargetBase": base, "currentSourceHead": head, "testedWitness": witness,
            "freshCiRequired": True, "independentExactHeadReviewRequired": True,
            "historicalAdmission": LITERALS["historicalAdmission"], "historicalValidationReasserted": False,
            "learningEligible": False, "runtimeAuthority": "NONE", "executionAuthorized": False}


def validate_event(repo, base_ref, event, checkout_ref="HEAD"):
    require(type(event) is dict, "PR event must be an object")
    pr = event.get("pull_request")
    if pr is None or event.get("number") != 184:
        return None
    require(type(event["number"]) is int and type(pr) is dict and pr.get("number") == 184, "Exact PR184 event identity required")
    own_repo = LITERALS["repository"]
    require(event["repository"]["full_name"] == own_repo and pr["head"]["repo"]["full_name"] == own_repo and
            pr["base"]["repo"]["full_name"] == own_repo and pr["base"]["ref"] == "main", "Owned repository/main binding required")
    base = evidence.commit(repo, base_ref)
    require(pr["base"]["sha"] == base, "Observed PR base differs from actual fetched target")
    source = evidence.commit(repo, pr["head"]["sha"])
    require(source == pr["head"]["sha"], "Exact canonical event source SHA required")
    checkout = evidence.commit(repo, checkout_ref)
    require(evidence.commit(repo, "HEAD") == checkout, "Checkout identity mismatch")
    if checkout != source:
        parents = evidence.git(repo, "rev-list", "--parents", "-n", "1", checkout).decode().split()[1:]
        require(len(parents) == 2 and set(parents) == {base, source}, "Checkout must be the source or its genuine current target merge")
    source_tree = evidence.git(repo, "rev-parse", source + "^{tree}")
    require(source_tree == evidence.git(repo, "rev-parse", checkout + "^{tree}"), "Checkout tree differs from exact event source tree")
    common = ("--no-ext-diff", "--no-textconv", "--no-relative", "--ignore-submodules=none", "--name-only", "-z")
    require(not evidence.git(repo, "diff", *common, "HEAD") and
            not evidence.git(repo, "diff", "--cached", *common, "HEAD"), "Tracked checkout/index must be clean")
    result = validate(repo, base, source, 184)
    if result is not None:
        result.update(checkoutHead=checkout, checkoutTreeEqualsCurrentSource=True, observedRepository=own_repo)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--event", type=Path, required=True)
    parser.add_argument("--checkout", default="HEAD")
    args = parser.parse_args()
    try:
        result = validate_event(args.repository, args.base, evidence.load_json(args.event.read_bytes()), args.checkout)
        if result is None:
            return 3
        print(json.dumps(result, sort_keys=True))
        return 0
    except (ValueError, KeyError, TypeError, OSError) as exc:
        print("Invalid finite source candidate: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
