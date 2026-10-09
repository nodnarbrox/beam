import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_item_types.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/beam_library_service.dart';

void main() {
  MediaItem original(int episode) => MediaItem(
    id: 'episode-$episode',
    backend: MediaBackend.plex,
    kind: MediaKind.episode,
    title: 'Pioneer episode $episode',
    serverId: 'server-a',
    grandparentId: 'pioneer-one',
    grandparentTitle: 'Pioneer One',
    parentIndex: 1,
    index: episode,
  );

  test('TV metadata and next target survive serialized library replay', () {
    final first = original(1);
    final second = original(2);
    final identity = BeamEpisodeIdentity(
      showId: 'pioneer-one',
      showTitle: 'Pioneer One',
      season: 1,
      episode: 1,
      metadata: first,
      episodeQueue: [first, second],
    );
    final restored = BeamEpisodeIdentity.fromJson(identity.toJson());
    final next = restored.forEpisode(restored.episodeQueue[1]);
    expect(next.contentKey, isNot(identity.contentKey));
    expect(next.playerMetadata.isEpisode, isTrue);
    expect(next.playerMetadata.id, second.id);
    expect(next.playerMetadata.serverId, 'server-a');
    expect(next.playerMetadata.title, second.title);
    expect(next.season, 1);
    expect(next.episode, 2);
    expect(next.showId, identity.showId);
    expect(next.episodeQueue.length, 2);
  });

  test('paired file queue skips included stories but retains current identity and other seasons', () {
    final first = original(1);
    final second = original(2);
    final third = original(3);
    final otherSeason = original(1).copyWith(id: 'season-two-episode-one', parentIndex: 2);
    final identity = BeamEpisodeIdentity(
      showId: 'pioneer-one',
      showTitle: 'Pioneer One',
      season: 1,
      episode: 2,
      year: 2010,
      metadata: second,
      episodeQueue: [first, second, third, otherSeason],
    );
    final selected = identity.forSelectedFile('pack/Pioneer.One.S01E01-E02.mp4');
    expect(selected.episodeQueue, [second, third, otherSeason]);
    expect(selected.contentKey, identity.contentKey);
    expect(selected.playerMetadata, same(second));
    expect(selected.showTitle, identity.showTitle);
    expect(selected.year, 2010);
    expect(selected.episode, 2);
    expect(identity.episodeQueue, [first, second, third, otherSeason], reason: 'Original catalog queue stays intact.');
    expect(selected.forEpisode(third).episodeQueue, [second, third, otherSeason]);
    final fromFirst = identity.forEpisode(first).forSelectedFile('Pioneer.One.S01E01-E02.mp4');
    expect(fromFirst.episodeQueue, [
      first,
      third,
      otherSeason,
    ], reason: 'Next skips the story already included in this file.');
    expect(fromFirst.episode, 1);
  });

  test('explicit disjoint membership never removes an unnamed number between stories', () {
    final identity = BeamEpisodeIdentity(
      showId: 'pioneer-one',
      showTitle: 'Pioneer One',
      season: 1,
      episode: 1,
      episodeQueue: [original(1), original(2), original(3), original(4)],
    );
    final selected = identity.forSelectedFile('Pioneer.One.S01E01E03.mkv');
    expect(selected.episodeQueue.map((item) => item.index), [1, 2, 4]);
  });

  test('missing, single, ambiguous, wrong-season or unrelated files cannot alter the queue', () {
    final identity = BeamEpisodeIdentity(
      showId: 'pioneer-one',
      showTitle: 'Pioneer One',
      season: 1,
      episode: 2,
      episodeQueue: [original(1), original(2), original(3), original(4)],
    );
    for (final filename in <String?>[
      null,
      'Pioneer.One.S01E02.mkv',
      'Pioneer.One.02.mkv',
      'Pioneer.One.S02E01-E02.mkv',
      'Pioneer.One.S01E03-E04.mkv',
      'Pioneer.One.S01E01-E99.mkv',
    ]) {
      expect(
        identity.forSelectedFile(filename),
        same(identity),
        reason: '$filename is not proof of current combined membership',
      );
    }
  });

  test('incomplete episode metadata cannot manufacture an episode identity', () {
    expect(BeamEpisodeIdentity.fromMetadata(original(1).copyWith(index: null)), isNull);
    expect(BeamEpisodeIdentity.fromMetadata(original(1).copyWith(parentIndex: null)), isNull);
    expect(BeamEpisodeIdentity.fromMetadata(original(1).copyWith(grandparentTitle: null)), isNull);
    expect(BeamEpisodeIdentity.fromMetadata(original(1).copyWith(index: 0)), isNull);
  });

  test('only virtual catalog identity requires story proof and carries known same-season companion titles', () {
    final current = original(2).copyWith(serverId: null, title: 'To Catch a Cat', raw: {'beamCatalog': 'tvmaze'});
    final companion = original(1).copyWith(title: 'Mixing Up Trouble');
    final elsewhere = original(3).copyWith(parentIndex: 2, title: 'Another season');
    final identity = BeamEpisodeIdentity(
      showId: 'show',
      showTitle: 'Show',
      season: 1,
      episode: 2,
      metadata: current,
      episodeQueue: [companion, current, elsewhere],
    );
    expect(identity.storyConstraint?.title, 'To Catch a Cat');
    expect(identity.storyConstraint?.companionTitles, {1: 'Mixing Up Trouble', 2: 'To Catch a Cat'});
    expect(identity.forEpisode(companion).storyConstraint, isNull);
    expect(BeamEpisodeIdentity.fromMetadata(original(2))!.storyConstraint, isNull);
    final emptyTitle = current.copyWith(title: null);
    expect(
      BeamEpisodeIdentity.fromMetadata(emptyTitle)!.storyConstraint?.title,
      '',
      reason: 'Missing catalog title must still activate a failing constraint.',
    );
  });

  test('season-pack episodes keep separate resume across a changed source and database reopen', () async {
    final directory = await Directory.systemTemp.createTemp('beam-episode-test');
    final file = File('${directory.path}/library.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      var library = BeamLibraryService(db);
      final first = BeamEpisodeIdentity.fromMetadata(original(1))!;
      final second = BeamEpisodeIdentity.fromMetadata(original(2))!;
      for (final episode in [first, second]) {
        await library.recordPlayed(
          infoHash: 'same-pack-hash',
          title: episode.displayTitle,
          magnet: 'magnet:?xt=urn:btih:same-pack-hash',
          episode: episode,
        );
      }
      await library.saveProgress(infoHash: first.contentKey, positionMs: 12000, durationMs: 100000);
      await library.saveProgress(infoHash: second.contentKey, positionMs: 42000, durationMs: 100000);
      await library.recordPlayed(
        infoHash: 'replacement-source',
        title: second.displayTitle,
        magnet: 'magnet:?xt=urn:btih:replacement-source',
        episode: second,
      );
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      library = BeamLibraryService(db);
      expect((await library.resumeFor(first.contentKey))?.inMilliseconds, 12000);
      expect((await library.resumeFor(second.contentKey))?.inMilliseconds, 42000);
      expect(await library.resumeFor('same-pack-hash'), isNull);
      final rows = await library.continueWatching();
      expect(rows.length, 2);
      final row = rows.singleWhere((e) => e.episode?.episode == 2);
      expect(row.infoHash, 'replacement-source');
      expect(row.contentKey, second.contentKey);
      expect(row.episode?.playerMetadata.title, original(2).title);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test('legacy movie progress remains readable', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final library = BeamLibraryService(db);
      await library.recordPlayed(infoHash: 'movie-hash', title: 'Movie', magnet: 'magnet');
      await library.saveProgress(infoHash: 'movie-hash', positionMs: 10000, durationMs: 100000);
      expect((await library.resumeFor('movie-hash'))?.inMilliseconds, 10000);
      expect((await library.recentlyPlayed()).single.episode, isNull);
    } finally {
      await db.close();
    }
  });

  test('grab-only episode keeps content identity without a source hash', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      final library = BeamLibraryService(db);
      final episode = BeamEpisodeIdentity.fromMetadata(original(2))!;
      await library.recordPlayed(
        infoHash: '',
        title: episode.displayTitle,
        magnet: 'https://example.test/episode.torrent',
        episode: episode,
      );
      await library.saveProgress(infoHash: episode.contentKey, positionMs: 25000, durationMs: 100000);
      final row = (await library.continueWatching()).single;
      expect(row.episode?.episode, 2);
      expect(row.contentKey, episode.contentKey);
      expect((await library.resumeFor(row.contentKey))?.inMilliseconds, 25000);
    } finally {
      await db.close();
    }
  });

  test('v21 library migrates without losing legacy rows or progress', () async {
    final directory = await Directory.systemTemp.createTemp('beam-migration-test');
    final file = File('${directory.path}/library.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final library = BeamLibraryService(db);
      await library.recordPlayed(infoHash: 'legacy', title: 'Legacy movie', magnet: 'magnet');
      await library.saveProgress(infoHash: 'legacy', positionMs: 15000, durationMs: 100000);
      // Recreate the exact v21 Beam column set and version on an otherwise
      // complete database, then exercise the real onUpgrade implementation.
      await db.customStatement('ALTER TABLE beam_library DROP COLUMN source_info_hash');
      await db.customStatement('ALTER TABLE beam_library DROP COLUMN playback_metadata_json');
      await db.customStatement('PRAGMA user_version = 21');
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      final migrated = BeamLibraryService(db);
      expect((await migrated.resumeFor('legacy'))?.inMilliseconds, 15000);
      final legacy = (await migrated.recentlyPlayed()).single;
      expect(legacy.infoHash, 'legacy');
      expect(legacy.episode, isNull);
      final episode = BeamEpisodeIdentity.fromMetadata(original(2))!;
      await migrated.recordPlayed(infoHash: 'pack', title: episode.displayTitle, magnet: 'magnet', episode: episode);
      expect((await migrated.recentlyPlayed()).singleWhere((e) => e.episode != null).contentKey, episode.contentKey);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
}
