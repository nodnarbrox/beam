import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/beam/indexer_search.dart';
import 'package:plezy/services/beam/release_identity.dart';

void main() {
  const title = 'Spidey And His Amazing Friends S04E14 1080p WEB h264-DOLORES';
  Map<String, Object> row(int category, {String name = title}) => {
    'name': name,
    'category': '$category',
    'info_hash': category.toRadixString(16).padLeft(40, '0'),
    'size': '1000000',
    'seeders': '10',
    'leechers': '0',
  };

  test('real API TV categories survive adapter then exact episode identity gate', () async {
    final queries = <String>[];
    final source = ApibaySource(
      clientFactory: () async => MockClient((request) async {
        queries.add(request.url.queryParameters['q']!);
        return http.Response(
          jsonEncode([
            row(205),
            row(208),
            row(205000),
            row(201),
            row(501),
            row(208, name: 'Other Spidey And His Amazing Friends S04E14 1080p WEB'),
            row(208, name: 'Spidey And His Amazing Friends S04E13 1080p WEB'),
          ]),
          200,
        );
      }),
    );
    const query = 'Spidey and His Amazing Friends S04E14';
    final results = await source.search(query, categories: const [5000]);
    expect(queries, [query]);
    expect(results.take(3).map((source) => source.categories.single), everyElement(5000));
    final matched = results
        .where(
          (source) => ReleaseIdentity.matchesEpisodeSource(
            source,
            show: 'Spidey and His Amazing Friends',
            season: 4,
            episode: 14,
          ),
        )
        .toList();
    expect(matched.length, 3);
    expect(matched.map((source) => source.title), everyElement(title));
    expect(results[3].categories, [2000]);
    expect(results[4].categories, [6000]);
  });

  test('movie categories retain movie eligibility and adult categories stay excluded', () async {
    const movie = 'The.Butler.2013.1080p.BluRay.x264';
    final source = ApibaySource(
      clientFactory: () async => MockClient(
        (_) async =>
            http.Response(jsonEncode([row(201, name: movie), row(207, name: movie), row(501, name: movie)]), 200),
      ),
    );
    final results = await source.search('The Butler 2013');
    expect(results.map((source) => ReleaseIdentity.matchesMovie(source, title: 'The Butler', year: 2013)), [
      true,
      true,
      false,
    ]);
  });
}
