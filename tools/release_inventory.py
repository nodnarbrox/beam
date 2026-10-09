"""Inventory release-native artifacts; report unresolved review, not legal approval."""
import argparse
import hashlib
import json
import os
from pathlib import Path

SKIP = {".git", ".dart_tool", ".gradle", ".cxx", "build", "__pycache__"}
NATIVE = {".so", ".aar", ".dll", ".exe", ".a", ".dylib"}
PRIVATE = {"key.properties", "local.properties", ".env"}


def inventory(root):
    artifacts = []
    private = []
    for base, dirs, names in os.walk(root, followlinks=False):
        dirs[:] = [d for d in dirs if d not in SKIP]
        for name in sorted(names):
            p = Path(base) / name
            rel = p.relative_to(root).as_posix()
            if name in PRIVATE or p.suffix in {".jks", ".keystore"}:
                private.append(rel)
            if p.suffix.lower() in NATIVE:
                artifacts.append({"path": rel, "bytes": p.stat().st_size,
                                  "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
                                  "licenseAndSourceReview": "pending"})
    return {"releaseStatus": "NOT_READY", "legalApproval": False,
            "nativeArtifacts": artifacts, "privateFilesExcludedFromRelease": private,
            "scope": "Native artifacts and private filenames only; not a full copyright or secret audit."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = json.dumps(inventory(args.project.resolve()), indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report + "\n", encoding="utf-8")
    else:
        print(report)
