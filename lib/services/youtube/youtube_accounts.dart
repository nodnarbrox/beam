import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Saved connections are private to one Plezy profile. Tokens are already
/// encrypted by CredentialVault; only that encrypted value is archived here.
class YouTubeAccounts {
  YouTubeAccounts(this.preferences, this.profileId);
  final SharedPreferences preferences;
  final String profileId;
  String get _prefix => 'youtube.${Uri.encodeComponent(profileId)}';
  String get _key => '$_prefix.accounts';
  static const _historyKeys = ['saved', 'recent', 'viewedChannels'];

  Map<String, dynamic> _read() {
    final raw = preferences.getString(_key);
    return raw == null ? {} : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Map<String, dynamic>? get currentSnapshot {
    final raw = preferences.getString('$_prefix.googleLibrary');
    return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  String get activeId => currentSnapshot?['channelId'] as String? ?? 'legacy';
  List<Map<String, dynamic>> get accounts => _read().entries.map((entry) {
    final value = entry.value as Map;
    final snapshot = value['snapshot'] as Map? ?? {};
    return <String, dynamic>{
      'id': entry.key,
      'name': snapshot['name'] ?? 'YouTube',
      'avatarUrl': snapshot['avatarUrl'],
    };
  }).toList();

  Future<void> _save(Map<String, dynamic> data) async {
    if (!await preferences.setString(_key, jsonEncode(data))) throw StateError('Could not save YouTube accounts.');
  }

  Map<String, dynamic>? _current() {
    final token = preferences.getString('$_prefix.googleToken');
    if (token == null) return null;
    return {
      'token': token,
      'snapshot': currentSnapshot,
      for (final name in _historyKeys) name: preferences.getStringList('$_prefix.$name') ?? <String>[],
    };
  }

  Future<void> rememberCurrent() async {
    final current = _current();
    if (current == null) return;
    final data = _read();
    data[activeId] = current;
    // A pre-upgrade account acquires its stable channel id on refresh.
    if (activeId != 'legacy' && (data['legacy'] as Map?)?['token'] == current['token']) data.remove('legacy');
    await _save(data);
  }

  Future<void> _apply(Map value) async {
    final snapshot = value['snapshot'];
    if (snapshot == null) {
      await preferences.remove('$_prefix.googleLibrary');
    } else if (!await preferences.setString('$_prefix.googleLibrary', jsonEncode(snapshot))) {
      throw StateError('Could not switch YouTube library.');
    }
    for (final name in _historyKeys) {
      if (!await preferences.setStringList('$_prefix.$name', List<String>.from(value[name] as List? ?? []))) {
        throw StateError('Could not switch YouTube history.');
      }
    }
    if (!await preferences.setString('$_prefix.googleToken', value['token'] as String)) {
      throw StateError('Could not switch YouTube account.');
    }
  }

  Future<void> select(String id) async {
    await rememberCurrent();
    final value = _read()[id] as Map?;
    if (value == null) throw StateError('This account is no longer saved.');
    final previous = _current();
    try {
      await _apply(value);
    } catch (_) {
      if (previous != null) await _apply(previous);
      rethrow;
    }
  }

  Future<void> adopt(String pendingProfile) async {
    await rememberCurrent();
    final pending = YouTubeAccounts(preferences, pendingProfile);
    final value = pending._current();
    if (value == null || value['snapshot'] == null) throw StateError('Complete Google sign-in first.');
    final data = _read();
    final id = pending.activeId;
    // Reconnecting an existing account preserves its local viewing history.
    final old = data[id] as Map?;
    if (old != null) {
      for (final name in _historyKeys) {
        value[name] = old[name] ?? <String>[];
      }
    }
    data[id] = value;
    await _save(data);
    final previous = _current();
    try {
      await _apply(value);
    } catch (_) {
      if (previous != null) await _apply(previous);
      rethrow;
    }
    await pending.clearPending();
  }

  Future<void> forgetCurrent() async {
    final data = _read()..remove(activeId);
    await _save(data);
    await clearPending();
    if (data.isNotEmpty) await _apply(data.values.first as Map);
  }

  Future<void> clearPending() async {
    for (final name in ['googleToken', 'googleLibrary', ..._historyKeys]) {
      if (!await preferences.remove('$_prefix.$name')) throw StateError('Could not remove account data.');
    }
  }
}
