/// A transport-neutral file descriptor. IDs are native torrent indices or RD IDs.
class EpisodeFile {
  const EpisodeFile({required this.id, required this.path, required this.size, this.streamable = true});
  final int id;
  final String path;
  final int size;
  final bool streamable;
}

class EpisodeSelectionException implements Exception {
  const EpisodeSelectionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Catalog story numbers can differ from broadcaster episode numbers. Such
/// requests also need a complete story title in the selected actual filename.
class EpisodeStoryConstraint {
  const EpisodeStoryConstraint({required this.title, this.companionTitles = const {}});
  final String title;
  final Map<int, String> companionTitles;
}

/// Fails closed for TV: filenames (never parent directories) must explicitly
/// identify the requested episode. A bounded combined file can contain it, but
/// filenames never imply a mapping between story numbers and broadcast numbers.
class EpisodeFileSelector {
  static final _video = RegExp(r'\.(mkv|mp4|avi|mov|m4v|webm|ts|wmv|flv)$', caseSensitive: false);
  static final _extra = RegExp(
    r'(^|[ /\\._-])(samples?|extras?|trailers?|featurettes?)([ /\\._-]|$)',
    caseSensitive: false,
  );
  static final _episode = RegExp(
    r'(?:^|[^a-z0-9])(?:s(\d{1,3})[ ._-]*e(\d{1,3})|(\d{1,3})x(\d{1,3}))(?![0-9])',
    caseSensitive: false,
  );

  static bool matches(String path, int season, int episode, {EpisodeStoryConstraint? storyConstraint}) {
    final parsed = _parse(path, season: season);
    if (parsed == null || !parsed.$1.contains(episode)) return false;
    if (storyConstraint == null) return true;
    final expected = _storyTitle(storyConstraint.title);
    if (expected.isEmpty) return false;
    final suffix = _storyTitle(parsed.$2);
    // First compare the whole title; a title containing a technical word must
    // not be shortened merely because it resembles a release descriptor.
    final titles = {...storyConstraint.companionTitles, episode: storyConstraint.title};
    final accepted = <String>{expected};
    if (parsed.$1.length > 1 && parsed.$1.every((number) => _storyTitle(titles[number] ?? '').isNotEmpty)) {
      accepted.add(parsed.$1.map((number) => _storyTitle(titles[number]!)).join(' '));
      accepted.add(parsed.$1.map((number) => _storyTitle(titles[number]!)).join(' and '));
    }
    if (accepted.contains(suffix)) return true;
    final quality = _releaseDescriptor.firstMatch(suffix);
    return quality != null && accepted.contains(suffix.substring(0, quality.start).trim());
  }

  static String _storyTitle(String value) => value
      .replaceFirst(_video, '')
      .toLowerCase()
      .replaceAll(RegExp("['\u2018\u2019]"), '')
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
  static final _releaseDescriptor = RegExp(
    r'(?:^| )(?:\d{3,4}p|4k|8k|web|webrip|webdl|hdtv|bluray|brrip|bdrip|dvdrip|dvd|remux|hdr|hdr10|x264|x265|h264|h265|hevc|avc|aac|ddp|dts|ac3|eac3|proper|repack)(?: |$)',
  );

  /// Explicit episode membership, including small ranges/lists in one season.
  /// Combined files start at their beginning; this does not infer chapter times.
  /// A maximum of eight episodes keeps broad/accidental ranges from becoming a
  /// match. Repeated full season markers and ambiguous numbering fail closed.
  static List<int>? episodesFor(String path, {required int season}) => _parse(path, season: season)?.$1;

  static (List<int>, String)? _parse(String path, {required int season}) {
    if (season < 0) return null;
    final name = path.split(RegExp(r'[/\\]')).last;
    final markers = _episode.allMatches(name).toList();
    if (markers.length != 1) return null;
    final marker = markers.single;
    final s = int.parse(marker.group(1) ?? marker.group(3)!);
    final e = int.parse(marker.group(2) ?? marker.group(4)!);
    if (s != season || e < 1) return null;
    final episodes = <int>[e];
    final letter = marker.group(1) != null ? 'e' : 'x';
    final continuation = RegExp('^([ ._]*-?[ ._]*)($letter?)([0-9]{1,3})(?![0-9])', caseSensitive: false);
    var tail = name.substring(marker.end);
    while (true) {
      final next = continuation.firstMatch(tail);
      if (next == null) break;
      final separator = next.group(1)!;
      final explicitLetter = next.group(2)!.isNotEmpty;
      final isRange = separator.contains('-');
      // Bare numbers following an episode can be a resolution or a year.
      if (!explicitLetter && !isRange) break;
      final number = int.parse(next.group(3)!);
      if (number <= episodes.last) return null;
      if (isRange) {
        if (number - episodes.first >= 8) return null;
        final previous = episodes.last;
        episodes.addAll(List.generate(number - previous, (index) => previous + index + 1));
      } else {
        episodes.add(number);
      }
      if (episodes.length > 8) return null;
      tail = tail.substring(next.end);
    }
    // Reject malformed or mixed marker continuations rather than accepting the
    // first part of an unsupported combined filename. Ordinary title/quality
    // suffixes remain allowed after a separator.
    if (RegExp(r'^[a-z0-9]', caseSensitive: false).hasMatch(tail) ||
        RegExp(r'^[ ._+&-]*(?:[ex]\d|s\d+[ ._-]*e|-[ ._]*\d)', caseSensitive: false).hasMatch(tail) ||
        RegExp(r'^[ ._]+(?:(?:and|to)[ ._]+[ex]?\d|\d{1,3}(?:$|[ ._-]))', caseSensitive: false).hasMatch(tail)) {
      return null;
    }
    return (List.unmodifiable(episodes), tail);
  }

  static EpisodeFile select(
    Iterable<EpisodeFile> files, {
    int? season,
    int? episode,
    EpisodeStoryConstraint? storyConstraint,
  }) {
    if ((season == null) != (episode == null) || (season != null && (season < 0 || episode! < 1))) {
      throw const EpisodeSelectionException('A valid season and episode are required.');
    }
    if (storyConstraint != null && season == null) {
      throw const EpisodeSelectionException('Story verification requires a season and episode.');
    }
    final videos = files.where((f) => f.streamable && _video.hasMatch(f.path) && !_extra.hasMatch(f.path)).toList();
    if (season != null) {
      final matches = videos
          .where((f) => EpisodeFileSelector.matches(f.path, season, episode!, storyConstraint: storyConstraint))
          .toList();
      if (matches.length != 1) {
        throw EpisodeSelectionException(
          matches.isEmpty ? 'Requested episode is missing from this source.' : 'Requested episode has ambiguous files.',
        );
      }
      return matches.single;
    }
    if (videos.isEmpty) throw const EpisodeSelectionException('No playable video file.');
    videos.sort((a, b) => b.size.compareTo(a.size));
    return videos.first;
  }
}
