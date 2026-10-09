import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/indexer_search.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/tpb_magnet_source.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'beam_rd_token': 'fixture'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
  });
  tearDown(() {
    BeamFallback.searchOverride = null;
    BeamFallback.cachedSourcesOverride = null;
    BeamFallback.libraryLookupOverride = null;
    BeamFallback.playServiceOverride = null;
  });

  for (final episode in [true, false]) {
    testWidgets('automatic HTML magnet enters both ${episode ? 'episode' : 'movie'} races after API misses it', (
      tester,
    ) async {
      const hash = '8d37e46f1d45b72a0c3053c9e520446b2d75f78c';
      final title = episode ? '1000-lb Sisters S07E01 1080p WEB h264-FREQUENCY' : 'Big Buck Bunny 2008 720p BluRay';
      final category = episode ? 208 : 201;
      final html =
          '''<table id="searchResult">
      <tr><th>Type</th><th>Name</th><th>Uploaded</th><th></th><th>Size</th><th>SE</th><th>LE</th></tr>
      <tr><td><a href="/browse/$category">Video</a></td>
      <td><a href="/torrent/78834156/title">$title</a></td><td>date</td>
      <td><a href="magnet:?xt=urn:btih:$hash&amp;tr=udp%3A%2F%2Ftracker.example%3A80">magnet</a></td>
      <td>2.58 GiB</td><td>11</td><td>3</td></tr></table>''';
      var apiCalls = 0;
      var htmlCalls = 0;
      final indexer = CombinedIndexer(
        direct: MultiIndexer(
          sources: [
            ApibaySource(
              clientFactory: () async => MockClient((_) async {
                apiCalls++;
                return http.Response('[{"id":"0","name":"No results returned","info_hash":"${'0' * 40}"}]', 200);
              }),
              fallback: TpbMagnetSource(
                clientFactory: () async => MockClient((_) async {
                  htmlCalls++;
                  return http.Response(html, 200);
                }),
              ),
            ),
          ],
        ),
      );
      final native = <ProwlarrResult>[];
      final rd = <ProwlarrResult>[];
      final tokens = <BeamCancellation>[];
      Future<bool>? playback;
      BeamFallback.libraryLookupOverride = (_, _, _, _) async => null;
      BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
      BeamFallback.searchOverride = (query, kind) =>
          indexer.search(query, categories: kind == MediaKind.episode ? [5000] : [2000]);
      Future<BeamPlayResult> wait(ProwlarrResult source, BeamCancellation token, List<ProwlarrResult> seen) {
        seen.add(source);
        tokens.add(token);
        return token.bind(Completer<BeamPlayResult>().future);
      }

      BeamFallback.playServiceOverride = BeamPlayService(
        realDebrid: (source, _, _, token) => wait(source, token, rd),
        torrent: (source, _, _, token) => wait(source, token, native),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => playback = BeamFallback.playByTitle(
                  context,
                  title: episode ? '1000-lb Sisters' : 'Big Buck Bunny',
                  kind: episode ? MediaKind.episode : MediaKind.movie,
                  year: episode ? null : 2008,
                  season: episode ? 7 : null,
                  episode: episode ? 1 : null,
                ),
                child: const Text('Play'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Play'));
      for (var i = 0; i < 100 && native.isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(apiCalls, greaterThan(0));
      expect(htmlCalls, greaterThan(0));
      expect(native, hasLength(1), reason: 'Repeated title/pack queries deduplicate by the extracted hash');
      expect(rd, hasLength(1));
      expect(native.single.infoHash, hash);
      expect(rd.single.magnetUrl, native.single.magnetUrl);
      expect(native.single.seeders, 11);
      expect(Uri.parse(native.single.magnetUrl!).queryParametersAll['tr'], contains('udp://tracker.example:80'));
      expect(tokens.every((token) => !token.isCancelled), isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(await playback!, isFalse);
      expect(tokens.every((token) => token.isCancelled), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
