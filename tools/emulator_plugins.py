"""Stage reviewed libretro plugins for the Android build; never download code.

Metadata checks enforce a release policy, not a legal determination. Reviewers
must establish rights, license compatibility and complete corresponding source.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

LICENSES = {"MIT", "BSD-2-Clause", "BSD-3-Clause", "ISC", "Zlib",
            "Apache-2.0", "GPL-2.0-or-later", "GPL-3.0-only",
            "GPL-3.0-or-later", "LGPL-2.1-or-later", "LGPL-3.0-only",
            "LGPL-3.0-or-later"}
ABIS = {"armeabi-v7a": (1, 40), "arm64-v8a": (2, 183),
        "x86": (1, 3), "x86_64": (2, 62)}
ID = re.compile(r"[a-z][a-z0-9_]{0,63}\Z")


def checked_file(root, item):
    name = item["path"]
    if not isinstance(name, str) or "\\" in name or ":" in name:
        raise ValueError("Invalid plugin path")
    parts = name.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise ValueError("Invalid plugin path")
    path = root.joinpath(*parts)
    cursor = root
    for part in parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise ValueError("Plugin symlinks are not allowed")
    if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError("Missing or escaping plugin file")
    if not path.stat().st_size:
        raise ValueError("Empty plugin file")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if item.get("sha256") != digest:
        raise ValueError("Plugin file hash mismatch: " + name)
    return path


def validate(root):
    if root.is_symlink():
        raise ValueError("Plugin directory cannot be a symlink")
    raw = (root / "manifest.json").read_bytes()
    data = json.loads(raw)
    if data.get("schemaVersion") != 1 or not ID.fullmatch(data.get("id", "")):
        raise ValueError("Invalid plugin manifest")
    review = json.loads((root / "review.json").read_text(encoding="utf-8"))
    if (review.get("status") != "approved" or
            not str(review.get("reviewer", "")).strip() or
            not str(review.get("reviewedAt", "")).strip() or
            review.get("manifestSha256") != hashlib.sha256(raw).hexdigest() or
            review.get("redistributionVerified") is not True or
            review.get("correspondingSourceVerified") is not True or
            review.get("gpl3CompatibilityVerified") is not True):
        raise ValueError("Plugin requires review of this exact manifest")
    if data.get("license") not in LICENSES:
        raise ValueError("License needs separate compatibility review; not allowed by this policy")
    source = data.get("upstream", {})
    if not source.get("url", "").startswith("https://") or not source.get("revision"):
        raise ValueError("Exact upstream source revision is required")
    # A website link alone is insufficient for corresponding-source delivery.
    for field in ("licenseFile", "sourceArchive", "buildInstructions"):
        checked_file(root, data[field])
    binaries = data.get("binaries", [])
    if not binaries:
        raise ValueError("Plugin must supply at least one binary")
    seen = set()
    for item in binaries:
        abi = item.get("abi")
        if abi not in ABIS or abi in seen:
            raise ValueError("Unsupported or duplicate ABI")
        seen.add(abi)
        path = checked_file(root, item)
        header = path.read_bytes()[:20]
        klass, machine = ABIS[abi]
        if (len(header) < 20 or header[:4] != b"\x7fELF" or
                header[4] != klass or header[5] != 1 or
                int.from_bytes(header[16:18], "little") != 3 or
                int.from_bytes(header[18:20], "little") != machine):
            raise ValueError("Binary is not an Android shared ELF for " + abi)
    for asset in data.get("assets", []):
        checked_file(root, asset)
        if asset.get("license") not in LICENSES:
            raise ValueError("Asset license needs separate review")
        checked_file(root, asset["licenseFile"])
    return data


def stage(project):
    project = project.resolve()
    plugins = project / "emulator_plugins"
    target = project / "build/emulator_plugins"
    if target.is_symlink() or (project / "build").is_symlink():
        raise ValueError("Build output cannot be a symlink")
    # Bundled cores bypassing the review path must never enter an APK.
    for base in (project / "android/app/src", project / "android/app/libs"):
        if base.exists() and list(base.rglob("*libretro_android.so")):
            raise ValueError("Unreviewed bundled emulator core found outside plugin staging")
    roots = sorted(p for p in plugins.iterdir() if p.is_dir()) if plugins.exists() else []
    approved = [(root, validate(root)) for root in roots]
    ids = [data["id"] for _, data in approved]
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate plugin ID")
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = Path(tempfile.mkdtemp(prefix="emulator_plugins-", dir=target.parent))
    try:
        for root, data in approved:
            core = data["id"]
            for item in data["binaries"]:
                dest = temp / "jniLibs" / item["abi"] / f"lib{core}_libretro_android.so"
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(checked_file(root, item), dest)
            notice = temp / "assets/emulator_plugins" / core
            notice.mkdir(parents=True)
            (notice / "manifest.json").write_text(json.dumps(data, indent=2), encoding="utf-8")
            shutil.copyfile(checked_file(root, data["licenseFile"]), notice / "LICENSE")
            for n, asset in enumerate(data.get("assets", [])):
                dest = temp / "assets" / core / asset["path"]
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(checked_file(root, asset), dest)
                shutil.copyfile(checked_file(root, asset["licenseFile"]), notice / f"ASSET-LICENSE-{n}")
        # Validation or copying failures leave the previous output intact.
        if target.exists():
            shutil.rmtree(target)
        temp.rename(target)
    finally:
        if temp.exists():
            shutil.rmtree(temp)
    return ids


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps({"stagedPlugins": stage(args.project)}))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(1, "Emulator plugin staging refused: " + str(error) + "\n")
