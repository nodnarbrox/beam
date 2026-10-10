import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/video_store/video_store_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

class _Libraries extends LibrariesProvider {
  List<MediaLibrary> current = [];
  @override
  List<MediaLibrary> get libraries => List.unmodifiable(current);
  void emit(List<MediaLibrary> value) {
    current = value;
    notifyListeners();
  }
}

class _Client implements MediaServerClient {
  @override
  final serverId = ServerId('fixture-server');
  @override
  final serverName = 'Fixture server';
  int calls = 0;
  Completer<LibraryPage<MediaItem>>? gate;
  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    calls++;
    if (gate != null) return gate!.future;
    return LibraryPage<MediaItem>(
      items: [
        MediaItem(id: libraryId, backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Movie from $libraryId'),
      ],
      totalCount: 1,
      offset: 0,
    );
  }

  @override
  void close() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaLibrary library(String id) => MediaLibrary(
  id: id,
  backend: MediaBackend.plex,
  title: 'Shelf $id',
  kind: MediaKind.movie,
  serverId: 'fixture-server',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
  });
  Future<void> settleStore(WidgetTester tester) async {
    // Static shader loading uses real IO even though this host ultimately
    // chooses the non-Impeller fallback.
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pumpAndSettle();
  }

  testWidgets('store opened before libraries arrive fills shelves and ignores unrelated notices', (tester) async {
    final libraries = _Libraries();
    addTearDown(libraries.dispose);
    final client = _Client();
    final servers = testMultiServer(clients: [client]);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
        ],
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: const Scaffold(body: VideoStoreScreen()),
        ),
      ),
    );
    await settleStore(tester);
    expect(find.textContaining('No titles on the shelves'), findsOneWidget);

    libraries.emit([library('movies')]);
    await settleStore(tester);
    expect(find.text('Shelf movies'), findsOneWidget);
    expect(find.textContaining('No titles on the shelves'), findsNothing);
    expect(client.calls, 1);

    libraries.emit(List.of(libraries.current));
    await settleStore(tester);
    expect(client.calls, 1);

    libraries.emit([library('shows')]);
    await settleStore(tester);
    expect(find.text('Shelf shows'), findsOneWidget);
    expect(find.text('Shelf movies'), findsNothing);
    expect(client.calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old library response cannot populate a new profile store', (tester) async {
    final libraries = _Libraries()..current = [library('old')];
    addTearDown(libraries.dispose);
    final client = _Client()..gate = Completer();
    final servers = testMultiServer(clients: [client]);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<MultiServerProvider>.value(value: servers.provider),
        ],
        child: MaterialApp(
          theme: monoTheme(dark: true),
          home: const Scaffold(body: VideoStoreScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.pump();
    expect(client.calls, 1);
    final oldGate = client.gate!;
    client.gate = null;
    libraries.emit([library('new')]);
    await settleStore(tester);
    expect(find.text('Shelf new'), findsOneWidget);
    oldGate.complete(
      LibraryPage(
        items: [MediaItem(id: 'old', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Old profile movie')],
        totalCount: 1,
        offset: 0,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Shelf old'), findsNothing);
    expect(find.text('Shelf new'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
