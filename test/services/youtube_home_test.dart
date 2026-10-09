import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/youtube/youtube_home.dart';
import 'package:plezy/services/youtube/youtube_library.dart';
import 'package:plezy/services/youtube/youtube_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

YouTubeVideo video(String id) => YouTubeVideo(id: id, title: id, author: 'Creator', channelId: 'channel');

class FakeService extends YouTubeService {
  FakeService(this.fetch);
  final Future<List<YouTubeVideo>> Function(YouTubeVideo) fetch;
  @override
  Future<List<YouTubeVideo>> related(YouTubeVideo seed) => fetch(seed);
  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Home is useful without an account or media server', () async {
    var requests = 0;
    final home = YouTubeHome(
      serviceFactory: () => FakeService((_) async {
        requests++;
        return [];
      }),
    );
    addTearDown(home.dispose);
    await home.load('local');
    expect(home.hubs.first.title, 'My YouTube recommendations');
    expect(home.hubs.first.items.map(YouTubeHome.action), ['account', 'search']);
    expect(
      home.hubs[1].items.map((i) => i.title),
      containsAll(['Search YouTube', 'Music', 'Gaming', 'Podcasts', 'Live', 'Learning', 'Shorts']),
    );
    expect(requests, 0);
  });

  test('subscriptions show avatars and reorder after viewing without changing other profiles', () async {
    final prefs = await SharedPreferences.getInstance();
    final subscriptions = [
      {'id': 'a', 'title': 'Alpha', 'avatarUrl': 'https://yt3.ggpht.com/alpha'},
      {'id': 'b', 'title': 'Beta'},
      {'id': 'c', 'title': 'Charlie'},
    ];
    await prefs.setString('youtube.me.googleLibrary', jsonEncode({'subscriptions': subscriptions}));
    final home = YouTubeHome(serviceFactory: () => FakeService((_) async => []));
    addTearDown(home.dispose);
    final library = YouTubeLibrary(prefs, 'me');
    await home.load('me');
    expect(home.hubs.last.items.first.thumbPath, 'https://yt3.ggpht.com/alpha');
    expect(home.hubs.last.items.first.raw?['youtubeChannel'], isTrue);
    await library.recordChannelViewed('c');
    await home.load('me');
    expect(home.hubs.last.items.map((i) => i.title), ['Charlie', 'Alpha', 'Beta']);
    await library.recordPlayed(const YouTubeVideo(id: 'v', title: 'Video', author: 'Beta', channelId: 'b'));
    await home.load('me');
    expect(home.hubs.last.items.map((i) => i.title), ['Beta', 'Charlie', 'Alpha']);
    expect(YouTubeLibrary(prefs, 'me').viewedChannels, ['b', 'c']);
    expect(YouTubeLibrary(prefs, 'other').sortSubscriptions(subscriptions).map((c) => c['id']), ['a', 'b', 'c']);
    await library.clearHistory();
    expect(library.viewedChannels, isEmpty);
  });

  test('account shelves and ranked recommendations share playable video IDs', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'youtube.me.googleLibrary',
      jsonEncode({
        'updatedAt': 'today',
        'liked': [video('liked').toJson()],
        'uploads': [video('mine').toJson()],
        'subscriptions': [
          {'id': 'UC123', 'title': 'My channel'},
        ],
      }),
    );
    await YouTubeLibrary(prefs, 'me').recordPlayed(video('recent'));
    var requests = 0;
    final home = YouTubeHome(
      serviceFactory: () => FakeService((seed) async {
        requests++;
        return [video('liked'), video('recent'), video('shared'), video(seed.id == 'liked' ? 'next1' : 'next2')];
      }),
    );
    addTearDown(home.dispose);
    await home.load('me');
    expect(home.hubs.first.items.map((i) => YouTubeHome.video(i).id), ['shared', 'next1', 'next2']);
    expect(home.hubs.first.items.every((i) => YouTubeHome.action(i) == 'play'), isTrue);
    expect(home.hubs.first.items.first.thumbPath, video('shared').thumbnail);
    expect(home.hubs.singleWhere((h) => h.id == 'youtube.uploads').items.single.title, 'mine');
    expect(
      home.hubs.singleWhere((h) => h.id == 'youtube.subscriptions').items.single.raw?['query'],
      'https://www.youtube.com/channel/UC123',
    );
    await home.load('me');
    expect(requests, 2, reason: 'Returning Home without new signals reuses recommendations');
  });

  test('one failed seed preserves other results and cached account shelves', () async {
    final prefs = await SharedPreferences.getInstance();
    final library = YouTubeLibrary(prefs, 'me');
    await library.toggleSaved(video('bad'));
    await library.recordPlayed(video('good'));
    final home = YouTubeHome(
      serviceFactory: () => FakeService((seed) async {
        if (seed.id == 'bad') throw StateError('offline');
        return [video('result')];
      }),
    );
    addTearDown(home.dispose);
    await home.load('me');
    expect(YouTubeHome.video(home.hubs.first.items.single).id, 'result');
    expect(home.hubs.any((h) => h.id == 'youtube.recent'), isTrue);
  });

  test('late recommendations cannot leak across profiles', () async {
    final prefs = await SharedPreferences.getInstance();
    await YouTubeLibrary(prefs, 'old').recordPlayed(video('seed'));
    final pending = Completer<List<YouTubeVideo>>();
    final started = Completer<void>();
    final home = YouTubeHome(
      serviceFactory: () => FakeService((_) {
        started.complete();
        return pending.future;
      }),
    );
    addTearDown(home.dispose);
    final oldLoad = home.load('old');
    await started.future;
    await home.load('new');
    pending.complete([video('private-old-recommendation')]);
    await oldLoad;
    expect(home.library?.profileId, 'new');
    expect(home.hubs.expand((h) => h.items).any((i) => YouTubeHome.action(i) == 'play'), isFalse);
  });

  test('disconnect clears imported likes and recommendations on refresh', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'youtube.me.googleLibrary',
      jsonEncode({
        'liked': [video('liked').toJson()],
      }),
    );
    final home = YouTubeHome(serviceFactory: () => FakeService((_) async => [video('suggested')]));
    addTearDown(home.dispose);
    await home.load('me');
    expect(home.hubs.any((h) => h.id == 'youtube.liked'), isTrue);
    await prefs.remove('youtube.me.googleLibrary');
    await home.load('me');
    expect(home.hubs.any((h) => h.id == 'youtube.liked'), isFalse);
    expect(home.hubs.first.items.map(YouTubeHome.action), ['account', 'search']);
  });
}
