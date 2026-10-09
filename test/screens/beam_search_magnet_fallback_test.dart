import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:plezy/screens/beam/beam_search_screen.dart';
import 'package:plezy/services/beam/beam_config.dart';
import 'package:plezy/services/beam/beam_episode_identity.dart';
import 'package:plezy/services/beam/indexer_search.dart';
import 'package:plezy/services/beam/tpb_magnet_source.dart';

void main() {
  for (final episode in [true, false]) {
    testWidgets('Search displays automatic ${episode ? 'TV' : 'movie'} magnets and rejects mismatched titles', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await BeamConfig.init();
      final title = episode ? 'Pioneer One S01E02 720p WEB' : 'Big Buck Bunny 2008 720p BluRay';
      final wrong = episode ? 'Pioneer One S01E03 720p WEB' : 'Wrong Movie 2008 720p BluRay';
      final html =
          '''<table id="searchResult">
      <tr><th>Type</th><th>Name</th><th>Uploaded</th><th></th><th>Size</th><th>SE</th><th>LE</th></tr>
      ${[title, wrong].indexed.map((entry) => '''<tr><td><a href="/browse/${episode ? 208 : 201}">Video</a></td>
      <td><a href="/torrent/${entry.$1 + 1}/title">${entry.$2}</a></td><td>date</td>
      <td><a href="magnet:?xt=urn:btih:${'${entry.$1 + 1}' * 40}">magnet</a></td><td>1 GiB</td><td>11</td><td>0</td></tr>''').join()}
      </table>''';
      var calls = 0;
      final indexer = CombinedIndexer(
        direct: MultiIndexer(
          sources: [
            ApibaySource(
              clientFactory: () async => MockClient((_) async => http.Response('[]', 200)),
              fallback: TpbMagnetSource(
                clientFactory: () async => MockClient((_) async {
                  calls++;
                  return http.Response(html, 200);
                }),
              ),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BeamSearchScreen(
            initialQuery: episode ? 'Pioneer One S01E02' : 'Big Buck Bunny 2008',
            beamEpisode: episode
                ? BeamEpisodeIdentity(showId: 'fixture', showTitle: 'Pioneer One', season: 1, episode: 2)
                : null,
            movieTitle: episode ? null : 'Big Buck Bunny',
            movieYear: episode ? null : 2008,
            indexer: indexer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('No results'), findsNothing);
      expect(find.textContaining(episode ? 'Pioneer One' : 'Big Buck Bunny'), findsWidgets);
      expect(find.textContaining(episode ? 'S01E03' : 'Wrong Movie'), findsNothing);
      expect(find.text('11'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
