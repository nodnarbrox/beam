import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_buffer_wait.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/beam_playback_duration.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

class _Engine implements LibtorrentFlutter {
  @override
  final Map<int, TorrentInfo> torrents = {};
  @override
  final Map<int, StreamInfo> streams = {};
  final updates = StreamController<Map<int, StreamInfo>>.broadcast(sync: true);
  @override
  Stream<Map<int, StreamInfo>> get streamUpdates => updates.stream;
  bool metadataReady = false;
  int adds = 0;
  int removes = 0;
  final appliedDurations = <(int, int)>[];

  @override
  bool setStreamDuration(int streamId, int durationMs) {
    appliedDurations.add((streamId, durationMs));
    return true;
  }

  @override
  int addMagnet(String magnetUri, [String? savePath, bool streamOnly = false]) => ++adds;

  @override
  List<FileInfo> getFiles(int torrentId) => metadataReady
      ? const [
          FileInfo(
            index: 0,
            name: 'Pioneer.One.S01E02.mp4',
            path: 'Pioneer.One.S01E02.mp4',
            size: 1000000,
            isStreamable: true,
          ),
        ]
      : const [];

  StreamInfo _info(double buffer) => StreamInfo(
    id: 100,
    torrentId: 1,
    fileIndex: 0,
    url: 'http://127.0.0.1/fixture',
    fileSize: 1000000,
    readHead: 0,
    streamState: StreamState.buffering,
    bufferSeconds: buffer,
    bufferPieces: 0,
    readaheadWindow: 5,
    activePeers: 5,
    downloadRate: 1000000,
  );

  @override
  StreamInfo startStream(int torrentId, {int fileIndex = -1, int maxCacheBytes = 0}) {
    final info = _info(0);
    streams[info.id] = info;
    return info;
  }

  void buffer(double seconds) {
    final info = _info(seconds);
    streams[info.id] = info;
    updates.add({info.id: info});
  }

  void downloaded(int bytes, {int rate = 1000000}) {
    torrents[1] = TorrentInfo(
      id: 1,
      name: 'Pioneer One',
      savePath: '',
      errorMsg: '',
      state: TorrentState.downloading,
      progress: bytes / 1000000,
      downloadRate: rate,
      uploadRate: 0,
      totalDone: bytes,
      totalWanted: 1000000,
      totalUploaded: 0,
      numPeers: 2,
      numSeeds: 1,
      isPaused: false,
      isFinished: false,
      hasMetadata: true,
      queuePosition: 0,
    );
    buffer(streams[100]?.bufferSeconds ?? 0);
  }

  @override
  void stopAllStreamsForTorrent(int torrentId) => streams.clear();
  @override
  void stopStream(int streamId) => streams.remove(streamId);
  @override
  void removeTorrent(int id, {bool deleteFiles = false}) {
    expect(deleteFiles, isTrue);
    removes++;
    torrents.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Attempt {
  _Attempt({
    Future<void> Function()? privacyCheck,
    BeamPlaybackDuration? playbackDuration,
    BeamBufferWait? onBufferWait,
    DateTime Function()? now,
    BeamTransportResolver? realDebrid,
    bool deferLoserCancellation = false,
  }) {
    final native = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: privacyCheck ?? () async {},
      udpProbe: () async => false,
    );
    final service = BeamPlayService(torrentStreamService: native, now: now, realDebrid: realDebrid);
    service
        .race(
          ProwlarrResult.fromJson({
            'title': 'Pioneer.One.S01E02',
            'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
            'seeders': 5,
          }),
          rdEnabled: realDebrid != null,
          torrentEnabled: true,
          season: 1,
          episode: 2,
          torrentStall: const Duration(seconds: 30),
          playbackDuration: playbackDuration,
          onBufferWait: onBufferWait,
          deferLoserCancellation: deferLoserCancellation,
          cancellation: cancellation,
        )
        .then<void>(
          (value) {
            result = value;
          },
          onError: (Object value) {
            error = value;
          },
        );
  }

  final engine = _Engine();
  final cancellation = BeamCancellation();
  BeamPlayResult? result;
  Object? error;

  void close(FakeAsync time) {
    cancellation.cancel();
    time.flushMicrotasks();
    time.elapse(const Duration(seconds: 1));
    unawaited(engine.updates.close());
    time.flushMicrotasks();
    expect(time.nonPeriodicTimerCount, 0);
  }
}

void main() {
  for (final longWait in [false, true]) {
    test('measured ${longWait ? "13-minute" : "80-second"} wait survives shorter idle and preparation limits', () {
      fakeAsync((time) {
        final answers = <Completer<bool>>[];
        final offers = <BeamBufferWaitOffer>[];
        final attempt = _Attempt(
          now: time.getClock(DateTime(2026)).now,
          onBufferWait: (offer) {
            offers.add(offer);
            final answer = Completer<bool>();
            answers.add(answer);
            return answer.future;
          },
        );
        attempt.engine.metadataReady = true;
        time.flushMicrotasks();
        final scale = longWait ? 0.125 : 1.0;
        time.elapse(const Duration(seconds: 5));
        attempt.engine.buffer(scale);
        time.elapse(const Duration(seconds: 5));
        attempt.engine.buffer(2 * scale);
        time.elapse(const Duration(seconds: 10));
        attempt.engine.buffer(4 * scale);
        time.elapse(const Duration(seconds: 10));
        expect(offers.single.estimatedWait, Duration(seconds: longWait ? 780 : 80));
        answers.single.complete(true);
        time.flushMicrotasks();
        time.elapse(Duration(seconds: longWait ? 600 : 60));
        expect(attempt.error, isNull);
        expect(offers, hasLength(1));
        time.elapse(Duration(seconds: longWait ? 211 : 61));
        expect(attempt.error, isNull);
        expect(offers, hasLength(2)); // Reoffer when the accepted runway expires.
        attempt.engine.buffer(21);
        time.elapse(const Duration(milliseconds: 100));
        expect(attempt.result, isNotNull);
        attempt.close(time);
      });
    });
  }

  test('slow offer stays pending beyond initial timeout without blocking native readiness', () {
    fakeAsync((time) {
      final answer = Completer<bool>();
      final offers = <BeamBufferWaitOffer>[];
      var done = false;
      final attempt = _Attempt(
        now: time.getClock(DateTime(2026)).now,
        onBufferWait: (offer) {
          offers.add(offer);
          offer.done.then((_) => done = true);
          return answer.future;
        },
      );
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 30));
      expect(offers, hasLength(1));
      expect(offers.single.reason, BeamBufferWaitReason.slow);
      expect(offers.single.estimatedWait, isNull);
      time.elapse(const Duration(seconds: 100));
      expect(attempt.error, isNull);
      expect(offers, hasLength(1));
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result?.winner, BeamPlayWinner.torrent);
      expect(done, isTrue);
      answer.complete(false); // An obsolete dialog cannot cancel a ready source.
      time.flushMicrotasks();
      expect(attempt.engine.removes, 0);
      attempt.close(time);
    });
  });

  test('explicit wait renews initial deadline and idle budget from the answer', () {
    fakeAsync((time) {
      final answers = <Completer<bool>>[];
      final attempt = _Attempt(
        now: time.getClock(DateTime(2026)).now,
        onBufferWait: (_) {
          final answer = Completer<bool>();
          answers.add(answer);
          return answer.future;
        },
      );
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 110));
      expect(answers, hasLength(1));
      answers.single.complete(true);
      time.flushMicrotasks();
      for (var n = 1; n <= 5; n++) {
        time.elapse(const Duration(seconds: 20));
        attempt.engine.buffer(n.toDouble());
      }
      expect(attempt.error, isNull);
      expect(answers, hasLength(1)); // Original120s deadline was renewed.
      time.elapse(const Duration(seconds: 21));
      expect(answers, hasLength(2)); // Renewed120s deadline offers another choice.
      answers.last.complete(true);
      time.flushMicrotasks();
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result, isNotNull);
      attempt.close(time);
    });
  });

  test('Back interrupts an unanswered offer and cleans up its torrent', () {
    fakeAsync((time) {
      final answer = Completer<bool>();
      var done = false;
      final attempt = _Attempt(
        onBufferWait: (offer) {
          offer.done.then((_) => done = true);
          return answer.future;
        },
      );
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 30));
      attempt.cancellation.cancel();
      time.flushMicrotasks();
      expect(attempt.error, isA<BeamCancelled>());
      expect(done, isTrue);
      expect(attempt.engine.removes, greaterThanOrEqualTo(1));
      answer.complete(true);
      time.flushMicrotasks();
      expect(attempt.result, isNull);
      attempt.close(time);
    });
  });

  test('RD can win during a native wait offer and native lives until first frame', () {
    fakeAsync((time) {
      final rd = Completer<BeamPlayResult>();
      final answer = Completer<bool>();
      var done = false;
      final attempt = _Attempt(
        realDebrid: (_, _, _, _) => rd.future,
        deferLoserCancellation: true,
        onBufferWait: (offer) {
          offer.done.then((_) => done = true);
          return answer.future;
        },
      );
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 30));
      rd.complete(BeamPlayResult(url: 'https://fixture/rd', winner: BeamPlayWinner.realDebrid, magnet: 'fixture'));
      time.flushMicrotasks();
      expect(attempt.result?.winner, BeamPlayWinner.realDebrid);
      expect(attempt.engine.removes, 0);
      expect(done, isFalse);
      attempt.result!.commitPlayback();
      time.flushMicrotasks();
      expect(done, isTrue);
      expect(attempt.engine.removes, greaterThanOrEqualTo(1));
      attempt.close(time);
    });
  });

  test('renewed preparation deadline defers to an unanswered buffering choice', () {
    fakeAsync((time) {
      final answers = <Completer<bool>>[];
      final attempt = _Attempt(
        onBufferWait: (_) {
          final answer = Completer<bool>();
          answers.add(answer);
          return answer.future;
        },
      );
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 8));
      answers.single.complete(true);
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 2));
      expect(attempt.error, isNull); // The original9min limit was renewed.
      time.elapse(const Duration(minutes: 7));
      expect(attempt.error, isNull);
      expect(answers, hasLength(2));
      attempt.engine.buffer(21); // Readiness also beats the still-open choice.
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result?.winner, BeamPlayWinner.torrent);
      attempt.close(time);
    });
  });

  test('unanswered slow-buffer prompt survives nine minutes then Keep buffering permits playback', () {
    fakeAsync((time) {
      final answer = Completer<bool>();
      var offers = 0;
      final attempt = _Attempt(
        now: time.getClock(DateTime(2026)).now,
        onBufferWait: (_) {
          offers++;
          return answer.future;
        },
      );
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 10));
      expect(offers, 1);
      expect(attempt.error, isNull);
      expect(attempt.engine.removes, 0);
      answer.complete(true);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 60));
      expect(attempt.error, isNull);
      expect(offers, 1);
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result?.winner, BeamPlayWinner.torrent);
      attempt.close(time);
    });
  });

  test('actual race forwards known runtime into native preparation', () {
    fakeAsync((time) {
      final attempt = _Attempt(playbackDuration: const BeamPlaybackDuration(durationMs: 2400000));
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      expect(attempt.engine.appliedDurations, [(100, 2400000)]);
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result?.winner, BeamPlayWinner.torrent);
      attempt.close(time);
    });
  });

  test('both failed legs retain original RD account error and its stack', () async {
    final rd = Completer<BeamPlayResult>();
    final native = Completer<BeamPlayResult>();
    final original = RdException('fixture account failure', code: 401);
    final originalStack = StackTrace.fromString('original RD request stack');
    final service = BeamPlayService(realDebrid: (_, _, _, _) => rd.future, torrent: (_, _, _, _) => native.future);
    final result = service.race(
      ProwlarrResult.fromJson({
        'title': 'Pioneer.One.S01E02',
        'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
      }),
      rdEnabled: true,
      torrentEnabled: true,
    );
    final checked = result.then<void>(
      (_) => fail('both transports failed'),
      onError: (Object error, StackTrace stack) {
        expect(identical(error, original), isTrue);
        expect((error as RdException).code, 401);
        expect(stack.toString(), originalStack.toString());
      },
    );
    rd.completeError(original, originalStack);
    await Future<void>.delayed(Duration.zero);
    native.completeError(TimeoutException('native stalled'), StackTrace.fromString('native request stack'));
    await checked;
  });

  test('31 seconds waiting for metadata does not consume the buffer stall budget', () {
    fakeAsync((time) {
      final attempt = _Attempt();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 31));
      expect(attempt.engine.adds, 1);
      expect(attempt.engine.streams, isEmpty);
      expect(attempt.error, isNull);
      expect(attempt.engine.removes, 0);
      attempt.engine.metadataReady = true;
      time.elapse(const Duration(milliseconds: 500));
      expect(attempt.engine.streams, isNotEmpty);
      time.elapse(const Duration(seconds: 29));
      expect(attempt.error, isNull);
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result?.winner, BeamPlayWinner.torrent);
      expect(attempt.result?.selectedFilename, 'Pioneer.One.S01E02.mp4');
      expect(attempt.error, isNull);
      attempt.close(time);
    });
  });

  test('real buffer growth resets the idle deadline and permits playback', () {
    fakeAsync((time) {
      final attempt = _Attempt();
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 25));
      attempt.engine.buffer(3);
      time.elapse(const Duration(seconds: 25));
      expect(attempt.error, isNull);
      expect(attempt.engine.removes, 0);
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result, isNotNull);
      attempt.close(time);
    });
  });

  for (final committed in [false, true]) {
    test('buffer telemetry after handoff cannot rearm preparation timeout (committed=$committed)', () {
      fakeAsync((time) {
        final attempt = _Attempt();
        attempt.engine.metadataReady = true;
        time.flushMicrotasks();
        attempt.engine.buffer(21);
        time.elapse(const Duration(milliseconds: 100));
        expect(attempt.result, isNotNull);
        if (committed) attempt.result!.commitPlayback();
        attempt.engine.buffer(25);
        attempt.engine.downloaded(1000);
        time.elapse(const Duration(seconds: 31));
        expect(
          attempt.engine.removes,
          0,
          reason: 'the resolved winner belongs to the player, including before first frame',
        );
        expect(attempt.engine.streams, isNotEmpty);
        expect(attempt.error, isNull);
        attempt.result!.cancel();
        time.flushMicrotasks();
        expect(attempt.engine.removes, 1);
        attempt.close(time);
      });
    });
  }

  test('zero first-piece progress remains bounded by native 120-second preparation', () {
    fakeAsync((time) {
      final attempt = _Attempt();
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      for (var second = 0; second < 119; second++) {
        time.elapse(const Duration(seconds: 1));
        attempt.engine.buffer(0);
      }
      expect(attempt.error, isNull);
      time.elapse(const Duration(seconds: 2));
      expect(attempt.result, isNull);
      expect(attempt.error, isA<TimeoutException>());
      expect(attempt.engine.removes, 1);
      expect(attempt.engine.streams, isEmpty);
      attempt.close(time);
    });
  });

  test('first verified progress at 45 seconds permits a ready buffer at 55 seconds', () {
    fakeAsync((time) {
      final attempt = _Attempt();
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 45));
      expect(attempt.error, isNull);
      expect(attempt.engine.removes, 0);
      attempt.engine.downloaded(1000);
      time.elapse(const Duration(seconds: 10));
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result?.winner, BeamPlayWinner.torrent);
      expect(attempt.error, isNull);
      attempt.close(time);
    });
  });

  test('downloaded bytes advance with zero contiguous buffer and preserve preparation', () {
    fakeAsync((time) {
      final attempt = _Attempt();
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 25));
      attempt.engine.downloaded(1000);
      time.elapse(const Duration(seconds: 25));
      expect(attempt.engine.streams[100]!.bufferSeconds, 0);
      expect(attempt.error, isNull);
      expect(attempt.result, isNull);
      attempt.engine.downloaded(2000);
      time.elapse(const Duration(seconds: 25));
      expect(attempt.engine.removes, 0);
      expect(attempt.error, isNull);
      attempt.engine.buffer(21);
      time.elapse(const Duration(milliseconds: 100));
      expect(attempt.result?.winner, BeamPlayWinner.torrent);
      attempt.close(time);
    });
  });

  test('stale positive rate and unchanged or regressed bytes cannot extend buffer idle', () {
    fakeAsync((time) {
      final attempt = _Attempt();
      attempt.engine.metadataReady = true;
      time.flushMicrotasks();
      attempt.engine.downloaded(1000);
      for (var second = 0; second < 29; second++) {
        time.elapse(const Duration(seconds: 1));
        attempt.engine.downloaded(second.isEven ? 500 : 1000, rate: 224383);
      }
      expect(attempt.error, isNull);
      time.elapse(const Duration(seconds: 2));
      expect(attempt.error, isA<TimeoutException>());
      expect(attempt.result, isNull);
      expect(attempt.engine.removes, 1);
      attempt.close(time);
    });
  });

  test('cancel during metadata wait removes torrent immediately', () {
    fakeAsync((time) {
      final attempt = _Attempt();
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 31));
      attempt.cancellation.cancel();
      time.flushMicrotasks();
      expect(attempt.error, isA<BeamCancelled>());
      expect(attempt.engine.removes, 1);
      attempt.close(time);
    });
  });

  test('setup delay is separate from buffer idle but remains bounded', () {
    fakeAsync((time) {
      final privacy = Completer<void>();
      final attempt = _Attempt(privacyCheck: () => privacy.future);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 31));
      expect(attempt.error, isNull);
      expect(attempt.engine.adds, 0);
      time.elapse(const Duration(minutes: 9));
      expect(attempt.error, isA<TimeoutException>());
      privacy.complete();
      time.flushMicrotasks();
      expect(attempt.engine.adds, 0, reason: 'late setup must not add a cancelled torrent');
      attempt.close(time);
    });
  });
}
