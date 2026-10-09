import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'youtube_service.dart';

/// Local saves and taste signals are isolated by Plezy profile. Expiring stream
/// URLs are never persisted. These saves are independent of Google account likes.
class YouTubeLibrary {
  YouTubeLibrary(this.preferences, this.profileId);
  final SharedPreferences preferences;
  final String profileId;
  String _key(String name) => 'youtube.${Uri.encodeComponent(profileId)}.$name';

  List<YouTubeVideo> _read(String name) {
    final result = <YouTubeVideo>[];
    for (final raw in preferences.getStringList(_key(name)) ?? <String>[]) {
      try {
        result.add(YouTubeVideo.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    return result;
  }

  List<YouTubeVideo> get saved => _read('saved');
  List<YouTubeVideo> get recent => _read('recent');
  List<YouTubeVideo> get liked {
    try {
      final raw = preferences.getString(_key('googleLibrary'));
      if (raw == null) return [];
      final snapshot = jsonDecode(raw) as Map<String, dynamic>;
      return (snapshot['liked'] as List? ?? []).map((v) => YouTubeVideo.fromJson(v as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  bool isSaved(String id) => saved.any((video) => video.id == id);

  Future<void> _write(String name, List<YouTubeVideo> videos) async {
    final ok = await preferences.setStringList(
      _key(name),
      videos.take(100).map((v) => jsonEncode(v.toJson())).toList(),
    );
    if (!ok) throw StateError('Could not save your YouTube library.');
  }

  Future<void> toggleSaved(YouTubeVideo video) async {
    final list = saved;
    if (list.any((v) => v.id == video.id)) {
      list.removeWhere((v) => v.id == video.id);
    } else {
      list.insert(0, video);
    }
    await _write('saved', list);
  }

  List<String> get viewedChannels => preferences.getStringList(_key('viewedChannels')) ?? [];

  Future<void> recordChannelViewed(String id) async {
    if (id.isEmpty) return;
    if (!await preferences.setStringList(
      _key('viewedChannels'),
      [id, ...viewedChannels.where((value) => value != id)].take(500).toList(),
    )) {
      throw StateError('Could not save recently viewed channels.');
    }
  }

  List<Map> sortSubscriptions(List raw) {
    final channels = raw.whereType<Map>().toList();
    final order = viewedChannels;
    final original = {for (var i = 0; i < channels.length; i++) channels[i]['id']: i};
    int rank(Map channel) {
      final index = order.indexOf(channel['id'] as String? ?? '');
      return index < 0 ? order.length + original[channel['id']]! : index;
    }

    channels.sort((a, b) => rank(a).compareTo(rank(b)));
    return channels;
  }

  Future<void> recordPlayed(YouTubeVideo video) async {
    await _write('recent', [video, ...recent.where((v) => v.id != video.id)]);
    await recordChannelViewed(video.channelId);
  }

  Future<void> clearHistory() async {
    await _write('recent', []);
    if (!await preferences.remove(_key('viewedChannels'))) throw StateError('Could not clear channel history.');
  }

  List<YouTubeVideo> get recommendationSeeds {
    final seen = <String>{};
    // Interleave sources so existing local bookmarks do not crowd out Google
    // likes, and one source alone can still supply all three taste signals.
    final groups = [saved, liked, recent];
    final candidates = <YouTubeVideo>[];
    for (var i = 0; i < 3; i++) {
      for (final group in groups) {
        if (i < group.length) candidates.add(group[i]);
      }
    }
    return candidates.where((video) => seen.add(video.id)).take(3).toList();
  }

  static List<YouTubeVideo> rankRecommendations(List<List<YouTubeVideo>> groups, Set<String> seenIds) {
    final votes = <String, int>{};
    final items = <String, YouTubeVideo>{};
    for (final group in groups) {
      final groupIds = <String>{};
      for (final video in group) {
        if (seenIds.contains(video.id) || !groupIds.add(video.id)) continue;
        items[video.id] = video;
        votes.update(video.id, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    final ids = items.keys.toList()..sort((a, b) => votes[b]!.compareTo(votes[a]!));
    return ids.take(30).map((id) => items[id]!).toList();
  }
}
