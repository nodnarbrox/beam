import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/beam/beam_cancellation.dart';
import 'package:plezy/services/beam/beam_fallback.dart';
import 'package:plezy/services/beam/beam_play_service.dart';
import 'package:plezy/services/beam/episode_file_selector.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';

class Attempt {
  final rd = Completer<BeamPlayResult>();
  final torrent = Completer<BeamPlayResult>();
  late BeamCancellation rdToken;
  late BeamCancellation torrentToken;
  bool get cancelled => rdToken.isCancelled && torrentToken.isCancelled;
}

class Harness {
  Harness({
    int maxAttempts = 4,
    int? maxTotalAttempts,
    EpisodeStoryConstraint? storyConstraint,
    List<ProwlarrResult>? candidates,
    Iterable<Future<List<ProwlarrResult>>> candidateBatches = const [],
  }) : sources = candidates ?? List.generate(5, source) {
    final service = BeamPlayService(
      realDebrid: (source, season, episode, token) {
        rdStarts.add(source.infoHash!);
        final attempt = attempts.putIfAbsent(source.title, Attempt.new);
        attempt.rdToken = token;
        return attempt.rd.future;
      },
      torrent: (source, season, episode, token) {
        torrentStarts.add(source.infoHash!);
        final attempt = attempts[source.title]!;
        attempt.torrentToken = token;
        return attempt.torrent.future;
      },
    );
    BeamFallback.raceCandidateSources(
      sources,
      service: service,
      rdReady: true,
      torrentReady: true,
      maxAttempts: maxAttempts,
      maxTotalAttempts: maxTotalAttempts,
      candidateBatches: candidateBatches,
      season: 1,
      episode: 2,
      storyConstraint: storyConstraint,
      cancelled: back.future,
    ).then((value) {
      completed = true;
      result = value;
    });
  }
  static ProwlarrResult source(int index) => ProwlarrResult.fromJson({
    'title': 'candidate$index',
    'guid': 'magnet:?xt=urn:btih:${index.toString().padLeft(40, '0')}',
    'seeders': 5,
  });
  final List<ProwlarrResult> sources;
  final rdStarts = <String>[];
  final torrentStarts = <String>[];
  final attempts = <String, Attempt>{};
  final back = Completer<void>();
  bool completed = false;
  (BeamPlayResult, ProwlarrResult)? result;
  Attempt attempt(int index) => attempts['candidate$index']!;
  void succeed(int index, {bool rd = false, String filename = 'Show.S01E02.Correct.Story.mp4'}) {
    final result = BeamPlayResult(
      url: 'https://fixture/$index',
      winner: rd ? BeamPlayWinner.realDebrid : BeamPlayWinner.torrent,
      magnet: sources[index].magnetUrl!,
      selectedFilename: filename,
    );
    (rd ? attempt(index).rd : attempt(index).torrent).complete(result);
  }

  void fail(int index) {
    attempt(index).rd.completeError(StateError('RD unavailable'));
    attempt(index).torrent.completeError(StateError('dead swarm'));
  }
}

void main() {
  test('failed sources refill concurrent slots while stalled RD legs do not delay native winner', () {
    fakeAsync((clock) {
      final h = Harness(maxAttempts: 2, maxTotalAttempts: 4);
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0', 'candidate1']);
      h.attempt(0).rd.completeError(StateError('RD rate limited'));
      clock.flushMicrotasks();
      expect(h.attempts.length, 2, reason: 'One failed transport does not evict a live native attempt.');
      h.attempt(0).torrent.completeError(StateError('Wrong episode'));
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0', 'candidate1', 'candidate2']);
      expect(h.attempt(1).cancelled, isFalse);
      h.succeed(2);
      clock.flushMicrotasks();
      expect(h.result!.$2.title, 'candidate2');
      expect(h.attempt(1).cancelled, isFalse);
      expect(h.attempt(2).rdToken.isCancelled, isFalse);
      h.result!.$1.commitPlayback();
      clock.flushMicrotasks();
      expect(h.attempt(1).cancelled, isTrue);
      expect(h.attempt(2).rdToken.isCancelled, isTrue);
      expect(h.attempts.length, 3, reason: 'Queued candidates cannot launch after handoff.');
      h.result!.$1.cancel();
      clock.flushMicrotasks();
    });
  });

  test('a later provider can fill a failed slot ahead of unused earlier variants', () {
    fakeAsync((clock) {
      final batch = Completer<List<ProwlarrResult>>();
      final h = Harness(maxAttempts: 2, maxTotalAttempts: 4, candidateBatches: [batch.future]);
      clock.flushMicrotasks();
      batch.complete([Harness.source(0), Harness.source(8)]);
      clock.flushMicrotasks();
      expect(h.attempts.length, 2);
      h.fail(0);
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0', 'candidate1', 'candidate8']);
      expect(h.rdStarts, h.torrentStarts);
      h.back.complete();
      clock.flushMicrotasks();
      expect(h.attempts.values.every((attempt) => attempt.cancelled), isTrue);
      h.fail(8);
      clock.flushMicrotasks();
      expect(h.attempts.length, 3);
    });
  });

  test('replacement attempts respect lifetime budget without serializing active sources', () {
    fakeAsync((clock) {
      final h = Harness(maxAttempts: 2, maxTotalAttempts: 4);
      clock.flushMicrotasks();
      for (var i = 0; i < 4; i++) {
        expect(h.attempts.containsKey('candidate$i'), isTrue);
        expect(h.attempts.values.where((attempt) => !attempt.cancelled).length, lessThanOrEqualTo(2));
        h.fail(i);
        clock.flushMicrotasks();
      }
      expect(h.attempts.length, 4);
      expect(h.completed, isTrue);
      expect(h.result, isNull);
    });
  });

  test('duplicate info hashes do not consume distinct-source slots', () {
    fakeAsync((clock) {
      final h = Harness(
        maxAttempts: 3,
        candidates: [
          Harness.source(0),
          ProwlarrResult.fromJson({
            'title': 'renamed duplicate',
            'guid': '${Harness.source(0).magnetUrl!}&tr=https%3A%2F%2Ftracker.invalid',
            'seeders': 10,
          }),
          Harness.source(1),
          Harness.source(2),
        ],
      );
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0', 'candidate1', 'candidate2']);
      expect(h.rdStarts.toSet(), hasLength(3));
      expect(h.rdStarts, hasLength(3));
      expect(h.torrentStarts, h.rdStarts);
      h.back.complete();
      clock.flushMicrotasks();
    });
  });

  test('a later batch joins unresolved races immediately and shares their total cap', () {
    fakeAsync((clock) {
      final batch = Completer<List<ProwlarrResult>>();
      final h = Harness(maxAttempts: 3, candidates: [Harness.source(0)], candidateBatches: [batch.future]);
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0']);
      batch.complete([Harness.source(0), Harness.source(1), Harness.source(2), Harness.source(3)]);
      clock.flushMicrotasks();
      expect(clock.elapsed, Duration.zero);
      expect(h.attempts.keys, ['candidate0', 'candidate1', 'candidate2']);
      expect(h.rdStarts, hasLength(3));
      expect(h.torrentStarts, h.rdStarts);
      expect(h.attempt(0).cancelled, isFalse);
      h.back.complete();
      clock.flushMicrotasks();
    });
  });

  test('ready URL prevents later batches launching while existing losers await first frame', () {
    fakeAsync((clock) {
      final batch = Completer<List<ProwlarrResult>>();
      final h = Harness(candidates: [Harness.source(0), Harness.source(1)], candidateBatches: [batch.future]);
      clock.flushMicrotasks();
      h.succeed(0);
      clock.flushMicrotasks();
      batch.complete([Harness.source(2), Harness.source(3)]);
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0', 'candidate1']);
      expect(h.attempt(1).cancelled, isFalse);
      h.result!.$1.commitPlayback();
      clock.flushMicrotasks();
      expect(h.attempt(1).cancelled, isTrue);
      h.result!.$1.cancel();
      clock.flushMicrotasks();
    });
  });

  test('failed current races wait for pending batches; batch failures are consumed', () {
    fakeAsync((clock) {
      final indexed = Completer<List<ProwlarrResult>>();
      final cached = Completer<List<ProwlarrResult>>();
      final h = Harness(candidates: [Harness.source(0)], candidateBatches: [indexed.future, cached.future]);
      clock.flushMicrotasks();
      h.fail(0);
      clock.flushMicrotasks();
      expect(h.completed, isFalse);
      indexed.completeError(StateError('indexer unavailable'));
      clock.flushMicrotasks();
      expect(h.completed, isFalse);
      cached.complete([Harness.source(1)]);
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0', 'candidate1']);
      expect(h.completed, isFalse);
      h.fail(1);
      clock.flushMicrotasks();
      expect(h.completed, isTrue);
      expect(h.result, isNull);
    });
  });

  test('every selected candidate starts both legs immediately and holds losers until first frame', () {
    fakeAsync((clock) {
      final h = Harness();
      clock.flushMicrotasks();
      expect(h.attempts.keys, ['candidate0', 'candidate1', 'candidate2', 'candidate3']);
      expect(h.rdStarts, h.sources.take(4).map((source) => source.infoHash));
      expect(h.torrentStarts, h.rdStarts);
      expect(clock.elapsed, Duration.zero);
      clock.elapse(const Duration(minutes: 2));
      expect(h.attempts.length, 4);
      h.succeed(1);
      clock.flushMicrotasks();
      expect(h.result!.$2.title, 'candidate1');
      expect(h.result!.$1.selectedFilename, 'Show.S01E02.Correct.Story.mp4');
      expect(h.attempts.values.every((attempt) => !attempt.cancelled), isTrue);
      expect(h.attempt(1).rdToken.isCancelled, isFalse);
      clock.elapse(const Duration(minutes: 1));
      expect(h.attempts.length, 4);
      h.result!.$1.commitPlayback();
      h.result!.$1.commitPlayback();
      clock.flushMicrotasks();
      expect(h.attempt(0).cancelled, isTrue);
      expect(h.attempt(2).cancelled, isTrue);
      expect(h.attempt(3).cancelled, isTrue);
      expect(h.attempt(1).rdToken.isCancelled, isTrue);
      expect(h.attempt(1).torrentToken.isCancelled, isFalse);
      h.result!.$1.cancel();
      clock.flushMicrotasks();
      expect(h.attempt(1).cancelled, isTrue);
    });
  });

  test('all selected attempts start before any failure and total attempts stay bounded', () {
    fakeAsync((clock) {
      final h = Harness(maxAttempts: 3);
      clock.flushMicrotasks();
      expect(h.attempts.length, 3);
      expect(h.rdStarts, hasLength(3));
      expect(h.torrentStarts, hasLength(3));
      h.fail(0);
      clock.flushMicrotasks();
      expect(h.attempts.length, 3);
      expect(h.attempt(0).cancelled, isTrue);
      h.fail(1);
      clock.flushMicrotasks();
      expect(h.attempts.length, 3);
      expect(h.completed, isFalse);
      h.fail(2);
      clock.flushMicrotasks();
      expect(h.completed, isTrue);
      expect(h.result, isNull);
      clock.elapse(const Duration(minutes: 10));
      expect(h.attempts.length, 3);
    });
  });

  test('one failed race cannot delay or cancel the other already running candidates', () {
    fakeAsync((clock) {
      final h = Harness();
      clock.flushMicrotasks();
      expect(h.attempts.length, 4);
      h.fail(0);
      clock.flushMicrotasks();
      expect(h.attempts.length, 4);
      expect(h.attempt(1).cancelled, isFalse);
      expect(h.attempt(2).cancelled, isFalse);
      expect(h.attempt(3).cancelled, isFalse);
      clock.elapse(const Duration(minutes: 1));
      expect(h.attempts.length, 4);
      h.back.complete();
      clock.flushMicrotasks();
    });
  });

  for (final ready in [false, true]) {
    test(
      'Back ${ready ? "after URL before first frame" : "during all pending races"} cancels all and prevents late handoff',
      () {
        fakeAsync((clock) {
          final h = Harness();
          clock.flushMicrotasks();
          expect(h.attempts.length, 4);
          if (ready) {
            h.succeed(1);
            clock.flushMicrotasks();
          }
          h.back.complete();
          clock.flushMicrotasks();
          expect(h.attempts.values.every((attempt) => attempt.cancelled), isTrue);
          if (!ready) {
            expect(h.completed, isTrue);
            expect(h.result, isNull);
          }
          h.succeed(0);
          h.attempt(0).rd.completeError(StateError('late source failure'));
          clock.flushMicrotasks();
          h.result?.$1.commitPlayback();
          clock.elapse(const Duration(minutes: 10));
          expect(h.attempts.length, 4);
          expect(h.attempts.values.every((attempt) => attempt.cancelled), isTrue);
        });
      },
    );
  }

  test('another candidate URL arriving before commit stays owned and is cancelled at commit', () {
    fakeAsync((clock) {
      final h = Harness();
      clock.flushMicrotasks();
      h.succeed(1);
      clock.flushMicrotasks();
      h.succeed(0, rd: true);
      clock.flushMicrotasks();
      expect(h.result!.$2.title, 'candidate1');
      expect(h.attempt(0).cancelled, isFalse);
      h.result!.$1.commitPlayback();
      clock.flushMicrotasks();
      expect(h.attempt(0).cancelled, isTrue);
      h.succeed(3, rd: true);
      h.attempt(3).torrent.completeError(StateError('late native failure'));
      clock.flushMicrotasks();
      expect(h.result!.$2.title, 'candidate1');
      expect(h.attempt(3).cancelled, isTrue);
      h.result!.$1.cancel();
      clock.flushMicrotasks();
    });
  });

  test('simultaneous candidates retain actual story verification on both transports', () {
    fakeAsync((clock) {
      final h = Harness(storyConstraint: const EpisodeStoryConstraint(title: 'Correct Story'));
      clock.flushMicrotasks();
      expect(h.attempts.length, 4);
      h.succeed(0, filename: 'Show.S01E02.Wrong.Story.mp4');
      h.succeed(0, rd: true, filename: 'Show.S01E02.Other.Story.mp4');
      clock.flushMicrotasks();
      expect(h.completed, isFalse);
      h.succeed(1);
      clock.flushMicrotasks();
      expect(h.result!.$2.title, 'candidate1');
      h.result!.$1.cancel();
      clock.flushMicrotasks();
    });
  });
}
