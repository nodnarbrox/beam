import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/beam/prowlarr_client.dart';
import 'package:plezy/services/beam/release_identity.dart';

ProwlarrResult release(String title, {int? category}) => ProwlarrResult.fromJson({
  'title': title,
  'seeders': 10000,
  if (category != null)
    'categories': [
      {'id': category},
    ],
});

void main() {
  group('independent movie identity judge', () {
    for (final name in [
      '[JoyBear] Paige Turnah (Fleur distracts the butler / 12.18.2013)',
      'Fleur distracts the butler 2013 1080p',
      'The.Butler.2024.1080p.BluRay',
      'The.Butler.2.2013.1080p.BluRay',
      'The.Butler.Returns.2013.1080p.BluRay',
      'The.Butler.2013.Trailer.1080p',
      'The.Butler.2013.Sample.1080p',
      'The.Butler.2013.Extras.1080p',
      'The.Butler.2013.S01E01.1080p',
      'The.Butler.1080p.BluRay',
      'The.Butler.2013.2024.1080p',
    ]) {
      test('rejects $name despite high seed count', () {
        expect(ReleaseIdentity.matchesMovie(release(name), title: 'The Butler', year: 2013), isFalse);
      });
    }

    test('accepts exact movie title/year and ordinary release punctuation', () {
      for (final name in ['The.Butler.2013.1080p.BluRay.x264-GROUP', 'The Butler (2013) 720p BluRay']) {
        expect(ReleaseIdentity.matchesMovie(release(name), title: 'The Butler', year: 2013), isTrue);
      }
    });

    test('numeric title is consumed before release year', () {
      expect(ReleaseIdentity.matchesMovie(release('1917.2019.1080p.BluRay'), title: '1917', year: 2019), isTrue);
      expect(
        ReleaseIdentity.matchesMovie(
          release('2001.A.Space.Odyssey.1968.1080p.BluRay'),
          title: '2001: A Space Odyssey',
          year: 1968,
        ),
        isTrue,
      );
    });

    test('alternate title requires explicit catalog alias', () {
      final source = release('Lee.Daniels.The.Butler.2013.1080p.BluRay');
      expect(ReleaseIdentity.matchesMovie(source, title: 'The Butler', year: 2013), isFalse);
      expect(
        ReleaseIdentity.matchesMovie(source, title: 'The Butler', year: 2013, aliases: ["Lee Daniels' The Butler"]),
        isTrue,
      );
    });

    test('explicit TV category cannot become a movie', () {
      expect(
        ReleaseIdentity.matchesMovie(release('The.Butler.2013.1080p', category: 5000), title: 'The Butler', year: 2013),
        isFalse,
      );
    });
  });

  group('independent TV identity judge', () {
    for (final name in [
      'Other.Show.S01E02.720p',
      'Other.Show.Pioneer.One.S01E02.720p',
      'Pioneer.One.More.S01E02.720p',
      'Pioneer.One.S01E03.720p',
      'Pioneer.One.S02.Complete.720p',
      'Pioneer.One.S01E02.Sample.720p',
    ]) {
      test('rejects $name', () {
        expect(
          ReleaseIdentity.matchesEpisodeSource(release(name), show: 'Pioneer One', season: 1, episode: 2),
          isFalse,
        );
      });
    }

    test('accepts exact show, target episode and season pack', () {
      for (final name in [
        'Pioneer.One.S01E02.720p.x264-VODO',
        'Pioneer.One.2010.S01E02.720p',
        'Pioneer.One.S01.Complete.720p',
        'Pioneer One Season 1 720p',
        'Pioneer.One.1x02.720p',
        'Pioneer.One.S01E02E03.720p',
        'Pioneer.One.S01E02-E03.720p',
        'Pioneer.One.S01E02-03.720p',
        'Pioneer.One.1x02x03.720p',
      ]) {
        expect(
          ReleaseIdentity.matchesEpisodeSource(release(name), show: 'Pioneer One', season: 1, episode: 2),
          isTrue,
          reason: name,
        );
      }
    });
  });
}
