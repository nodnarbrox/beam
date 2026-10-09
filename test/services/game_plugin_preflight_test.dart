import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/games/game_library.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final game = LibraryGame({
    'id': '0123456789abcdef01234567',
    'title': 'Local test',
    'system': 'test',
    'systemName': 'Test',
  });
  late Directory root;
  late List<String> calls;
  late List<String> requests;
  late GameLibrary library;
  var missing = false;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('plezy-plugin-test-');
    calls = [];
    requests = [];
    missing = false;
    SharedPreferences.setMockInitialValues({'games.url': 'https://example.invalid'});
    library = GameLibrary(
      await SharedPreferences.getInstance(),
      'test',
      client: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path.startsWith('/saves/')) return http.Response('', 404);
        return http.Response(
          jsonEncode({
            'core': 'testcore',
            'path': 'test.rom',
            'files': [],
            // Must never trigger BIOS downloading in the release copy.
            'bios': [
              {'path': 'firmware.bin', 'name': 'firmware.bin', 'size': 1},
            ],
          }),
          200,
        );
      }),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(GameLibrary.channel, (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'paths') {
        return {'root': root.path, 'freeBytes': 1024 * 1024 * 1024};
      }
      if (call.method == 'checkCore' && missing) {
        throw PlatformException(code: 'plugin_missing');
      }
      if (call.method == 'launch') return {'played': false};
      return null;
    });
  });

  tearDown(() async {
    library.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      GameLibrary.channel,
      null,
    );
    await root.delete(recursive: true);
  });

  test('missing plugin prevents transfers, launch and cache creation', () async {
    missing = true;
    await expectLater(library.play(game, progress: (_, _) {}), throwsA(isA<PlatformException>()));
    expect(calls, ['paths', 'checkCore']);
    expect(requests, ['/game/${game.id}']);
    expect(await root.list().isEmpty, isTrue);
  });

  test('catalog BIOS entries are ignored after plugin preflight', () async {
    // An already cached user-supplied game avoids invoking the transfer adapter.
    final cached = Directory('${root.path}/cache/${game.id}');
    await cached.create(recursive: true);
    await File('${cached.path}/test.rom').writeAsBytes([0]);
    await library.play(game, progress: (_, _) {});
    expect(calls, ['paths', 'checkCore', 'launch']);
    expect(requests.where((path) => path.contains('firmware')), isEmpty);
    expect(await Directory('${root.path}/bios').exists(), isFalse);
  });
}
