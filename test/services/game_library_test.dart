import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/games/game_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('saved native favorite launches without ROM downloads and is remembered', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final library = GameLibrary(prefs, 'native-test', client: MockClient((_) async {
      fail('Native favorites must not request a ROM or server manifest');
    }));
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(GameLibrary.channel, (call) async { calls.add(call.method); return null; });
    try {
      await library.favorite(GameLibrary.rainbow3d);
      final saved = library.saved('favorites').single;
      await library.play(saved, progress: (_, _) {});
      await library.play(saved, progress: (_, _) {});
      expect(calls, ['launchRainbow', 'launchRainbow']);
      expect(library.saved('recent').single.id, saved.id);
      expect(library.isFavorite(saved), isTrue);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(GameLibrary.channel, null);
      library.close();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({'games.url': 'http://library:8768', 'games.token': 'private'}));
  test('catalog sends credentials in header and safely encodes search', () async {
    final prefs = await SharedPreferences.getInstance();
    final library = GameLibrary(
      prefs,
      'tv',
      client: MockClient((r) async {
        expect(r.headers['Authorization'], 'Bearer private');
        expect(r.url.queryParameters['q'], 'A & B');
        expect(r.url.toString(), isNot(contains('private')));
        return http.Response(jsonEncode({'games': [], 'total': 0}), 200);
      }),
    );
    await library.catalog(query: 'A & B');
    library.close();
  });
  test('history and favorites are isolated by Plezy profile', () async {
    final prefs = await SharedPreferences.getInstance();
    final a = GameLibrary(prefs, 'a');
    final b = GameLibrary(prefs, 'b');
    final game = LibraryGame({'id': '123', 'title': 'A', 'system': 'nes', 'systemName': 'NES'});
    await a.remember(game);
    await a.remember(game);
    await a.favorite(game);
    expect(a.saved('recent').length, 1);
    expect(a.isFavorite(game), isTrue);
    expect(b.saved('recent'), isEmpty);
    expect(b.isFavorite(game), isFalse);
    await a.favorite(game);
    expect(a.isFavorite(game), isFalse);
    a.close();
    b.close();
  });
  test('untrusted paths cannot escape the cache', () {
    for (final value in ['../outside', 'nes/../../file', '/etc/passwd', 'C:/file', 'nes\\file', 'nes//file']) {
      expect(() => GameLibrary.safeRelative(value), throwsFormatException);
    }
    expect(GameLibrary.safeRelative('nes/A game (USA).nes'), 'nes/A game (USA).nes');
  });
}
