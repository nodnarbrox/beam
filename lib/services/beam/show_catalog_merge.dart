import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import 'show_episode_catalog.dart';

const _catalogMarker = 'beamCatalog';

bool isCatalogEpisode(MediaItem item) => item.kind == MediaKind.episode && item.raw?[_catalogMarker] == 'tvmaze';

bool isCatalogSeason(MediaItem item) => item.kind == MediaKind.season && item.raw?[_catalogMarker] == 'tvmaze';

/// Only exact, playable numbering is a merge key. Unnumbered specials do not
/// acquire a made-up episode number or collide with a numbered episode.
String? catalogEpisodeKey(MediaItem item) {
  final season = item.parentIndex;
  final episode = item.index;
  if (item.kind != MediaKind.episode || season == null || season < 0 || episode == null || episode <= 0) return null;
  return 'S${season}E$episode';
}

class ShowCatalogNumberingConflict {
  const ShowCatalogNumberingConflict({
    required this.seasonNumber,
    required this.episodeNumber,
    required this.libraryTitle,
    required this.catalogTitle,
  });

  final int seasonNumber;
  final int episodeNumber;
  final String libraryTitle;
  final String catalogTitle;
}

class ShowCatalogMergeResult {
  ShowCatalogMergeResult({required List<MediaItem> seasons, required List<MediaItem> episodes, required this.conflicts})
    : seasons = List.unmodifiable(seasons),
      episodes = List.unmodifiable(episodes);

  final List<MediaItem> seasons;
  final List<MediaItem> episodes;
  final List<ShowCatalogNumberingConflict> conflicts;
  Set<int> get conflictedSeasons => conflicts.map((conflict) => conflict.seasonNumber).toSet();
}

/// Supplement server metadata without replacing its identity or watch state.
///
/// Different meaningful titles at the same S/E are conservatively treated as
/// evidence of incompatible numbering (for example split vs combined stories).
/// That season receives no catalog additions. This is an inference, not a claim
/// that either provider's numbering is wrong. Missing/generic server titles do
/// not establish a conflict. Existing server duplicates remain distinct items.
ShowCatalogMergeResult mergeShowCatalog({
  required MediaItem show,
  required ShowEpisodeCatalogResult catalog,
  List<MediaItem> librarySeasons = const [],
  List<MediaItem> libraryEpisodes = const [],
}) {
  // Recompute catalog additions on refresh; only actual server items have
  // precedence. Otherwise a previous virtual episode can hide new server data.
  final episodes = libraryEpisodes.where((item) => !isCatalogEpisode(item)).toList();
  final seasons = librarySeasons.where((item) => !isCatalogSeason(item)).toList();
  final byNumber = <String, List<MediaItem>>{};
  for (final item in episodes) {
    final key = catalogEpisodeKey(item);
    if (key != null) (byNumber[key] ??= []).add(item);
  }

  final conflicts = <ShowCatalogNumberingConflict>[];
  for (final episode in catalog.episodes) {
    final number = episode.episodeNumber;
    if (episode.seasonNumber < 0 || number == null || number <= 0) continue;
    for (final existing in byNumber['S${episode.seasonNumber}E$number'] ?? const <MediaItem>[]) {
      if (_meaningfulTitle(existing.title) &&
          _meaningfulTitle(episode.name) &&
          _normalizedTitle(existing.title!) != _normalizedTitle(episode.name)) {
        conflicts.add(
          ShowCatalogNumberingConflict(
            seasonNumber: episode.seasonNumber,
            episodeNumber: number,
            libraryTitle: existing.title!,
            catalogTitle: episode.name,
          ),
        );
      }
    }
  }
  final conflicted = conflicts.map((conflict) => conflict.seasonNumber).toSet();
  final present = byNumber.keys.toSet();
  final showTitle = show.title?.trim().isNotEmpty == true ? show.title! : catalog.name;
  final showThumb = show.thumbPath ?? catalog.imageUrl;
  String seasonId(int number) => 'tvmaze:${catalog.tvmazeId}:season:$number';
  Map<String, Object?> marker() => {_catalogMarker: 'tvmaze', 'tvmazeShowId': catalog.tvmazeId};

  for (final episode in catalog.episodes) {
    final number = episode.episodeNumber;
    final season = episode.seasonNumber;
    if (season < 0 || number == null || number <= 0 || conflicted.contains(season)) continue;
    if (!present.add('S${season}E$number')) continue;
    final matchingSeason = seasons.where((item) => item.index == season).firstOrNull;
    episodes.add(
      MediaItem(
        id: 'tvmaze:episode:${episode.id}',
        backend: show.backend,
        kind: MediaKind.episode,
        title: episode.name,
        summary: episode.summary,
        // Beam searches by the show's release year, not the episode air year.
        year: show.year ?? catalog.year,
        originallyAvailableAt: episode.airdate,
        parentId: matchingSeason?.id ?? seasonId(season),
        parentTitle: matchingSeason?.title ?? (season == 0 ? 'Specials' : 'Season $season'),
        parentIndex: season,
        index: number,
        grandparentId: show.id,
        grandparentTitle: showTitle,
        grandparentThumbPath: showThumb,
        grandparentArtPath: show.artPath,
        grandparentBackdropPaths: show.backdropPaths,
        thumbPath: episode.imageUrl ?? showThumb,
        artPath: show.artPath,
        durationMs: episode.runtimeMinutes == null ? null : episode.runtimeMinutes! * 60000,
        raw: {
          ...marker(),
          'tvmazeEpisodeId': episode.id,
          'catalogSourceUrl': episode.sourceUrl,
          'catalogAirStamp': episode.airStamp?.toIso8601String(),
          'catalogEpisodeType': episode.type,
          'beamShowAliases': catalog.aliases,
          if (catalog.imdbId != null && RegExp(r'^tt\d{6,9}$').hasMatch(catalog.imdbId!))
            'beamShowImdbId': catalog.imdbId,
          if (catalog.numberingEvidence[episode.id] case final evidence?) 'beamNumberingEvidence': evidence.toRaw(),
        },
      ),
    );
  }

  final presentSeasons = seasons.map((item) => item.index).toSet();
  for (final season in catalog.seasons) {
    if (season.number < 0 || conflicted.contains(season.number) || !presentSeasons.add(season.number)) continue;
    seasons.add(
      MediaItem(
        id: seasonId(season.number),
        backend: show.backend,
        kind: MediaKind.season,
        title: season.name?.trim().isNotEmpty == true
            ? season.name
            : (season.number == 0 ? 'Specials' : 'Season ${season.number}'),
        summary: season.summary,
        year: show.year ?? catalog.year,
        originallyAvailableAt: season.premiereDate,
        index: season.number,
        parentId: show.id,
        parentTitle: showTitle,
        grandparentId: show.id,
        grandparentTitle: showTitle,
        thumbPath: season.imageUrl ?? showThumb,
        artPath: show.artPath,
        leafCount: episodes
            .where((item) => item.parentIndex == season.number)
            .map(catalogEpisodeKey)
            .nonNulls
            .toSet()
            .length,
        raw: {...marker(), 'tvmazeSeasonId': season.id, 'catalogSourceUrl': catalog.sourceUrl},
      ),
    );
  }

  return ShowCatalogMergeResult(
    seasons: _stableNumberSort(seasons, (item) => (item.index ?? 1 << 30, 0)),
    episodes: _stableNumberSort(episodes, (item) => (item.parentIndex ?? 1 << 30, item.index ?? 1 << 30)),
    conflicts: List.unmodifiable(conflicts),
  );
}

List<MediaItem> _stableNumberSort(List<MediaItem> items, (int, int) Function(MediaItem) numbering) {
  final indexed = items.indexed.toList();
  indexed.sort((a, b) {
    final left = numbering(a.$2);
    final right = numbering(b.$2);
    final season = left.$1.compareTo(right.$1);
    if (season != 0) return season;
    final episode = left.$2.compareTo(right.$2);
    return episode != 0 ? episode : a.$1.compareTo(b.$1);
  });
  return indexed.map((item) => item.$2).toList();
}

String _normalizedTitle(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&', ' and ')
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

bool _meaningfulTitle(String? title) {
  if (title == null || title.trim().isEmpty) return false;
  final normalized = _normalizedTitle(title);
  return normalized.isNotEmpty &&
      !RegExp(r'^(?:episode|ep|chapter|part)\d+$').hasMatch(normalized) &&
      !RegExp(r'^s\d+e\d+$').hasMatch(normalized);
}
