import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/episode_source_probe.dart';
import 'package:plezy/services/beam/indexer_search.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

const files = [
  {'id': 1, 'path': '/Pioneer.One.S01E01.mkv', 'bytes': 2913186, 'selected': 1},
  {'id': 2, 'path': '/Pioneer.One.S01E02.mkv', 'bytes': 1028067, 'selected': 1},
];

class _OfflineTvIndexer extends ApibaySource {
  @override
  Future<List<ProwlarrResult>> search(String query, {List<int> categories = const [2000, 5000]}) async {
    throw StateError('offline');
  }
}

http.Response json(Object value, [int status = 200]) => http.Response(jsonEncode(value), status);
ProwlarrResult source() =>
    ProwlarrResult.fromJson({'title': 'Pioneer One S01', 'seeders': 5, 'guid': 'magnet:?xt=urn:btih:fixture'});
BeamPlayResult result(BeamPlayWinner winner) => BeamPlayResult(
  url: winner == BeamPlayWinner.torrent ? 'http://127.0.0.1/e02' : 'https://fixture/e02',
  winner: winner,
  magnet: source().magnetUrl!,
);
void main() {
  test('TV no-op providers cannot disguise failure of applicable sources', () async {
    await expectLater(
      MultiIndexer(
        sources: [YtsSource(), EztvSource(), _OfflineTvIndexer()],
      ).search('Pioneer One S01E02', categories: const [5000]),
      throwsA(isA<IndexerUnavailableException>()),
    );
  });
  test('native torrent adapter selects smaller E02 and rejects missing or ambiguous', () {
    final native = files
        .map(
          (f) => FileInfo(
            index: f['id'] as int,
            name: f['path'] as String,
            path: f['path'] as String,
            size: f['bytes'] as int,
            isStreamable: true,
          ),
        )
        .toList();
    expect(TorrentStreamService.selectFileIndex(native, season: 1, episode: 2), 2);
    expect(
      () => TorrentStreamService.selectFileIndex(native, season: 1, episode: 3),
      throwsA(isA<EpisodeSelectionException>()),
    );
    expect(
      () => TorrentStreamService.selectFileIndex([...native, native.last], season: 1, episode: 2),
      throwsA(isA<EpisodeSelectionException>()),
    );
  });
  test('RD cached full pack maps requested selected file to correct link', () async {
    final unlocked = <String>[];
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'test',
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/torrents')) {
          return json([
            {'id': 'cached', 'hash': 'hash', 'status': 'downloaded'},
          ]);
        }
        if (r.url.path.endsWith('/info/cached')) {
          return json({
            'status': 'downloaded',
            'files': files,
            'links': ['rd-e01', 'rd-e02'],
          });
        }
        if (r.url.path.endsWith('/unrestrict/link')) {
          unlocked.add(r.bodyFields['link']!);
          return json({'filename': 'Pioneer.One.S01E02.mkv', 'download': 'https://fixture/e02', 'filesize': 1028067});
        }
        fail('Unexpected request ${r.url}');
      }),
    );
    final resolved = await client.resolveMagnetSmart('magnet:fixture', infoHash: 'hash', season: 1, episode: 2);
    expect(resolved.primaryVideo!.downloadUrl, 'https://fixture/e02');
    expect(unlocked, ['rd-e02']);
  });
  test('RD E01-only cache adds fresh job selecting only requested E02', () async {
    var polls = 0;
    final selected = <String>[];
    final unlocked = <String>[];
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'test',
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/torrents')) {
          return json([
            {'id': 'old', 'hash': 'hash', 'status': 'downloaded'},
          ]);
        }
        if (r.url.path.endsWith('/info/old')) {
          return json({
            'status': 'downloaded',
            'files': [
              files.first,
              {...files.last, 'selected': 0},
            ],
            'links': ['rd-e01'],
          });
        }
        if (r.url.path.endsWith('/addMagnet')) {
          return json({'id': 'new'}, 201);
        }
        if (r.url.path.endsWith('/info/new')) {
          return json({
            'status': polls++ == 0 ? 'waiting_files_selection' : 'downloaded',
            'files': [
              {...files.first, 'selected': 0},
              files.last,
            ],
            'links': ['rd-e02'],
          });
        }
        if (r.url.path.endsWith('/selectFiles/new')) {
          selected.add(r.bodyFields['files']!);
          return http.Response('', 204);
        }
        if (r.url.path.endsWith('/unrestrict/link')) {
          unlocked.add(r.bodyFields['link']!);
          return json({'filename': 'Pioneer.One.S01E02.mkv', 'download': 'https://fixture/e02'});
        }
        fail('Unexpected request ${r.url}');
      }),
    );
    final resolved = await client.resolveMagnetSmart(
      'magnet:fixture',
      infoHash: 'hash',
      season: 1,
      episode: 2,
      pollEvery: Duration.zero,
    );
    expect(resolved.primaryVideo!.downloadUrl, 'https://fixture/e02');
    expect(selected, ['2']);
    expect(unlocked, ['rd-e02']);
  });
  test('RD missing and ambiguous episodes fail before select and unrestrict', () async {
    for (final invalid in [
      files.take(1).toList(),
      [
        ...files,
        {...files.last, 'id': 3},
      ],
    ]) {
      final client = RealDebridClient(
        coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
        tokenProvider: () async => 'test',
        httpClient: MockClient((r) async {
          if (r.url.path.endsWith('/addMagnet')) {
            return json({'id': 'test'}, 201);
          }
          if (r.url.path.endsWith('/info/test')) {
            return json({'status': 'waiting_files_selection', 'files': invalid});
          }
          fail('Must reject before selecting/unrestricting ${r.url}');
        }),
      );
      await expectLater(
        client.resolveMagnet('magnet:fixture', season: 1, episode: 2),
        throwsA(isA<EpisodeSelectionException>()),
      );
    }
  });
  test('empty episode search probes pack, cache expires, outages are unknown', () async {
    var now = DateTime(2026);
    var pack = true;
    var outage = false;
    final calls = <String>[];
    final probe = EpisodeSourceProbe((q) async {
      calls.add(q);
      if (outage) {
        throw StateError('offline');
      }
      if (q.endsWith('S01') && pack) {
        return [
          ProwlarrResult.fromJson({
            'title': 'Pioneer One S01 Complete',
            'seeders': 5,
            'guid': 'magnet:?xt=urn:btih:fixture',
          }),
        ];
      }
      return [];
    }, now: () => now);
    expect(await probe.check('Pioneer One', 1, 2), EpisodeSourceAvailability.candidate);
    expect(calls, EpisodeSourceProbe.queries('Pioneer One', 1, 2));
    pack = false;
    expect(await probe.check('Pioneer One', 1, 3), EpisodeSourceAvailability.candidate);
    now = now.add(const Duration(minutes: 3));
    expect(await probe.check('Pioneer One', 1, 3), EpisodeSourceAvailability.unavailable);
    outage = true;
    expect(await probe.check('Pioneer One', 1, 3), EpisodeSourceAvailability.unknown);
  });
  test('first success ignores earlier failure and consumes late failure', () async {
    final success = Completer<String>();
    final failure = Completer<String>();
    final race = BeamPlayService.firstSuccessful([failure.future, success.future]);
    failure.completeError(StateError('dead swarm'));
    success.complete('e02');
    expect(await race, 'e02');
    final late = Completer<String>();
    expect(await BeamPlayService.firstSuccessful([Future.value('e02'), late.future]), 'e02');
    late.completeError(StateError('late error'));
    final old = BeamCancellation();
    final fresh = BeamCancellation();
    final pending = Completer<String>();
    final cancelled = old.bind(pending.future);
    old.cancel();
    await expectLater(cancelled, throwsA(isA<BeamCancelled>()));
    pending.complete('late e01');
    expect(await fresh.bind(Future.value('e02')), 'e02');
  });
  test('actual race releases same-turn and late-ready losing torrent', () async {
    for (final late in [false, true]) {
      final torrent = Completer<BeamPlayResult>();
      final rd = Completer<BeamPlayResult>();
      var released = false;
      final service = BeamPlayService(
        realDebrid: (_, season, episode, cancel) {
          expect((season, episode), (1, 2));
          return rd.future;
        },
        torrent: (_, season, episode, cancel) {
          expect((season, episode), (1, 2));
          unawaited(
            cancel.whenCancelled.then((_) {
              released = true;
            }),
          );
          return torrent.future;
        },
      );
      final race = service.race(source(), rdEnabled: true, torrentEnabled: true, season: 1, episode: 2);
      rd.complete(result(BeamPlayWinner.realDebrid));
      if (!late) {
        torrent.complete(result(BeamPlayWinner.torrent));
      }
      expect((await race).winner, BeamPlayWinner.realDebrid);
      await Future<void>.delayed(Duration.zero);
      expect(released, isTrue);
      if (late) {
        torrent.complete(result(BeamPlayWinner.torrent));
      }
    }
  });
  test('torrent wins before RD selection; losing RD resolver stops without a second handoff', () async {
    final metadataRequested = Completer<void>();
    final metadata = Completer<http.Response>();
    final torrent = Completer<BeamPlayResult>();
    final cached = Completer<void>();
    final selections = <String>[];
    final unlocked = <String>[];
    var polls = 0;
    var handoffs = 0;
    final service = BeamPlayService(
      realDebrid: (source, season, episode, cancellation) async {
        final httpClient = MockClient((request) async {
          if (request.url.path.endsWith('/addMagnet')) return json({'id': 'cache'}, 201);
          if (request.url.path.endsWith('/info/cache')) {
            if (polls++ == 0) {
              metadataRequested.complete();
              return metadata.future;
            }
            return json({
              'status': 'downloaded',
              'files': [
                {...files.first, 'selected': 0},
                files.last,
              ],
              'links': ['rd-e02'],
            });
          }
          if (request.url.path.endsWith('/selectFiles/cache')) {
            selections.add(request.bodyFields['files']!);
            return http.Response('', 204);
          }
          if (request.url.path.endsWith('/unrestrict/link')) {
            unlocked.add(request.bodyFields['link']!);
            return json({'filename': 'Pioneer.One.S01E02.mkv', 'download': 'https://fixture/e02'});
          }
          fail('Unexpected request ${request.url}');
        });
        try {
          final resolved =
              await RealDebridClient(
                coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
                httpClient: httpClient,
                tokenProvider: () async => 'test',
              ).resolveMagnet(
                source.magnetUrl!,
                season: season,
                episode: episode,
                cancellation: cancellation,
                pollEvery: Duration.zero,
              );
          expect(resolved.streams.single.filename, 'Pioneer.One.S01E02.mkv');
          expect(cancellation.isCancelled, isFalse);
          cached.complete();
          return result(BeamPlayWinner.realDebrid);
        } catch (error, stack) {
          cached.completeError(error, stack);
          rethrow;
        } finally {
          httpClient.close();
        }
      },
      torrent: (_, _, _, _) => torrent.future,
    );
    final cacheFinished = expectLater(cached.future, throwsA(isA<BeamCancelled>()));
    final playback = service.race(source(), rdEnabled: true, torrentEnabled: true, season: 1, episode: 2).then((
      winner,
    ) {
      handoffs++;
      return winner;
    });
    await metadataRequested.future;
    torrent.complete(result(BeamPlayWinner.torrent));
    expect((await playback).winner, BeamPlayWinner.torrent);
    expect(selections, isEmpty);
    metadata.complete(json({'status': 'waiting_files_selection', 'files': files}));
    await cacheFinished;
    await Future<void>.delayed(Duration.zero);
    expect(selections, isEmpty);
    expect(unlocked, isEmpty);
    expect(handoffs, 1);
  });
  test('explicit cancellation still interrupts both pending race legs', () async {
    final caller = BeamCancellation();
    final pending = Completer<BeamPlayResult>();
    final tokens = <BeamCancellation>[];
    Future<BeamPlayResult> leg(ProwlarrResult source, int? season, int? episode, BeamCancellation token) {
      tokens.add(token);
      return token.bind(pending.future);
    }

    final playback = BeamPlayService(
      realDebrid: leg,
      torrent: leg,
    ).race(source(), rdEnabled: true, torrentEnabled: true, cancellation: caller);
    final cancelled = expectLater(playback, throwsA(isA<BeamCancelled>()));
    caller.cancel();
    await cancelled;
    expect(tokens, hasLength(2));
    expect(tokens.every((token) => token.isCancelled), isTrue);
    pending.complete(result(BeamPlayWinner.realDebrid));
    await Future<void>.delayed(Duration.zero);
  });
  test('failed race cancels both transport tokens', () async {
    final tokens = <BeamCancellation>[];
    Future<BeamPlayResult> failLeg(ProwlarrResult source, int? season, int? episode, BeamCancellation token) async {
      tokens.add(token);
      throw StateError('unavailable');
    }

    await expectLater(
      BeamPlayService(realDebrid: failLeg, torrent: failLeg).race(source(), rdEnabled: true, torrentEnabled: true),
      throwsStateError,
    );
    expect(tokens.every((token) => token.isCancelled), isTrue);
  });
  test('actual race cancellation after readiness releases only its attempt', () async {
    final releases = <int>[];
    var call = 0;
    final service = BeamPlayService(
      torrent: (_, season, episode, cancel) async {
        final owner = ++call;
        unawaited(
          cancel.whenCancelled.then((_) {
            releases.add(owner);
          }),
        );
        return result(BeamPlayWinner.torrent);
      },
    );
    final old = BeamCancellation();
    final fresh = BeamCancellation();
    await service.race(source(), rdEnabled: false, torrentEnabled: true, season: 1, episode: 1, cancellation: old);
    await service.race(source(), rdEnabled: false, torrentEnabled: true, season: 1, episode: 2, cancellation: fresh);
    old.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(releases, [1]);
    fresh.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(releases, [1, 2]);
  });
  test('RD cancelled during metadata cannot select late response', () async {
    final token = BeamCancellation();
    final metadata = Completer<http.Response>();
    final client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'test',
      httpClient: MockClient((r) async {
        if (r.url.path.endsWith('/addMagnet')) {
          return json({'id': 'test'}, 201);
        }
        if (r.url.path.endsWith('/info/test')) {
          token.cancel();
          return metadata.future;
        }
        fail('Cancelled operation advanced to ${r.url}');
      }),
    );
    final resolve = client.resolveMagnet('magnet:fixture', season: 1, episode: 2, cancellation: token);
    metadata.complete(json({'status': 'waiting_files_selection', 'files': files}));
    await expectLater(resolve, throwsA(isA<BeamCancelled>()));
  });
}
