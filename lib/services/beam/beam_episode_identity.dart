import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_item_types.dart';
import '../../media/media_kind.dart';
import 'episode_file_selector.dart';

/// Content identity is independent of the torrent and its changing stream URL.
class BeamEpisodeIdentity {
  const BeamEpisodeIdentity({
    required this.showId,
    required this.showTitle,
    required this.season,
    required this.episode,
    this.year,
    this.metadata,
    this.episodeQueue = const [],
  }) : assert(season >= 0),
       assert(episode > 0);

  final String showId;
  final String showTitle;
  final int season;
  final int episode;
  final int? year;
  final MediaItem? metadata;
  final List<MediaItem> episodeQueue;

  String get contentKey => 'episode:${Uri.encodeComponent(showId)}:$season:$episode';
  String get displayTitle => '$showTitle S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  MediaItem get playerMetadata =>
      metadata ??
      MediaItem(
        id: contentKey,
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: 'Episode $episode',
        grandparentId: showId,
        grandparentTitle: showTitle,
        parentIndex: season,
        index: episode,
        year: year,
      );

  static BeamEpisodeIdentity? fromMetadata(MediaItem item) {
    final season = item.parentIndex;
    final episode = item.index;
    final show = item.grandparentTitle?.trim();
    if (!item.isEpisode ||
        season == null ||
        season < 0 ||
        episode == null ||
        episode <= 0 ||
        show == null ||
        show.isEmpty) {
      return null;
    }
    final id = item.grandparentId;
    return BeamEpisodeIdentity(
      showId: id != null && id.isNotEmpty
          ? '${item.backend.name}:${item.serverId ?? 'discover'}:$id'
          : titleShowId(show, item.year),
      showTitle: show,
      season: season,
      episode: episode,
      year: item.year,
      metadata: item,
    );
  }

  /// Parent-show ID supplied by the verified episode catalog, never an
  /// episode GUID or a title-derived guess. Kept in metadata across queues.
  String? get verifiedShowImdbId {
    final item = metadata;
    final raw = item?.raw;
    final catalogId = raw?['tvmazeShowId'];
    final imdb = raw?['beamShowImdbId'];
    if (item?.isEpisode != true ||
        raw?['beamCatalog'] != 'tvmaze' ||
        catalogId is! int ||
        catalogId <= 0 ||
        imdb is! String ||
        !RegExp(r'^tt\d{6,9}$').hasMatch(imdb)) {
      return null;
    }
    return imdb;
  }

  static String titleShowId(String title, int? year) =>
      'title:${title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ')}:${year ?? ''}';

  /// Catalog story numbering can differ from broadcast numbering. Require
  /// filename story evidence for virtual catalog episodes only.
  EpisodeStoryConstraint? get storyConstraint {
    bool isCatalog(MediaItem item) =>
        item.isEpisode && item.serverId?.isNotEmpty != true && item.raw?['beamCatalog'] == 'tvmaze';
    final current = metadata;
    if (current == null || !isCatalog(current)) return null;
    final evidence = current.raw?['beamNumberingEvidence'];
    if (evidence is Map &&
        evidence['authority'] == 'tvmaze-broadcast-bijection-v1' &&
        evidence['showId'] == current.raw?['tvmazeShowId'] &&
        evidence['showId'] is int &&
        (evidence['showId'] as int) > 0 &&
        evidence['episodeId'] == current.raw?['tvmazeEpisodeId'] &&
        evidence['episodeId'] is int &&
        (evidence['episodeId'] as int) > 0 &&
        current.parentIndex == season &&
        current.index == episode &&
        evidence['season'] == season &&
        evidence['episode'] == episode &&
        evidence['title'] == current.title &&
        current.title?.trim().isNotEmpty == true &&
        evidence['alternateListId'] is int &&
        (evidence['alternateListId'] as int) > 0 &&
        evidence['source'] ==
            'https://api.tvmaze.com/alternatelists/${evidence['alternateListId']}/alternateepisodes') {
      return null;
    }
    return EpisodeStoryConstraint(
      // Empty catalog titles deliberately fail closed in the selector.
      title: current.title?.trim() ?? '',
      companionTitles: Map.unmodifiable({
        for (final item in episodeQueue)
          if (item.isEpisode &&
              item.parentIndex == season &&
              item.index != null &&
              item.index! > 0 &&
              item.title?.trim().isNotEmpty == true)
            item.index!: item.title!.trim(),
      }),
    );
  }

  /// Keep the requested identity/resume key while avoiding replay of another
  /// story explicitly included in this file. This is file membership only:
  /// never guess adjacent episode numbers or chapter/start offsets.
  BeamEpisodeIdentity forSelectedFile(String? filename) {
    if (filename == null || episodeQueue.isEmpty) return this;
    final members = EpisodeFileSelector.episodesFor(filename, season: season);
    if (members == null || members.length < 2 || !members.contains(episode)) return this;
    final queue = episodeQueue
        .where(
          (item) =>
              !item.isEpisode || item.parentIndex != season || item.index == episode || !members.contains(item.index),
        )
        .toList();
    if (queue.length == episodeQueue.length) return this;
    return BeamEpisodeIdentity(
      showId: showId,
      showTitle: showTitle,
      season: season,
      episode: episode,
      year: year,
      metadata: metadata,
      episodeQueue: List.unmodifiable(queue),
    );
  }

  BeamEpisodeIdentity forEpisode(MediaItem item) {
    if (!item.isEpisode ||
        item.parentIndex == null ||
        item.index == null ||
        item.index! <= 0 ||
        item.parentIndex! < 0) {
      throw ArgumentError('Episode navigation requires exact season and episode metadata');
    }
    return BeamEpisodeIdentity(
      showId: showId,
      showTitle: showTitle,
      season: item.parentIndex!,
      episode: item.index!,
      year: year,
      metadata: item,
      episodeQueue: episodeQueue,
    );
  }

  Map<String, dynamic> toJson() => {
    'showId': showId,
    'showTitle': showTitle,
    'season': season,
    'episode': episode,
    'year': year,
    'metadata': metadata?.toJson(),
    'episodeQueue': episodeQueue.map((e) => e.toJson()).toList(),
  };

  factory BeamEpisodeIdentity.fromJson(Map<String, dynamic> json) => BeamEpisodeIdentity(
    showId: json['showId'] as String,
    showTitle: json['showTitle'] as String,
    season: json['season'] as int,
    episode: json['episode'] as int,
    year: json['year'] as int?,
    metadata: json['metadata'] == null ? null : MediaItem.fromJson(Map<String, dynamic>.from(json['metadata'] as Map)),
    episodeQueue: [
      for (final item in json['episodeQueue'] as List? ?? const [])
        MediaItem.fromJson(Map<String, dynamic>.from(item as Map)),
    ],
  );
}
