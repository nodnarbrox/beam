import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

const _files = [
  FileInfo(index: 0, name: 'Pioneer.One.S01E01.mp4', path: 'Pioneer.One.S01E01.mp4', size: 1000000, isStreamable: true),
];

class _Engine implements LibtorrentFlutter {
  @override
  final Map<int, TorrentInfo> torrents = {};
  @override
  final Map<int, StreamInfo> streams = {};
  // Closed by service.dispose in every fake-clock test.
  // ignore: close_sinks
  final updates = StreamController<Map<int, StreamInfo>>.broadcast(sync: true);
  @override
  Stream<Map<int, StreamInfo>> get streamUpdates => updates.stream;
  List<FileInfo> files = [];
  int adds = 0;
  int starts = 0;

  void peers(int peers, int seeds) {
    torrents[1] = TorrentInfo(
      id: 1,
      name: 'Pioneer One',
      savePath: '',
      errorMsg: '',
      state: TorrentState.downloading,
      progress: 0,
      downloadRate: 0,
      uploadRate: 0,
      totalDone: 0,
      totalWanted: 1000000,
      totalUploaded: 0,
      numPeers: peers,
      numSeeds: seeds,
      isPaused: false,
      isFinished: false,
      hasMetadata: files.isNotEmpty,
      queuePosition: 0,
    );
  }

  @override
  int addMagnet(String magnetUri, [String? savePath, bool streamOnly = false]) {
    adds++;
    peers(0, 0);
    return 1;
  }

  @override
  List<FileInfo> getFiles(int torrentId) => files;

  void buffer(double seconds) {
    streams[101] = StreamInfo(
      id: 101,
      torrentId: 1,
      fileIndex: 0,
      url: 'http://127.0.0.1:8191/stream/101',
      fileSize: 1000000,
      readHead: 0,
      streamState: StreamState.buffering,
      bufferSeconds: seconds,
      bufferPieces: 1,
      readaheadWindow: 5,
      activePeers: 2,
      downloadRate: 1000000,
    );
  }

  @override
  StreamInfo startStream(int torrentId, {int fileIndex = -1, int maxCacheBytes = 0}) {
    starts++;
    buffer(0);
    return streams[101]!;
  }

  @override
  void stopAllStreamsForTorrent(int torrentId) => streams.clear();
  @override
  void removeTorrent(int id, {bool deleteFiles = false}) => torrents.remove(id);
  @override
  Future<void> dispose() => updates.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TorrentStreamService _service(_Engine engine, {Future<void> Function()? privacyCheck, bool udp = true}) =>
    TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: privacyCheck ?? () async {},
      udpProbe: () async => udp,
    );

void main() {
  test('reports real preparation stages and peer changes without announcing premature readiness', () {
    fakeAsync((clock) {
      final engine = _Engine();
      final privacy = Completer<void>();
      final service = _service(engine, privacyCheck: () => privacy.future);
      final statuses = <String>[];
      String? url;
      unawaited(
        service
            .streamMagnet('magnet:fixture', season: 1, episode: 1, onPreparationStatus: statuses.add)
            .then((value) => url = value),
      );
      clock.flushMicrotasks();
      expect(statuses, ['Checking torrent connection']);
      expect(engine.adds, 0);
      privacy.complete();
      clock.flushMicrotasks();
      expect(statuses, [
        'Checking torrent connection',
        'Starting torrent engine',
        'Checking tracker connectivity',
        'Finding peers · 0 peers · 0 seeds',
      ]);
      clock.elapse(const Duration(seconds: 1));
      expect(statuses, hasLength(4), reason: 'Unchanged metadata polling must not flood the UI.');
      engine.peers(3, 1);
      clock.elapse(const Duration(milliseconds: 500));
      expect(statuses.last, 'Downloading torrent metadata · 3 peers · 1 seeds');
      expect(engine.starts, 0);
      expect(url, isNull);
      engine.files = _files;
      clock.elapse(const Duration(milliseconds: 500));
      expect(statuses.sublist(statuses.length - 2), ['Verifying requested episode', 'Buffering video']);
      expect(engine.starts, 1);
      expect(url, isNull);
      engine.buffer(19);
      clock.elapse(const Duration(milliseconds: 100));
      expect(url, isNull);
      engine.buffer(20);
      clock.elapse(const Duration(milliseconds: 100));
      expect(url, 'http://127.0.0.1:8191/stream/101');
      service.dispose();
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('TCP discovery is visible and cancelled metadata cannot publish late verification', () {
    fakeAsync((clock) {
      final engine = _Engine();
      final service = _service(engine, udp: false);
      final cancellation = BeamCancellation();
      final statuses = <String>[];
      Object? failure;
      unawaited(
        service
            .streamMagnet('magnet:fixture', onPreparationStatus: statuses.add, cancellation: cancellation)
            .then<void>(
              (_) => fail('Cancelled source became ready'),
              onError: (Object error) {
                failure = error;
              },
            ),
      );
      clock.flushMicrotasks();
      expect(statuses.last, 'Finding peers via HTTP trackers · 0 peers · 0 seeds');
      final beforeCancel = List<String>.of(statuses);
      cancellation.cancel();
      engine.files = _files;
      clock.elapse(const Duration(seconds: 1));
      expect(failure, isNotNull);
      expect(statuses, beforeCancel);
      expect(engine.starts, 0);
      expect(engine.torrents, isEmpty);
      service.dispose();
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('cancelling a pending connection check suppresses late engine and metadata stages', () {
    fakeAsync((clock) {
      final engine = _Engine();
      final privacy = Completer<void>();
      final service = _service(engine, privacyCheck: () => privacy.future);
      final cancellation = BeamCancellation();
      final statuses = <String>[];
      Object? failure;
      unawaited(
        service
            .streamMagnet('magnet:fixture', onPreparationStatus: statuses.add, cancellation: cancellation)
            .then<void>(
              (_) => fail('Cancelled source became ready'),
              onError: (Object error) {
                failure = error;
              },
            ),
      );
      clock.flushMicrotasks();
      cancellation.cancel();
      privacy.complete();
      clock.flushMicrotasks();
      expect(failure, isA<BeamCancelled>());
      expect(statuses, ['Checking torrent connection']);
      expect(engine.adds, 0);
      service.dispose();
      clock.flushMicrotasks();
    });
  });

  test('wrong episode reports verification then fails without claiming buffering', () {
    fakeAsync((clock) {
      final engine = _Engine()..files = _files;
      final service = _service(engine);
      final statuses = <String>[];
      Object? failure;
      unawaited(
        service
            .streamMagnet('magnet:fixture', season: 1, episode: 2, onPreparationStatus: statuses.add)
            .then<void>(
              (_) => fail('Wrong episode became ready'),
              onError: (Object error) {
                failure = error;
              },
            ),
      );
      clock.flushMicrotasks();
      expect(failure, isNotNull);
      expect(statuses.last, 'Verifying requested episode');
      expect(statuses, isNot(contains('Buffering video')));
      expect(engine.starts, 0);
      expect(engine.torrents, isEmpty);
      service.dispose();
      clock.flushMicrotasks();
    });
  });
}
