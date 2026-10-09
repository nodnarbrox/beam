import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/beam_playback_duration.dart';

MediaItem _episode(int number, int? duration, {int season = 1}) => MediaItem(
  id: 'episode:$season:$number',
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  parentIndex: season,
  index: number,
  durationMs: duration,
);

void main() {
  test('single episode and movie use actual metadata runtime rather than a filesize guess', () {
    final context = BeamPlaybackDuration.fromMetadata(_episode(2, 2400000))!;
    expect(context.forFile('Pioneer.One.S01E02.mp4', season: 1, episode: 2), 2400000);
    expect(context.forFile('Pioneer.One.S01E03.mp4', season: 1, episode: 2), isNull);
    expect(const BeamPlaybackDuration(durationMs: 7200000).forFile('movie.mkv'), 7200000);
  });

  test('paired file sums all explicit known members and ignores another season', () {
    final context = BeamPlaybackDuration.fromMetadata(
      _episode(2, 780000),
      episodeQueue: [_episode(1, 720000), _episode(1, 999999, season: 2)],
    )!;
    expect(context.forFile('Show.S01E01-E02.mp4', season: 1, episode: 2), 1500000);
    expect(context.forFile('Show.S02E01-E02.mp4', season: 1, episode: 2), isNull);
  });

  test('unknown paired member never applies one story runtime to the whole file', () {
    final context = BeamPlaybackDuration.fromMetadata(_episode(2, 780000), episodeQueue: [_episode(1, null)])!;
    expect(context.forFile('Show.S01E01-E02.mp4', season: 1, episode: 2), isNull);
    expect(context.forFile('Show.S01E02-E03.mp4', season: 1, episode: 2), isNull);
  });

  test('invalid and absent durations preserve the native estimated fallback', () {
    expect(BeamPlaybackDuration.fromMetadata(null), isNull);
    for (final duration in [null, -1, 0, 86400001]) {
      final context = BeamPlaybackDuration.fromMetadata(_episode(2, duration))!;
      expect(context.forFile('Show.S01E02.mp4', season: 1, episode: 2), isNull);
    }
    const overflow = BeamPlaybackDuration(durationMs: 86400000, episodeDurationsMs: {1: 1000});
    expect(overflow.forFile('Show.S01E01-E02.mp4', season: 1, episode: 2), isNull);
  });
}
