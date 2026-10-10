# Beam

A media-center app based on [Plezy](https://github.com/edde746/plezy), with Plex and Jellyfin libraries, a Halloween Blockbusta video store, TV remote navigation and optional streaming services.

Beam is independently maintained and is not an official Plezy release. Beta releases include Android **armeabi-v7a** (32-bit Onn), Windows **x64**, Linux **x64**, and macOS **arm64** packages. Builds, application source, Android native source and checksums are available from [GitHub Releases](https://github.com/nodnarbrox/beam/releases). The upstream GPLv3 license and third-party notices remain included. The current Mac build requires macOS 26 or newer and is ad-hoc signed, without Apple notarization. Linux requires its system runtime libraries. See [DESKTOP_BUILD.md](DESKTOP_BUILD.md) for platform requirements.

The separate Beam search tab is removed. Use Search for browsing and Settings → Beam streaming for streaming configuration. The store opens with the newer Halloween layout, scrolling racks and haunted props.

## Development

Use Flutter **3.44.8** and Dart 3.12.2; Windows uses **3.44.0** to match its pinned patched video-compositing engine. The store uses flutter_scene 0.16.0. Dependencies requiring forked Git revisions are vendored at their pinned revisions under packages/vendor.

```sh
flutter pub get
flutter analyze --no-pub
flutter test --no-pub test/navigation/navigation_tabs_test.dart test/screens/video_store_remote_test.dart test/services/direct_tv_service_test.dart test/screens/direct_tv_screen_test.dart
```

Android development also requires SDK 36, NDK 29.0.14206865 and CMake 3.31.6. See [NATIVE_BUILD.md](NATIVE_BUILD.md) for the exact native source and build record. Native libtorrent must be rebuilt from this repository's patched source; substituting an unpatched upstream binary changes its ABI and privacy behavior. Native binaries and signing keys are not committed to Git. Emulator cores and firmware are not included. See emulator_plugins/README.md for the optional core build path.

## Configuration

Plex/Jellyfin sign-in, streaming service credentials, optional proxies and TV tuner addresses belong to each user and are entered on their device. There is no default private TV server or Prowlarr key.

Optional Trakt, MyAnimeList, Simkl and YouTube account integrations require the maintainer's own registered application configuration. Error reporting is off by default and has no bundled reporting endpoint. Do not commit environment files, service credentials or signing keys.

## Status

The source includes fixes for store focus handoff, Back navigation, reversed turns and repeated OK activation. Release notes distinguish automated checks, on-device Android key-event tests and remaining physical-remote/performance limits. See BEAM_CHANGES.md for the change scope.

## License and attribution

Plezy application code and this fork are distributed under the included GPLv3 license. Dependencies retain their own licenses. Plezy upstream: https://github.com/edde746/plezy. This snapshot is based on the owner's modified checkout at upstream-base commit 3e3bafa, with the separately developed Halloween store integrated. The new repository contains no prior private history.
