import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../credential_vault.dart';
import 'beam_config.dart';

/// A single, self-contained proxy/VPN network the user can select. The app
/// ships a small curated list of well-known privacy-friendly SOCKS5/VPN
/// providers as templates (host/port left for the user to fill from their own
/// subscription — we never bundle someone else's paid endpoint), and the user
/// can add fully custom entries. Everything lives on-device; nothing about the
/// proxy leaves the app except the traffic it carries.
class ProxyProfile {
  ProxyProfile({
    required this.id,
    required this.name,
    required this.scheme, // socks5 | http | https
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
    this.builtIn = false,
    this.note = '',
  });

  final String id;
  String name;
  String scheme;
  String host;
  int port;
  String username;
  String password; // stored encrypted at the profiles-list level
  final bool builtIn;
  String note;

  bool get isComplete => host.trim().isNotEmpty && port > 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'scheme': scheme,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'builtIn': builtIn,
        'note': note,
      };

  factory ProxyProfile.fromJson(Map<String, dynamic> j) => ProxyProfile(
        id: '${j['id']}',
        name: '${j['name']}',
        scheme: '${j['scheme'] ?? 'socks5'}',
        host: '${j['host'] ?? ''}',
        port: (j['port'] is int) ? j['port'] as int : int.tryParse('${j['port']}') ?? 1080,
        username: '${j['username'] ?? ''}',
        password: '${j['password'] ?? ''}',
        builtIn: j['builtIn'] == true,
        note: '${j['note'] ?? ''}',
      );

  ProxyProfile copy() => ProxyProfile.fromJson(toJson());
}

/// Curated starter templates. These are common privacy providers that support
/// SOCKS5 for user traffic; host/port/creds are intentionally blank so the user
/// pastes the endpoint from *their own* account. "Custom" is always available.
/// This keeps the app self-contained (a pick-list) without shipping anyone's
/// paid credentials.
List<ProxyProfile> _builtInTemplates() => [
      ProxyProfile(
        id: 'tpl_custom',
        name: 'Custom SOCKS5',
        scheme: 'socks5',
        host: '',
        port: 1080,
        builtIn: true,
        note: 'Enter any SOCKS5 host:port (+ user/pass if required).',
      ),
      ProxyProfile(
        id: 'tpl_mullvad',
        name: 'Mullvad SOCKS5',
        scheme: 'socks5',
        host: '', // e.g. 10.64.0.1 over WireGuard, or a mullvad socks endpoint
        port: 1080,
        builtIn: true,
        note: 'Mullvad exposes SOCKS5 on its VPN network. Fill your endpoint.',
      ),
      ProxyProfile(
        id: 'tpl_seedbox',
        name: 'Seedbox SOCKS5',
        scheme: 'socks5',
        host: '',
        port: 1080,
        builtIn: true,
        note: 'Most seedboxes provide a SOCKS5 proxy for torrent traffic.',
      ),
      ProxyProfile(
        id: 'tpl_http',
        name: 'Custom HTTP proxy',
        scheme: 'http',
        host: '',
        port: 8080,
        builtIn: true,
        note: 'Plain HTTP/HTTPS proxy (Dart-traffic only; not torrent swarm).',
      ),
    ];

/// Persists the proxy profile list + the active selection, and syncs the active
/// one into [BeamConfig] so the existing HTTP layer and the native torrent
/// engine both read a single source of truth.
class ProxyProfiles {
  ProxyProfiles._();

  static const _kList = 'beam_proxy_profiles_v1'; // encrypted (has passwords)
  static const _kActive = 'beam_proxy_active_id';

  static SharedPreferences get _p {
    // BeamConfig.init() already loaded prefs; reuse a fresh handle safely.
    // (SharedPreferences is a singleton under the hood.)
    return _prefs!;
  }

  static SharedPreferences? _prefs;
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static Future<List<ProxyProfile>> all() async {
    final raw = _p.getString(_kList);
    if (raw == null || raw.isEmpty) {
      // First run: seed with templates.
      final seeded = _builtInTemplates();
      await _save(seeded);
      return seeded;
    }
    String jsonStr = raw;
    if (CredentialVault.isProtected(raw)) {
      jsonStr = await CredentialVault.reveal(raw) ?? '[]';
    }
    try {
      final list = (jsonDecode(jsonStr) as List)
          .whereType<Map<String, dynamic>>()
          .map(ProxyProfile.fromJson)
          .toList();
      // Ensure the built-in templates are always present.
      final ids = list.map((e) => e.id).toSet();
      for (final t in _builtInTemplates()) {
        if (!ids.contains(t.id)) list.add(t);
      }
      return list;
    } catch (_) {
      final seeded = _builtInTemplates();
      await _save(seeded);
      return seeded;
    }
  }

  static Future<void> _save(List<ProxyProfile> list) async {
    final jsonStr = jsonEncode(list.map((e) => e.toJson()).toList());
    final protectedValue = await CredentialVault.protect(jsonStr);
    await _p.setString(_kList, protectedValue);
  }

  static Future<void> upsert(ProxyProfile profile) async {
    final list = await all();
    final idx = list.indexWhere((e) => e.id == profile.id);
    if (idx >= 0) {
      list[idx] = profile;
    } else {
      list.add(profile);
    }
    await _save(list);
    // If this is the active profile, push it into BeamConfig.
    if (await activeId() == profile.id) {
      await _syncActiveToConfig(profile);
    }
  }

  static Future<void> remove(String id) async {
    final list = await all();
    list.removeWhere((e) => e.id == id && !e.builtIn);
    await _save(list);
  }

  static Future<String?> activeId() async => _p.getString(_kActive);

  static Future<ProxyProfile?> active() async {
    final id = await activeId();
    if (id == null) return null;
    final list = await all();
    for (final p in list) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Selects a profile as active, enables the proxy, and mirrors its values
  /// into [BeamConfig] (the single source the HTTP + torrent layers read).
  static Future<void> select(String id) async {
    await _p.setString(_kActive, id);
    final list = await all();
    final chosen = list.firstWhere(
      (e) => e.id == id,
      orElse: () => list.first,
    );
    await _syncActiveToConfig(chosen);
  }

  /// Turns the proxy off entirely (direct traffic).
  static Future<void> disable() async {
    await BeamConfig.setProxyEnabled(false);
  }

  static Future<void> _syncActiveToConfig(ProxyProfile p) async {
    await BeamConfig.setProxyScheme(p.scheme);
    await BeamConfig.setProxyHost(p.host);
    await BeamConfig.setProxyPort(p.port);
    await BeamConfig.setProxyUser(p.username);
    await BeamConfig.setProxyPass(p.password);
    await BeamConfig.setProxyEnabled(p.isComplete);
  }
}
