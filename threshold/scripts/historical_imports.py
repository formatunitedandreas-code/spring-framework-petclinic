"""Capture and verify inert historical imports; validation never authorizes effects."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

PREFIX = "threshold/runs/historical-imports/"
SCHEMA = "threshold.historical_import.v1"
ARCHIVE_ATTRIBUTES = b"* -text\noriginal.diff -diff\nblobs/*.bin -diff\n"
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
LITERALS = {
    "schemaVersion": SCHEMA,
    "disposition": "historical_only",
    "historicalValidationReasserted": False,
    "runtimeAuthority": "NONE",
    "executionAuthorized": False,
    "authorityCreated": False,
    "qualificationGranted": False,
}
MANIFEST_KEYS = set(LITERALS) | {
    "pullRequest", "originalHead", "originalTargetBase", "originalMergeBase",
    "originalDiff", "changes",
}


class InvalidImport(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidImport(message)


def git(repo: Path, *args: str, data: bytes | None = None, env=None) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], input=data, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False, env=env,
    )
    if result.returncode:
        raise InvalidImport("Git operation failed: " + " ".join(args[:2]))
    return result.stdout


def commit(repo, ref):
    value = git(repo, "rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()
    require(HEX40.fullmatch(value), "Expected a canonical commit")
    return value


def ancestor(repo, older, newer):
    return subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", older, newer],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    ).returncode == 0


def path_name(value):
    require(type(value) is str and bool(value), "Path must be a nonempty string")
    require("\\" not in value and ":" not in value, "Noncanonical path")
    require(not any(ord(c) < 32 for c in value), "Control character in path")
    parts = PurePosixPath(value).parts
    require(not value.startswith("/") and all(p not in ("", ".", "..") for p in parts), "Escaping path")
    require(str(PurePosixPath(value)) == value, "Noncanonical path spelling")
    return value


def exact_keys(value, keys, label):
    require(type(value) is dict and set(value) == set(keys), "Unexpected " + label + " fields")


def load_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise InvalidImport("Invalid UTF-8 JSON") from exc


def tree(repo, revision, prefix=None):
    args = ["ls-tree", "-r", "-z", revision]
    if prefix is not None:
        args += ["--", prefix]
    result = {}
    for item in git(repo, *args).split(b"\0"):
        if not item:
            continue
        metadata, raw_path = item.split(b"\t", 1)
        mode, kind, oid = metadata.decode("ascii").split(" ")
        name = raw_path.decode("utf-8", errors="strict")
        path_name(name)
        result[name] = (mode, kind, oid)
    return result


def changed_paths(repo, base, head):
    return sorted([
        path_name(x.decode("utf-8", errors="strict"))
        for x in git(repo, "diff", "--no-ext-diff", "--no-textconv", "--name-only",
                     "--no-renames", "--no-relative", "--ignore-submodules=none",
                     "-O", os.devnull, "-z", base, head).split(b"\0") if x
    ])


def source_changes(repo, base, head):
    before = tree(repo, base)
    after = tree(repo, head)
    return [(p, before.get(p), after.get(p)) for p in changed_paths(repo, base, head)]


def diff_bytes(repo, base, head, paths=None):
    # The archive is compared on other hosts: pin presentation rather than
    # inheriting each operator's context, prefixes, indicators or file ordering.
    return git(repo, "-c", "core.quotePath=true", "-c", "diff.noprefix=false",
               "-c", "diff.mnemonicPrefix=false", "-c", "diff.suppressBlankEmpty=false",
               "diff", "--binary", "--full-index", "--no-ext-diff",
               "--no-textconv", "--no-renames", "--no-relative", "--ignore-submodules=none",
               "--src-prefix=a/", "--dst-prefix=b/", "--no-color", "--diff-algorithm=myers",
               "--no-indent-heuristic", "--unified=3", "--inter-hunk-context=0", "--line-prefix=",
               "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= ",
               "-O", os.devnull, base, head, *(["--", *paths] if paths is not None else []),
               env=dict(os.environ, GIT_DIFF_OPTS="--unified=3"))


def blob(repo, oid):
    require(HEX40.fullmatch(oid), "Invalid blob object name")
    return git(repo, "cat-file", "blob", oid)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def binding(repo, original, original_target, declared_base=None):
    original = commit(repo, original)
    original_target = commit(repo, original_target)
    require(not ancestor(repo, original, original_target), "Original head was already included in original target")
    bases = git(repo, "merge-base", "--all", original, original_target).decode().splitlines()
    require(len(bases) == 1 and HEX40.fullmatch(bases[0]), "Ambiguous original merge-base")
    if declared_base is not None:
        require(declared_base == bases[0], "Original merge-base mismatch")
    return original, original_target, bases[0]


def capture(repo: Path, original, original_target, number):
    repo = Path(git(repo, "rev-parse", "--show-toplevel").decode().strip())
    require(type(number) is int and number > 0, "Invalid pull request number")
    original, original_target, base = binding(repo, original, original_target)
    changes = source_changes(repo, base, original)
    require(changes, "Original diff is empty")
    directory = PREFIX + f"pr-{number}"
    output = repo / directory
    require(not output.exists(), "Historical import directory already exists")
    # Capture writes only beneath the real repository, never through symlinks.
    for parent in [repo / "threshold", repo / "threshold/runs", repo / "threshold/runs/historical-imports"]:
        require(not parent.is_symlink(), "Historical import parent is a symlink")
        require(parent.resolve().is_relative_to(repo.resolve()), "Historical import parent escapes repository")
    require(output.resolve().is_relative_to(repo.resolve()) and not output.is_symlink(), "Historical import output escapes repository")
    output.mkdir(parents=True)
    (output / ".gitattributes").write_bytes(ARCHIVE_ATTRIBUTES)
    (output / "blobs").mkdir()
    records = []
    for index, (name, before, after) in enumerate(changes):
        record = {"path": name, "before": None, "after": None}
        for side, value in (("before", before), ("after", after)):
            if value is None:
                continue
            mode, kind, oid = value
            require(kind == "blob" and mode in ("100644", "100755", "120000"), "Unsupported original object")
            raw = blob(repo, oid)
            archive = f"blobs/{index:06d}-{side}.bin"
            (output / archive).write_bytes(raw)
            record[side] = {"mode": mode, "blob": oid, "archive": archive, "sha256": digest(raw)}
        records.append(record)
    original_diff = diff_bytes(repo, base, original)
    (output / "original.diff").write_bytes(original_diff)
    manifest = dict(LITERALS, pullRequest=number, originalHead=original,
                    originalTargetBase=original_target, originalMergeBase=base,
                    originalDiff={"path": "original.diff", "sha256": digest(original_diff)},
                    changes=records)
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                                         encoding="utf-8", newline="\n")
    return directory


def validate(repo: Path, base_ref, head_ref):
    base = commit(repo, base_ref)
    head = commit(repo, head_ref)
    final_paths = changed_paths(repo, base, head)
    reserved = [p for p in final_paths if p.startswith(PREFIX)]
    if not reserved:
        return None
    require(commit(repo, "HEAD") == head, "Validation must inspect checkout HEAD")
    require(not git(repo, "status", "--porcelain", "--untracked-files=no"), "Tracked checkout changes prevent historical import validation")
    require(final_paths and len(reserved) == len(final_paths), "Historical import also changes active/product/policy paths")
    directories = set()
    for name in reserved:
        match = re.fullmatch(re.escape(PREFIX) + r"(pr-([1-9][0-9]*))/(.+)", name)
        require(match is not None, "Invalid historical import directory")
        directories.add((match[1], int(match[2])))
    require(len(directories) == 1, "Only one historical import is allowed per PR")
    folder, number = next(iter(directories))
    directory = PREFIX + folder
    require(ancestor(repo, base, head), "Actual target base is not incorporated")
    require(not tree(repo, base, directory), "Existing historical imports are immutable")
    archived = tree(repo, head, directory)
    require(set(archived) == set(final_paths), "Archive inventory does not match final delta")
    for mode, kind, _oid in archived.values():
        require(mode == "100644" and kind == "blob", "Archive objects must be non-executable regular files")
    manifest_path = directory + "/manifest.json"
    require(manifest_path in archived, "Missing manifest")
    manifest = load_json(blob(repo, archived[manifest_path][2]))
    exact_keys(manifest, MANIFEST_KEYS, "manifest")
    for key, value in LITERALS.items():
        require(type(manifest[key]) is type(value) and manifest[key] == value, "Forbidden historical claim: " + key)
    require(type(manifest["pullRequest"]) is int and manifest["pullRequest"] == number, "Pull request/directory mismatch")
    for key in ("originalHead", "originalTargetBase", "originalMergeBase"):
        require(type(manifest[key]) is str and HEX40.fullmatch(manifest[key]), "Invalid original commit binding")
    original, original_target, original_base = binding(
        repo, manifest["originalHead"], manifest["originalTargetBase"], manifest["originalMergeBase"])
    require(ancestor(repo, original, head), "Original head is not in import ancestry")
    require(ancestor(repo, original_target, base), "Original target is not in actual target ancestry")
    changes = source_changes(repo, original_base, original)
    require(changes and type(manifest["changes"]) is list and len(manifest["changes"]) == len(changes),
            "Original change inventory is incomplete")
    exact_keys(manifest["originalDiff"], ("path", "sha256"), "original diff")
    require(manifest["originalDiff"]["path"] == "original.diff", "Invalid original diff path")
    attributes_path = directory + "/.gitattributes"
    require(attributes_path in archived and blob(repo, archived[attributes_path][2]) == ARCHIVE_ATTRIBUTES,
            "Archive must preserve bytes without custom attributes or filters")
    expected_files = {manifest_path, directory + "/original.diff", attributes_path}
    actual_diff = diff_bytes(repo, original_base, original)
    diff_path = directory + "/original.diff"
    require(diff_path in archived and blob(repo, archived[diff_path][2]) == actual_diff, "Full original diff mismatch")
    require(manifest["originalDiff"]["sha256"] == digest(actual_diff), "Original diff digest mismatch")
    for index, ((name, before, after), record) in enumerate(zip(changes, manifest["changes"])):
        exact_keys(record, ("path", "before", "after"), "change")
        require(path_name(record["path"]) == name, "Original path mismatch")
        for side, value in (("before", before), ("after", after)):
            entry = record[side]
            if value is None:
                require(entry is None, "Addition/deletion must be explicit")
                continue
            exact_keys(entry, ("mode", "blob", "archive", "sha256"), "blob")
            mode, kind, oid = value
            require(kind == "blob" and mode in ("100644", "100755", "120000"), "Unsupported original object")
            expected_path = f"blobs/{index:06d}-{side}.bin"
            require(path_name(entry["archive"]) == expected_path, "Invalid archive blob path")
            require(entry["mode"] == mode and entry["blob"] == oid, "Original blob identity/mode mismatch")
            full_path = directory + "/" + expected_path
            require(full_path in archived, "Original blob omitted")
            raw = blob(repo, oid)
            require(blob(repo, archived[full_path][2]) == raw, "Original blob bytes mismatch")
            require(entry["sha256"] == digest(raw), "Original blob digest mismatch")
            expected_files.add(full_path)
    require(set(archived) == expected_files, "Unexpected or omitted archive objects")
    return {
        "status": "verified_inert_historical_import", "pullRequest": number,
        "actualTargetBase": base, "head": head, "originalHead": original,
        "originalMergeBase": original_base, "preservedChangeCount": len(changes),
        "activeTreeChanged": False, "historicalValidationReasserted": False,
        "runtimeAuthority": "NONE", "executionAuthorized": False,
    }


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "capture"):
        command_parser = sub.add_parser(name)
        command_parser.add_argument("--repository", type=Path, required=True)
        if name == "validate":
            command_parser.add_argument("--base", required=True)
            command_parser.add_argument("--head", default="HEAD")
        else:
            command_parser.add_argument("--original-head", required=True)
            command_parser.add_argument("--original-target-base", required=True)
            command_parser.add_argument("--pull-request", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "capture":
            print(json.dumps({"directory": capture(args.repository, args.original_head,
                                                   args.original_target_base, args.pull_request)}))
            return 0
        result = validate(args.repository, args.base, args.head)
        if result is None:
            print(json.dumps({"status": "not_applicable"}))
            return 3
        print(json.dumps(result, sort_keys=True))
        return 0
    except (InvalidImport, OSError, UnicodeError) as exc:
        print(json.dumps({"status": "invalid_historical_import", "error": str(exc)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
