import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_playback_duration.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

const _magnet = 'magnet:?xt=urn:btih:pioneer-one-fixture';
const _files = [
  FileInfo(index: 1, name: 'Pioneer.One.S01E01.mp4', path: 'Pioneer.One.S01E01.mp4', size: 7525547, isStreamable: true),
  FileInfo(index: 2, name: 'Pioneer.One.S01E02.mp4', path: 'Pioneer.One.S01E02.mp4', size: 5952939, isStreamable: true),
];

class _Engine implements LibtorrentFlutter {
  @override
  final Map<int, TorrentInfo> torrents = {};
  @override
  final Map<int, StreamInfo> streams = {};
  final updates = StreamController<Map<int, StreamInfo>>.broadcast(sync: true);
  @override
  Stream<Map<int, StreamInfo>> get streamUpdates => updates.stream;
  List<FileInfo> files = _files;
  final added = <String>[];
  final removed = <int>[];
  final stopped = <int>[];
  final selected = <int>[];
  final appliedDurations = <(int, int)>[];
  bool durationSupported = true;
  int _nextStream = 100;
  void Function(StreamInfo)? onStart;

  @override
  int addMagnet(String magnetUri, [String? savePath, bool streamOnly = false]) {
    added.add(magnetUri);
    torrents[1] = const TorrentInfo(
      id: 1,
      name: 'Pioneer One',
      savePath: '',
      errorMsg: '',
      state: TorrentState.downloading,
      progress: .5,
      downloadRate: 1000000,
      uploadRate: 0,
      totalDone: 7525547,
      totalWanted: 13478486,
      totalUploaded: 0,
      numPeers: 5,
      numSeeds: 3,
      isPaused: false,
      isFinished: false,
      hasMetadata: true,
      queuePosition: 0,
    );
    return 1;
  }

  @override
  List<FileInfo> getFiles(int torrentId) => files;

  StreamInfo _info(int id, int file, double buffer) => StreamInfo(
    id: id,
    torrentId: 1,
    fileIndex: file,
    url: 'http://127.0.0.1:8191/stream/$id',
    fileSize: 5952939,
    readHead: 0,
    streamState: buffer >= 20 ? StreamState.ready : StreamState.buffering,
    bufferSeconds: buffer,
    bufferPieces: 2,
    readaheadWindow: 5,
    activePeers: 5,
    downloadRate: 1000000,
  );

  @override
  StreamInfo startStream(int torrentId, {int fileIndex = -1, int maxCacheBytes = 0}) {
    selected.add(fileIndex);
    final info = _info(_nextStream++, fileIndex, fileIndex == 1 ? 25 : 0);
    streams[info.id] = info;
    onStart?.call(info);
    return info;
  }

  void buffer(int streamId, double seconds) {
    final info = _info(streamId, streams[streamId]!.fileIndex, seconds);
    streams[streamId] = info;
    updates.add({streamId: info});
  }

  @override
  bool setStreamDuration(int streamId, int durationMs) {
    appliedDurations.add((streamId, durationMs));
    if (!durationSupported) return false;
    // Correcting an inflated duration lowers the cached buffer estimate too.
    buffer(streamId, 0);
    return true;
  }

  @override
  void stopStream(int streamId) {
    stopped.add(streamId);
    streams.remove(streamId);
  }

  @override
  void stopAllStreamsForTorrent(int torrentId) {
    for (final id in streams.keys.toList()) {
      stopStream(id);
    }
  }

  @override
  void removeTorrent(int id, {bool deleteFiles = false}) {
    expect(deleteFiles, isTrue);
    removed.add(id);
    torrents.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('older native duration setter fallback retains estimated streaming behavior', () async {
    final engine = _Engine()..durationSupported = false;
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () async {},
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    final url = await service.streamMagnet(
      _magnet,
      season: 1,
      episode: 1,
      playbackDuration: const BeamPlaybackDuration(durationMs: 2400000),
    );
    expect(url, engine.streams.values.single.url);
    expect(engine.appliedDurations, [(100, 2400000)]);
    expect(engine.streams.values.single.bufferSeconds, 25);
    await service.stopAll();
  });

  test('known runtime applies before readiness on fresh and reused episode streams', () async {
    final engine = _Engine();
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () async {},
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    for (final episode in [1, 2]) {
      var ready = false;
      final operation = service
          .streamMagnet(
            _magnet,
            season: 1,
            episode: episode,
            playbackDuration: BeamPlaybackDuration(durationMs: episode * 1200000),
          )
          .then((url) {
            ready = true;
            return url;
          });
      await Future<void>.delayed(Duration.zero);
      final stream = engine.streams.values.last;
      expect(engine.appliedDurations.last, (stream.id, episode * 1200000));
      expect(ready, isFalse, reason: 'readiness must use corrected telemetry, not startStream estimated seconds');
      engine.buffer(stream.id, 21);
      expect(await operation, stream.url);
    }
    expect(engine.added, [_magnet]);
    expect(engine.appliedDurations, hasLength(2));
    await service.stopAll();
  });

  test('stopAll invalidates an attempt still checking privacy', () async {
    final engine = _Engine();
    final privacy = Completer<void>();
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () => privacy.future,
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    final pending = service.streamMagnet(_magnet, season: 1, episode: 1);
    final cancelled = expectLater(pending, throwsA(isA<BeamCancelled>()));
    await service.stopAll();
    privacy.complete();
    await cancelled;
    expect(engine.added, isEmpty);
  });

  test('reuse without a listener releases the old progress callback', () async {
    final engine = _Engine();
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () async {},
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    final oldStatus = <TorrentStreamStatus>[];
    final freshFiles = <String>[];
    final reusedFiles = <String>[];
    await service.streamMagnet(_magnet, season: 1, episode: 1, onStatus: oldStatus.add, onFileSelected: freshFiles.add);
    final url = await service.streamMagnet(_magnet, season: 1, episode: 1, onFileSelected: reusedFiles.add);
    engine.buffer(engine.streams.values.last.id, 30);
    expect(oldStatus, isEmpty);
    expect(engine.added, [_magnet]);
    expect(freshFiles, ['Pioneer.One.S01E01.mp4']);
    expect(reusedFiles, freshFiles);
    await service.stopUrl(url);
  });

  test('stop during pending privacy check prevents a late torrent add', () async {
    final engine = _Engine();
    final privacy = Completer<void>();
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () => privacy.future,
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    final pending = service.streamMagnet(_magnet, season: 1, episode: 1);
    final cancelled = expectLater(pending, throwsA(isA<BeamCancelled>()));
    await service.stop(_magnet);
    privacy.complete();
    await cancelled;
    expect(engine.added, isEmpty);
    expect(engine.streams, isEmpty);
  });

  test('older pending privacy check cannot replace a newer stream owner', () async {
    final engine = _Engine();
    final privacy = Completer<void>();
    var requests = 0;
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () {
        return ++requests == 1 ? privacy.future : Future.value();
      },
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    final old = service.streamMagnet(_magnet, season: 1, episode: 2);
    final cancelled = expectLater(old, throwsA(isA<BeamCancelled>()));
    final freshToken = BeamCancellation();
    final freshUrl = await service.streamMagnet(_magnet, season: 1, episode: 1, cancellation: freshToken);
    privacy.complete();
    await cancelled;
    expect(engine.added, [_magnet]);
    expect(engine.selected, [1]);
    expect(engine.streams.values.single.url, freshUrl);
    freshToken.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(engine.removed, [1]);
  });

  test('reuse keeps peers and pieces, waits for E02 buffer, and scopes old URL/token cleanup', () async {
    final engine = _Engine();
    var guards = 0;
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () async {
        guards++;
      },
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    final old = BeamCancellation();
    final fresh = BeamCancellation();
    final oldUrl = await service.streamMagnet(_magnet, season: 1, episode: 1, cancellation: old);
    final oldStream = engine.streams.values.single.id;
    final started = Completer<StreamInfo>();
    engine.onStart = started.complete;
    final statuses = <TorrentStreamStatus>[];
    var ready = false;
    final next = service.streamMagnet(_magnet, season: 1, episode: 2, cancellation: fresh, onStatus: statuses.add).then(
      (url) {
        ready = true;
        return url;
      },
    );
    final newStream = await started.future;
    expect(engine.added, [_magnet]);
    expect(engine.removed, isEmpty);
    expect(engine.selected, [1, 2]);
    expect(newStream.url, isNot(oldUrl));
    expect(guards, 2);
    engine.buffer(oldStream, 90);
    await Future<void>.delayed(const Duration(milliseconds: 130));
    expect(ready, isFalse, reason: 'E01 buffer cannot satisfy requested E02 readiness');
    expect(statuses, isEmpty, reason: 'E01 telemetry cannot update E02 progress');
    old.cancel();
    await Future<void>.delayed(Duration.zero);
    await service.stopUrl(oldUrl);
    expect(engine.stopped, [oldStream]);
    expect(engine.removed, isEmpty);
    expect(engine.streams.containsKey(newStream.id), isTrue);
    engine.buffer(newStream.id, 21);
    expect(await next, newStream.url);
    expect(statuses.single.bufferSeconds, 21);
    await service.stopUrl(newStream.url);
    expect(engine.removed, [1]);
    expect(engine.streams, isEmpty);
    fresh.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(engine.removed, [1], reason: 'released owner cannot delete twice');
  });

  for (final rejection in ['missing episode', 'ambiguous episode', 'privacy']) {
    test('$rejection rejection preserves previous stream and its cancellation owner', () async {
      final engine = _Engine();
      var allowed = true;
      final service = TorrentStreamService.forTesting(
        engine: engine,
        privacyCheck: () async {
          if (!allowed) throw const TorrentProxyRequiredException('VPN required');
        },
        udpProbe: () async => true,
      );
      addTearDown(engine.updates.close);
      final old = BeamCancellation();
      final oldUrl = await service.streamMagnet(_magnet, season: 1, episode: 1, cancellation: old);
      if (rejection == 'ambiguous episode') engine.files = [..._files, _files.last];
      if (rejection == 'privacy') allowed = false;
      await expectLater(
        service.streamMagnet(_magnet, season: 1, episode: rejection == 'missing episode' ? 3 : 2),
        throwsA(rejection == 'privacy' ? isA<TorrentProxyRequiredException>() : isA<EpisodeSelectionException>()),
      );
      expect(engine.streams.values.single.url, oldUrl);
      expect(engine.added, [_magnet]);
      expect(engine.removed, isEmpty);
      old.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(engine.removed, [1]);
      expect(engine.streams, isEmpty);
    });
  }

  test('current reused attempt cancellation stops its pending E02 stream', () async {
    final engine = _Engine();
    final service = TorrentStreamService.forTesting(
      engine: engine,
      privacyCheck: () async {},
      udpProbe: () async => true,
    );
    addTearDown(engine.updates.close);
    await service.streamMagnet(_magnet, season: 1, episode: 1);
    final started = Completer<StreamInfo>();
    engine.onStart = started.complete;
    final cancellation = BeamCancellation();
    final next = service.streamMagnet(_magnet, season: 1, episode: 2, cancellation: cancellation);
    final cancelled = expectLater(next, throwsA(isA<BeamCancelled>()));
    await started.future;
    cancellation.cancel();
    await cancelled;
    expect(engine.added, [_magnet]);
    expect(engine.removed, [1]);
    expect(engine.streams, isEmpty);
  });
}
