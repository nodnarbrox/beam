import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';

void main() {
  EpisodeFile file(int id, String path, [int size = 100]) => EpisodeFile(id: id, path: path, size: size);
  int select(List<EpisodeFile> files, {int season = 1, int episode = 2}) =>
      EpisodeFileSelector.select(files, season: season, episode: episode).id;

  test('judge: real Pioneer One fixture sizes cannot choose larger E01', () {
    expect(
      select([
        file(1, 'Pioneer.One.S01E01.test-excerpt.mp4', 2913186),
        file(2, 'Pioneer.One.S01E02.test-excerpt.mp4', 1028067),
      ]),
      2,
    );
  });

  test('judge: directory episode markers never override the filename', () {
    expect(
      () => select([file(1, 'Pioneer.One.S01E02/Pioneer.One.S01E01.mkv')]),
      throwsA(isA<EpisodeSelectionException>()),
    );
  });

  test('judge: wrong season, sample directory and extras cannot win', () {
    expect(
      select([
        file(1, 'Pioneer.One.S02E02.mkv', 9000),
        file(2, r'Sample\Pioneer.One.S01E02.mp4', 8000),
        file(3, 'Extras/Pioneer.One.S01E02.mp4', 7000),
        file(4, 'Pioneer.One.1x02.mp4'),
      ]),
      4,
    );
  });

  for (final name in [
    'Pioneer.One.S01E02E03.mkv',
    'Pioneer.One.S01E02-E03.mkv',
    'Pioneer.One.S01E02-03.mkv',
    'Pioneer.One.1x02x03.mkv',
  ]) {
    test('judge: explicit combined episode includes requested story $name', () {
      expect(select([file(1, name)]), 1);
      expect(select([file(1, name)], episode: 3), 1);
      expect(() => select([file(1, name)], episode: 4), throwsA(isA<EpisodeSelectionException>()));
    });
  }

  test('judge: E020 is not E02', () {
    expect(() => select([file(1, 'Pioneer.One.S01E020.mkv')]), throwsA(isA<EpisodeSelectionException>()));
  });

  test('judge: duplicate episode encodes must not silently choose one', () {
    expect(
      () => select([file(1, 'Pioneer.One.S01E02.720p.mkv'), file(2, 'Pioneer.One.S01E02.1080p.mkv', 9000)]),
      throwsA(isA<EpisodeSelectionException>()),
    );
  });

  test('judge: specials support season zero without matching season one', () {
    expect(select([file(1, 'Pioneer.One.S01E02.mp4', 9000), file(2, 'Pioneer.One.S00E02.mp4')], season: 0), 2);
  });

  test('judge: one missing coordinate cannot invoke movie selection', () {
    expect(
      () => EpisodeFileSelector.select([file(1, 'movie.mp4')], season: 1),
      throwsA(isA<EpisodeSelectionException>()),
    );
  });

  test('judge: normal movie largest-video behavior survives', () {
    expect(EpisodeFileSelector.select([file(1, 'Movie.mp4', 1000), file(2, 'Movie.sample.mp4', 2000)]).id, 1);
  });

  test('judge: RD returned filename cannot contradict selected episode', () async {
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture-token',
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/addMagnet')) {
          return http.Response(jsonEncode({'id': 'pack'}), 201);
        }
        if (request.url.path.endsWith('/info/pack')) {
          return http.Response(
            jsonEncode({
              'status': 'downloaded',
              'files': [
                {'id': 42, 'path': '/Pioneer.One.S01E02.mp4', 'bytes': 1028067, 'selected': 1},
              ],
              'links': ['https://fixture.invalid/episode-link'],
            }),
            200,
          );
        }
        if (request.url.path.endsWith('/unrestrict/link')) {
          return http.Response(
            jsonEncode({
              'filename': 'Pioneer.One.S01E01.mp4',
              'filesize': 2913186,
              'download': 'https://fixture.invalid/wrong-episode.mp4',
            }),
            200,
          );
        }
        throw StateError('Unexpected request: ${request.url.path}');
      }),
    );
    await expectLater(
      client.resolveMagnet('magnet:?xt=urn:btih:fixture', season: 1, episode: 2),
      throwsA(anyOf(isA<EpisodeSelectionException>(), isA<RdException>())),
    );
  });
}
