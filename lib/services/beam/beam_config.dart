import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../credential_vault.dart';

/// Central configuration for the "Beam" media-center module (Prowlarr search,
/// Real-Debrid streaming, qBittorrent fallback, rclone, and the private proxy
/// that hides all of the above).
///
/// Non-secret fields live directly in SharedPreferences. Secrets (Real-Debrid
/// token, proxy password, qBittorrent password) are encrypted through the
/// app's existing [CredentialVault] before persistence, matching how the rest
/// of Plezy handles server tokens.
class BeamConfig {
  BeamConfig._();

  static const _kProwlarrUrl = 'beam_prowlarr_url';
  static const _kProwlarrKey = 'beam_prowlarr_key'; // secret
  static const _kRdToken = 'beam_rd_token'; // secret
  static const _kProxyEnabled = 'beam_proxy_enabled';
  static const _kTorrentPlayEnabled = 'beam_torrent_play_enabled';
  static const _kAllowCam = 'beam_allow_cam_releases';
  static const _kProxyScheme = 'beam_proxy_scheme'; // socks5 | http
  static const _kProxyHost = 'beam_proxy_host';
  static const _kProxyPort = 'beam_proxy_port';
  static const _kProxyUser = 'beam_proxy_user';
  static const _kProxyPass = 'beam_proxy_pass'; // secret
  static const _kQbUrl = 'beam_qb_url';
  static const _kQbUser = 'beam_qb_user';
  static const _kQbPass = 'beam_qb_pass'; // secret
  static const _kRcloneUrl = 'beam_rclone_url';
  static const _kRcloneUser = 'beam_rclone_user';
  static const _kRclonePass = 'beam_rclone_pass'; // secret

  // External Prowlarr is optional and configured by the user.
  static const String defaultProwlarrUrl = '';
  static const String defaultProwlarrKey = '';

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static SharedPreferences get _p {
    final p = _prefs;
    if (p == null) {
      throw StateError('BeamConfig.init() must be awaited before use');
    }
    return p;
  }

  // ---- Prowlarr ----
  static String get prowlarrUrl =>
      _stripSlash(_p.getString(_kProwlarrUrl) ?? defaultProwlarrUrl);
  static Future<void> setProwlarrUrl(String v) =>
      _p.setString(_kProwlarrUrl, _stripSlash(v));

  static Future<String> getProwlarrKey() async =>
      _readSecret(_kProwlarrKey, defaultProwlarrKey);
  static Future<void> setProwlarrKey(String v) =>
      _writeSecret(_kProwlarrKey, v);

  // ---- Real-Debrid ----
  static Future<String> getRdToken() async => _readSecret(_kRdToken, '');
  static Future<void> setRdToken(String v) => _writeSecret(_kRdToken, v);
  static Future<bool> get rdConfigured async =>
      (await getRdToken()).trim().isNotEmpty;

  // ---- Playback sources ----
  /// Whether the on-device instant-torrent fallback may be used.
  ///
  /// This defaults on to preserve Beam's existing behavior. The torrent
  /// service still fails closed unless a device VPN or verified proxy is
  /// active, so this preference never weakens the privacy gate.
  static bool get torrentPlayEnabled =>
      _p.getBool(_kTorrentPlayEnabled) ?? true;
  static Future<void> setTorrentPlayEnabled(bool v) =>
      _p.setBool(_kTorrentPlayEnabled, v);

  /// When on, the app auto-connects its free community VPN (VPN Gate) before a
  /// Beam search/play if no VPN is already up — so indexers/trackers reach
  /// through a non-censoring tunnel without the user toggling anything. Off by
  /// default (it replaces any other VPN, so it must be opt-in).
  static const _kAutoCommunityVpn = 'beam_auto_community_vpn';
  static bool get autoCommunityVpn =>
      _p.getBool(_kAutoCommunityVpn) ?? false;
  static Future<void> setAutoCommunityVpn(bool v) =>
      _p.setBool(_kAutoCommunityVpn, v);

  // ---- Proxy ----
  static bool get proxyEnabled => _p.getBool(_kProxyEnabled) ?? false;
  static Future<void> setProxyEnabled(bool v) => _p.setBool(_kProxyEnabled, v);

  // ---- Release filtering ----
  /// Allow cam / telesync ("junk") releases to be auto-picked.
  ///
  /// ON by default (user request): cam/telesync releases are ALWAYS available
  /// so a title only just in cinemas still plays instead of showing "no
  /// sources". They can never out-rank a real release — the quality profile
  /// scores cams negative, so BluRay/WEB/etc are always tried first and a cam is
  /// only picked when nothing better exists. As soon as a high-quality release
  /// appears it automatically leads.
  static bool get allowCamReleases => _p.getBool(_kAllowCam) ?? true;
  static Future<void> setAllowCamReleases(bool v) => _p.setBool(_kAllowCam, v);

  static String get proxyScheme => _p.getString(_kProxyScheme) ?? 'socks5';
  static Future<void> setProxyScheme(String v) =>
      _p.setString(_kProxyScheme, v);

  static String get proxyHost => _p.getString(_kProxyHost) ?? '';
  static Future<void> setProxyHost(String v) => _p.setString(_kProxyHost, v);

  static int get proxyPort => _p.getInt(_kProxyPort) ?? 1080;
  static Future<void> setProxyPort(int v) => _p.setInt(_kProxyPort, v);

  static String get proxyUser => _p.getString(_kProxyUser) ?? '';
  static Future<void> setProxyUser(String v) => _p.setString(_kProxyUser, v);

  static Future<String> getProxyPass() async => _readSecret(_kProxyPass, '');
  static Future<void> setProxyPass(String v) => _writeSecret(_kProxyPass, v);

  /// The `host:port` a Dart `HttpClient` proxy setting expects, or null when
  /// the proxy is disabled/unconfigured.
  static String? get proxyHostPort {
    if (!proxyEnabled) return null;
    if (proxyHost.trim().isEmpty) return null;
    return '$proxyHost:$proxyPort';
  }

  // ---- qBittorrent (fallback downloader) ----
  static String get qbUrl => _stripSlash(_p.getString(_kQbUrl) ?? '');
  static Future<void> setQbUrl(String v) =>
      _p.setString(_kQbUrl, _stripSlash(v));
  static String get qbUser => _p.getString(_kQbUser) ?? 'admin';
  static Future<void> setQbUser(String v) => _p.setString(_kQbUser, v);
  static Future<String> getQbPass() async => _readSecret(_kQbPass, '');
  static Future<void> setQbPass(String v) => _writeSecret(_kQbPass, v);

  // ---- rclone remote control daemon ----
  static String get rcloneUrl => _stripSlash(_p.getString(_kRcloneUrl) ?? '');
  static Future<void> setRcloneUrl(String v) =>
      _p.setString(_kRcloneUrl, _stripSlash(v));
  static String get rcloneUser => _p.getString(_kRcloneUser) ?? '';
  static Future<void> setRcloneUser(String v) => _p.setString(_kRcloneUser, v);
  static Future<String> getRclonePass() async => _readSecret(_kRclonePass, '');
  static Future<void> setRclonePass(String v) => _writeSecret(_kRclonePass, v);

  // ---- helpers ----
  static String _stripSlash(String v) {
    var s = v.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  static Future<String> _readSecret(String key, String fallback) async {
    final raw = _p.getString(key);
    if (raw == null || raw.isEmpty) return fallback;
    if (CredentialVault.isProtected(raw)) {
      try {
        return await CredentialVault.reveal(raw) ?? fallback;
      } catch (_) {
        return fallback;
      }
    }
    return raw; // legacy plaintext
  }

  static Future<void> _writeSecret(String key, String value) async {
    if (value.isEmpty) {
      await _p.remove(key);
      return;
    }
    final protectedValue = await CredentialVault.protect(value);
    await _p.setString(key, protectedValue);
  }

  /// Diagnostic dump (secrets masked) for the settings screen / logs.
  static Future<Map<String, dynamic>> describe() async {
    return {
      'prowlarrUrl': prowlarrUrl,
      'prowlarrKey': _mask(await getProwlarrKey()),
      'rdToken': _mask(await getRdToken()),
      'torrentPlayEnabled': torrentPlayEnabled,
      'proxyEnabled': proxyEnabled,
      'proxy': proxyHostPort ?? '(off)',
      'proxyScheme': proxyScheme,
      'qbUrl': qbUrl.isEmpty ? '(unset)' : qbUrl,
      'rcloneUrl': rcloneUrl.isEmpty ? '(unset)' : rcloneUrl,
    };
  }

  static String _mask(String v) {
    if (v.isEmpty) return '(unset)';
    if (v.length <= 6) return '••••';
    return '${v.substring(0, 3)}…${v.substring(v.length - 3)}';
  }
}

/// Serializable snapshot used by any isolate/UI that cannot await the async
/// secret reads inline.
class BeamConfigSnapshot {
  BeamConfigSnapshot({
    required this.prowlarrUrl,
    required this.prowlarrKey,
    required this.rdToken,
    required this.proxyHostPort,
    required this.proxyScheme,
    required this.proxyUser,
    required this.proxyPass,
  });

  final String prowlarrUrl;
  final String prowlarrKey;
  final String rdToken;
  final String? proxyHostPort;
  final String proxyScheme;
  final String proxyUser;
  final String proxyPass;

  static Future<BeamConfigSnapshot> capture() async => BeamConfigSnapshot(
    prowlarrUrl: BeamConfig.prowlarrUrl,
    prowlarrKey: await BeamConfig.getProwlarrKey(),
    rdToken: await BeamConfig.getRdToken(),
    proxyHostPort: BeamConfig.proxyHostPort,
    proxyScheme: BeamConfig.proxyScheme,
    proxyUser: BeamConfig.proxyUser,
    proxyPass: await BeamConfig.getProxyPass(),
  );

  String toJson() =>
      jsonEncode({'prowlarrUrl': prowlarrUrl, 'proxy': proxyHostPort});
}
