import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/network_artwork_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/catalog/catalog_item.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/beam/beam_detail_screen.dart';
import 'package:plezy/services/beam/plex_public_discover.dart';
import 'package:plezy/services/catalog/catalog_library_matcher.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/network_artwork.dart';
import 'package:plezy/widgets/optimized_media_image.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/prefs.dart';

class _Matcher implements CatalogLibraryMatcher {
  _Matcher(this.result);
  final Future<List<MediaItem>> result;
  @override
  Future<List<MediaItem>> match(CatalogItem item) => result;
}

class _Servers extends ChangeNotifier implements MultiServerProvider {
  _Servers(this.client);
  final MediaServerClient client;
  bool visible = true;
  @override
  List<String> get onlineServerIds => visible ? [client.serverId] : [];
  @override
  MediaServerClient? getClientForServer(ServerId id) => id == client.serverId ? client : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Discover extends PlexPublicDiscover {
  @override
  Future<BeamDiscoverDetail?> detail(BeamDiscoverItem item) async =>
      BeamDiscoverDetail(item: item, artUrl: 'https://public.invalid/backdrop.jpg');
}

final _item = BeamDiscoverItem(
  title: 'The Butler',
  year: 2013,
  kind: MediaKind.movie,
  guid: 'plex://movie/butler2013',
  ratingKey: 'butler2013',
  posterUrl: 'https://public.invalid/poster.jpg',
);
final _owned = MediaItem(
  id: '42',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: 'The Butler',
  year: 2013,
  serverId: 'owned-server',
  thumbPath: '/library/metadata/42/thumb/custom',
  artPath: '/library/metadata/42/art/custom',
);

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    NetworkArtworkProvider.clientOverride = MockClient(
      (_) async => http.Response.bytes(
        base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
        200,
      ),
    );
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    NetworkArtworkProvider.clientOverride?.close();
    NetworkArtworkProvider.clientOverride = null;
    await db.close();
  });

  testWidgets('verified library poster and backdrop use the owning Plex photo API', (tester) async {
    final client = testPlexClient(serverId: ServerId('owned-server'), baseUrl: 'https://owned.invalid');
    addTearDown(client.close);
    final servers = _Servers(client);
    addTearDown(servers.dispose);
    final matcher = _Matcher(Future.value([_owned]));
    Widget app(CatalogLibraryMatcher current) => MultiProvider(
      providers: [
        ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
        Provider<CatalogLibraryMatcher>.value(value: current),
      ],
      child: MaterialApp(
        home: BeamDetailScreen(item: _item, discover: _Discover()),
      ),
    );
    await tester.pumpWidget(app(matcher));
    await tester.pumpAndSettle();
    final images = tester.widgetList<OptimizedMediaImage>(find.byType(OptimizedMediaImage)).toList();
    expect(images.map((image) => image.imagePath), unorderedEquals([_owned.thumbPath, _owned.artPath]));
    for (final image in images) {
      expect(image.client, same(client));
      final uri = Uri.parse(
        MediaImageHelper.getOptimizedImageUrl(
          client: image.client,
          thumbPath: image.imagePath,
          maxWidth: 100,
          maxHeight: 150,
          devicePixelRatio: 1,
          imageType: image.imageType,
        ),
      );
      expect(uri.host, 'owned.invalid');
      expect(uri.path, '/photo/:/transcode');
      expect(uri.queryParameters['url'], startsWith(image.imagePath!));
    }
    // A profile-scoped matcher change must not continue displaying old art,
    // even if the same server remains reachable under the new profile.
    await tester.pumpWidget(app(_Matcher(Future.value([]))));
    await tester.pumpAndSettle();
    expect(find.byType(OptimizedMediaImage), findsNothing);
    expect(
      tester.widgetList<NetworkArtwork>(find.byType(NetworkArtwork)).map((w) => w.imageUrl),
      contains('https://public.invalid/poster.jpg'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden server retains public Plex artwork', (tester) async {
    final client = testPlexClient(serverId: ServerId('owned-server'));
    addTearDown(client.close);
    final servers = _Servers(client)..visible = false;
    addTearDown(servers.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers),
          Provider<CatalogLibraryMatcher>.value(value: _Matcher(Future.value([_owned]))),
        ],
        child: MaterialApp(
          home: BeamDetailScreen(item: _item, discover: _Discover()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OptimizedMediaImage), findsNothing);
    expect(
      tester.widgetList<NetworkArtwork>(find.byType(NetworkArtwork)).map((w) => w.imageUrl),
      containsAll(['https://public.invalid/poster.jpg', 'https://public.invalid/backdrop.jpg']),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
