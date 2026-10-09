import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

const _hashA = '0123456789012345678901234567890123456789';
const _hashB = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd';
const _magnetA = 'magnet:?xt=urn:btih:$_hashA';
const _magnetB = 'magnet:?xt=urn:btih:$_hashB';
const _filename = 'Pioneer.One.S01E01.mp4';

class _DiskEngine implements LibtorrentFlutter {
  @override
  final Map<int, TorrentInfo> torrents = {};
  @override
  final Map<int, StreamInfo> streams = {};
  // Each test closes its engine's controller in tearDown.
  // ignore: close_sinks
  final updates = StreamController<Map<int, StreamInfo>>.broadcast(sync: true);
  @override
  Stream<Map<int, StreamInfo>> get streamUpdates => updates.stream;
  final savePaths = <int, String>{};
  final files = <int, File>{};
  final deletes = <void Function()>[];
  bool delayDeletes = false;
  int adds = 0;

  @override
  int addMagnet(String magnetUri, [String? savePath, bool streamOnly = false]) {
    expect(savePath, isNotNull);
    final id = ++adds;
    savePaths[id] = savePath!;
    final directory = Directory(savePath)..createSync(recursive: true);
    files[id] = File('${directory.path}${Platform.pathSeparator}$_filename')..writeAsStringSync('source-$id');
    return id;
  }

  @override
  List<FileInfo> getFiles(int torrentId) => const [
    FileInfo(index: 0, name: _filename, path: _filename, size: 1000000, isStreamable: true),
  ];

  @override
  StreamInfo startStream(int torrentId, {int fileIndex = -1, int maxCacheBytes = 0}) {
    final info = StreamInfo(
      id: torrentId + 100,
      torrentId: torrentId,
      fileIndex: fileIndex,
      url: 'http://127.0.0.1/fixture/$torrentId',
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
  void removeTorrent(int id, {bool deleteFiles = false}) {
    expect(deleteFiles, isTrue);
    final file = files[id]!;
    void remove() {
      if (file.existsSync()) file.deleteSync();
    }

    if (delayDeletes) {
      deletes.add(remove);
    } else {
      remove();
    }
    torrents.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory root;
  late _DiskEngine engine;
  late TorrentStreamService service;
  setUp(() {
    root = Directory.systemTemp.createTempSync('plezy-storage-isolation-');
    engine = _DiskEngine();
    service = TorrentStreamService.forTesting(
      engine: engine,
      tempRoot: root,
      privacyCheck: () async {},
      udpProbe: () async => true,
    );
  });
  tearDown(() async {
    await service.stopAll();
    await engine.updates.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('concurrent different hashes with identical filenames cannot overwrite or delete the winner', () async {
    final loser = BeamCancellation();
    await Future.wait([
      service.streamMagnet(_magnetA, season: 1, episode: 1, cancellation: loser),
      service.streamMagnet(_magnetB, season: 1, episode: 1),
    ]);
    expect(engine.savePaths[1], contains('${Platform.pathSeparator}$_hashA${Platform.pathSeparator}'));
    expect(engine.savePaths[2], contains('${Platform.pathSeparator}$_hashB${Platform.pathSeparator}'));
    expect(engine.savePaths[1], isNot(engine.savePaths[2]));
    expect(engine.files[1]!.readAsStringSync(), 'source-1');
    expect(engine.files[2]!.readAsStringSync(), 'source-2');
    loser.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(engine.files[1]!.existsSync(), isFalse);
    expect(engine.files[2]!.readAsStringSync(), 'source-2');
    expect(engine.streams[102]?.torrentId, 2);
  });

  test('delayed deletion of a same-hash attempt cannot remove replacement data', () async {
    engine.delayDeletes = true;
    await service.streamMagnet(_magnetA, season: 1, episode: 1);
    await service.stop(_magnetA);
    await service.streamMagnet(_magnetA, season: 1, episode: 1);
    expect(engine.savePaths[1], isNot(engine.savePaths[2]));
    expect(engine.savePaths[2], contains('${Platform.pathSeparator}$_hashA${Platform.pathSeparator}'));
    engine.deletes.single();
    expect(engine.files[1]!.existsSync(), isFalse);
    expect(engine.files[2]!.readAsStringSync(), 'source-2');
  });

  test('warm restart after stopAll still uses the owned isolated root', () async {
    await service.streamMagnet(_magnetA, season: 1, episode: 1);
    await service.stopAll();
    expect(root.existsSync(), isFalse);
    await service.streamMagnet(_magnetB, season: 1, episode: 1);
    expect(engine.savePaths[2], startsWith('${root.path}${Platform.pathSeparator}$_hashB'));
    expect(engine.files[2]!.readAsStringSync(), 'source-2');
  });
}
