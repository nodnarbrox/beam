# Beam desktop builds

Use Flutter 3.44.8 (Windows: 3.44.0) and the checked-in pubspec.lock. Run `flutter pub get`
before each platform build. Desktop torrent bridges compile the repository's
patched C++ source; downloading an upstream unpatched binary is disabled by
default. Keep native binaries, SDK paths and signing material out of Git.

## Windows x64

Install Visual Studio 2022 C++ desktop build tools and vcpkg's
`libtorrent:x64-windows` package. Set `VCPKG_ROOT` to that vcpkg checkout,
and use an isolated Flutter 3.44.0 SDK. Run `flutter precache --windows`, then
`windows/tool/install-patched-engine.ps1`. The installer verifies the pinned
DirectComposition engine archive hash and matching SDK engine revision. This
engine is required for the Flutter controls to composite over the mpv video.
Do not substitute a stock engine or bypass the version check.

Run `python tools/map_generated_plugin_uri.py`, then
`flutter build windows --release --no-pub --split-debug-info=PATH/TO/SYMBOLS`.
Distribute the entire
`build/windows/x64/runner/Release` directory, including DLLs and data, rather
than the executable alone. Launch `Beam.exe` from that directory.
Include the bridge's transitive DLL dependencies from vcpkg's release `bin`
directory and the corresponding Microsoft Visual C++ runtime DLLs; check PE
imports and load the packaged bridge before distributing. Keep PDB files and
split debug symbols outside the public archive.

## Linux x64

The `Beam Linux release build` GitHub workflow installs Ubuntu 24.04 native
development packages, builds the public source and checks shared-library loading
and startup under Xvfb. Its artifact contains the complete portable bundle.
Extract it and run `./plezy` (the compatibility executable name). GTK, libmpv,
libtorrent-rasterbar and their runtime dependencies must be installed; this
archive does not claim to be a universal static Linux package.

## macOS Apple silicon

On a Mac with Xcode and CocoaPods, install Homebrew `cmake` and
`libtorrent-rasterbar`, then run:

```sh
bash packages/libtorrent_flutter/build_macos.sh
python3 tools/map_generated_plugin_uri.py
flutter build macos --release --no-pub --split-debug-info=/private/symbols/directory
```

The native bridge and OpenSSL libraries are supplied through the local CocoaPod.
Before packaging, check all Mach-O dependencies, embed any required dylibs in
`Beam.app/Contents/Frameworks`, and sign the completed app. A local ad-hoc
signature is not an Apple Developer ID signature or notarization. Label an
ad-hoc build accordingly. The source project's deployment baseline is macOS 14.

The current Homebrew dependency build requires macOS 26 or newer. Package it with
`tools/package_macos.py --app PATH/Beam.app --entitlements macos/Runner/Release.entitlements --audit audit.json`;
the tool bundles dependencies, sets that minimum version, checks arm64 libraries
and verifies the ad-hoc signature. It retains only arm64 code and removes debug
and Swift module build metadata. Keep split debug symbols outside the app.
The audit is a local build record, not app data.

The Android native-source companion is documented separately in NATIVE_BUILD.md.
Desktop native dependencies retain their upstream licenses and source locations:
vcpkg libtorrent/OpenSSL/Boost, Ubuntu libtorrent/libmpv, and Homebrew
libtorrent/OpenSSL/Boost plus the pinned MPVKit package used by Xcode.
