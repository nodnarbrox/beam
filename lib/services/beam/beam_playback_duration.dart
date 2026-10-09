import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import 'episode_file_selector.dart';

/// Metadata runtime for the actual selected file, never inferred from size.
/// A combined episode file requires known runtimes for every explicit member.
class BeamPlaybackDuration {
  const BeamPlaybackDuration({this.durationMs, this.episodeDurationsMs = const {}});

  final int? durationMs;
  final Map<int, int> episodeDurationsMs;
  static const maxDurationMs = 24 * 60 * 60 * 1000;

  static int? valid(int? value) => value != null && value > 0 && value <= maxDurationMs ? value : null;

  static BeamPlaybackDuration? fromMetadata(MediaItem? item, {Iterable<MediaItem> episodeQueue = const []}) {
    if (item == null) return null;
    return BeamPlaybackDuration(
      durationMs: valid(item.durationMs),
      episodeDurationsMs: Map.unmodifiable({
        for (final episode in episodeQueue)
          if (episode.kind == MediaKind.episode &&
              episode.parentIndex == item.parentIndex &&
              episode.index != null &&
              valid(episode.durationMs) != null)
            episode.index!: episode.durationMs!,
        if (item.kind == MediaKind.episode && item.index != null && valid(item.durationMs) != null)
          item.index!: item.durationMs!,
      }),
    );
  }

  int? forFile(String filename, {int? season, int? episode}) {
    if (season == null && episode == null) return valid(durationMs);
    if (season == null || episode == null) return null;
    final members = EpisodeFileSelector.episodesFor(filename, season: season);
    if (members == null || !members.contains(episode)) return null;
    if (members.length == 1) return valid(durationMs);
    var total = 0;
    for (final member in members) {
      final runtime = valid(member == episode ? durationMs : episodeDurationsMs[member]);
      if (runtime == null) return null;
      total += runtime;
    }
    return valid(total);
  }
}
