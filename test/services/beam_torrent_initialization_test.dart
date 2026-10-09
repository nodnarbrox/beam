import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

class _Engine implements LibtorrentFlutter {
  @override
  final Map<int, TorrentInfo> torrents = {};
  @override
  final Map<int, StreamInfo> streams = {};
  // Each test owns this controller and registers updates.close with addTearDown.
  // ignore: close_sinks
  final updates = StreamController<Map<int, StreamInfo>>.broadcast(sync: true);
  int listeners = 0;
  int adds = 0;
  int disposals = 0;
  final disposed = Completer<void>();
  @override
  Stream<Map<int, StreamInfo>> get streamUpdates {
    listeners++;
    return updates.stream;
  }

  @override
  int addMagnet(String magnetUri, [String? savePath, bool streamOnly = false]) => ++adds;
  @override
  List<FileInfo> getFiles(int torrentId) => const [
    FileInfo(
      index: 0,
      name: 'Pioneer.One.S01E01.mp4',
      path: 'Pioneer.One.S01E01.mp4',
      size: 1000000,
      isStreamable: true,
    ),
  ];
  @override
  StreamInfo startStream(int torrentId, {int fileIndex = -1, int maxCacheBytes = 0}) {
    final info = StreamInfo(
      id: torrentId + 100,
      torrentId: torrentId,
      fileIndex: fileIndex,
      url: 'http://127.0.0.1:8191/stream/$torrentId',
      fileSize: 1000000,
      readHead: 0,
      streamState: StreamState.buffering,
      bufferSeconds: 21,
      bufferPieces: 5,
      readaheadWindow: 5,
      activePeers: 2,
      downloadRate: 1000000,
    );
    streams[info.id] = info;
    return info;
  }

  @override
  void stopAllStreamsForTorrent(int torrentId) => streams.removeWhere((_, info) => info.torrentId == torrentId);
  @override
  void removeTorrent(int id, {bool deleteFiles = false}) => torrents.remove(id);
  @override
  Future<void> dispose() async {
    disposals++;
    if (!disposed.isCompleted) disposed.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TorrentStreamService _service(Future<LibtorrentFlutter> Function() initialize) => TorrentStreamService.forTesting(
  engineInitializer: initialize,
  privacyCheck: () async {},
  udpProbe: () async => false,
);

void main() {
  test('two cold candidates share setup and one stream subscription', () async {
    final engine = _Engine();
    addTearDown(engine.updates.close);
    final initializing = Completer<LibtorrentFlutter>();
    var calls = 0;
    final service = _service(() {
      calls++;
      return initializing.future;
    });
    final first = service.streamMagnet('magnet:first', season: 1, episode: 1);
    final second = service.streamMagnet('magnet:second', season: 1, episode: 1);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(engine.adds, 0);
    initializing.complete(engine);
    final urls = await Future.wait([first, second]);
    expect(urls.toSet(), hasLength(2));
    expect(engine.adds, 2);
    expect(engine.listeners, 1);
    service.dispose();
    await engine.disposed.future;
    expect(engine.disposals, 1);
  });

  test('one cancelled waiter cannot cancel the other cold candidate', () async {
    final engine = _Engine();
    addTearDown(engine.updates.close);
    final initializing = Completer<LibtorrentFlutter>();
    final service = _service(() => initializing.future);
    final cancellation = BeamCancellation();
    final cancelled = service.streamMagnet('magnet:first', cancellation: cancellation);
    final cancelledCheck = expectLater(cancelled, throwsA(isA<BeamCancelled>()));
    final live = service.streamMagnet('magnet:second');
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    initializing.complete(engine);
    await cancelledCheck;
    expect(await live, contains('/stream/1'));
    expect(engine.adds, 1);
    expect(engine.listeners, 1);
    expect(engine.disposals, 0);
    service.dispose();
    await engine.disposed.future;
  });

  test('shared initialization failure clears the attempt and permits a clean retry', () async {
    final engine = _Engine();
    addTearDown(engine.updates.close);
    final failing = Completer<LibtorrentFlutter>();
    var calls = 0;
    final service = _service(() => ++calls == 1 ? failing.future : Future.value(engine));
    final first = expectLater(service.streamMagnet('magnet:first'), throwsStateError);
    final second = expectLater(service.streamMagnet('magnet:second'), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    failing.completeError(StateError('fixture cold initialization failed'));
    await Future.wait([first, second]);
    expect(calls, 1);
    expect(engine.listeners, 0);
    expect(await service.streamMagnet('magnet:retry'), contains('/stream/1'));
    expect(calls, 2);
    expect(engine.listeners, 1);
    service.dispose();
    await engine.disposed.future;
  });

  test('dispose during cold initialization cannot publish or add a late torrent', () async {
    final engine = _Engine();
    addTearDown(engine.updates.close);
    final initializing = Completer<LibtorrentFlutter>();
    var calls = 0;
    final service = _service(() {
      calls++;
      return initializing.future;
    });
    final first = expectLater(service.streamMagnet('magnet:first'), throwsA(isA<BeamCancelled>()));
    final second = expectLater(service.streamMagnet('magnet:second'), throwsA(isA<BeamCancelled>()));
    await Future<void>.delayed(Duration.zero);
    service.dispose();
    service.dispose();
    initializing.complete(engine);
    await Future.wait([first, second]);
    await engine.disposed.future;
    expect(engine.adds, 0);
    expect(engine.listeners, 0);
    expect(engine.disposals, 1);
    await expectLater(service.streamMagnet('magnet:after-dispose'), throwsA(isA<BeamCancelled>()));
    expect(calls, 1);
  });

  test('synchronous initializer throw also clears the shared future for retry', () async {
    final engine = _Engine();
    addTearDown(engine.updates.close);
    var calls = 0;
    final service = _service(() {
      if (++calls == 1) throw StateError('synchronous factory failure');
      return Future.value(engine);
    });
    await expectLater(service.streamMagnet('magnet:first'), throwsStateError);
    expect(await service.streamMagnet('magnet:retry'), contains('/stream/1'));
    expect(calls, 2);
    expect(engine.listeners, 1);
    service.dispose();
    await engine.disposed.future;
  });
}
