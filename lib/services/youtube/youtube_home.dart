import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../media/media_backend.dart';
import '../../media/media_hub.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../utils/app_logger.dart';
import 'youtube_account.dart';
import 'youtube_library.dart';
import 'youtube_service.dart';

/// Home shelves share the active Plezy profile's account and playback history.
/// Related videos are ranked from taste signals, not presented as Google's feed.
class YouTubeHome extends ChangeNotifier {
  YouTubeHome({YouTubeService Function()? serviceFactory}) : _serviceFactory = serviceFactory ?? YouTubeService.new;

  final YouTubeService Function() _serviceFactory;
  YouTubeService? _service;
  YouTubeAccount? _avatarAccount;
  YouTubeLibrary? library;
  String? _profileId;
  String? _accountIdentity;
  int _generation = 0;
  bool _disposed = false;
  String? _signature;
  List<YouTubeVideo> _recommendations = [];
  List<MediaHub> hubs = const [];

  static bool owns(MediaItem item) => item.raw?['youtubeHome'] != null;
  static String? action(MediaItem item) => item.raw?['youtubeHome'] as String?;
  static YouTubeVideo video(MediaItem item) =>
      YouTubeVideo.fromJson(Map<String, dynamic>.from(item.raw!['video'] as Map));

  Future<void> load(String profileId, {bool force = false}) async {
    final changedProfile = _profileId != profileId;
    if (changedProfile) {
      _profileId = profileId;
      _signature = null;
      _recommendations = [];
      library = null;
      hubs = const [];
      _service?.close();
    }
    final generation = ++_generation;
    _avatarAccount?.close();
    _avatarAccount = null;
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || generation != _generation) return;
    final local = YouTubeLibrary(prefs, profileId);
    library = local;
    final account = YouTubeAccount(prefs, profileId);
    var snapshot = account.snapshot;
    final identity = snapshot?['channelId'] as String?;
    if (_accountIdentity != identity) {
      _accountIdentity = identity;
      _signature = null;
      _recommendations = [];
    }
    final tokenKey = 'youtube.${Uri.encodeComponent(profileId)}.googleToken';
    final connection = prefs.getString(tokenKey);
    final connected = account.connected;
    final seeds = local.recommendationSeeds;
    final signature =
        '${snapshot?['updatedAt']}:${seeds.map((v) => v.id).join(',')}:${local.recent.map((v) => v.id).join(',')}:${local.viewedChannels.join(',')}';
    if (!force && _signature == signature && _service == null) {
      account.close();
      return;
    }
    _signature = signature;
    if (seeds.isEmpty) _recommendations = [];
    _rebuild(local, snapshot, connected);
    notifyListeners();
    _avatarAccount = account;
    try {
      await account.refreshSubscriptionAvatars();
      if (_disposed || generation != _generation || prefs.getString(tokenKey) != connection) return;
      snapshot = account.snapshot;
      _rebuild(local, snapshot, connected);
      notifyListeners();
    } catch (error, stack) {
      if (!_disposed && generation == _generation) {
        appLogger.w('YouTube subscription avatars could not refresh', error: error, stackTrace: stack);
      }
    } finally {
      account.close();
      if (identical(_avatarAccount, account)) _avatarAccount = null;
    }
    if (_disposed || generation != _generation) return;
    _service?.close();
    final service = _service = _serviceFactory();
    try {
      final groups = await Future.wait(
        seeds.map((seed) async {
          try {
            return await service.related(seed);
          } catch (error, stack) {
            if (!_disposed && generation == _generation) {
              appLogger.w('YouTube Home recommendations could not refresh', error: error, stackTrace: stack);
            }
            return <YouTubeVideo>[];
          }
        }),
      );
      if (_disposed || generation != _generation || prefs.getString(tokenKey) != connection) return;
      final ranked = YouTubeLibrary.rankRecommendations(
        groups,
        {...local.saved, ...local.liked, ...local.recent}.map((v) => v.id).toSet(),
      );
      if (ranked.isNotEmpty || seeds.isEmpty) _recommendations = ranked;
      _rebuild(local, snapshot, connected);
      notifyListeners();
    } finally {
      service.close();
      if (identical(_service, service)) _service = null;
    }
  }

  MediaItem _entry(
    String id,
    String title,
    String description,
    String action, {
    String? query,
    YouTubeVideo? video,
    String? avatarUrl,
    bool channel = false,
  }) => MediaItem(
    id: 'youtube:$id',
    backend: MediaBackend.plex,
    kind: MediaKind.clip,
    title: title,
    summary: description,
    studio: video?.author ?? 'YouTube',
    thumbPath: avatarUrl ?? video?.thumbnail,
    artPath: video?.thumbnail,
    durationMs: video?.durationSeconds == null ? null : video!.durationSeconds! * 1000,
    serverId: 'youtube',
    raw: {
      'youtubeHome': action,
      'query': query,
      if (channel) 'youtubeChannel': true,
      if (video != null) 'video': video.toJson(),
    },
  );

  MediaItem _video(YouTubeVideo v) => _entry(v.id, v.title, '${v.author} · Play on YouTube', 'play', video: v);

  void _rebuild(YouTubeLibrary local, Map<String, dynamic>? snapshot, bool connected) {
    List<YouTubeVideo> videos(String key) {
      try {
        return (snapshot?[key] as List? ?? [])
            .map((v) => YouTubeVideo.fromJson(Map<String, dynamic>.from(v as Map)))
            .toList();
      } catch (error, stack) {
        appLogger.w('YouTube Home account shelf could not be read', error: error, stackTrace: stack);
        return [];
      }
    }

    MediaHub shelf(String id, String title, List<MediaItem> items) =>
        MediaHub(id: 'youtube.$id', title: title, type: 'clip', items: items, size: items.length);
    final accountEntry = _entry(
      'account',
      avatarUrl: snapshot?['avatarUrl'] as String?,
      channel: true,
      connected ? 'Your YouTube account' : 'Connect your YouTube',
      'Your likes, uploads and subscribed channels. Recommendations use your likes and videos played in Beam.',
      'account',
    );
    final searchEntry = _entry(
      'search',
      'Search YouTube',
      'Find a video, channel or playlist and play it here.',
      'search',
      query: '',
    );
    final recommendations = _recommendations.map(_video).toList();
    hubs = [
      shelf(
        'recommendations',
        'My YouTube recommendations',
        recommendations.isEmpty ? [accountEntry, searchEntry] : recommendations,
      ),
      shelf('browse', 'Your YouTube', [
        searchEntry,
        accountEntry,
        _entry(
          'refresh',
          'Refresh recommendations',
          'Find more videos based on your likes and recently played videos.',
          'refresh',
        ),
        for (final topic in ['Music', 'Gaming', 'Podcasts', 'Live', 'Learning', 'Shorts'])
          _entry(
            'topic:$topic',
            topic,
            'Explore $topic videos on YouTube.',
            'search',
            query: topic == 'Live' ? 'live now' : topic,
          ),
      ]),
      if (local.recent.isNotEmpty) shelf('recent', 'Recently played on YouTube', local.recent.map(_video).toList()),
      if (videos('liked').isNotEmpty) shelf('liked', 'My liked YouTube videos', videos('liked').map(_video).toList()),
      if (videos('uploads').isNotEmpty) shelf('uploads', 'My YouTube uploads', videos('uploads').map(_video).toList()),
      if ((snapshot?['subscriptions'] as List? ?? []).isNotEmpty)
        shelf('subscriptions', 'My YouTube subscriptions', [
          for (final channel in local.sortSubscriptions(snapshot!['subscriptions'] as List))
            if (channel['id'] is String && channel['title'] is String)
              _entry(
                'channel:${channel['id']}',
                channel['title'] as String,
                'Browse this channel and play its videos.',
                'search',
                query: 'https://www.youtube.com/channel/${channel['id']}',
                avatarUrl: channel['avatarUrl'] as String?,
                channel: true,
              ),
        ]),
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _service?.close();
    _avatarAccount?.close();
    super.dispose();
  }
}
