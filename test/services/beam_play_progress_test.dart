import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/beam/beam_buffer_wait.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/beam_playback_duration.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/realdebrid_client.dart';
import 'package:plezy/services/beam/torrent_stream_service.dart';

class _Torrent implements TorrentStreamService {
  final ready = Completer<String>();
  late BeamCancellation cancellation;
  late void Function(String) preparation;
  late void Function(TorrentStreamStatus) status;
  late void Function(String) selected;

  @override
  Future<String> streamMagnet(
    String magnetUri, {
    void Function(TorrentStreamStatus)? onStatus,
    void Function(String)? onPreparationStatus,
    void Function(String)? onFileSelected,
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
    BeamPlaybackDuration? playbackDuration,
    BeamBufferWaitController? bufferWait,
    BeamCancellation? cancellation,
  }) {
    this.cancellation = cancellation!;
    preparation = onPreparationStatus!;
    status = onStatus!;
    selected = onFileSelected!;
    preparation('Finding peers · 0 peers · 0 seeds');
    return ready.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _source = ProwlarrResult.fromJson({
  'title': 'Pioneer.One.S01E02',
  'guid': 'magnet:?xt=urn:btih:0123456789012345678901234567890123456789',
  'seeders': 5,
});
BeamPlayResult _rdResult() =>
    BeamPlayResult(url: 'https://fixture.invalid/video', winner: BeamPlayWinner.realDebrid, magnet: _source.magnetUrl!);

void main() {
  test('pending RD stays visible with native preparation and buffer updates; first frame still commits', () async {
    final native = _Torrent();
    final rd = Completer<BeamPlayResult>();
    late BeamCancellation rdCancellation;
    final statuses = <String>[];
    final fractions = <double?>[];
    final race =
        BeamPlayService(
          torrentStreamService: native,
          realDebrid: (_, _, _, cancellation) {
            rdCancellation = cancellation;
            return rd.future;
          },
        ).race(
          _source,
          rdEnabled: true,
          torrentEnabled: true,
          deferLoserCancellation: true,
          onProgress: (value, {progress}) {
            statuses.add(value);
            fractions.add(progress);
          },
        );
    expect(statuses.last, contains('Real-Debrid: Connecting'));
    expect(statuses.last, contains('InstantPlay: Finding peers'));
    native.preparation('Downloading torrent metadata · 2 peers · 1 seed');
    native.selected('Pioneer.One.S01E02.mp4');
    native.status(
      const TorrentStreamStatus(progress: .25, downloadRate: 1048576, numSeeds: 1, bufferSeconds: 10, ready: false),
    );
    expect(statuses.last, contains('Real-Debrid: Connecting'));
    expect(statuses.last, contains('InstantPlay: Torrent  25%'));
    expect(
      fractions.every((value) => value == null),
      isTrue,
      reason: 'Two transports have no combined progress percent',
    );
    native.ready.complete('http://127.0.0.1/fixture');
    final result = await race;
    expect(statuses.last, contains('InstantPlay: Ready to play'));
    expect(rdCancellation.isCancelled, isFalse);
    expect(native.cancellation.isCancelled, isFalse);
    result.commitPlayback();
    expect(rdCancellation.isCancelled, isTrue);
    expect(native.cancellation.isCancelled, isFalse);
    final count = statuses.length;
    native.preparation('late event');
    rd.complete(_rdResult());
    await Future<void>.delayed(Duration.zero);
    expect(statuses.length, count);
    result.cancel();
    expect(native.cancellation.isCancelled, isTrue);
  });

  for (final (code, label) in [
    (429, 'Rate limited'),
    (451, 'Source blocked by Real-Debrid'),
    (401, 'Account authorization failed'),
    (500, 'Unavailable'),
  ]) {
    test('RD $code remains terminal while native metadata continues without exposing response details', () async {
      final native = _Torrent();
      final rd = Completer<BeamPlayResult>();
      final statuses = <String>[];
      final race = BeamPlayService(torrentStreamService: native, realDebrid: (_, _, _, _) => rd.future).race(
        _source,
        rdEnabled: true,
        torrentEnabled: true,
        deferLoserCancellation: true,
        onProgress: (value, {progress}) => statuses.add(value),
      );
      rd.completeError(RdException('secret-token https://private.invalid?key=secret', code: code));
      await Future<void>.delayed(Duration.zero);
      expect(statuses.last, contains('Real-Debrid: $label'));
      expect(statuses.last, contains('InstantPlay: Finding peers'));
      expect(native.cancellation.isCancelled, isFalse);
      native.preparation('Downloading torrent metadata · 1 peer · 0 seeds');
      expect(statuses.last, contains('Real-Debrid: $label'));
      expect(statuses.last, contains('InstantPlay: Downloading torrent metadata'));
      expect(statuses.join(), isNot(contains('secret')));
      expect(statuses.join(), isNot(contains('https://')));
      native.selected('Pioneer.One.S01E02.mp4');
      native.ready.complete('http://127.0.0.1/fixture');
      final result = await race;
      expect(result.winner, BeamPlayWinner.torrent);
      result.cancel();
    });
  }

  test('native failure remains visible while RD continues; late native updates cannot revive it', () async {
    final native = _Torrent();
    final rd = Completer<BeamPlayResult>();
    final statuses = <String>[];
    final race = BeamPlayService(torrentStreamService: native, realDebrid: (_, _, _, _) => rd.future).race(
      _source,
      rdEnabled: true,
      torrentEnabled: true,
      deferLoserCancellation: true,
      onProgress: (value, {progress}) => statuses.add(value),
    );
    native.ready.completeError(const TorrentProxyRequiredException('private configuration details'));
    await Future<void>.delayed(Duration.zero);
    expect(statuses.last, contains('InstantPlay: VPN or proxy required'));
    expect(statuses.last, contains('Real-Debrid: Connecting'));
    final count = statuses.length;
    native.preparation('late peer event');
    expect(statuses.length, count);
    rd.complete(_rdResult());
    final result = await race;
    expect(statuses.last, contains('Real-Debrid: Ready to play'));
    expect(statuses.last, contains('InstantPlay: VPN or proxy required'));
    result.cancel();
  });
}
