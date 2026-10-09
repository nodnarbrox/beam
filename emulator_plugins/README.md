# Emulator plugins

This release copy ships without emulator cores. Properly licensed emulator code
is welcome. Plugins are selected at build time and installed with the APK; this
is not a way to distribute code without permission or avoid copyleft obligations.

Each plugin lives in its own folder here and contains `manifest.json`,
`review.json`, the native binaries, license text, an exact corresponding-source
archive and build instructions. Keep all those files available with a release;
an upstream link alone is not the source delivery plan. Android Gradle runs
`python tools/emulator_plugins.py .` before packaging. No plugins is valid.

Example manifest (placeholders must be replaced with actual files and hashes):

```json
{
  "schemaVersion": 1,
  "id": "example_core",
  "license": "GPL-3.0-or-later",
  "upstream": {"url": "https://example.org/project", "revision": "exact-commit"},
  "licenseFile": {"path": "COPYING", "sha256": "actual-sha256"},
  "sourceArchive": {"path": "source.zip", "sha256": "actual-sha256"},
  "buildInstructions": {"path": "BUILD.txt", "sha256": "actual-sha256"},
  "binaries": [
    {"abi": "armeabi-v7a", "path": "native/core.so", "sha256": "actual-sha256"}
  ],
  "assets": []
}
```

The source archive must contain the actual modifications and required build
material for the supplied binary, not just a different upstream snapshot.
Assets have `path`, `sha256`, `license`, and a `licenseFile` object. PPSSPP's
reviewed assets should use paths under `PPSSPP/`; they stage under `ppsspp/PPSSPP/`.
Never include proprietary BIOS/firmware or retail game assets in a plugin.

Only after an actual review, create a review record:

```json
{
  "status": "pending",
  "reviewer": "",
  "reviewedAt": "",
  "manifestSha256": "sha256-of-exact-manifest-file",
  "redistributionVerified": false,
  "correspondingSourceVerified": false,
  "gpl3CompatibilityVerified": false
}
```

The tool refuses pending reviews, missing source/license/build files, hash
changes, escaping paths, wrong ABI, duplicate core IDs and unreviewed cores in
the original Android source folders. A signed-off metadata record is evidence
of a review process, not proof of legality; do not invent a reviewer or approval.
The project's GPLv3 obligations remain. GPL-2.0-only and noncommercial licenses
are not admitted by this integration policy. Exceptions/dual licensing need a
separate documented assessment before changing it.

The loader remains libretro-based. Play! or AnyPS5 require compatible adapters;
this change does not implement their native-player integration or prove gameplay.

Sources: [Play! license](https://github.com/jpd002/Play-/blob/master/License.txt),
[original Kyty](https://github.com/InoriRus/Kyty),
[GNU license compatibility](https://www.gnu.org/licenses/gpl-faq.html#AllCompatibility).
