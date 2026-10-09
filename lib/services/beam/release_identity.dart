import 'episode_file_selector.dart';
import 'prowlarr_client.dart';

enum EpisodeReleaseKind { episode, seasonPack, seriesPack }

/// Conservative identity check before any playback transport is started.
/// Indexer keyword matches and release quality are not evidence of identity.
class ReleaseIdentity {
  static bool matchesMovie(
    ProwlarrResult source, {
    required String title,
    int? year,
    Iterable<String> aliases = const [],
  }) {
    if (!_categoryMatches(source, 2000)) return false;
    for (final requested in [title, ...aliases]) {
      final remainder = _afterTitle(source.title, requested);
      if (remainder == null) continue;
      final parts = remainder.isEmpty ? <String>[] : remainder.split(' ');
      if (year != null) {
        if (parts.isEmpty || parts.first != '$year') continue;
        parts.removeAt(0);
      } else if (parts.isNotEmpty && _year.hasMatch(parts.first)) {
        parts.removeAt(0);
      }
      if (parts.isEmpty || (parts.length == 1 && _videoExtensions.contains(parts.single))) return true;
      // A different title/sequel cannot be smuggled in between the requested
      // title/year and the release descriptors. Multiple years indicate an
      // ambiguous collection or another release, so do not auto-play it.
      if (!_movieSuffix.hasMatch(parts.first)) continue;
      if (parts.any((part) => _year.hasMatch(part) || _notFeature.contains(part))) continue;
      if (RegExp(
        r'(?:^| )(?:s\d{1,2}e\d{1,3}|season|episode|part|collection|trilogy)(?: |$)',
      ).hasMatch(parts.join(' '))) {
        continue;
      }
      return true;
    }
    return false;
  }

  static bool matchesEpisodeSource(
    ProwlarrResult source, {
    required String show,
    required int season,
    required int episode,
    Iterable<String> aliases = const [],
  }) => episodeSourceKind(source, show: show, season: season, episode: episode, aliases: aliases) != null;

  /// A release name is only a candidate. Both transports still verify the
  /// requested episode against the actual files before opening any stream.
  static EpisodeReleaseKind? episodeSourceKind(
    ProwlarrResult source, {
    required String show,
    required int season,
    required int episode,
    Iterable<String> aliases = const [],
  }) {
    if (season < 0 || episode < 1 || !_categoryMatches(source, 5000)) return null;
    for (final requested in [show, ...aliases]) {
      // Preserve explicit range separators before punctuation normalization;
      // "S01 S05" is not evidence that seasons two through four are present.
      final release = source.title.replaceAllMapped(
        RegExp(r'\b(s\d{1,2}|seasons?[ ._-]*\d{1,2})\s*[-\u2013\u2014]\s*(s?\d{1,2})\b', caseSensitive: false),
        (match) => '${match[1]} to ${match[2]}',
      );
      var remainder = _afterTitle(release, requested.replaceFirst(RegExp(r'\s*\(\d{4}\)\s*$'), ''));
      if (remainder == null || remainder.isEmpty) continue;
      final parts = remainder.split(' ');
      // Series release filenames may name the current season's year rather
      // than the premiere year. Title and season/episode establish identity.
      if (_year.hasMatch(parts.first)) remainder = parts.skip(1).join(' ');
      if (remainder.split(' ').any(_notFeature.contains)) continue;
      // The normalized prefix establishes exact show identity; parse the raw
      // filename to preserve explicit episode ranges and lists. Both transports
      // apply this same membership check again against actual video filenames.
      if (RegExp(r'^(?:s\d{1,3}\s*e\d{1,3}|\d{1,3}x\d{1,3})').hasMatch(remainder)) {
        if (EpisodeFileSelector.matches(source.title, season, episode)) return EpisodeReleaseKind.episode;
        continue;
      }
      final packRemainder = remainder.replaceFirst(RegExp(r'^(?:the )?complete\s+(?=seasons?\b|s\d)'), '');
      final range = RegExp(r'^(?:s|seasons?\s*)(\d{1,2})\s+to\s+s?(\d{1,2})(?: |$)').firstMatch(packRemainder);
      if (range != null) {
        final start = int.parse(range[1]!);
        final end = int.parse(range[2]!);
        if (start <= season && season <= end && _packSuffix(packRemainder.substring(range.end))) {
          return EpisodeReleaseKind.seriesPack;
        }
        continue;
      }
      final complete = RegExp(
        r'^(?:the )?(?:complete(?: series)?|entire series|full series)(?: |$)',
      ).firstMatch(remainder);
      if (complete != null && _packSuffix(remainder.substring(complete.end))) return EpisodeReleaseKind.seriesPack;
      final scene = RegExp(r'^s(\d{1,2})(?:\s*e(\d{1,3}))?(?: |$)').firstMatch(packRemainder);
      final verbose = RegExp(r'^season\s*(\d{1,2})(?:\s+episode\s*(\d{1,3}))?(?: |$)').firstMatch(packRemainder);
      final cross = RegExp(r'^(\d{1,2})x(\d{1,3})(?: |$)').firstMatch(remainder);
      final marker = scene ?? verbose ?? cross;
      if (marker == null || int.parse(marker.group(1)!) != season) continue;
      final selectedEpisode = marker.group(2);
      if (selectedEpisode != null && int.parse(selectedEpisode) != episode) continue;
      final suffix = packRemainder.substring(marker.end).trim();
      if (selectedEpisode != null && RegExp(r'^(?:e\d+|s\d+e\d+|\d{1,3}|and|to)(?: |$)').hasMatch(suffix)) {
        continue;
      }
      if (selectedEpisode == null && !_packSuffix(suffix)) continue;
      return selectedEpisode == null ? EpisodeReleaseKind.seasonPack : EpisodeReleaseKind.episode;
    }
    return null;
  }

  static bool _packSuffix(String suffix) {
    final rest = suffix.trim().replaceFirst(RegExp(r'^(?:complete|series)(?: |$)'), '').trim();
    if (rest.isEmpty) return true;
    if (RegExp(r'(?:^| )(?:s\d+(?:e\d+)?|e\d+|\d+x\d+|seasons?|episodes?|to|and)(?: |$)').hasMatch(rest)) return false;
    return _movieSuffix.hasMatch(rest.split(' ').first);
  }

  static final _year = RegExp(r'^(?:18|19|20|21)\d{2}$');
  static final _movieSuffix = RegExp(
    r'^(?:\d{3,4}p|4k|8k|bluray|blu|brrip|bdrip|bdremux|dvdrip|dvd|dvdscr|webrip|webdl|web|hdtv|hdrip|remux|hdr|hdr10|dv|x264|x265|h264|h265|hevc|avc|aac|dts|ddp|ac3|eac3|proper|repack|extended|unrated|remastered|criterion|directors|theatrical|limited|internal|multi|dual|eng|english)$',
  );
  static const _videoExtensions = {'mkv', 'mp4', 'avi', 'mov', 'm4v', 'ts', 'webm'};
  static const _notFeature = {'sample', 'trailer', 'trailers', 'extras', 'featurette', 'featurettes', 'xxx'};

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp("['\u2018\u2019]"), '')
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[\s._:;,!?/\\()\[\]{}+\-\u2013\u2014]+'), ' ')
      .trim();

  static String? _afterTitle(String release, String title) {
    final expected = _normalize(title);
    final actual = _normalize(release);
    if (expected.isEmpty) return null;
    if (actual == expected) return '';
    return actual.startsWith('$expected ') ? actual.substring(expected.length + 1) : null;
  }

  static bool _categoryMatches(ProwlarrResult source, int bucket) {
    final categories = source.categories.where((category) => category >= 1000 && category < 9000).toList();
    if (categories.any((category) => category >= 6000 && category < 7000)) return false;
    return categories.isEmpty || categories.any((category) => category >= bucket && category < bucket + 1000);
  }
}
