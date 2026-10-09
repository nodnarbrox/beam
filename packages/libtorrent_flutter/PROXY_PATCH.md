# libtorrent_flutter — SOCKS5/HTTP proxy fork (MediaBeam)

Adds proxy support so torrent swarm traffic routes through the user's SOCKS5/HTTP
proxy (settings_pack). Append-only struct edits — calloc zero-init means
proxy_type=0=none=today's behavior, so unset = direct (no regression).

## Layer 1 — C struct  `src/torrent_bridge.h` (end of `lt_bt_config`)
```c
    int32_t responsive_mode;
    /* SOCKS5/HTTP proxy — 0=none,1=socks4,2=socks5,4=socks5_pw,3=http,5=http_pw */
    int32_t proxy_type;              /* default 0 = direct */
    char    proxy_host[256];
    int32_t proxy_port;
    char    proxy_user[128];
    char    proxy_pass[128];
} lt_bt_config;
```

## Layer 2 — C++ apply  `src/torrent_bridge.cpp`
In `lt_configure_session`, after the encryption block (before user_agent set):
```cpp
    if (cfg.proxy_type != 0) {
        sp.set_int(lt::settings_pack::proxy_type, cfg.proxy_type);
        sp.set_str(lt::settings_pack::proxy_hostname, cfg.proxy_host);
        sp.set_int(lt::settings_pack::proxy_port, cfg.proxy_port);
        sp.set_str(lt::settings_pack::proxy_username, cfg.proxy_user);
        sp.set_str(lt::settings_pack::proxy_password, cfg.proxy_pass);
        sp.set_bool(lt::settings_pack::proxy_peer_connections, true);
        sp.set_bool(lt::settings_pack::proxy_hostnames, true);  // DNS via proxy
        sp.set_bool(lt::settings_pack::anonymous_mode, true);
    } else {
        sp.set_int(lt::settings_pack::proxy_type, lt::settings_pack::none);
        sp.set_bool(lt::settings_pack::anonymous_mode, false);
    }
```
Also zero the new fields in `lt_get_default_config` and
`SessionWrapper::init_default_config()` (proxy_type=0, host/user/pass[0]=0, port=0).

## Layer 3 — Dart FFI  `lib/src/ffi_bindings.dart` (`LtBtConfig`, after responsiveMode)
```dart
  @Int32()    external int proxyType;
  @Array(256) external Array<Char> proxyHost;
  @Int32()    external int proxyPort;
  @Array(128) external Array<Char> proxyUser;
  @Array(128) external Array<Char> proxyPass;
```

## Layer 4 — Dart BtConfig  `lib/src/models.dart` + base
- BtConfig: add `int proxyType=0, String proxyHost='', int proxyPort=0,
  String proxyUser='', String proxyPass=''` to fields, const ctor, copyWith.
- `libtorrent_flutter_base.dart` configureSession(): write ints directly, use a
  `_writeCharArray(Array<Char>, String, maxLen)` helper (needs `import
  'dart:convert';`) for host/user/pass. getDefaultConfig(): read back with the
  existing `readCharArray`.

## BUILD (armeabi-v7a, on Linux) — versions from upstream CI
libtorrent v2.0.11, Boost 1.84.0 (headers), OpenSSL 3.2.1 static (no-asm),
NDK r26d, API 24, -std=c++17. Output → `prebuilt/android/armeabi-v7a/
liblibtorrent_flutter.so`; build with gradle `-PlibtorrentFlutterSkipDownload=true`.
Full command sequence: see MediaBeam memory `mediabeam-app` / session notes.
Verify: `llvm-nm -D liblibtorrent_flutter.so | grep lt_configure_session`.
