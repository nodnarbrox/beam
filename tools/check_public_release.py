"""Verify exact native inputs, bundled notices and corresponding-source delivery.

This is an automated packaging check, not a human or legal certification.
"""
import hashlib
import json
import os
from pathlib import Path
import sys
import zipfile

from release_inventory import inventory, SKIP, PRIVATE


def source_digest(root):
    rows = []
    for base, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d not in SKIP]
        for name in names:
            path = Path(base) / name
            relative = path.relative_to(root).as_posix()
            if (name in PRIVATE or name == ".flutter-plugins-dependencies" or
                    path.suffix in {".jks", ".keystore"} or
                    relative.startswith("release-review/")):
                continue
            if path.is_symlink():
                raise ValueError("Release source contains a symlink")
            rows.append(relative + "\0" + hashlib.sha256(path.read_bytes()).hexdigest())
    return hashlib.sha256("\n".join(sorted(rows)).encode()).hexdigest()


def check(root):
    current = source_digest(root)
    approval = json.loads((root / "release-review/packaging.json").read_text(encoding="utf-8"))
    if (approval.get("schemaVersion") != 2 or
            approval.get("sourceDigest") != current):
        raise ValueError("Exact source packaging record is missing or stale")
    for field in ("nativeSourceBundle", "licenseNotices"):
        entry = approval[field]
        path = (root / entry["path"]).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise ValueError("Missing or escaping " + field)
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Changed " + field)
    with zipfile.ZipFile(root / approval["nativeSourceBundle"]["path"]) as bundle:
        source_files = set(bundle.namelist())
    actual = {x["path"]: x["sha256"] for x in inventory(root)["nativeArtifacts"]}
    reviewed = {x["path"]: x["sha256"] for x in approval.get("nativeArtifacts", [])
                if x.get("sourceComponent") in source_files and x.get("license") and x.get("provenance")}
    if actual != reviewed:
        raise ValueError("Native binary review is incomplete or stale")
    return current


if __name__ == "__main__":
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    try:
        print("Release packaging verified for source " + check(root))
    except (ValueError, KeyError, OSError, TypeError) as error:
        sys.exit("Public release packaging blocked: " + str(error))
