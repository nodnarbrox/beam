import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../credential_vault.dart';
import 'youtube_service.dart';

class YouTubeAccountFailure implements Exception {
  const YouTubeAccountFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class YouTubeDeviceCode {
  const YouTubeDeviceCode(this.deviceCode, this.userCode, this.url, this.expiresAt, this.interval);
  final String deviceCode;
  final String userCode;
  final String url;
  final DateTime expiresAt;
  final Duration interval;
  String get qrUrl =>
      Uri.parse(url).replace(queryParameters: {...Uri.parse(url).queryParameters, 'user_code': userCode}).toString();
}

/// Read-only Google device authorization. Credentials belong to Plezy's own
/// registered TV client; no third-party application's client identity is used.
class YouTubeAccount {
  YouTubeAccount(
    this.preferences,
    this.profileId, {
    http.Client? client,
    this.clientId = const String.fromEnvironment('YOUTUBE_CLIENT_ID'),
    this.clientSecret = const String.fromEnvironment('YOUTUBE_CLIENT_SECRET'),
    Future<String> Function(String)? protect,
    Future<String?> Function(String)? reveal,
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _protect = protect ?? CredentialVault.protect,
       _reveal = reveal ?? CredentialVault.reveal,
       _now = now ?? DateTime.now,
       _expectedToken = preferences.getString('youtube.${Uri.encodeComponent(profileId)}.googleToken');

  final SharedPreferences preferences;
  final String profileId;
  final String clientId;
  final String clientSecret;
  final http.Client _http;
  final Future<String> Function(String) _protect;
  final Future<String?> Function(String) _reveal;
  final DateTime Function() _now;
  bool _closed = false;
  String? _expectedToken;
  int _generation = 0;
  Timer? _delay;
  Completer<void>? _waiting;
  String get _prefix => 'youtube.${Uri.encodeComponent(profileId)}';
  String get _tokenKey => '$_prefix.googleToken';
  String get _snapshotKey => '$_prefix.googleLibrary';
  bool get configured => clientId.isNotEmpty && clientSecret.isNotEmpty;
  bool get connected => preferences.containsKey(_tokenKey);

  Map<String, dynamic>? get snapshot {
    try {
      final raw = preferences.getString(_snapshotKey);
      return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void _check(int generation) {
    if (_closed || generation != _generation || preferences.getString(_tokenKey) != _expectedToken) {
      throw const YouTubeAccountFailure('Connection changed or cancelled.');
    }
  }

  Map<String, dynamic> _decodeResponse(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      // FormatException can include response contents, including credentials.
      throw const YouTubeAccountFailure('Google returned an unreadable response. Try again.');
    }
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, String> body) async {
    final response = await _http
        .post(Uri.https('oauth2.googleapis.com', path), body: body)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode >= 500) throw const YouTubeAccountFailure('Google is unavailable. Try again.');
    // Return only parsed protocol fields; never log token responses or bodies.
    return _decodeResponse(response.body);
  }

  Future<YouTubeDeviceCode> begin() async {
    if (!configured) throw const YouTubeAccountFailure('Google connection is not configured for this build.');
    final generation = ++_generation;
    final data = await _post('/device/code', {
      'client_id': clientId,
      'scope': 'https://www.googleapis.com/auth/youtube.readonly',
    });
    _check(generation);
    if (data['error'] != null || data['device_code'] == null) {
      throw const YouTubeAccountFailure('Google could not start sign-in. Check the app registration.');
    }
    final url = Uri.parse(data['verification_url'] as String);
    if (url.scheme != 'https' || !const {'www.google.com', 'google.com', 'accounts.google.com'}.contains(url.host)) {
      throw const YouTubeAccountFailure('Google returned an unexpected sign-in address.');
    }
    return YouTubeDeviceCode(
      data['device_code'] as String,
      data['user_code'] as String,
      url.toString(),
      _now().add(Duration(seconds: data['expires_in'] as int)),
      Duration(seconds: (data['interval'] as int? ?? 5).clamp(1, 60)),
    );
  }

  Future<void> _wait(Duration interval) {
    final waiting = Completer<void>();
    _waiting = waiting;
    _delay = Timer(interval, () {
      _waiting = null;
      waiting.complete();
    });
    return waiting.future;
  }

  Future<void> finish(YouTubeDeviceCode code) async {
    final generation = _generation;
    var interval = code.interval;
    while (_now().isBefore(code.expiresAt)) {
      await _wait(interval);
      _check(generation);
      if (!_now().isBefore(code.expiresAt)) break;
      final data = await _post('/token', {
        'client_id': clientId,
        'client_secret': clientSecret,
        'device_code': code.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      _check(generation);
      switch (data['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'access_denied':
          throw const YouTubeAccountFailure('Google sign-in was declined.');
        case 'expired_token':
          throw const YouTubeAccountFailure('The sign-in code expired. Try again.');
        case null:
          if (data['access_token'] == null || data['refresh_token'] == null) {
            throw const YouTubeAccountFailure('Google did not provide a complete account connection.');
          }
          await _saveToken(data, generation);
          return;
        default:
          throw const YouTubeAccountFailure('Google sign-in failed. Try again.');
      }
    }
    throw const YouTubeAccountFailure('The sign-in code expired. Try again.');
  }

  Future<void> _saveToken(Map<String, dynamic> data, int generation) async {
    final value = await _protect(
      jsonEncode({
        'access_token': data['access_token'],
        'refresh_token': data['refresh_token'],
        'expiresAt': _now().add(Duration(seconds: (data['expires_in'] as int? ?? 3600) - 60)).toIso8601String(),
      }),
    );
    _check(generation);
    if (!await preferences.setString(_tokenKey, value)) {
      throw const YouTubeAccountFailure('The account connection could not be saved.');
    }
    _expectedToken = value;
  }

  Future<String> _accessToken(int generation) async {
    final raw = preferences.getString(_tokenKey);
    if (raw == null) throw const YouTubeAccountFailure('Connect your YouTube account first.');
    final clear = await _reveal(raw);
    _check(generation);
    if (clear == null) throw const YouTubeAccountFailure('Connect your YouTube account again.');
    final token = _decodeResponse(clear);
    if (_now().isBefore(DateTime.parse(token['expiresAt'] as String))) return token['access_token'] as String;
    final data = await _post('/token', {
      'client_id': clientId,
      'client_secret': clientSecret,
      'refresh_token': token['refresh_token'] as String,
      'grant_type': 'refresh_token',
    });
    _check(generation);
    if (data['access_token'] == null) throw const YouTubeAccountFailure('Google needs you to connect again.');
    data['refresh_token'] ??= token['refresh_token'];
    await _saveToken(data, generation);
    return data['access_token'] as String;
  }

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query, String token) async {
    final response = await _http
        .get(Uri.https('www.googleapis.com', '/youtube/v3/$path', query), headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw YouTubeAccountFailure(
        response.statusCode == 401
            ? 'Google needs you to connect again.'
            : 'Your YouTube library could not be refreshed. Try again.',
      );
    }
    return _decodeResponse(response.body);
  }

  static List<YouTubeVideo> _videos(Map<String, dynamic> response, {bool playlist = false}) {
    final result = <YouTubeVideo>[];
    for (final item in (response['items'] as List? ?? [])) {
      final snippet = item['snippet'] as Map<String, dynamic>;
      final id = playlist ? (snippet['resourceId']?['videoId']) : item['id'];
      if (id is! String || snippet['title'] == 'Deleted video' || snippet['title'] == 'Private video') continue;
      result.add(
        YouTubeVideo(
          id: id,
          title: snippet['title'] as String,
          author: (snippet['videoOwnerChannelTitle'] ?? snippet['channelTitle'] ?? '') as String,
          channelId: (snippet['videoOwnerChannelId'] ?? snippet['channelId'] ?? '') as String,
        ),
      );
    }
    return result;
  }

  Future<void> sync() async {
    final generation = _generation;
    final token = await _accessToken(generation);
    final responses = await Future.wait([
      _get('videos', {'part': 'snippet', 'myRating': 'like', 'maxResults': '50'}, token),
      _get('channels', {'part': 'snippet,contentDetails', 'mine': 'true'}, token),
      _get('subscriptions', {'part': 'snippet', 'mine': 'true', 'maxResults': '50', 'order': 'alphabetical'}, token),
    ]);
    _check(generation);
    final channels = responses[1]['items'] as List? ?? [];
    final channel = channels.isEmpty ? null : channels.first;
    final playlist = channel?['contentDetails']?['relatedPlaylists']?['uploads'] as String?;
    final uploads = playlist == null
        ? <YouTubeVideo>[]
        : _videos(
            await _get('playlistItems', {'part': 'snippet', 'playlistId': playlist, 'maxResults': '50'}, token),
            playlist: true,
          );
    _check(generation);
    final subscriptions = _subscriptions(responses[2]);
    final snapshot = {
      'name': channel?['snippet']?['title'] ?? 'YouTube',
      'channelId': channel?['id'],
      'avatarUrl':
          (channel?['snippet']?['thumbnails']?['high'] ?? channel?['snippet']?['thumbnails']?['default'])?['url'],
      'updatedAt': _now().toIso8601String(),
      'liked': _videos(responses[0]).map((v) => v.toJson()).toList(),
      'uploads': uploads.map((v) => v.toJson()).toList(),
      'subscriptions': subscriptions,
      'channelAvatarsVersion': 2,
    };
    if (!await preferences.setString(_snapshotKey, jsonEncode(snapshot))) {
      throw const YouTubeAccountFailure('Your YouTube library could not be saved.');
    }
  }

  static List<Map<String, dynamic>> _subscriptions(Map<String, dynamic> response) =>
      (response['items'] as List? ?? []).map((item) {
        final snippet = item['snippet'] as Map;
        final thumbnails = snippet['thumbnails'] as Map? ?? {};
        return <String, dynamic>{
          'id': snippet['resourceId']['channelId'],
          'title': snippet['title'],
          'avatarUrl': (thumbnails['high'] ?? thumbnails['medium'] ?? thumbnails['default'])?['url'],
        };
      }).toList();

  /// Upgrade existing snapshots once without requiring another sign-in.
  Future<void> refreshSubscriptionAvatars() async {
    if (!connected || snapshot?['channelAvatarsVersion'] == 2) return;
    final generation = _generation;
    final token = await _accessToken(generation);
    final response = await _get('subscriptions', {
      'part': 'snippet',
      'mine': 'true',
      'maxResults': '50',
      'order': 'alphabetical',
    }, token);
    final identity = await _get('channels', {'part': 'snippet', 'mine': 'true'}, token);
    _check(generation);
    if (!connected) return;
    final identities = identity['items'] as List? ?? [];
    final channel = identities.isEmpty ? null : identities.first;
    final updated = {
      ...?snapshot,
      if (channel != null) ...{
        'channelId': channel['id'],
        'name': channel['snippet']['title'],
        'avatarUrl':
            (channel['snippet']['thumbnails']?['high'] ?? channel['snippet']['thumbnails']?['default'])?['url'],
      },
      'subscriptions': _subscriptions(response),
      'channelAvatarsVersion': 2,
      'updatedAt': _now().toIso8601String(),
    };
    if (!await preferences.setString(_snapshotKey, jsonEncode(updated))) {
      throw const YouTubeAccountFailure('Channel avatars could not be saved.');
    }
  }

  Future<void> disconnect() async {
    ++_generation;
    _cancelWait();
    // Local removal is reliable even offline. Google can revoke the grant from
    // its account connections page; no other profile's connection is affected.
    final removedToken = await preferences.remove(_tokenKey);
    final removedSnapshot = await preferences.remove(_snapshotKey);
    if (!removedToken || !removedSnapshot) {
      throw const YouTubeAccountFailure('The account connection could not be removed.');
    }
  }

  void _cancelWait() {
    _delay?.cancel();
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  void close() {
    _closed = true;
    ++_generation;
    _cancelWait();
    _http.close();
  }
}
