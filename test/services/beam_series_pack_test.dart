import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/episode_source_probe.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/release_identity.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';

ProwlarrResult source(String title) => ProwlarrResult.fromJson({
  'title': title,
  'seeders': 5,
  'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
});

void main() {
  for (final title in [
    'Sherlock Complete Series 1080p BluRay',
    'Sherlock The Complete Series 720p',
    'Sherlock Complete 1080p',
    'Sherlock S01-S04 1080p',
    'Sherlock S01-04 Complete 1080p',
    'Sherlock Seasons 1-4 1080p',
    'Sherlock Complete Seasons 1-4 1080p',
  ]) {
    test('whole-series candidate covers S03E02: $title', () {
      expect(
        ReleaseIdentity.episodeSourceKind(source(title), show: 'Sherlock', season: 3, episode: 2),
        EpisodeReleaseKind.seriesPack,
      );
    });
  }
  for (final title in ['Sherlock S03 Complete 1080p', 'Sherlock Complete Season 3 1080p']) {
    test('complete season candidate: $title', () {
      expect(
        ReleaseIdentity.episodeSourceKind(source(title), show: 'Sherlock', season: 3, episode: 2),
        EpisodeReleaseKind.seasonPack,
      );
    });
  }
  for (final title in [
    'Sherlock Holmes Complete Series 1080p',
    'Other Sherlock Complete Series 1080p',
    'Sherlock S01-S02 1080p',
    'Sherlock S04-S01 1080p',
    'Sherlock S01 S04 1080p',
    'Sherlock Complete Season 2 1080p',
    'Sherlock Complete S03E01 1080p',
    'Sherlock Complete Series Sample 1080p',
    'Sherlock Complete Series 1080p S03E01',
    'Sherlock S03E01 1080p',
    'Sherlock S03E020 1080p',
  ]) {
    test('rejects unrelated, ambiguous or wrong-coordinate pack: $title', () {
      expect(ReleaseIdentity.matchesEpisodeSource(source(title), show: 'Sherlock', season: 3, episode: 2), isFalse);
    });
  }

  test('numeric hyphens in a show title are not season ranges', () {
    expect(
      ReleaseIdentity.matchesEpisodeSource(source('9.1.1.Complete.Series.1080p'), show: '9-1-1', season: 3, episode: 2),
      isTrue,
    );
  });

  test('full-series pack selects actual episode across seasons, never the largest file', () {
    const files = [
      EpisodeFile(id: 1, path: 'Sherlock/Season 1/Sherlock.S01E02.mkv', size: 9000),
      EpisodeFile(id: 2, path: 'Sherlock/Season 3/Sherlock.S03E01.mkv', size: 8000),
      EpisodeFile(id: 3, path: 'Sherlock/Season 3/Sherlock.S03E02.mkv', size: 1000),
    ];
    expect(EpisodeFileSelector.select(files, season: 3, episode: 2).id, 3);
    expect(() => EpisodeFileSelector.select(files, season: 4, episode: 2), throwsA(isA<EpisodeSelectionException>()));
  });

  test('probe discovers whole series after empty episode and season searches', () async {
    final calls = <String>[];
    final probe = EpisodeSourceProbe((query) async {
      calls.add(query);
      return query == 'Sherlock Complete' ? [source('Sherlock Complete Series 1080p')] : [];
    });
    expect(await probe.check('Sherlock', 3, 2), EpisodeSourceAvailability.candidate);
    expect(calls.toSet(), EpisodeSourceProbe.queries('Sherlock', 3, 2).toSet());
    expect(calls.length, 5);
  });

  test('range-only pack is discoverable by bounded title query', () async {
    final probe = EpisodeSourceProbe((query) async => query == 'Sherlock' ? [source('Sherlock S01-S04 1080p')] : []);
    expect(await probe.check('Sherlock', 3, 2), EpisodeSourceAvailability.candidate);
  });

  test('completed full-series RD candidate opens only requested season and episode link', () async {
    const hash = '0123456789012345678901234567890123456789';
    final unlocked = <String>[];
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/torrents')) {
          return http.Response(
            jsonEncode([
              {'id': 'series', 'hash': hash, 'status': 'downloaded', 'filename': 'Sherlock Complete Series 1080p'},
            ]),
            200,
          );
        }
        if (request.url.path.endsWith('/info/series')) {
          return http.Response(
            jsonEncode({
              'status': 'downloaded',
              'files': [
                {'id': 1, 'path': '/Sherlock/Sherlock.S01E02.mkv', 'bytes': 9000, 'selected': 1},
                {'id': 2, 'path': '/Sherlock/Sherlock.S03E02.mkv', 'bytes': 1000, 'selected': 1},
                {'id': 3, 'path': '/Sherlock/Sherlock.S04E02.mkv', 'bytes': 8000, 'selected': 1},
              ],
              'links': ['rd-s01e02', 'rd-s03e02', 'rd-s04e02'],
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/unrestrict/link')) {
          unlocked.add(request.bodyFields['link']!);
          return http.Response(
            jsonEncode({
              'filename': 'Sherlock.S03E02.mkv',
              'download': 'https://fixture.invalid/s03e02',
              'filesize': 1000,
            }),
            200,
          );
        }
        fail('Unexpected RD mutation or request: ${request.url.path}');
      }),
    );
    final candidates = await client.completedCandidates(title: 'Sherlock', season: 3, episode: 2);
    expect(candidates.single.infoHash, hash);
    final result = await client.resolveMagnetSmart(candidates.single.magnetUrl!, infoHash: hash, season: 3, episode: 2);
    expect(result.primaryVideo!.filename, 'Sherlock.S03E02.mkv');
    expect(unlocked, ['rd-s03e02']);
  });

  test('probe rejects wrong-show and wrong-episode hits; partial outage stays unknown', () async {
    var fail = false;
    final probe = EpisodeSourceProbe((query) async {
      if (fail && query.endsWith('Complete')) throw StateError('provider unavailable');
      return [source('Other Show Complete Series'), source('Sherlock S03E01 1080p')];
    });
    expect(await probe.check('Sherlock', 3, 2), EpisodeSourceAvailability.unavailable);
    fail = true;
    expect(await probe.check('Sherlock', 4, 2), EpisodeSourceAvailability.unknown);
  });

  test('cached episode hit cannot make the next episode available', () async {
    final probe = EpisodeSourceProbe((query) async => query.endsWith('S03') ? [source('Sherlock S03E02 1080p')] : []);
    expect(await probe.check('Sherlock', 3, 2), EpisodeSourceAvailability.candidate);
    expect(await probe.check('Sherlock', 3, 3), EpisodeSourceAvailability.unavailable);
  });

  test('concurrent episode probes share only four pack searches', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    final probe = EpisodeSourceProbe((query) async {
      calls.add(query);
      if (query.contains('E0')) return [];
      await gate.future;
      return [source('Sherlock Complete Series 1080p')];
    });
    final first = probe.check('Sherlock', 3, 2);
    final next = probe.check('Sherlock', 3, 3);
    await Future<void>.delayed(Duration.zero);
    expect(calls.length, 6);
    gate.complete();
    expect(await Future.wait([first, next]), everyElement(EpisodeSourceAvailability.candidate));
  });
}
