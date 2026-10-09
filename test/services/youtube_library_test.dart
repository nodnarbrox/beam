import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/youtube/youtube_library.dart';
import 'package:plezy/services/youtube/youtube_service.dart';
// Regression for the upstream related-video response observed in the live probe.
import 'package:youtube_explode_dart/src/extensions/helpers_extension.dart';

YouTubeVideo video(String id) => YouTubeVideo(id: id, title: 'Video $id', author: 'Creator', channelId: 'channel');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saves and history persist separately per profile', () async {
    final prefs = await SharedPreferences.getInstance();
    final first = YouTubeLibrary(prefs, 'first');
    final second = YouTubeLibrary(prefs, 'second');
    await first.toggleSaved(video('a'));
    await first.recordPlayed(video('b'));
    await first.recordPlayed(video('b'));
    expect(first.saved.single.id, 'a');
    expect(first.recent.single.id, 'b');
    expect(second.saved, isEmpty);
    expect(second.recent, isEmpty);
    expect(YouTubeLibrary(prefs, 'first').saved.single.id, 'a');
    await first.toggleSaved(video('a'));
    expect(first.saved, isEmpty);
    await first.clearHistory();
    expect(first.recent, isEmpty);
  });

  test('recommendations prioritize overlap and exclude seen videos', () {
    final ranked = YouTubeLibrary.rankRecommendations(
      [
        [video('a'), video('b'), video('watched')],
        [video('b'), video('c'), video('c')],
      ],
      {'watched'},
    );
    expect(ranked.first.id, 'b');
    expect(ranked.map((v) => v.id).toSet(), {'a', 'b', 'c'});
  });

  test('unknown YouTube date labels do not abort recommendations', () {
    expect('Streamed live yesterday'.toDateTime(), isNull);
    expect('2 unexpected ago'.toDateTime(), isNull);
    expect('2 days ago'.toDateTime(), isNotNull);
  });
}
