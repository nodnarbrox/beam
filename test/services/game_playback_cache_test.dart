import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/games/game_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SharedPreferences prefs;
  const id = '012345678901234567890123';
  final game = LibraryGame({
    'id': id,
    'title': 'Demo',
    'system': 'nes',
    'systemName': 'Nintendo',
    'path': 'nes/demo.nes',
    'core': 'fceumm',
    'extensions': ['.nes'],
  });
  final manifest = {
    ...game.data,
    'files': [
      {'path': 'nes/demo.nes', 'size': 400000},
    ],
  };
  setUp(() async {
    root = await Directory.systemTemp.createTemp('plezy-games-test-');
    SharedPreferences.setMockInitialValues({
      'games.url': 'http://library',
      'games.token': 'private',
      'games.cacheMB': 1,
    });
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      GameLibrary.channel,
      null,
    );
    expect(p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path), isTrue);
    await root.delete(recursive: true);
  });
  test('cached launch evicts only older ROMs and uploads newly saved progress', () async {
    final cached = File(p.join(root.path, 'cache', id, 'nes/demo.nes'));
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes(List.filled(400000, 0));
    final older = File(p.join(root.path, 'cache', 'abcdefabcdefabcdefabcdef', 'old.nes'));
    await older.parent.create(recursive: true);
    await older.writeAsBytes(List.filled(700000, 0));
    final protected = File(p.join(root.path, 'saves', 'existing', 'save.srm'));
    await protected.parent.create(recursive: true);
    await protected.writeAsString('keep');
    var launched = false;
    var uploaded = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(GameLibrary.channel, (
      call,
    ) async {
      if (call.method == 'paths') return {'root': root.path, 'freeBytes': 1024 * 1024 * 1024};
      if (call.method == 'launch') {
        launched = true;
        expect(call.arguments['path'], cached.path);
        final saves = call.arguments['saveDir'] as String;
        await File(p.join(saves, 'resume.state')).writeAsString('progress');
        await File(p.join(saves, '.pending')).writeAsString('sync');
        return {'played': true};
      }
      throw StateError('Unexpected method');
    });
    final library = GameLibrary(
      prefs,
      'profile',
      client: MockClient((request) async {
        if (request.url.path.startsWith('/game/')) return http.Response(jsonEncode(manifest), 200);
        if (request.method == 'PUT') {
          uploaded = true;
          expect(request.body, 'progress');
          return http.Response('{}', 200);
        }
        return http.Response('', 404);
      }),
    );
    await library.play(game, progress: (_, _) {});
    expect(launched, isTrue);
    expect(uploaded, isTrue);
    expect(await older.exists(), isFalse);
    expect(await protected.readAsString(), 'keep');
    expect(library.saved('recent').single.id, id);
    expect(await File(p.join(root.path, 'saves', library.profileKey, id, '.pending')).exists(), isFalse);
    library.close();
  });
  test('cancel during preparation never launches the emulator or overwrites saves', () async {
    final paths = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    var launched = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(GameLibrary.channel, (
      call,
    ) async {
      if (call.method == 'paths') {
        started.complete();
        return paths.future;
      }
      launched = true;
      return {'played': true};
    });
    final library = GameLibrary(
      prefs,
      'profile',
      client: MockClient((_) async => http.Response(jsonEncode(manifest), 200)),
    );
    final play = library.play(game, progress: (_, _) {});
    final assertion = expectLater(play, throwsA(isA<GameCancelled>()));
    await started.future;
    library.cancel();
    paths.complete({'root': root.path, 'freeBytes': 1024 * 1024 * 1024});
    await assertion;
    expect(launched, isFalse);
    expect(library.saved('recent'), isEmpty);
    library.close();
  });
}
