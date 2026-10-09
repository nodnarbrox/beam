import 'package:plezy/services/beam/rd_request_coordinator.dart';
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);

class _Fixture {
  _Fixture(this.time, {this.adopted = false}) {
    client = RealDebridClient(
      coordinator: RdRequestCoordinator(minSpacing: Duration.zero, minimumCooldown: Duration.zero),
      tokenProvider: () async => 'fixture',
      now: () => DateTime(2026).add(time.elapsed),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/torrents')) {
          return _json(
            adopted
                ? [
                    {'id': 'existing', 'hash': 'hash', 'status': 'downloading'},
                  ]
                : [],
          );
        }
        if (request.url.path.endsWith('/addMagnet')) return _json({'id': 'fresh'}, 201);
        if (request.url.path.contains('/info/')) return onInfo(request.url.path.split('/').last);
        if (request.url.path.contains('/selectFiles/')) {
          selections.add(request.bodyFields['files']!);
          return http.Response('', 204);
        }
        if (request.url.path.contains('/delete/')) return http.Response('', 204);
        if (request.url.path.endsWith('/unrestrict/link')) {
          return _json({'filename': 'Pioneer.One.S01E02.mp4', 'download': 'https://fixture/e02.mp4'});
        }
        throw StateError('Unexpected fixture request');
      }),
    );
  }
  final FakeAsync time;
  final bool adopted;
  final paths = <String>[];
  final selections = <String>[];
  late final RealDebridClient client;
  late FutureOr<http.Response> Function(String id) onInfo;
  RdResolveResult? result;
  Object? error;
  int get adds => paths.where((path) => path.endsWith('/addMagnet')).length;
  int get deletes => paths.where((path) => path.contains('/delete/')).length;
  void start({Duration maxWait = const Duration(minutes: 30), BeamCancellation? cancellation, bool tv = false}) {
    client
        .resolveMagnetSmart(
          'magnet:fixture',
          infoHash: 'hash',
          maxWait: maxWait,
          cancellation: cancellation,
          season: tv ? 1 : null,
          episode: tv ? 2 : null,
        )
        .then(
          (value) {
            result = value;
          },
          onError: (Object value) {
            error = value;
          },
        );
    time.flushMicrotasks();
  }
}

const _files = [
  {'id': 1, 'path': 'Pioneer.One.S01E01.mp4', 'bytes': 200, 'selected': 1},
  {'id': 2, 'path': 'Pioneer.One.S01E02.mp4', 'bytes': 100, 'selected': 0},
];

void main() {
  for (final readyWinner in BeamPlayWinner.values) {
    test('deferred ${readyWinner.name} URL waits for first-frame commit before stopping loser', () async {
      final tokens = <BeamPlayWinner, BeamCancellation>{};
      final late = Completer<BeamPlayResult>();
      Future<BeamPlayResult> leg(BeamPlayWinner kind, BeamCancellation token) {
        tokens[kind] = token;
        return kind == readyWinner
            ? Future.value(
                BeamPlayResult(
                  url: 'https://fixture/video',
                  winner: kind,
                  magnet: 'magnet:fixture',
                  selectedFilename: '${kind.name}/Pioneer.One.S01E01-E02.mp4',
                ),
              )
            : token.bind(late.future);
      }

      final source = ProwlarrResult.fromJson({'title': 'fixture', 'guid': 'magnet:?xt=urn:btih:fixture'});
      final playback = await BeamPlayService(
        realDebrid: (_, _, _, token) => leg(BeamPlayWinner.realDebrid, token),
        torrent: (_, _, _, token) => leg(BeamPlayWinner.torrent, token),
      ).race(source, rdEnabled: true, torrentEnabled: true, deferLoserCancellation: true);
      expect(playback.selectedFilename, '${readyWinner.name}/Pioneer.One.S01E01-E02.mp4');
      expect(tokens.values.every((token) => !token.isCancelled), isTrue);
      playback.commitPlayback();
      playback.commitPlayback();
      expect(tokens[readyWinner]!.isCancelled, isFalse);
      expect(tokens.entries.where((entry) => entry.key != readyWinner).single.value.isCancelled, isTrue);
      late.completeError(StateError('late loser error must be consumed'));
      await Future<void>.delayed(Duration.zero);
      playback.cancel();
      playback.commitPlayback();
      expect(playback.selectedFilename, '${readyWinner.name}/Pioneer.One.S01E01-E02.mp4');
      expect(tokens.values.every((token) => token.isCancelled), isTrue);
    });
  }

  test('closing or failing before first frame cancels both and late commit cannot revive either', () async {
    final tokens = <BeamCancellation>[];
    final ready = BeamPlayResult(
      url: 'https://fixture/video',
      winner: BeamPlayWinner.realDebrid,
      magnet: 'magnet:fixture',
    );
    final source = ProwlarrResult.fromJson({'title': 'fixture', 'guid': 'magnet:?xt=urn:btih:fixture'});
    final playback = await BeamPlayService(
      realDebrid: (_, _, _, token) async {
        tokens.add(token);
        return ready;
      },
      torrent: (_, _, _, token) {
        tokens.add(token);
        return token.bind(Completer<BeamPlayResult>().future);
      },
    ).race(source, rdEnabled: true, torrentEnabled: true, deferLoserCancellation: true);
    expect(tokens.every((token) => !token.isCancelled), isTrue);
    playback.cancel();
    playback.commitPlayback();
    playback.cancel();
    expect(tokens.every((token) => token.isCancelled), isTrue);
  });

  test('Back after URL but before first frame still cancels both deferred paths', () async {
    final parent = BeamCancellation();
    final tokens = <BeamCancellation>[];
    final source = ProwlarrResult.fromJson({'title': 'fixture', 'guid': 'magnet:?xt=urn:btih:fixture'});
    final playback = await BeamPlayService(
      realDebrid: (_, _, _, token) async {
        tokens.add(token);
        return BeamPlayResult(
          url: 'https://fixture/video',
          winner: BeamPlayWinner.realDebrid,
          magnet: 'magnet:fixture',
        );
      },
      torrent: (_, _, _, token) {
        tokens.add(token);
        return token.bind(Completer<BeamPlayResult>().future);
      },
    ).race(source, rdEnabled: true, torrentEnabled: true, deferLoserCancellation: true, cancellation: parent);
    parent.cancel();
    await Future<void>.delayed(Duration.zero);
    playback.commitPlayback();
    expect(tokens.every((token) => token.isCancelled), isTrue);
  });

  test('progressing uncached RD cannot block native winner and its polling stops', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      var polls = 0;
      fixture.onInfo = (_) {
        polls++;
        return _json({'status': 'downloading', 'progress': time.elapsed.inSeconds / 3});
      };
      final native = Completer<BeamPlayResult>();
      BeamCancellation? rdToken;
      Object? rdError;
      BeamPlayResult? winner;
      var handoffs = 0;
      final source = ProwlarrResult.fromJson({'title': 'fixture', 'guid': 'magnet:?xt=urn:btih:fixture'});
      BeamPlayService(
        realDebrid: (_, _, _, cancellation) async {
          rdToken = cancellation;
          try {
            final resolved = await fixture.client.resolveMagnet('magnet:fixture', cancellation: cancellation);
            return BeamPlayResult(
              url: resolved.primaryVideo!.downloadUrl,
              winner: BeamPlayWinner.realDebrid,
              magnet: 'magnet:fixture',
            );
          } catch (error) {
            rdError = error;
            rethrow;
          }
        },
        torrent: (_, _, _, _) => native.future,
      ).race(source, rdEnabled: true, torrentEnabled: true).then((value) {
        winner = value;
        handoffs++;
      });
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 130));
      expect(winner, isNull);
      native.complete(
        BeamPlayResult(url: 'http://127.0.0.1/video', winner: BeamPlayWinner.torrent, magnet: 'magnet:fixture'),
      );
      time.flushMicrotasks();
      expect(winner?.winner, BeamPlayWinner.torrent);
      expect(rdToken?.isCancelled, isTrue);
      expect(rdError, isA<BeamCancelled>());
      final pollsAtWin = polls;
      time.elapse(const Duration(minutes: 3));
      expect(polls, pollsAtWin);
      expect(fixture.deletes, 0);
      expect(handoffs, 1);
    });
  });

  test('RD winner cancels native resolver while leaving winning RD token active', () async {
    BeamCancellation? rdToken;
    BeamCancellation? nativeToken;
    final pending = Completer<BeamPlayResult>();
    final source = ProwlarrResult.fromJson({'title': 'fixture', 'guid': 'magnet:?xt=urn:btih:fixture'});
    final winner = await BeamPlayService(
      realDebrid: (_, _, _, token) async {
        rdToken = token;
        return BeamPlayResult(
          url: 'https://fixture/video',
          winner: BeamPlayWinner.realDebrid,
          magnet: 'magnet:fixture',
        );
      },
      torrent: (_, _, _, token) {
        nativeToken = token;
        return token.bind(pending.future);
      },
    ).race(source, rdEnabled: true, torrentEnabled: true);
    expect(winner.winner, BeamPlayWinner.realDebrid);
    expect(rdToken?.isCancelled, isFalse);
    expect(nativeToken?.isCancelled, isTrue);
  });

  for (final adopted in [false, true]) {
    test('${adopted ? "adopted" : "fresh"} RD download can progress beyond old 120-second limit', () {
      fakeAsync((time) {
        final fixture = _Fixture(time, adopted: adopted);
        fixture.onInfo = (_) => _json(
          time.elapsed.inSeconds >= 240
              ? {
                  'status': 'downloaded',
                  'links': ['rd-e02'],
                }
              : {'status': 'downloading', 'progress': time.elapsed.inSeconds / 3},
        );
        fixture.start();
        time.elapse(const Duration(seconds: 180));
        expect(fixture.error, isNull);
        expect(fixture.result, isNull);
        time.elapse(const Duration(seconds: 60));
        expect(fixture.result?.primaryVideo?.downloadUrl, 'https://fixture/e02.mp4');
        expect(fixture.adds, adopted ? 0 : 1);
        expect(fixture.deletes, 0);
      });
    });
  }

  test('forward upload progress can advance beyond 120 seconds after download reached 100', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.onInfo = (_) => _json(
        time.elapsed.inSeconds == 0
            ? {'status': 'downloading', 'progress': 100}
            : time.elapsed.inSeconds >= 240
            ? {
                'status': 'downloaded',
                'links': ['rd-e02'],
              }
            : {'status': 'uploading', 'progress': time.elapsed.inSeconds / 3},
      );
      fixture.start();
      time.elapse(const Duration(seconds: 180));
      expect(fixture.error, isNull);
      expect(fixture.result, isNull);
      time.elapse(const Duration(seconds: 60));
      expect(fixture.result?.primaryVideo?.downloadUrl, 'https://fixture/e02.mp4');
      expect(fixture.adds, 1);
    });
  });

  test('backward processing phases cannot reset later phase progress or idle budget', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.onInfo = (_) => _json(
        time.elapsed.inSeconds % 4 == 0
            ? {'status': 'downloading', 'progress': 100}
            : {'status': 'uploading', 'progress': 10},
      );
      fixture.start();
      time.elapse(const Duration(seconds: 122));
      expect(fixture.error, isA<RdException>().having((e) => e.message, 'message', contains('stopped progressing')));
      expect(fixture.adds, 1);
      expect(fixture.deletes, 0);
    });
  });

  test('adopted stalled download fails once without duplicate add or deletion', () {
    fakeAsync((time) {
      final fixture = _Fixture(time, adopted: true);
      fixture.onInfo = (_) => _json({'status': 'downloading', 'progress': 24});
      fixture.start();
      time.elapse(const Duration(seconds: 120));
      expect(fixture.error, isA<RdException>().having((e) => e.code, 'code', 408));
      expect(fixture.adds, 0);
      expect(fixture.deletes, 0);
    });
  });

  test('regressing progress and status oscillation cannot renew idle budget', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.onInfo = (_) => _json({
        'status': time.elapsed.inSeconds % 4 == 0 ? 'downloading' : 'queued',
        'progress': time.elapsed.inSeconds % 4 == 0 ? 20 : 10,
      });
      fixture.start();
      time.elapse(const Duration(seconds: 120));
      expect(fixture.error, isA<RdException>());
      expect(fixture.adds, 1);
      expect(fixture.deletes, 0);
    });
  });

  test('advancing download still obeys finite total wait limit', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.onInfo = (_) => _json({'status': 'downloading', 'progress': time.elapsed.inSeconds / 100});
      fixture.start(maxWait: const Duration(minutes: 3));
      time.elapse(const Duration(minutes: 3));
      expect(fixture.error, isA<RdException>().having((e) => e.message, 'message', contains('wait limit')));
      expect(fixture.adds, 1);
      expect(fixture.deletes, 0);
    });
  });

  test('adopted info failure propagates without duplicate add', () {
    fakeAsync((time) {
      final fixture = _Fixture(time, adopted: true);
      fixture.onInfo = (_) => _json({'error': 'unavailable'}, 503);
      fixture.start();
      expect(fixture.error, isA<RdException>().having((e) => e.code, 'code', 503));
      expect(fixture.adds, 0);
      expect(fixture.deletes, 0);
    });
  });

  test('adopted wrong episode starts requested selection immediately and preserves old job', () {
    fakeAsync((time) {
      final fixture = _Fixture(time, adopted: true);
      fixture.onInfo = (id) => _json(
        id == 'existing'
            ? {'status': 'downloading', 'progress': 15, 'files': _files}
            : fixture.selections.isEmpty
            ? {'status': 'waiting_files_selection', 'files': _files}
            : {
                'status': 'downloaded',
                'files': [
                  {..._files[0], 'selected': 0},
                  {..._files[1], 'selected': 1},
                ],
                'links': ['rd-e02'],
              },
      );
      fixture.start(tv: true);
      expect(fixture.adds, 1);
      expect(fixture.selections, ['2']);
      time.elapse(const Duration(seconds: 2));
      expect(fixture.result?.primaryVideo?.downloadUrl, 'https://fixture/e02.mp4');
      expect(fixture.deletes, 0);
    });
  });

  test('Back cancellation ends pending info immediately and late data cannot select files', () {
    fakeAsync((time) {
      final fixture = _Fixture(time, adopted: true);
      final pending = Completer<http.Response>();
      fixture.onInfo = (_) => pending.future;
      final cancellation = BeamCancellation();
      fixture.start(cancellation: cancellation, tv: true);
      cancellation.cancel();
      time.flushMicrotasks();
      expect(fixture.error, isA<BeamCancelled>());
      pending.complete(_json({'status': 'waiting_files_selection', 'files': _files}));
      time.flushMicrotasks();
      expect(fixture.selections, isEmpty);
      expect(fixture.adds, 0);
      expect(fixture.deletes, 0);
    });
  });

  test('explicit cachedOnly diagnostics still reject and remove their uncached new job', () {
    fakeAsync((time) {
      final fixture = _Fixture(time);
      fixture.onInfo = (_) => _json({'status': 'downloading', 'progress': 5});
      fixture.client
          .resolveMagnet('magnet:fixture', cachedOnly: true)
          .then(
            (value) {
              fixture.result = value;
            },
            onError: (Object value) {
              fixture.error = value;
            },
          );
      time.flushMicrotasks();
      expect(fixture.error, isA<RdException>().having((e) => e.code, 'code', 408));
      expect(fixture.adds, 1);
      expect(fixture.deletes, 1);
    });
  });
}
