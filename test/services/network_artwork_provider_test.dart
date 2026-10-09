import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/services/image_cache_service.dart';
import 'package:plezy/services/network_artwork_provider.dart';
import 'package:plezy/widgets/network_artwork.dart';

class _TrackedPaths extends PathProviderPlatform {
  _TrackedPaths(this.path);
  final String path;
  int calls = 0;
  Future<String?> _read() async {
    calls++;
    return path;
  }

  @override
  Future<String?> getTemporaryPath() => _read();
  @override
  Future<String?> getApplicationCachePath() => _read();
  @override
  Future<String?> getApplicationSupportPath() => _read();
}

Future<ImageInfo> _load(ImageProvider provider) {
  final result = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      result.complete(info);
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stack) {
      result.completeError(error, stack);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return result.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  test('valid HTTP artwork decodes with without disk changes and reuses RAM', () async {
    final disk = await Directory.systemTemp.createTemp('network-artwork-test-');
    final sentinel = File('${disk.path}/preserve.txt')..writeAsStringSync('existing');
    addTearDown(() => disk.delete(recursive: true));
    final before = disk.listSync(recursive: true).map((entry) => entry.path).toList();
    final original = PathProviderPlatform.instance;
    final paths = _TrackedPaths(disk.path);
    PathProviderPlatform.instance = paths;
    addTearDown(() => PathProviderPlatform.instance = original);
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.headers['User-Agent'], 'Plezy');
      return http.Response.bytes(png, 200);
    });
    final provider = NetworkArtworkProvider('https://example.invalid/poster?token=secret', client: client);
    final first = await _load(provider);
    expect(first.image.width, 1);
    final second = await _load(NetworkArtworkProvider(provider.url, client: client));
    expect(second.image.height, 1);
    expect(requests, 1);
    expect(paths.calls, 0);
    expect(disk.listSync(recursive: true).map((entry) => entry.path).toList(), before);
    expect(sentinel.readAsStringSync(), 'existing');
    first.dispose();
    second.dispose();
  });

  for (final status in [404, 500]) {
    test('HTTP $status errors are sanitized and release limited slots', () async {
      final client = createArtworkHttpClientForTest(
        MockClient(
          (request) async =>
              request.url.path == '/bad' ? http.Response('token=secret', status) : http.Response.bytes(png, 200),
        ),
        maxConcurrent: 1,
      );
      final bad = NetworkArtworkProvider('https://example.invalid/bad?token=secret', client: client);
      await expectLater(_load(bad), throwsA(isA<NetworkArtworkException>()));
      expect(bad.toString(), isNot(contains('secret')));
      final info = await _load(NetworkArtworkProvider('https://example.invalid/good', client: client));
      info.dispose();
    });
  }

  test('invalid image and oversized response fail without leaking URL or body', () async {
    for (final response in [http.Response('invalid secret', 200), http.Response.bytes(png, 200)]) {
      final provider = NetworkArtworkProvider(
        'https://example.invalid/secret',
        client: MockClient((_) async => response),
        maxResponseBytes: 20,
      );
      await expectLater(
        _load(provider),
        throwsA(predicate((Object error) => error is NetworkArtworkException && !error.toString().contains('secret'))),
      );
    }
  });

  test('headers separate memory identities while equivalent maps reuse identity', () {
    final first = NetworkArtworkProvider(
      'https://example.invalid/a',
      headers: const {'Authorization': 'a', 'Accept': 'image/*'},
    );
    final same = NetworkArtworkProvider(first.url, headers: const {'Accept': 'image/*', 'Authorization': 'a'});
    final other = NetworkArtworkProvider(first.url, headers: const {'Authorization': 'b'});
    expect(first, same);
    expect(first.hashCode, same.hashCode);
    expect(first, isNot(other));
    expect(
      NetworkArtworkProvider('https://example.invalid/a?token=a', cacheKey: 'same'),
      isNot(NetworkArtworkProvider('https://example.invalid/a?token=b', cacheKey: 'same')),
    );
  });

  test('response deadline fails rather than hanging artwork forever', () async {
    final gate = Completer<http.Response>();
    final provider = NetworkArtworkProvider(
      'https://example.invalid/secret',
      client: MockClient((_) => gate.future),
      timeout: const Duration(milliseconds: 10),
    );
    await expectLater(_load(provider), throwsA(isA<NetworkArtworkException>()));
    gate.complete(http.Response.bytes(png, 200));
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('widget preserves fallback and bounds decode even for unconstrained image', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NetworkArtwork(
          imageUrl: 'unsupported://artwork',
          width: 100,
          height: 150,
          placeholder: (_, _) => const Text('Loading'),
          errorBuilder: (_, _, _) => const Text('Unavailable'),
        ),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    final resize = image.image as ResizeImage;
    expect(resize.width, lessThanOrEqualTo(300));
    expect(resize.height, lessThanOrEqualTo(450));
    expect(resize.policy, ResizeImagePolicy.fit);
    await tester.pump();
    expect(find.text('Unavailable'), findsOneWidget);
  });
  testWidgets('infinite width uses finite tile constraint instead of backdrop decode budget', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 150,
            child: NetworkArtwork(
              imageUrl: 'unsupported://tile',
              width: double.infinity,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    final resize = tester.widget<Image>(find.byType(Image)).image as ResizeImage;
    expect(resize.width, lessThanOrEqualTo(300));
    expect(resize.height, lessThanOrEqualTo(450));
    await tester.pump();
  });
}
