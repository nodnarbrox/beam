import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/show_catalog_merge.dart';
import 'package:plezy/services/beam/show_episode_catalog.dart';

void main() {
  test('fills exact missing numbers with real metadata while preserving server identities and watch state', () {
    final owned = libraryEpisode(9, 'Campout Chaos').copyWith(viewOffsetMs: 1234, viewCount: 2);
    final ownedVersion = owned.copyWith(id: 'other-version', serverId: 'other-server');
    final ownedSeason = MediaItem(
      id: 'server-season-4',
      backend: MediaBackend.plex,
      kind: MediaKind.season,
      index: 4,
      title: 'Season 4',
      serverId: 'server',
      viewedLeafCount: 3,
    );
    final result = mergeShowCatalog(
      show: show,
      catalog: catalog([
        episode(9, 'Campout Chaos'),
        episode(13, 'Lost Lair of Web-Beard'),
        episode(15, 'Mixing Up Trouble'),
      ]),
      librarySeasons: [ownedSeason],
      libraryEpisodes: [owned, ownedVersion],
    );
    expect(result.conflicts, isEmpty);
    expect(result.episodes.map((item) => item.index), [9, 9, 13, 15]);
    expect(identical(result.episodes[0], owned), isTrue);
    expect(identical(result.episodes[1], ownedVersion), isTrue);
    expect(identical(result.seasons.single, ownedSeason), isTrue);
    final missing = result.episodes[2];
    expect(missing.serverId, isNull);
    expect(missing.raw?['beamShowImdbId'], 'tt10862280');
    expect(BeamEpisodeIdentity.fromMetadata(missing)?.verifiedShowImdbId, 'tt10862280');
    expect(missing.raw?['beamShowAliases'], ["Marvel's Spidey and His Amazing Friends"]);
    expect(missing.id, 'tvmaze:episode:4013');
    expect(missing.title, 'Lost Lair of Web-Beard');
    expect(missing.summary, 'Actual episode summary');
    expect(missing.originallyAvailableAt, '2026-09-24');
    expect(missing.year, 2021);
    expect(missing.parentId, 'server-season-4');
    expect(missing.grandparentId, show.id);
    expect(missing.grandparentTitle, show.title);
    expect(missing.thumbPath, 'https://images.test/episode.jpg');
    expect(missing.grandparentThumbPath, show.thumbPath);
    expect(missing.artPath, show.artPath);
    expect(missing.durationMs, 660000);
    expect(isCatalogEpisode(missing), isTrue);
    expect(catalogEpisodeKey(missing), 'S4E13');
    expect(BeamEpisodeIdentity.fromMetadata(missing)?.year, 2021);
  });

  test('parent IMDb getter rejects guessed, malformed and unbound metadata', () {
    final valid = mergeShowCatalog(show: show, catalog: catalog([episode(13, 'Story')])).episodes.single;
    for (final raw in [
      {...?valid.raw}..remove('beamCatalog'),
      {...?valid.raw, 'beamShowImdbId': 'tt12'},
      {...?valid.raw, 'tvmazeShowId': 0},
      {...?valid.raw}..remove('beamShowImdbId'),
    ]) {
      expect(BeamEpisodeIdentity.fromMetadata(valid.copyWith(raw: raw))?.verifiedShowImdbId, isNull);
    }
  });

  test('does not fabricate gaps or numbers for unnumbered specials; preserves numbered season zero', () {
    final result = mergeShowCatalog(
      show: show,
      catalog: catalog([
        episode(13, 'Thirteen'),
        episode(null, 'Unnumbered special', season: 0),
        episode(2, 'Numbered special', season: 0),
        episode(0, 'Invalid zero'),
      ]),
    );
    expect(result.episodes.map(catalogEpisodeKey), ['S0E2', 'S4E13']);
    expect(result.seasons.map((item) => item.index), [0, 4]);
    expect(result.seasons.every(isCatalogSeason), isTrue);
    expect(result.seasons.every((item) => item.serverId == null), isTrue);
    expect(result.seasons.map((item) => item.leafCount), [1, 1]);
  });

  test('material title mismatch blocks additions for the whole conflicting season only', () {
    final owned = libraryEpisode(9, 'A Different Story');
    final result = mergeShowCatalog(
      show: show,
      catalog: catalog([episode(9, 'Campout Chaos'), episode(13, 'Lost Lair'), episode(1, 'Other season', season: 5)]),
      libraryEpisodes: [owned],
    );
    expect(result.conflictedSeasons, {4});
    expect(result.conflicts.single.libraryTitle, 'A Different Story');
    expect(result.conflicts.single.catalogTitle, 'Campout Chaos');
    expect(result.episodes.map(catalogEpisodeKey), ['S4E9', 'S5E1']);
    expect(result.episodes.first, same(owned));
    expect(result.seasons.map((item) => item.index), [5]);
  });

  test('punctuation, markup and placeholder titles do not falsely block additions', () {
    final result = mergeShowCatalog(
      show: show,
      catalog: catalog([episode(9, 'Campout Chaos'), episode(13, 'Lost Lair'), episode(15, 'Mixing Up Trouble')]),
      libraryEpisodes: [libraryEpisode(9, '<b>Camp-Out: Chaos!</b>'), libraryEpisode(13, 'Episode 13')],
    );
    expect(result.conflicts, isEmpty);
    expect(result.episodes.map(catalogEpisodeKey), ['S4E9', 'S4E13', 'S4E15']);
  });

  test('a conflicting duplicate library version also blocks additions without dropping either version', () {
    final first = libraryEpisode(9, 'Campout Chaos');
    final second = libraryEpisode(9, 'Different numbering').copyWith(id: 'version-two');
    final result = mergeShowCatalog(
      show: show,
      catalog: catalog([episode(9, 'Campout Chaos'), episode(13, 'Lost Lair')]),
      libraryEpisodes: [first, second],
    );
    expect(result.episodes, [first, second]);
    expect(result.conflictedSeasons, {4});
  });

  test('refresh replaces virtual episodes with new server entries and remains idempotent', () {
    final source = catalog([episode(9, 'Campout Chaos'), episode(13, 'Lost Lair')]);
    final initial = mergeShowCatalog(show: show, catalog: source);
    final owned = libraryEpisode(9, 'Campout Chaos');
    final refreshed = mergeShowCatalog(
      show: show,
      catalog: source,
      librarySeasons: initial.seasons,
      libraryEpisodes: [...initial.episodes, owned],
    );
    expect(refreshed.episodes.length, 2);
    expect(refreshed.episodes.first, same(owned));
    expect(refreshed.episodes.last.id, initial.episodes.last.id);
    expect(refreshed.seasons.single.id, initial.seasons.single.id);
  });

  test('unnumbered library items remain intact and cannot suppress a numbered catalog episode', () {
    final unknown = libraryEpisode(9, 'Unknown').copyWith(index: null);
    final result = mergeShowCatalog(
      show: show,
      catalog: catalog([episode(9, 'Campout Chaos')]),
      libraryEpisodes: [unknown],
    );
    expect(result.episodes.length, 2);
    expect(result.episodes.last, same(unknown));
    expect(catalogEpisodeKey(unknown), isNull);
    expect(isCatalogEpisode(unknown), isFalse);
  });

  test('only explicitly marked items are recognized as catalog metadata', () {
    final ordinary = libraryEpisode(9, 'Campout Chaos').copyWith(serverId: null);
    expect(isCatalogEpisode(ordinary), isFalse);
    expect(isCatalogSeason(ordinary), isFalse);
    final result = mergeShowCatalog(show: show, catalog: catalog([episode(9, 'Campout Chaos')]));
    expect(isCatalogEpisode(result.seasons.single), isFalse);
    expect(isCatalogSeason(result.episodes.single), isFalse);
  });
}

final show = MediaItem(
  id: 'library-show',
  backend: MediaBackend.plex,
  kind: MediaKind.show,
  title: 'Spidey and His Amazing Friends',
  year: 2021,
  serverId: 'server',
  thumbPath: 'https://images.test/show.jpg',
  artPath: 'https://images.test/show-art.jpg',
);

MediaItem libraryEpisode(int number, String title) => MediaItem(
  id: 'library-episode-$number',
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: title,
  parentIndex: 4,
  index: number,
  serverId: 'server',
);

ShowCatalogEpisode episode(int? number, String title, {int season = 4}) => ShowCatalogEpisode(
  id: season * 1000 + (number ?? 999),
  seasonNumber: season,
  episodeNumber: number,
  name: title,
  airdate: '2026-09-24',
  imageUrl: 'https://images.test/episode.jpg',
  summary: 'Actual episode summary',
  sourceUrl: 'https://www.tvmaze.com/episodes/fixture',
  runtimeMinutes: 11,
);

ShowEpisodeCatalogResult catalog(List<ShowCatalogEpisode> episodes) => ShowEpisodeCatalogResult(
  tvmazeId: 43708,
  imdbId: 'tt10862280',
  name: 'Spidey and His Amazing Friends',
  aliases: const ["Marvel's Spidey and His Amazing Friends"],
  premiered: '2021-08-06',
  sourceUrl: 'https://www.tvmaze.com/shows/43708',
  seasons: [
    for (final number in episodes.map((item) => item.seasonNumber).toSet())
      ShowCatalogSeason(
        id: number + 400,
        number: number,
        episodes: episodes.where((item) => item.seasonNumber == number).toList(),
      ),
  ],
  episodes: episodes,
);
