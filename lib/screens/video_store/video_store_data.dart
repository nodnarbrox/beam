import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as scene;
import 'package:http/http.dart' as http;

import '../../media/media_item.dart';
import '../../media/library_query.dart';
import '../../media/media_kind.dart';
import '../../media/media_role.dart';
import '../../media/media_library.dart';
import '../../media/media_server_client.dart';
import '../../services/library_query_translator.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/provider_extensions.dart';

/// One title on a shelf: the source [MediaItem] plus its resolved poster
/// texture (or null while loading / evicted / on failure — the shelf paints a
/// solid spine color in that case).
class StoreTitle {
  StoreTitle({required this.item, required this.library, this.texture});

  final MediaItem item;
  final MediaLibrary library;

  /// Shelf-resolution GPU texture built from the poster bytes. Null until a
  /// load resolves, and null AGAIN once the cache evicts it — the racks scroll
  /// through the whole library, so only the posters near the camera are ever
  /// resident. Anything bound to this must re-check it every frame.
  gpu.Texture? texture;

  /// A fetch for this title is in flight.
  bool loading = false;

  /// The server genuinely has no usable poster. Never re-queued.
  bool posterFailed = false;

  /// Generation of the last [VideoStoreData.setWanted] that asked for this
  /// title. Titles whose stamp is stale are eviction candidates.
  int wantGen = -1;

  /// Full per-item metadata, fetched lazily on pick-up. The list query omits
  /// cast headshot paths, so the sleeve needs this for real photos.
  MediaItem? detail;
  bool detailsLoaded = false;

  /// The richest record we have: the detail fetch when it has landed, else the
  /// list item. Every metadata getter below reads through this.
  MediaItem get _best => detail ?? item;

  String get title => item.displayTitle;
  int? get year => item.year;
  String get key => item.globalKey;

  /// A–Z shelving key: the server's sort title ("Matrix, The" style handling is
  /// the server's job), lower-cased so case never splits a letter.
  late final String sortKey =
      ((item.titleSort?.isNotEmpty ?? false) ? item.titleSort! : title)
          .trim()
          .toLowerCase();

  /// The shelf-divider letter this title files under: A–Z, or '#' for
  /// anything starting with a digit or symbol.
  String get shelfLetter {
    if (sortKey.isEmpty) return '#';
    final c = sortKey.codeUnitAt(0);
    if (c >= 97 && c <= 122) return String.fromCharCode(c - 32);
    return '#';
  }

  // Back-of-the-box copy. All of these are genuinely optional on a MediaItem,
  // so the rental card has to degrade when a server returns a sparse record.
  String? get summary => _best.summary;
  String? get tagline => _best.tagline;
  String? get studio => _best.studio;
  String? get contentRating => _best.contentRating;

  /// Genres, crew and billed cast for the printed box back. All optional.
  List<String> get genres => _best.genres ?? const [];
  List<String> get directors => _best.directors ?? const [];

  /// Billed cast as "Actor as Character" (character omitted when unknown).
  List<String> get cast => [
        for (final r in _best.roles ?? const [])
          if (r.tag.isNotEmpty)
            (r.role != null && r.role!.isNotEmpty)
                ? '${r.tag} as ${r.role}'
                : r.tag,
      ];

  /// Billed cast with their headshot paths, for the box back's cast strip.
  List<MediaRole> get castRoles =>
      [for (final r in _best.roles ?? const []) if (r.tag.isNotEmpty) r];

  /// Wide background art for the sleeve, when the server has it.
  String? get backdropPath => _best.artPath;

  /// Critic score as a whole percentage (the "67%" on a detail page), or null.
  int? get ratingPercent {
    // `rating` is on the shared MediaItem surface; `audienceRating` is only on
    // the Plex variant of the sealed union, so don't reach for it here.
    final r = _best.rating;
    if (r == null || r <= 0) return null;
    // Plex/Jellyfin report 0-10; a value already >10 is a percentage.
    return r > 10 ? r.round() : (r * 10).round();
  }

  /// Runtime as "1h 38m" / "47m", or null when the server didn't supply one.
  String? get runtime {
    final ms = _best.durationMs;
    if (ms == null || ms <= 0) return null;
    final total = Duration(milliseconds: ms);
    final h = total.inHours;
    final m = total.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }
}

/// Loads the user's Plex/Jellyfin libraries into video-store sections and
/// streams poster artwork into GPU textures for the 3D racks.
///
/// The WHOLE library is shelved. The first page of each library is loaded
/// before the store opens (so it opens fast); every later page streams in
/// behind it and is filed into the matching section, and the racks simply grow
/// as their title lists do. Poster textures are the scarce resource, not
/// titles: [setWanted] is told which titles are near the camera each frame and
/// the cache keeps exactly those resident, evicting the rest.
///
/// This deliberately reuses the app's own client + URL resolver
/// ([MediaImageHelper.getOptimizedImageUrl]) so the store shows the exact same
/// artwork, auth, and transcoding as the 2D grid — it does not invent its own
/// image pipeline.
class VideoStoreData {
  VideoStoreData({
    this.pageSize = 400,
    this.maxTitlesPerLibrary = 20000,
    this.posterConcurrency = 8,
    this.textureBudget = 700,
    this.posterWidth = 256,
    this.posterHeight = 384,
    this.maxSectionsPerLibrary = 7,
  });

  /// Named genre sections per library before the rest pool into MORE TITLES.
  /// Each section is a rack face of `rows x (cols + 1)` case nodes, so this is
  /// the node-budget lever: 5 (+MORE) keeps a two-library server at ~12 faces
  /// / ~480 cases on the reduced tier, in line with what the ONN has held.
  final int maxSectionsPerLibrary;

  /// Titles per network page. The first page gates store open; 400 was
  /// measured safe on the ONN (240 ANR'd it only because the OLD code queued a
  /// poster for every title on the page — posters are now demand-driven).
  final int pageSize;

  /// Hard ceiling per library so a pathological server can't grow forever.
  final int maxTitlesPerLibrary;

  /// Max simultaneous poster fetch+decode+upload jobs.
  final int posterConcurrency;

  /// Max poster textures resident at once. 256x384 RGBA is ~393 KB, so the
  /// full-quality budget is ~275 MB; the reduced-quality caller passes a far
  /// smaller budget and a smaller poster (see [VideoStoreData.reduced]).
  int textureBudget;

  /// Shelf poster decode size. The tape you pick up gets a separate hi-res
  /// fetch ([loadHiResPoster]), so the shelf copy only has to read at arm's
  /// length.
  final int posterWidth;
  final int posterHeight;

  /// Settings for the 1.9 GB Mali-G31 class of box: 200x300 posters (~234 KB)
  /// and a 360-texture budget (~84 MB), which still covers every face near the
  /// camera plus a scroll-ahead margin.
  factory VideoStoreData.reduced() => VideoStoreData(
        textureBudget: 360,
        posterWidth: 200,
        posterHeight: 300,
        posterConcurrency: 8,
        maxSectionsPerLibrary: 5,
      );

  final List<StoreAisle> aisles = [];

  /// Bumped whenever more titles land, so the scene/HUD can react cheaply.
  int revision = 0;

  /// True while later pages are still streaming in.
  bool get stillLoading => _pagingJobs > 0;
  int _pagingJobs = 0;
  bool _disposed = false;

  int _inFlight = 0;
  final List<StoreTitle> _posterQueue = [];
  final List<StoreTitle> _resident = [];
  int _wantGen = 0;

  /// Loads the first page of each movie/show library and files it into
  /// sections. Later pages are fetched in the background ([_pageRest]) and
  /// appended to the same sections. Poster textures are NOT loaded here —
  /// [setWanted] + [pumpPosterQueue] drive them from the render loop.
  Future<void> load(BuildContext context, List<MediaLibrary> libraries,
      {bool halloween = false}) async {
    _halloween = halloween;
    aisles.clear();
    _posterQueue.clear();

    // Video-store aisles are movies and TV — skip music/photo libraries.
    final storeLibraries = libraries.where((lib) {
      final k = lib.kind;
      return k == MediaKind.movie ||
          k == MediaKind.show ||
          k == MediaKind.unknown; // mixed libs often hold films
    }).toList();

    // Resolve every library's client synchronously, BEFORE any await, so no
    // BuildContext use crosses an async gap (paging below is all async).
    final resolved = <(MediaLibrary, MediaServerClient)>[];
    for (final library in storeLibraries) {
      try {
        resolved.add((library, context.getMediaClientForLibrary(library)));
      } catch (_) {
        // server offline / not signed in — skip this aisle
      }
    }

    for (final (library, client) in resolved) {
      try {
        final page = await _fetchPage(library, client, 0);
        if (page.items.isEmpty) continue;
        final titles = [
          for (final item in page.items) StoreTitle(item: item, library: library),
        ];
        // One aisle per LIBRARY gives a two-gondola store on a typical server
        // (Movies + TV Shows). A real video store runs many labelled sections,
        // so split each library by genre — every section gets its own rack
        // face with its own sign.
        final sections = _splitByGenre(titles);
        if (sections.isEmpty) {
          aisles.add(StoreAisle(library: library, titles: titles, client: client));
        } else {
          for (final entry in sections) {
            aisles.add(StoreAisle(
              library: library,
              titles: entry.$2,
              client: client,
              sectionName: entry.$1,
            ));
          }
        }
        if (page.totalCount > page.items.length) {
          unawaited(_pageRest(library, client, page.items.length, page.totalCount));
        }
        debugPrint('[VideoStore] library ${library.title}: '
            '${page.items.length}/${page.totalCount} titles on open, '
            '${sections.isEmpty ? 1 : sections.length} sections');
      } catch (e) {
        debugPrint('[VideoStore] failed to load ${library.title}: $e');
      }
    }
    for (final a in aisles) {
      a.sortTitles();
    }
    if (halloween) _buildSeasonalSection();
    revision++;
  }

  bool _halloween = false;

  /// The seasonal HALLOWEEN rack (Halloween theme only), or null.
  StoreAisle? get seasonal {
    for (final a in aisles) {
      if (a.seasonal) return a;
    }
    return null;
  }

  /// Words that mark a title as Halloween viewing even outside Horror —
  /// Hocus Pocus is filed under Family/Comedy, Beetlejuice under Comedy.
  static final RegExp _spooky = RegExp(
    r'halloween|hocus|witch|ghost|haunt|zombie|vampire|dracula|frankenstein|'
    r'werewolf|monster|scream|nightmare|evil dead|exorcis|demon|devil|'
    r'possess|poltergeist|conjuring|insidious|goosebumps|addams|beetlejuice|'
    r'coraline|casper|spooky|trick .?r treat|pumpkin|graveyard|curse|'
    r'skeleton|creepshow|hellraiser|chucky|annabelle|it follows|sleepy hollow|'
    r'corpse bride|paranorm|boogeyman|slasher|terrifier|smile',
    caseSensitive: false,
  );

  static bool isHalloweenTitle(StoreTitle t) =>
      t.genres.any((g) => g.toLowerCase().contains('horror')) ||
      _spooky.hasMatch(t.title);

  /// Pulls every Halloween title from every section into one seasonal rack
  /// at the FRONT of the store (index 0 = the rack you face on spawn). The
  /// genre racks keep their titles too — like a real store's seasonal
  /// display, a film can be in both, and the StoreTitle (and its poster
  /// texture) is shared, so it costs no extra memory.
  void _buildSeasonalSection() {
    final picks = <StoreTitle>{};
    for (final a in aisles) {
      for (final t in a.titles) {
        if (isHalloweenTitle(t)) picks.add(t);
      }
    }
    if (picks.isEmpty || aisles.isEmpty) return;
    final first = picks.first;
    final host = aisles.firstWhere((a) => a.library.id == first.library.id);
    aisles.insert(
      0,
      StoreAisle(
        library: first.library,
        titles: picks.toList(),
        client: host.client,
        sectionName: 'HALLOWEEN',
        seasonal: true,
      )..sortTitles(),
    );
    debugPrint('[VideoStore] seasonal HALLOWEEN rack: ${picks.length} titles');
  }

  Future<LibraryPage<MediaItem>> _fetchPage(
      MediaLibrary library, MediaServerClient client, int offset) {
    final query = libraryQueryFromPlexMap(
      // Server-side A–Z so pages arrive in shelf order and later pages append
      // at the END of each section instead of reshuffling the racks.
      map: const {'sort': 'titleSort'},
      libraryKind: library.kind,
      offset: offset,
      limit: pageSize,
    );
    return client.fetchLibraryPagedContent(
      library.id,
      query: query,
      libraryKind: library.kind,
    );
  }

  /// Streams the rest of [library] in behind the open store, filing each
  /// title into its genre section (or the library's catch-all).
  Future<void> _pageRest(MediaLibrary library, MediaServerClient client,
      int offset, int total) async {
    _pagingJobs++;
    try {
      final cap = total < maxTitlesPerLibrary ? total : maxTitlesPerLibrary;
      var at = offset;
      while (at < cap && !_disposed) {
        // Yield between pages so the render loop and input never starve.
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final page = await _fetchPage(library, client, at);
        final items = page.items;
        if (items.isEmpty) break;
        final mine = aisles
            .where((a) => a.library.id == library.id && !a.seasonal)
            .toList();
        if (mine.isEmpty) break;
        final byName = {for (final a in mine) a.name.toUpperCase(): a};
        // Titles whose first genre has no section of its own go to the
        // catch-all: the one named MORE TITLES, else the last section.
        final catchAll = byName['MORE TITLES'] ?? mine.last;
        final touched = <StoreAisle>{};
        for (final item in items) {
          final t = StoreTitle(item: item, library: library);
          final g = t.genres.isNotEmpty ? t.genres.first.trim().toUpperCase() : '';
          final target = byName[g] ?? catchAll;
          target.titles.add(t);
          touched.add(target);
        }
        final season = _halloween ? seasonal : null;
        if (season != null) {
          // Iterate a COPY: the loop adds the seasonal rack to [touched].
          for (final a in touched.toList()) {
            for (final t in a.titles) {
              if (t.library.id == library.id &&
                  !season.titles.contains(t) &&
                  isHalloweenTitle(t)) {
                season.titles.add(t);
                touched.add(season);
              }
            }
          }
        }
        for (final a in touched.toList()) {
          a.sortTitles();
        }
        at += items.length;
        revision++;
        debugPrint('[VideoStore] paged ${library.title}: $at/$total');
      }
    } catch (e) {
      debugPrint('[VideoStore] paging ${library.title} stopped: $e');
    } finally {
      _pagingJobs--;
    }
  }

  /// Tells the cache which titles matter right now, most important first
  /// (the face being browsed, then faces by distance from the camera). The
  /// first [textureBudget] of them are fetched if missing; resident textures
  /// for titles NOT in the list are evicted once the budget is exceeded.
  void setWanted(List<StoreTitle> ordered) {
    _wantGen++;
    final budget = textureBudget;
    final n = ordered.length < budget ? ordered.length : budget;
    _posterQueue.clear();
    for (var i = 0; i < n; i++) {
      final t = ordered[i];
      t.wantGen = _wantGen;
      if (t.texture == null && !t.loading && !t.posterFailed) {
        _posterQueue.add(t);
      }
    }
    // Evict oldest-resident titles that are no longer wanted. Their materials
    // fall back to the spine tint on the next rack update, which is what
    // actually releases the GPU memory.
    if (_resident.length > budget) {
      var excess = _resident.length - budget;
      _resident.removeWhere((t) {
        if (excess <= 0 || t.wantGen == _wantGen) return false;
        t.texture = null;
        excess--;
        return true;
      });
    }
  }

  /// Kicks off up to [posterConcurrency] poster loads. Call once per frame;
  /// returns true while there is still work pending.
  bool pumpPosterQueue(BuildContext context) {
    while (_inFlight < posterConcurrency && _posterQueue.isNotEmpty) {
      final title = _posterQueue.removeAt(0);
      if (title.texture != null || title.loading || title.posterFailed) continue;
      title.loading = true;
      _inFlight++;
      unawaited(_loadPosterTexture(context, title).whenComplete(() {
        _inFlight--;
        title.loading = false;
      }));
    }
    return _inFlight > 0 || _posterQueue.isNotEmpty;
  }

  /// Poster textures currently resident (for the debug HUD / logs).
  int get residentCount => _resident.length;

  /// Fetches FULL metadata for [title] and folds it back into the StoreTitle.
  ///
  /// The library list query returns cast NAMES but no headshot paths
  /// (verified on device: roles=3, thumbs=[null,null,null]) — those only come
  /// from a per-item request. Called once per pick-up and cached on the title,
  /// so turning the same box over again costs nothing.
  Future<void> hydrateDetails(BuildContext context, StoreTitle title) async {
    if (title.detailsLoaded) return;
    title.detailsLoaded = true; // don't retry a server that returns nothing
    try {
      final client = _tryClient(context, title);
      if (client == null) return;
      final full = await client.fetchItem(title.item.id);
      if (full != null) title.detail = full;
    } catch (_) {
      // Detail is a bonus; the sleeve renders fine from the list item.
    }
  }

  /// Groups [titles] into genre sections, biggest first, so a single library
  /// becomes several labelled rack faces instead of one.
  ///
  /// A title lands in its FIRST genre only, so no film is stocked twice.
  /// Genres too small to be worth a sign are pooled into MORE TITLES rather
  /// than dropped — every title in the library is shelved somewhere, because
  /// the racks scroll. Returns empty when the server supplies no genre data at
  /// all, in which case the caller keeps the single whole-library aisle.
  List<(String, List<StoreTitle>)> _splitByGenre(List<StoreTitle> titles) {
    final byGenre = <String, List<StoreTitle>>{};
    final ungrouped = <StoreTitle>[];
    for (final t in titles) {
      final g = t.genres.isNotEmpty ? t.genres.first.trim() : '';
      if (g.isEmpty) {
        ungrouped.add(t);
      } else {
        byGenre.putIfAbsent(g.toUpperCase(), () => []).add(t);
      }
    }
    if (byGenre.isEmpty) return const [];

    // The racks scroll, so a section no longer has to FILL a fixture to earn
    // one — but a sign over a dozen tapes still looks like a gap. Below this a
    // genre is pooled.
    const minPerSection = 24;
    final sections = <(String, List<StoreTitle>)>[];
    final leftovers = <StoreTitle>[...ungrouped];
    for (final e in byGenre.entries) {
      if (e.value.length >= minPerSection) {
        sections.add((e.key, e.value));
      } else {
        leftovers.addAll(e.value);
      }
    }
    // Biggest section first so the entrance shows the deepest run.
    sections.sort((a, b) => b.$2.length.compareTo(a.$2.length));
    // Each section is one rack face (two per fixture). Faces past this cap
    // are pooled — never dropped — so the store stays inside the node budget
    // the ONN has held (~550 nodes) while the whole library stays reachable.
    if (sections.length > maxSectionsPerLibrary) {
      for (final dropped in sections.sublist(maxSectionsPerLibrary)) {
        leftovers.addAll(dropped.$2);
      }
      sections.removeRange(maxSectionsPerLibrary, sections.length);
    }
    if (leftovers.isNotEmpty) {
      sections.add(('MORE TITLES', leftovers));
    }
    return sections;
  }

  /// Fetches an arbitrary artwork path for [title] and decodes it to a
  /// `ui.Image` for painting into the box-back sleeve (backdrop, cast
  /// headshots). Returns null on any failure — the sleeve is designed to
  /// degrade rather than block on missing art.
  ///
  /// NOT flipped: this is drawn into a canvas that is itself pre-flipped by
  /// [StoreTextures._bake], unlike the poster path which uploads directly.
  Future<ui.Image?> loadArtImage(
    BuildContext context,
    StoreTitle title,
    String? path, {
    required double maxWidth,
    required double maxHeight,
    ImageType imageType = ImageType.art,
  }) async {
    if (path == null || path.isEmpty) return null;
    try {
      final client = _tryClient(context, title);
      final url = MediaImageHelper.getOptimizedImageUrl(
        client: client,
        thumbPath: path,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        devicePixelRatio: 1.0,
        imageType: imageType,
      );
      if (url.isEmpty) return null;
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;
      final codec = await ui.instantiateImageCodec(resp.bodyBytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// A one-off HIGH-resolution poster for the tape in hand. Not cached: the
  /// caller owns it and drops it when the tape is shelved.
  Future<gpu.Texture?> loadHiResPoster(BuildContext context, StoreTitle title) =>
      _fetchPosterTexture(context, title, 512, 768);

  Future<void> _loadPosterTexture(BuildContext context, StoreTitle title) async {
    final tex =
        await _fetchPosterTexture(context, title, posterWidth, posterHeight);
    if (tex == null) {
      title.posterFailed = true;
      return;
    }
    title.texture = tex;
    _resident.add(title);
  }

  Future<gpu.Texture?> _fetchPosterTexture(
      BuildContext context, StoreTitle title, int w, int h) async {
    try {
      final client = _tryClient(context, title);
      final thumb = title.item.posterThumb();
      if (thumb == null || thumb.isEmpty) return null;

      final url = MediaImageHelper.getOptimizedImageUrl(
        client: client,
        thumbPath: thumb,
        maxWidth: w.toDouble(),
        maxHeight: h.toDouble(),
        devicePixelRatio: 1.0,
        imageType: ImageType.poster,
      );
      if (url.isEmpty) return null;

      // 6 s, not 15: a dead remote endpoint (measured: plex.direct "No route
      // to host") otherwise pins a fetch slot long enough that a freshly
      // scrolled rack sits on blank tints.
      final resp =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return null;

      // Decode straight to the target size: the server honours maxWidth only
      // approximately, and an oversize decode is wasted texture memory.
      final codec = await ui.instantiateImageCodec(
        resp.bodyBytes,
        targetWidth: w,
        targetHeight: h,
      );
      final frame = await codec.getNextFrame();
      final ui.Image decoded = frame.image;
      codec.dispose();
      // A cuboid face samples its map vertically flipped (see the note in
      // store_textures.dart), so box art has to be pre-flipped or every poster
      // on the shelf hangs upside-down. The VHS case geometry keeps the same
      // face UV convention, so the same correction applies.
      final ui.Image image = await _flipVertical(decoded);
      decoded.dispose();
      final texture = await scene.gpuTextureFromImage(image);
      image.dispose();
      return texture;
    } catch (e) {
      // A missing poster is not fatal — the shelf paints a solid spine.
      debugPrint('[VideoStore] poster load failed for ${title.title}: $e');
      return null;
    }
  }

  /// Returns [src] flipped top-to-bottom. Cheap GPU blit through a recorder —
  /// the alternative (rolling every box node in the scene) would still leave
  /// the room's own signage wrong.
  Future<ui.Image> _flipVertical(ui.Image src) async {
    final w = src.width.toDouble(), h = src.height.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w, h));
    canvas.translate(0, h);
    canvas.scale(1, -1);
    canvas.drawImage(src, ui.Offset.zero, ui.Paint());
    final picture = recorder.endRecording();
    final out = await picture.toImage(src.width, src.height);
    picture.dispose();
    return out;
  }

  MediaServerClient? _tryClient(BuildContext context, StoreTitle title) {
    try {
      return context.getMediaClientForLibrary(title.library);
    } catch (_) {
      return null;
    }
  }

  /// Stops background paging (call from the screen's dispose).
  void dispose() {
    _disposed = true;
  }

  /// Total title count across every aisle — for the store marquee.
  int get totalTitles => aisles.fold(0, (n, a) => n + a.titles.length);
}

/// One section of a library (a genre, or the whole library) shelved on one
/// rack face.
class StoreAisle {
  StoreAisle({
    required this.library,
    required this.titles,
    required this.client,
    this.sectionName,
    this.seasonal = false,
  });

  /// The Halloween display rack: titles from EVERY library, not a genre.
  final bool seasonal;

  final MediaLibrary library;
  final List<StoreTitle> titles;
  final MediaServerClient client;

  /// Genre section this run was split into ("HORROR", "COMEDY"). Null for a
  /// whole-library aisle, which then falls back to the library's own name.
  final String? sectionName;

  String get name => sectionName ?? library.title;

  /// Section label as it appears on the rack sign: TV sections carry the
  /// library kind so "DRAMA" on the movie side and the TV side don't collide.
  String get signLabel =>
      (!seasonal && library.kind == MediaKind.show && sectionName != null)
          ? 'TV · $name'
          : name;

  void sortTitles() => titles.sort((a, b) => a.sortKey.compareTo(b.sortKey));

  /// Index of the first title filed under [letter] (or the nearest following
  /// letter), for the A–Z jump. -1 when there is nothing at or after it.
  int indexOfLetter(String letter) {
    for (var i = 0; i < titles.length; i++) {
      final l = titles[i].shelfLetter;
      if (l == letter || (letter != '#' && l != '#' && l.compareTo(letter) > 0)) {
        return i;
      }
    }
    return -1;
  }
}
