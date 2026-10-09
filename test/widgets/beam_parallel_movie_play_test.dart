import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

ProwlarrResult _source(String release, String hash) => ProwlarrResult.fromJson({
  'title': 'The.Butler.2013.720p.$release',
  'seeders': 20,
  'guid': 'magnet:?xt=urn:btih:$hash',
});

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
    BeamFallback.playServiceOverride = null;
  });
  for (final cachePending in [false, true]) {
    testWidgets(
      cachePending
          ? 'indexed sources race while cached lookup is pending'
          : 'RD-safe and native WEB-DL movie sources race together',
      (tester) async {
        final cached = Completer<List<ProwlarrResult>>();
        final sources = [_source('BluRay.OFT', '1' * 40), _source('WEB-DL.RAWR', '2' * 40)];
        final rd = <String>[];
        final native = <String>[];
        Future<bool>? playback;
        BeamFallback.searchOverride = (_, _) async => sources;
        BeamFallback.cachedSourcesOverride = (_, _, _, _) => cachePending ? cached.future : Future.value([]);
        BeamFallback.playServiceOverride = BeamPlayService(
          realDebrid: (source, _, _, token) {
            rd.add(source.title);
            return token.bind(Completer<BeamPlayResult>().future);
          },
          torrent: (source, _, _, token) {
            native.add(source.title);
            return token.bind(Completer<BeamPlayResult>().future);
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => playback = BeamFallback.playByTitle(context, title: 'The Butler', year: 2013),
                  child: const Text('Play'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Play'));
        for (var i = 0; i < 100 && native.length < 2; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
        expect(rd, unorderedEquals(sources.map((s) => s.title)));
        expect(native, unorderedEquals(sources.map((s) => s.title)));
        expect(find.text('Trying 2 sources at the same time'), findsOneWidget);
        expect(find.textContaining('Source 1:'), findsOneWidget);
        expect(find.textContaining('Source 2:'), findsOneWidget);
        final row = tester.widget<Text>(find.textContaining('Source 1:'));
        expect(row.data, contains('InstantPlay:'));
        expect(row.data, contains('Real-Debrid:'));
        expect(row.maxLines, greaterThanOrEqualTo(2));
        if (cachePending) expect(cached.isCompleted, isFalse);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(await playback!, isFalse);
        if (cachePending) {
          cached.completeError(StateError('late account lookup error'));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('actual Play replaces a failed source while eight other source slots keep racing', (tester) async {
    final sources = List.generate(9, (i) => _source('WEB-DL.fixture$i', '${i + 1}' * 40));
    final rd = <String, Completer<BeamPlayResult>>{};
    final native = <String, Completer<BeamPlayResult>>{};
    Future<bool>? playback;
    BeamFallback.searchOverride = (_, _) async => sources;
    BeamFallback.cachedSourcesOverride = (_, _, _, _) async => [];
    BeamFallback.playServiceOverride = BeamPlayService(
      realDebrid: (source, _, _, token) {
        final result = rd[source.title] = Completer<BeamPlayResult>();
        return token.bind(result.future);
      },
      torrent: (source, _, _, token) {
        final result = native[source.title] = Completer<BeamPlayResult>();
        return token.bind(result.future);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => playback = BeamFallback.playByTitle(context, title: 'The Butler', year: 2013),
              child: const Text('Play'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Play'));
    for (var i = 0; i < 100 && native.length < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(rd.length, 8);
    expect(native.length, 8);
    final failed = rd.keys.first;
    rd[failed]!.completeError(StateError('RD unavailable'));
    await tester.pump();
    expect(native.length, 8);
    native[failed]!.completeError(StateError('No matching file'));
    await tester.pump();
    await tester.pump();
    expect(rd.length, 9);
    expect(native.keys, unorderedEquals(rd.keys));
    expect(find.text('Trying 8 sources at the same time'), findsOneWidget);
    expect(find.textContaining('Source 1:'), findsNothing);
    expect(find.textContaining('Source 9:'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await playback!, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
