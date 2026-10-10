# Beam

A free, open-source media center for your Plex and Jellyfin libraries, with a walkable Halloween Blockbusta video store, TV remote navigation and optional streaming services.

**[Download Beam 2.10.1 beta](https://github.com/nodnarbrox/beam/releases/tag/v2.10.1-beam.1)** — available for Android TV / Onn, Windows, Linux and Mac.

![Beam's Halloween Blockbusta store on Onn Android TV, showing pumpkins, haunted props, video racks and remote-control hints](docs/images/halloween-blockbusta-onn.png)

*Actual screenshot from the released Android build on the Onn, using reduced graphics effects.*

## Downloads

| Platform | Download | Requirements and launch |
| --- | --- | --- |
| Android TV / Onn | [32-bit ARM APK](https://github.com/nodnarbrox/beam/releases/download/v2.10.1-beam.1/beam-2.10.1-armeabi-v7a.apk) | Android 7.1 / API 25 or newer, `armeabi-v7a`. Install the APK; this is the tested 32-bit Onn build. |
| Windows | [Windows x64 ZIP](https://github.com/nodnarbrox/beam/releases/download/v2.10.1-beam.1/beam-2.10.1-windows-x64.zip) | Extract the entire folder and run `Beam.exe`. Runtime DLLs are included. Unsigned beta executable. |
| Linux | [Linux x64 archive](https://github.com/nodnarbrox/beam/releases/download/v2.10.1-beam.1/beam-2.10.1-linux-x64.tar.gz) | Ubuntu 24.04 build. Extract and run `./plezy`; GTK, libmpv, libtorrent-rasterbar and their runtime dependencies must be installed. |
| Mac | [Apple silicon ZIP](https://github.com/nodnarbrox/beam/releases/download/v2.10.1-beam.1/beam-2.10.1-macos-arm64.zip) | macOS 26 or newer, Apple silicon. Extract and open `Beam.app`. Built and tested on the MacBook Pro; ad-hoc signed, without Apple notarization. |

[Release notes, source archives and SHA-256 checksums](https://github.com/nodnarbrox/beam/releases/tag/v2.10.1-beam.1) accompany the downloads. See [DESKTOP_BUILD.md](DESKTOP_BUILD.md) for desktop dependencies and build instructions.

## Getting started

1. Install or extract the package for your device.
2. Sign in to your own Plex or Jellyfin server to access your library.
3. Open **Store** for Halloween Blockbusta, or use **Search** to browse. Optional streaming configuration is under **Settings → Beam streaming**.

The separate **Beam Search** navigation tab has been removed. The Android package keeps the existing app ID and update certificate so compatible installs can update while retaining their account data.

## Halloween store and remote controls

The store includes scrolling video racks, pumpkins, haunted props and fixes for focus handoff, turning, Back navigation and repeated OK presses.

| Control | Action in the 3D store |
| --- | --- |
| Hold Up | Walk forward. |
| Left / Right | Turn. |
| OK / Select | Browse a nearby rack. |
| Back / Escape | Leave rack browsing or return focus to navigation. |

## Beta testing and known limits

All **41 focused app tests** and **4 release-packaging tests** passed, and the Flutter analyzer reported no issues. Source and binary packages passed automated privacy checks; public download checksums were verified.

| Platform | Checks completed |
| --- | --- |
| Onn Android TV | Updated install, Halloween rendering, remote key-event navigation, installed native-library hash and an isolated piece-retention regression. |
| Windows | App startup, packaged DLL loading, torrent-file loading and decoding an owned H.264 test clip through the packaged media library. |
| Linux | Native-library loading, dependency resolution and a 20-second headless startup check in GitHub Actions. |
| MacBook Pro | Fresh app startup, native-library and torrent-file loading, bundled dependencies, Apple silicon architecture and signature verification. |

The Onn Halloween scene measured about **11 FPS** with reduced effects. Physical remote hardware has not been tested. The test Plex server was unreachable, so title pickup and Plex playback on the TV remain unverified. Complete desktop playback and control-overlay flows also remain unverified. See the release notes for the full test scope.

## Development

Use Flutter **3.44.8** and Dart 3.12.2; Windows uses **3.44.0** to match its pinned patched video-compositing engine. The store uses flutter_scene 0.16.0. Dependencies requiring forked Git revisions are vendored at their pinned revisions under packages/vendor.

```sh
flutter pub get
flutter analyze --no-pub
python -m unittest discover -s test/release -v
flutter test --no-pub --concurrency=1 test/navigation/navigation_tabs_test.dart test/screens/video_store_remote_test.dart test/services/direct_tv_service_test.dart test/screens/direct_tv_screen_test.dart test/widgets/side_navigation_rail_test.dart test/screens/main_screen_layout_test.dart
```

Android development also requires SDK 36, NDK 29.0.14206865 and CMake 3.31.6. See [NATIVE_BUILD.md](NATIVE_BUILD.md) for the exact native source and build record. Native libtorrent must be rebuilt from this repository's patched source; substituting an unpatched upstream binary changes its ABI and privacy behavior. Native binaries and signing keys are not committed to Git. Emulator cores and firmware are not included. See emulator_plugins/README.md for the optional core build path.

## Configuration

Plex/Jellyfin sign-in, streaming service credentials, optional proxies and TV tuner addresses belong to each user and are entered on their device. There is no default private TV server or Prowlarr key.

Optional Trakt, MyAnimeList, Simkl and YouTube account integrations require the maintainer's own registered application configuration. Error reporting is off by default and has no bundled reporting endpoint. Do not commit environment files, service credentials or signing keys.

## License and attribution

Beam is independently maintained and is not an official Plezy release. It is based on [Plezy](https://github.com/edde746/plezy) and distributed under the included [GPLv3 license](LICENSE). Dependencies retain their own licenses and notices.

This fork is based on the owner's modified checkout at upstream-base commit `3e3bafa`, with the separately developed Halloween store integrated. The public repository contains no prior private history. See [BEAM_CHANGES.md](BEAM_CHANGES.md) for the change scope.
