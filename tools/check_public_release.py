"""Block public release packaging until an exact-content review is recorded.

This checks review records, not legal conclusions. Never fabricate approvals.
"""
import hashlib
import json
import os
from pathlib import Path
import sys

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
    approval = json.loads((root / "release-review/approval.json").read_text(encoding="utf-8"))
    if (approval.get("status") != "approved" or
            not str(approval.get("reviewer", "")).strip() or
            not str(approval.get("reviewedAt", "")).strip() or
            approval.get("sourceDigest") != current or
            approval.get("copyrightAndLicenseReviewComplete") is not True or
            approval.get("correspondingSourceDeliveryVerified") is not True or
            approval.get("assetRightsVerified") is not True):
        raise ValueError("Exact source, asset and license review is missing or stale")
    actual = {x["path"]: x["sha256"] for x in inventory(root)["nativeArtifacts"]}
    reviewed = {x["path"]: x["sha256"] for x in approval.get("nativeArtifacts", [])
                if x.get("licenseAndSourceReview") == "approved"}
    if actual != reviewed:
        raise ValueError("Native binary review is incomplete or stale")
    return current


if __name__ == "__main__":
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    try:
        print("Release review matches source " + check(root))
    except (ValueError, KeyError, OSError, TypeError) as error:
        sys.exit("Public release packaging blocked: " + str(error))
