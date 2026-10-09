# Android native source and build record

The Android beta targets `armeabi-v7a` (the tested 32-bit Onn). Do not advertise
another ABI without building and testing all its native libraries. Signing keys,
local SDK paths, credentials and device backups are excluded from source releases.

The companion `beam-native-source.zip` contains upstream source archives, exact
submodule snapshots, source hashes and rclone's vendored dependencies. It preserves
upstream licenses. LibretroDroid's sample emulator binaries are excluded; Beam
does not bundle emulator cores, firmware or games.

## Patched torrent bridge

Versions: libtorrent 2.0.11 (revision
`9d7443f467147d1784fb7516d2a882db1abb5a8b`), Boost 1.84.0 and OpenSSL 3.2.1
(`a7e992847de83aa36be0c399c89db3fb827b0be2`). The dependency libraries were
built for Android API 24 with NDK 26.3.11579264; the release's patched bridge
was freshly compiled with NDK 29.0.14206865. Static libraries retain their
upstream source and licenses in the companion archive.

Extract dependency sources into `dependencies/libtorrent-src`,
`dependencies/boost_1_84_0` and `dependencies/openssl-src`. Place the archived
libtorrent submodules at the paths declared by its `.gitmodules`.

In a Unix shell with the NDK compiler tools on PATH, build OpenSSL:

```sh
cd dependencies/openssl-src
export ANDROID_NDK_ROOT=/path/to/ndk
export PATH="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH"
perl Configure android-arm no-shared no-asm no-tests -D__ANDROID_API__=24 \
  -fPIC --prefix="$(pwd)/../openssl-armeabi-v7a"
make -j4
make install_sw
```

Build libtorrent as a position-independent static library with CMake:

```sh
cmake -S dependencies/libtorrent-src -B dependencies/libtorrent-build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=armeabi-v7a -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF -Ddeprecated-functions=OFF \
  -DBOOST_ROOT="$(pwd)/dependencies/boost_1_84_0" \
  -DOPENSSL_ROOT_DIR="$(pwd)/dependencies/openssl-armeabi-v7a" \
  -DOPENSSL_USE_STATIC_LIBS=ON
cmake --build dependencies/libtorrent-build --parallel 4
python tools/build_torrent_bridge.py --ndk "$ANDROID_NDK_ROOT" \
  --dependencies dependencies \
  --libtorrent-static dependencies/libtorrent-build/libtorrent-rasterbar.a \
  --output packages/libtorrent_flutter/prebuilt/android/armeabi-v7a/liblibtorrent_flutter.so
```

Use the host-appropriate NDK toolchain directory on Windows. Strip the bridge
with the NDK's `llvm-strip --strip-unneeded` before packaging. The public bridge
build script is the exact compiler/link invocation used for this release.

## Other native libraries

- **rclone 1.68.2**, MIT: freshly built from the companion's vendored source
  with Go 1.26.1, `GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0`, then
  `go build -mod=vendor -trimpath -ldflags '-s -w -X github.com/rclone/rclone/fs.Version=v1.68.2' -o librclone.so .`.
- **LibretroDroid 0.14.0**, GPLv3: the input AAR is byte-identical to
  `https://jitpack.io/com/github/Swordfish90/LibretroDroid/0.14.0/LibretroDroid-0.14.0.aar`.
  Its source, build scripts and exact oboe/libretro-common submodules accompany it.
- **libmpv-android v1.0.7**: the hash-pinned official AAR comes from
  `edde746/libmpv-android`. Its source archive contains the build driver and patches;
  all dependencies named by `buildscripts/include/depinfo.sh` accompany it.
  Run its documented Linux build workflow, placing submodules at their declared paths.
- **libdovi 2.3.1**, MIT: source and the pinned `edde746/libdovi-builds`
  workflow accompany the hash-pinned static libraries downloaded by Gradle.
- Beam builds its Media3 FFmpeg adapter and Dolby Vision bridge from the sources
  in `android/app/src/main/cpp`. FFmpeg 8.0.1 headers and runtime come from
  the same libmpv build. The old unused standalone FFmpeg 3 executable is excluded.
- Flutter, Android Maven dependencies and the NDK runtime retain their upstream
  notices; Flutter's generated NOTICES asset covers resolved Dart packages.

Native and rclone notices are bundled in the app assets. Automated packaging
checks verify exact input hashes, corresponding-source archive and notices.
This build record does not claim human or legal review.
