import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/indexer_search.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';

const hash = '0123456789012345678901234567890123456789';
http.Response json(Object value) => http.Response(jsonEncode(value), 200);

void main() {
  test('read-only account lookup injects only completed exact movie copies with valid hashes', () async {
    final paths = <String>[];
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        paths.add(request.url.path);
        return json([
          {'id': 'correct', 'status': 'downloaded', 'filename': 'The.Butler.2013.1080p.BluRay.YIFY', 'hash': hash},
          {
            'id': 'active',
            'status': 'downloading',
            'filename': 'The.Butler.2013.720p.BluRay',
            'hash': '1123456789012345678901234567890123456789',
          },
          {
            'id': 'wrongyear',
            'status': 'downloaded',
            'filename': 'The.Butler.2024.720p.BluRay',
            'hash': '2123456789012345678901234567890123456789',
          },
          {
            'id': 'unrelated',
            'status': 'downloaded',
            'filename': 'Fleur distracts the butler 2013',
            'hash': '3123456789012345678901234567890123456789',
          },
          {'id': 'nohash', 'status': 'downloaded', 'filename': 'The.Butler.2013.720p.BluRay', 'hash': 'bad'},
          {
            'id': 'bare',
            'status': 'downloaded',
            'filename': 'The.Butler.2013.mp4',
            'hash': '4123456789012345678901234567890123456789',
          },
        ]);
      }),
    );
    final candidates = await client.completedCandidates(title: 'The Butler', year: 2013);
    expect(candidates.map((source) => source.title), ['The.Butler.2013.1080p.BluRay.YIFY', 'The.Butler.2013.mp4']);
    expect(paths, ['/rest/1.0/torrents']);
    expect(candidates.first.infoHash, hash);
    final magnet = Uri.parse(candidates.first.magnetUrl!);
    expect(magnet.queryParameters['xt'], 'urn:btih:$hash');
    expect(magnet.queryParameters['dn'], candidates.first.title);
    expect(magnet.queryParametersAll['tr'], containsAll(kProxyableTrackers));
    expect(magnet.queryParametersAll['tr']!.any((tracker) => Uri.parse(tracker).scheme == 'http'), isTrue);
    expect(candidates.first.seeders, 0); // No fabricated swarm measurements.
  });

  test('completed TV lookup requires the right series and episode or season pack', () async {
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient(
        (_) async => json([
          {'status': 'downloaded', 'filename': 'Other.Show.S01E02.720p', 'hash': hash},
          {
            'status': 'downloaded',
            'filename': 'Pioneer.One.S01E03.720p',
            'hash': '1123456789012345678901234567890123456789',
          },
          {
            'status': 'downloaded',
            'filename': 'Pioneer.One.S01.Complete.720p',
            'hash': '2123456789012345678901234567890123456789',
          },
        ]),
      ),
    );
    final candidates = await client.completedCandidates(title: 'Pioneer One', season: 1, episode: 2);
    expect(candidates.single.title, 'Pioneer.One.S01.Complete.720p');
    final magnet = Uri.parse(candidates.single.magnetUrl!);
    expect(magnet.queryParameters['xt'], 'urn:btih:2123456789012345678901234567890123456789');
    expect(magnet.queryParametersAll['tr'], containsAll(kProxyableTrackers));
  });

  test('completed duplicate wins over earlier active duplicate without adding or polling active job', () async {
    final paths = <String>[];
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/torrents')) {
          return json([
            {'id': 'active', 'status': 'downloading', 'hash': hash},
            {'id': 'ready', 'status': 'downloaded', 'hash': hash},
          ]);
        }
        if (request.url.path.endsWith('/info/ready')) {
          return json({
            'status': 'downloaded',
            'links': ['ready-link'],
          });
        }
        if (request.url.path.endsWith('/unrestrict/link')) {
          return json({'filename': 'The.Butler.2013.mp4', 'download': 'https://fixture/butler.mp4'});
        }
        fail('Unexpected request: ${request.url.path}');
      }),
    );
    final result = await client.resolveMagnetSmart('magnet:?xt=urn:btih:$hash', infoHash: hash);
    expect(result.torrentId, 'ready');
    expect(paths, ['/rest/1.0/torrents', '/rest/1.0/torrents/info/ready', '/rest/1.0/unrestrict/link']);
  });
}
