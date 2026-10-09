import 'dart:math' as math;

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'haunted_store.dart';
import 'store_rack.dart';
import 'store_textures.dart';
import 'video_store_data.dart';

export 'store_rack.dart'
    show StoreBox, RackFace, screenRightOf, browseStep, scrollFirstFor;

/// A single browsable box on a shelf: its scene [node], the [title] it shows,
/// and its world position so the camera can walk to it.
enum _ShopperState { walking, browsing }

/// A blocky customer browsing the aisles. Built from the same cuboids as the
/// rest of the store — six parts, no skeleton, no per-frame allocation.
class _Shopper {
  _Shopper({
    required this.aisle,
    required this.z,
    required this.dir,
    required this.dwell,
    required this.scale,
    required this.phase,
  });

  final int aisle;
  double z;
  double dir;
  double dwell;
  final double scale;
  double phase;
  _ShopperState state = _ShopperState.walking;

  Node? head, torso, armL, armR, legL, legR;
}

/// A non-interactive framed one-sheet on a perimeter wall. It is NOT a
/// [StoreBox] — you cannot walk up and pick it off the wall — but its poster
/// texture arrives on the same async schedule, so it needs the same late bind.
class _WallPoster {
  _WallPoster(this.title, this.material);

  final StoreTitle title;
  final PhysicallyBasedMaterial material;
  bool applied = false;
}

/// Builds and owns the 3D video-store scene graph from [VideoStoreData].
///
/// Layout mimics a real Blockbuster: a bright, open sales floor. Aisles are
/// double-height white shelf runs with a blue Blockbuster header valance,
/// standing on blue retail carpet under a drop-ceiling of glowing fluorescent
/// light panels. Boxes stand face-out toward the corridor the camera walks.
class VideoStoreScene {
  VideoStoreScene({required this.halloween, required this.reducedQuality});

  /// Seasonal theme: bright blue Blockbuster store vs. cold spooky Halloween.
  final bool halloween;

  /// Low-end (Fire TV / Mali-G31) path: fewer boxes per aisle, no ceiling
  /// panels, no MSAA — see [build].
  final bool reducedQuality;

  final Scene scene = Scene();
  /// Every rack face in the store — one per section, two per gondola.
  final List<RackFace> faces = [];

  /// Every case currently on show (inside a run, bound to a title).
  List<StoreBox> get boxes => [
        for (final f in faces)
          for (final b in f.slots)
            if (b.active) b,
      ];

  /// Dead-store dressing (Halloween only): flicker, ghosts, props.
  HauntedStore? haunted;
  final List<_WallPoster> _wallArt = [];

  /// Procedurally-baked surface maps. Set by the screen before [build] — if
  /// null (or a bake failed) every surface just keeps its solid base colour.
  StoreTextures? textures;

  // --- world metrics (metres) ---
  static const double _boxWidth = 0.30;
  static const double _boxHeight = 0.45; // portrait poster spine
  // A VHS clamshell is chunky (~20 x 11 x 2.8 cm). At 0.04 the stock read as
  // paper cards with no spine; 0.09 keeps the same face size but gives every
  // case real thickness, which is what makes a shelf look like tapes.
  static const double _boxDepth = 0.09;

  /// Case thickness, for callers placing things on its faces.
  static double get boxDepth => _boxDepth;
  static const double _slotSpacing = 0.34; // along the shelf run (Z)
  static const double _shelfGapY = 0.62; // vertical between shelves
  // Y of the LOWEST shelf's box centres. Real gondola stock starts off the
  // floor and climbs THROUGH eye level; based at 0 the bottom row was half
  // sunk under the carpet and the top row topped out at 1.465 m — entirely
  // below the 1.6 m eye height, leaving ~0.9 m of blank white panel filling
  // the middle of the frame every time you faced a shelf.
  static const double _shelfBaseY = 0.42;
  static const double _aisleWidth = 3.2; // corridor between facing shelf runs
  // Distance between corridor centres. A gondola is stocked on BOTH faces, so
  // this is (corridor width + fixture depth) — tight enough that the back of
  // one fixture forms the far side of the next corridor, like a real store.
  // At the old 6.0 there was a 4.4 m strip of bare carpet between every run.
  static const double _aislePitch = 4.4;
  static const double eyeHeight = 1.6;

  // Density. Measured budget on the ARMv7/Mali-G31 target at rows=3/slots=8
  // was ~138 scene nodes with OOM=0 across many runs, so there is room to
  // stock deeper runs; 4 tiers also gives browse mode a real top/middle/bottom
  // rather than a three-way choice. The non-reduced tier is left alone — it
  // was never the constrained one.
  int get rows => reducedQuality ? 4 : 5;
  int get maxSlotsPerRow => reducedQuality ? 9 : 12;

  /// How many aisles [build] actually created — the free-walk camera clamps
  /// its roam area from this.
  int aisleCount = 0;

  /// Length of one shelf run along Z (the walkable aisle depth).
  double get runLength => (maxSlotsPerRow + 1) * _slotSpacing;

  /// Half the corridor width — distance from an aisle's centre to its shelf.
  double get corridorHalfWidth => _aisleWidth / 2;

  /// X of aisle [a]'s solid shelf wall (the fixture the boxes hang on).
  double shelfWallX(int a) => aisleCenterX(a) - _aisleWidth / 2;

  // --- room shell bounds (the four walls + ceiling that enclose the floor) ---
  // A store is a ROOM. Without these the camera looks out into an infinite
  // black void the moment it faces off-axis, which is what made the scene read
  // as geometry floating in space rather than an interior.

  /// Left wall X. Aisle 0's fixture is stocked on its -X face too, so this
  /// leaves a full corridor's width there rather than a crawlspace.
  double get roomMinX => shelfWallX(0) - _aisleWidth;

  /// Right wall X — the open front-of-store floor that holds the checkout.
  double get roomMaxX =>
      aisleCenterX(math.max(1, aisleCount) - 1) + corridorHalfWidth + 3.4;

  /// Front wall Z — the entrance end, behind the camera's spawn.
  double get roomMinZ => -3.0;

  /// Back wall Z — the far end past the shelf runs.
  double get roomMaxZ => runLength + 3.2;

  /// Underside of the drop ceiling.
  double get ceilingY => rows * _shelfGapY + 1.15;

  /// Width of the back-wall brand sign. Shared so the framed one-sheets can
  /// keep clear of it — hung on nominal offsets they sat entirely BEHIND the
  /// sign and only their top and bottom edges peeked out.
  double get brandSignWidth => math.min(5.0, (roomMaxX - roomMinX) * 0.55);

  // --- Blockbuster palette ---
  static final vm.Vector4 _bbBlue = vm.Vector4(0.05, 0.22, 0.62, 1.0);
  static final vm.Vector4 _bbYellow = vm.Vector4(0.98, 0.78, 0.10, 1.0);
  static final vm.Vector4 _shelfWhite = vm.Vector4(0.90, 0.91, 0.93, 1.0);
  static final vm.Vector4 _carpetBlue = vm.Vector4(0.08, 0.16, 0.42, 1.0);

  /// Constructs all static geometry + box nodes and attaches them to [scene].
  /// Poster textures are applied later via [applyReadyTextures] as they load.
  void build(VideoStoreData data) {
    // flutter_scene defaults to 4x offscreen MSAA, which allocates a
    // multisampled color target plus an MSAA-resolve target. The Mali-G31 in
    // 1.9 GB Android TV boxes advertises offscreen-MSAA support but then fails
    // to allocate that resolve target every frame (ErrorOutOfDeviceMemory), so
    // the 3D store renders solid black. Dropping to no MSAA renders straight
    // into a single non-multisampled target the driver can actually allocate.
    if (reducedQuality) {
      scene.antiAliasingMode = AntiAliasingMode.none;
    }

    // One section per rack FACE, two faces per gondola: the racks scroll, so
    // a face shelves a whole section however long it is. Fixture count (not
    // section count) is what sizes the room.
    aisleCount = math.max(1, (data.aisles.length + 1) ~/ 2);
    _caseGeometry =
        vhsCaseGeometry(vm.Vector3(_boxDepth, _boxHeight, _boxWidth));

    _setupLighting();
    _buildRoom();

    // With no sections at all (server unreachable at open — measured on the
    // ONN with a VPN up) the room still builds, just with no gondolas; the
    // old per-aisle loop tolerated that and indexing sections must too.
    final fixturesWithStock = (data.aisles.length + 1) ~/ 2;
    for (var f = 0; f < fixturesWithStock; f++) {
      final front = 2 * f;
      final back = 2 * f + 1;
      _buildFixture(
        f,
        data,
        frontSection: front < data.aisles.length ? front : null,
        // An odd section count leaves the last back face without a section of
        // its own: it shelves the front section from the middle instead of
        // standing as a blank slab.
        backSection: back < data.aisles.length ? back : front,
        backStartsMidway: back >= data.aisles.length,
      );
    }

    // Halcyon floor props. The camera walks 0.9 m off a shelf wall looking
    // straight at it (-X), so tall props in the corridor fill the frame with a
    // face-filling slab. The endcap displays are therefore SHORT (below box
    // height) and pushed to the END of each run (high Z), so they read as low
    // floor units in the distance rather than blocking the focused box. Plus a
    // CRT hung overhead. Both stay well inside the Mali-G31 budget.
    _buildEndcaps(aisleCount);
    _buildHangingTv(aisleCount);
    _buildCheckout();
    _buildWallArt(data);
    _buildShoppers();

    // Stock the ceiling TV's reel: the Halloween rack on Halloween,
    // otherwise the front of every section.
    final season = data.seasonal;
    if (halloween && season != null) {
      _reelTitles.addAll(season.titles.take(24));
    } else {
      for (final aisle in data.aisles) {
        _reelTitles.addAll(aisle.titles.take(4));
      }
    }

    // Halloween: the store closed down years ago and something still works
    // the night shift. Built last so it can dress what's already standing.
    if (halloween) {
      haunted = HauntedStore(this)..build();
    }
  }

  /// Advances every animated part of the store for one frame.
  void update(double dt, vm.Vector3 cameraPos) {
    updateRacks(dt, cameraPos);
    updateShoppers(dt, cameraPos);
    updateDemoReel(dt);
    haunted?.update(dt, cameraPos);
  }

  /// Framed one-sheets on the perimeter walls, drawn from real library art.
  ///
  /// The shelf runs only occupy the middle of the room, so the back and front
  /// walls were left as big blank painted planes — the last thing in frame
  /// that read as "empty 3D box" rather than "shop". Real video stores papered
  /// exactly these walls with one-sheets. Titles are taken from the TAIL of
  /// each aisle's list (indices past what the shelves display) so the walls
  /// show art you cannot already see on a spine, at no extra texture cost —
  /// [VideoStoreData] fetches and uploads all of them regardless.
  void _buildWallArt(VideoStoreData data) {
    // Past the first screenful of each rack, dealt round-robin across the
    // sections so the walls aren't all one genre.
    final shown = rows * maxSlotsPerRow;
    final pool = <StoreTitle>[];
    // On Halloween the walls are papered with the seasonal rack's art.
    final season = data.seasonal;
    if (halloween && season != null) {
      final ts = season.titles;
      final step = math.max(1, ts.length ~/ 12);
      for (var i = 0; i < ts.length && pool.length < 12; i += step) {
        pool.add(ts[i]);
      }
    }
    for (var k = 0; k < 6; k++) {
      for (final aisle in data.aisles) {
        final i = shown + k * 11;
        if (i < aisle.titles.length) pool.add(aisle.titles[i]);
      }
    }
    // Fall back to the front of the list if every title is already shelved.
    if (pool.isEmpty) {
      for (final aisle in data.aisles) {
        pool.addAll(aisle.titles.take(3));
      }
    }
    if (pool.isEmpty) return;

    final x0 = roomMinX, x1 = roomMaxX;
    final z0 = roomMinZ, z1 = roomMaxZ;
    const t = 0.16;
    const pw = 1.15, ph = 1.72; // one-sheet is ~2:3
    final y = 1.55;

    final frameMat = _surface(vm.Vector4(0.09, 0.10, 0.13, 1.0), roughness: 0.5);
    var n = 0;

    void hang(vm.Vector3 at, bool alongX) {
      final title = pool[n % pool.length];
      final mat = PhysicallyBasedMaterial()
        ..baseColorFactor = _spineTintColor(title.key)
        ..emissiveFactor = _ambientLift(_spineTintColor(title.key))
        ..roughnessFactor = 0.5
        ..metallicFactor = 0.0;
      final art = alongX
          ? vm.Vector3(pw, ph, 0.05)
          : vm.Vector3(0.05, ph, pw);
      final frame = alongX
          ? vm.Vector3(pw + 0.14, ph + 0.14, 0.04)
          : vm.Vector3(0.04, ph + 0.14, pw + 0.14);
      // Frame sits a hair behind the art so it reads as a border, not z-fight.
      final back = alongX
          ? vm.Vector3(at.x, at.y, at.z + (at.z > 0 ? 0.03 : -0.03))
          : vm.Vector3(at.x + (at.x > (x0 + x1) / 2 ? 0.03 : -0.03), at.y, at.z);
      scene.add(Node(
        name: 'wallart_frame_$n',
        mesh: Mesh(CuboidGeometry(frame), frameMat),
        localTransform: vm.Matrix4.translation(back),
      ));
      final node = Node(
        name: 'wallart_$n',
        mesh: Mesh(CuboidGeometry(art), mat),
        localTransform: vm.Matrix4.translation(at),
      );
      scene.add(node);
      _wallArt.add(_WallPoster(title, mat));
      n++;
    }

    // Back wall, genuinely FLANKING the brand sign: start clear of the sign's
    // half-width plus half a frame, or the poster hides behind it.
    final cx = (x0 + x1) / 2;
    final clear = brandSignWidth / 2 + pw / 2 + 0.35;
    for (final dx in [-clear - 1.5, -clear, clear, clear + 1.5]) {
      final x = cx + dx;
      if (x < x0 + 1.0 || x > x1 - 1.0) continue;
      hang(vm.Vector3(x, y, z1 - t / 2 - 0.05), true);
    }
    // Front wall, either side of the entrance.
    for (final dx in const [-3.2, -0.8, 1.6]) {
      final x = cx + dx;
      if (x < x0 + 1.0 || x > x1 - 1.0) continue;
      hang(vm.Vector3(x, y, z0 + t / 2 + 0.05), true);
    }
    // Left wall, down the length of the store.
    final zs = [z0 + (z1 - z0) * 0.35, z0 + (z1 - z0) * 0.65];
    for (final z in zs) {
      hang(vm.Vector3(x0 + t / 2 + 0.05, y, z), false);
    }
  }

  /// The checkout desk by the entrance — a wood-front counter with a laminate
  /// top, a register, and a drop bin. A store with no point of sale reads as a
  /// warehouse; this is the prop that says "shop" from the spawn view.
  void _buildCheckout() {
    final cx = roomMaxX - 2.2;
    final cz = roomMinZ + 2.6;
    const len = 3.0;

    final frontMat = _surface(
      halloween ? vm.Vector4(0.09, 0.07, 0.06, 1.0) : vm.Vector4(0.42, 0.29, 0.18, 1.0),
      tex: halloween ? null : textures?.woodTrim,
      roughness: 0.7,
    );
    scene.add(Node(
      name: 'counter_body',
      mesh: Mesh(CuboidGeometry(vm.Vector3(0.9, 1.0, len)), frontMat),
      localTransform: vm.Matrix4.translation(vm.Vector3(cx, 0.5, cz)),
    ));

    final topMat = _surface(
      vm.Vector4(0.17, 0.18, 0.23, 1.0),
      tex: textures?.counterTop,
      roughness: 0.35,
    );
    scene.add(Node(
      name: 'counter_top',
      mesh: Mesh(
        CuboidGeometry(vm.Vector3(1.06, 0.07, len + 0.14)),
        topMat,
      ),
      localTransform: vm.Matrix4.translation(vm.Vector3(cx, 1.03, cz)),
    ));

    // Register + monitor.
    scene.add(_prop('register', vm.Vector4(0.13, 0.13, 0.15, 1.0),
        vm.Vector3(0.42, 0.24, 0.36), vm.Vector3(cx, 1.19, cz - 0.7),
        roughness: 0.5));
    scene.add(_prop(
      'register_screen',
      vm.Vector4(0.30, 0.45, 0.65, 1.0),
      vm.Vector3(0.03, 0.26, 0.34),
      vm.Vector3(cx - 0.23, 1.42, cz - 0.7),
      emissive: vm.Vector4(0.28, 0.38, 0.52, 1.0),
      roughness: 0.3,
    ));
    scene.add(_prop('register_stem', vm.Vector4(0.10, 0.10, 0.12, 1.0),
        vm.Vector3(0.1, 0.14, 0.1), vm.Vector3(cx, 1.34, cz - 0.7)));

    // Backlit CHECKOUT sign hung above the desk, facing the sales floor (-X),
    // so the point of sale is legible from anywhere on the open floor.
    final signTex = textures?.signCheckout;
    if (signTex != null) {
      final signMat = PhysicallyBasedMaterial()
        ..baseColorTexture = signTex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        // Matched to the wall signs: additive emissive washes the dark field
        // out long before it helps the legend read.
        ..emissiveFactor = halloween
            ? vm.Vector4(0.10, 0.10, 0.10, 1.0)
            : vm.Vector4(0.08, 0.08, 0.08, 1.0)
        ..roughnessFactor = 0.35
        ..metallicFactor = 0.0;
      final signY = ceilingY - 1.25;
      scene.add(Node(
        name: 'sign_checkout',
        mesh: Mesh(CuboidGeometry(vm.Vector3(0.08, 0.62, 2.5)), signMat),
        localTransform:
            vm.Matrix4.translation(vm.Vector3(cx - 0.5, signY, cz)),
      ));
      // Two drop rods to the ceiling so it reads as hung, not floating.
      for (final dz in const [-1.0, 1.0]) {
        scene.add(_prop(
          'sign_checkout_rod_${dz > 0 ? 'a' : 'b'}',
          vm.Vector4(0.10, 0.10, 0.12, 1.0),
          vm.Vector3(0.05, ceilingY - signY - 0.31, 0.05),
          vm.Vector3(cx - 0.5, (signY + 0.31 + ceilingY) / 2, cz + dz),
          roughness: 0.6,
        ));
      }
    }

    // Return drop bin, out on the floor beside the desk.
    final binBlue = halloween ? vm.Vector4(0.20, 0.05, 0.30, 1.0) : _bbBlue;
    scene.add(_prop('return_bin', binBlue, vm.Vector3(0.7, 0.95, 0.7),
        vm.Vector3(cx - 1.5, 0.475, cz + 2.4),
        roughness: 0.5));
    scene.add(_prop('return_bin_lip', _bbYellow, vm.Vector3(0.78, 0.1, 0.78),
        vm.Vector3(cx - 1.5, 0.98, cz + 2.4),
        emissive: halloween
            ? vm.Vector4(0.30, 0.12, 0.02, 1.0)
            : vm.Vector4(0.55, 0.44, 0.06, 1.0),
        roughness: 0.4));

    _buildSnacks(cx, cz, len);
  }

  /// The snack side of the counter: the impulse candy rack you were parked in
  /// front of while your parents paid, a stack of popcorn tubs on the counter,
  /// and a lit drinks cooler against the wall. Blockbuster made real money on
  /// this corner, and without it the checkout reads as an empty desk.
  void _buildSnacks(double cx, double cz, double counterLen) {
    final candyTex = textures?.candySheet;
    final popTex = textures?.popcornBox;
    final coolerTex = textures?.coolerFront;

    // --- Impulse candy rack, floor unit at the end of the counter ---------
    final rackBody = halloween
        ? vm.Vector4(0.16, 0.06, 0.22, 1.0)
        : vm.Vector4(0.10, 0.24, 0.55, 1.0);
    // Out on the floor beside the queue line rather than tight against the
    // counter end, where it was half-hidden behind the desk from every angle.
    final rackX = cx - 1.35;
    final rackZ = cz - counterLen / 2 - 0.35;
    scene.add(_prop('candy_rack_body', rackBody,
        vm.Vector3(0.55, 1.25, 1.15), vm.Vector3(rackX, 0.62, rackZ),
        roughness: 0.55));

    // Four ranks of wrappers on the -X face (toward the sales floor). Each
    // rank is its own thin slab so the rack reads as tiered shelves of candy.
    if (candyTex != null) {
      for (var tier = 0; tier < 4; tier++) {
        final mat = PhysicallyBasedMaterial()
          ..baseColorTexture = candyTex
          ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
          // Low: additive, and these wrappers are already saturated.
          ..emissiveFactor = vm.Vector4(0.10, 0.10, 0.10, 1.0)
          ..roughnessFactor = 0.45
          ..metallicFactor = 0.0;
        scene.add(Node(
          name: 'candy_tier_$tier',
          mesh: Mesh(CuboidGeometry(vm.Vector3(0.04, 0.26, 1.05)), mat),
          localTransform: vm.Matrix4.translation(
            vm.Vector3(rackX - 0.30, 0.34 + tier * 0.30, rackZ),
          ),
        ));
      }
    }
    // Yellow topper so it matches the endcaps.
    scene.add(_prop('candy_rack_top', _bbYellow, vm.Vector3(0.6, 0.12, 1.2),
        vm.Vector3(rackX, 1.30, rackZ),
        emissive: halloween
            ? vm.Vector4(0.30, 0.12, 0.02, 1.0)
            : vm.Vector4(0.55, 0.44, 0.06, 1.0),
        roughness: 0.4));

    // --- Popcorn tubs stacked on the counter top -------------------------
    if (popTex != null) {
      final popMat = PhysicallyBasedMaterial()
        ..baseColorTexture = popTex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..emissiveFactor = vm.Vector4(0.12, 0.12, 0.12, 1.0)
        ..roughnessFactor = 0.6
        ..metallicFactor = 0.0;
      // Two on the deck, one balanced on top — a stack, not a neat row.
      const spots = [
        [0.0, 1.19, 0.55],
        [0.0, 1.19, 0.92],
        [0.0, 1.47, 0.74],
      ];
      for (var i = 0; i < spots.length; i++) {
        final s = spots[i];
        scene.add(Node(
          name: 'popcorn_$i',
          mesh: Mesh(CuboidGeometry(vm.Vector3(0.26, 0.28, 0.26)), popMat),
          localTransform: vm.Matrix4.translation(
            vm.Vector3(cx + s[0], s[1], cz + s[2]),
          ),
        ));
      }
    }

    // --- Drinks cooler against the front wall ----------------------------
    final coolerX = cx + 0.55;
    final coolerZ = cz + counterLen / 2 + 1.5;
    scene.add(_prop('cooler_body', vm.Vector4(0.09, 0.10, 0.12, 1.0),
        vm.Vector3(0.75, 1.95, 1.5), vm.Vector3(coolerX, 0.975, coolerZ),
        roughness: 0.5));
    if (coolerTex != null) {
      final glassMat = PhysicallyBasedMaterial()
        ..baseColorTexture = coolerTex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        // A cooler is INTERNALLY lit, so this one earns a real lift.
        ..emissiveFactor = vm.Vector4(0.34, 0.36, 0.38, 1.0)
        ..roughnessFactor = 0.2
        ..metallicFactor = 0.0;
      scene.add(Node(
        name: 'cooler_glass',
        mesh: Mesh(CuboidGeometry(vm.Vector3(0.05, 1.55, 1.30)), glassMat),
        localTransform: vm.Matrix4.translation(
          vm.Vector3(coolerX - 0.40, 1.05, coolerZ),
        ),
      ));
    }
  }

  void _setupLighting() {
    // A real store is FLAT-BRIGHT overhead fluorescent, not a single dramatic
    // key. flutter_scene shades one scene-level directional light plus the
    // constant emissive "ambient lift" each material carries. So we point the
    // directional nearly straight down and keep it bright + neutral-white to
    // read as ceiling fluorescents.
    scene.directionalLight = DirectionalLight(
      direction: vm.Vector3(-0.15, -1.0, -0.1)..normalize(),
      // Kept greenish but pulled back from the original (0.55, 0.85, 0.65):
      // that much saturation visibly drains warm cover art. The purple cast on
      // held boxes turned out to be the FOCUS highlight, not this — see
      // setFocus() — so the spooky key stays, just gentler.
      color: halloween
          ? vm.Vector3(0.74, 0.88, 0.78) // muted sickly green key
          : vm.Vector3(1.0, 0.98, 0.94), // clean white fluorescents
      intensity: halloween ? 3.2 : 4.6,
    );
  }

  /// Constant emissive that stands in for the bright store ambient so no face
  /// reads as black. A real Blockbuster is evenly, brightly lit, so this is a
  /// LARGE lift (unlike a dim dramatic scene) — scaled by the surface tint.
  vm.Vector4 _ambientLift(vm.Vector4 base) {
    // Now that the scene is a closed room, the directional key actually has
    // surfaces to fall off across — so this lift is smaller than it was when
    // it had to keep unlit geometry from reading as black silhouettes.
    final k = halloween ? 0.06 : 0.22;
    return vm.Vector4(base.x * k, base.y * k, base.z * k, 1.0);
  }

  /// Builds a material. When [tex] is present the base colour is neutralised
  /// so the map shows at its painted colours, and the ambient lift is a flat
  /// grey rather than a tint of the (now white) base.
  PhysicallyBasedMaterial _surface(
    vm.Vector4 color, {
    gpu.Texture? tex,
    double roughness = 0.7,
  }) {
    final mat = PhysicallyBasedMaterial()
      ..roughnessFactor = roughness
      ..metallicFactor = 0.0;
    if (tex != null) {
      mat.baseColorTexture = tex;
      mat.baseColorFactor = vm.Vector4(1, 1, 1, 1);
      mat.emissiveFactor = halloween
          ? vm.Vector4(0.05, 0.05, 0.05, 1.0)
          : vm.Vector4(0.18, 0.18, 0.18, 1.0);
    } else {
      mat.baseColorFactor = color;
      mat.emissiveFactor = _ambientLift(color);
    }
    return mat;
  }

  /// The room shell — carpet, four perimeter walls, drop ceiling and its
  /// fluorescent strips. Built on EVERY device (the old reduced-quality skip
  /// is what left the low-end box staring into an infinite black void the
  /// moment it turned away from a shelf; an interior with no walls cannot read
  /// as a store no matter how good the shelving is).
  ///
  /// Floor and ceiling are laid as a GRID of tiles rather than one giant slab
  /// because flutter_scene 0.16 has no sampler wrap mode: a cuboid face maps
  /// UV 0..1, so a single slab would stretch one 512 px carpet image across
  /// ~12 m. Each tile gets its own 0..1 mapping, which is real tiling.
  void _buildRoom() {
    final tx = textures;
    final x0 = roomMinX, x1 = roomMaxX;
    final z0 = roomMinZ, z1 = roomMaxZ;
    final w = x1 - x0, l = z1 - z0;
    final ceilY = ceilingY;

    // --- carpet ---
    final floorColor =
        halloween ? vm.Vector4(0.04, 0.05, 0.06, 1.0) : _carpetBlue;
    final floorMat =
        _surface(floorColor, tex: tx?.carpet, roughness: 0.9);
    final fCols = math.max(1, (w / 3.0).round());
    final fRows = math.max(1, (l / 3.0).round());
    final fw = w / fCols, fl = l / fRows;
    for (var i = 0; i < fCols; i++) {
      for (var j = 0; j < fRows; j++) {
        scene.add(Node(
          name: 'floor_${i}_$j',
          mesh: Mesh(CuboidGeometry(vm.Vector3(fw, 0.05, fl)), floorMat),
          localTransform: vm.Matrix4.translation(
            vm.Vector3(x0 + fw * (i + 0.5), 0, z0 + fl * (j + 0.5)),
          ),
        ));
      }
    }

    // --- drop ceiling ---
    final ceilColor = halloween
        ? vm.Vector4(0.03, 0.04, 0.05, 1.0)
        : vm.Vector4(0.72, 0.73, 0.75, 1.0);
    final ceilMat =
        _surface(ceilColor,
            tex: halloween ? (tx?.ceilingStained ?? tx?.ceilingTile) : tx?.ceilingTile,
            roughness: 0.95);
    final cCols = math.max(1, (w / 4.0).round());
    final cRows = math.max(1, (l / 4.0).round());
    final cw = w / cCols, cl = l / cRows;
    for (var i = 0; i < cCols; i++) {
      for (var j = 0; j < cRows; j++) {
        scene.add(Node(
          name: 'ceil_${i}_$j',
          mesh: Mesh(CuboidGeometry(vm.Vector3(cw, 0.06, cl)), ceilMat),
          localTransform: vm.Matrix4.translation(
            vm.Vector3(x0 + cw * (i + 0.5), ceilY, z0 + cl * (j + 0.5)),
          ),
        ));
      }
    }

    // --- perimeter walls ---
    final wallColor = halloween
        ? vm.Vector4(0.06, 0.07, 0.09, 1.0)
        : vm.Vector4(0.88, 0.89, 0.91, 1.0);
    final wallMat = _surface(wallColor, tex: tx?.wallPaint, roughness: 0.85);
    const t = 0.16;
    final wallH = ceilY + 0.1;
    // Walls are panelled in ~2.5 m segments for the same UV-tiling reason as
    // the floor: one cuboid stretched across the whole 12 m span turns the
    // paint speckle into smeared grey clouds.
    void wallRun(String name, bool alongX, double fixed, double from, double to) {
      final span = to - from;
      final n = math.max(1, (span / 2.5).round());
      final seg = span / n;
      for (var i = 0; i < n; i++) {
        final c = from + seg * (i + 0.5);
        scene.add(Node(
          name: '${name}_$i',
          mesh: Mesh(
            CuboidGeometry(alongX
                ? vm.Vector3(seg, wallH, t)
                : vm.Vector3(t, wallH, seg)),
            wallMat,
          ),
          localTransform: vm.Matrix4.translation(alongX
              ? vm.Vector3(c, wallH / 2, fixed)
              : vm.Vector3(fixed, wallH / 2, c)),
        ));
      }
    }

    wallRun('wall_front', true, z0, x0, x1);
    wallRun('wall_back', true, z1, x0, x1);
    wallRun('wall_left', false, x0, z0, z1);
    wallRun('wall_right', false, x1, z0, z1);

    // Dark rubber baseboard. Without it the wall meets the carpet in a single
    // hard seam, which is one of the strongest "untextured 3D" tells.
    final baseMat = _surface(vm.Vector4(0.12, 0.13, 0.16, 1.0), roughness: 0.6);
    void baseboard(String name, vm.Vector3 size, vm.Vector3 at) {
      scene.add(Node(
        name: name,
        mesh: Mesh(CuboidGeometry(size), baseMat),
        localTransform: vm.Matrix4.translation(at),
      ));
    }

    baseboard('base_front', vm.Vector3(w, 0.14, 0.08),
        vm.Vector3((x0 + x1) / 2, 0.07, z0 + t / 2 + 0.04));
    baseboard('base_back', vm.Vector3(w, 0.14, 0.08),
        vm.Vector3((x0 + x1) / 2, 0.07, z1 - t / 2 - 0.04));
    baseboard('base_left', vm.Vector3(0.08, 0.14, l),
        vm.Vector3(x0 + t / 2 + 0.04, 0.07, (z0 + z1) / 2));
    baseboard('base_right', vm.Vector3(0.08, 0.14, l),
        vm.Vector3(x1 - t / 2 - 0.04, 0.07, (z0 + z1) / 2));

    // Blockbuster's blue/gold band wrapping the top of the walls — the single
    // strongest brand read in the room, and it also breaks up the tall blank
    // wall planes that otherwise look like an empty box.
    final bandBlue = halloween ? vm.Vector4(0.20, 0.05, 0.30, 1.0) : _bbBlue;
    final bandMat = _surface(bandBlue, roughness: 0.5);
    final bandY = ceilY - 0.55;
    void band(String name, vm.Vector3 size, vm.Vector3 at) {
      scene.add(Node(
        name: name,
        mesh: Mesh(CuboidGeometry(size), bandMat),
        localTransform: vm.Matrix4.translation(at),
      ));
    }

    band('band_front', vm.Vector3(w, 0.5, 0.1),
        vm.Vector3((x0 + x1) / 2, bandY, z0 + t / 2 + 0.05));
    band('band_back', vm.Vector3(w, 0.5, 0.1),
        vm.Vector3((x0 + x1) / 2, bandY, z1 - t / 2 - 0.05));
    band('band_left', vm.Vector3(0.1, 0.5, l),
        vm.Vector3(x0 + t / 2 + 0.05, bandY, (z0 + z1) / 2));
    band('band_right', vm.Vector3(0.1, 0.5, l),
        vm.Vector3(x1 - t / 2 - 0.05, bandY, (z0 + z1) / 2));

    // --- fluorescent strips, one per corridor ---
    final lightMat = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(1.0, 1.0, 0.98, 1.0)
      ..emissiveFactor = halloween
          ? vm.Vector4(0.20, 0.45, 0.30, 1.0)
          : vm.Vector4(0.95, 0.95, 0.90, 1.0)
      ..roughnessFactor = 0.4;
    // Halloween builds its own dying tube fixtures (see HauntedStore) — a
    // continuous glowing strip can't flicker tube by tube.
    for (var a = 0; a < (halloween ? 0 : math.max(1, aisleCount)); a++) {
      scene.add(Node(
        name: 'light_$a',
        mesh: Mesh(
          CuboidGeometry(vm.Vector3(0.55, 0.05, l * 0.82)),
          lightMat,
        ),
        localTransform: vm.Matrix4.translation(
          vm.Vector3(aisleCenterX(a), ceilY - 0.09, (z0 + z1) / 2),
        ),
      ));
    }
    // --- wall signage ---
    // A blank painted wall filling the frame is the loudest remaining "this is
    // an empty 3D box" cue once the fixtures are stocked, so every long wall
    // gets something to read. Signs are self-lit (a real backlit sign face is
    // brighter than the wall behind it) rather than relying on the key light.
    PhysicallyBasedMaterial? wallSign(
        String name, gpu.Texture? tex, vm.Vector3 size, vm.Vector3 at) {
      if (tex == null) return null;
      final mat = PhysicallyBasedMaterial()
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        // VERY low: emissive is ADDED to the sampled colour, so it lifts the
        // dark field far more (proportionally) than the bright legend. At 0.20
        // the deep blue read as grey-lavender on-device; the sign only needs
        // enough lift to stay legible when the key light is off-axis.
        ..emissiveFactor = halloween
            ? vm.Vector4(0.08, 0.08, 0.08, 1.0)
            : vm.Vector4(0.06, 0.06, 0.06, 1.0)
        ..roughnessFactor = 0.35
        ..metallicFactor = 0.0;
      scene.add(Node(
        name: name,
        mesh: Mesh(CuboidGeometry(size), mat),
        localTransform: vm.Matrix4.translation(at),
      ));
      return mat;
    }

    // Brand sign on the back wall — the thing you read walking down any aisle.
    brandSignMaterial = wallSign(
      'sign_brand',
      tx?.signBrand,
      vm.Vector3(brandSignWidth, 1.15, 0.09),
      vm.Vector3((x0 + x1) / 2, ceilY - 1.5, z1 - t / 2 - 0.07),
    );
    // Section sign over the open walk-around floor on the right wall.
    wallSign(
      'sign_new_releases',
      tx?.signNewReleases,
      vm.Vector3(0.09, 0.80, math.min(3.4, l * 0.35)),
      vm.Vector3(x1 - t / 2 - 0.07, ceilY - 1.5, (z0 + z1) / 2),
    );
    // EXIT over the entrance end, behind the spawn point.
    wallSign(
      'sign_exit',
      tx?.signExit,
      vm.Vector3(1.1, 0.55, 0.09),
      vm.Vector3(x1 - 1.6, ceilY - 1.9, z0 + t / 2 + 0.07),
    );

    // Sponsor panels: LuxuriousComputers.com, hung 2:1 at reading height on
    // the long walls where a shopper walking the floor actually faces them.
    // One per end so the ad is visible from either half of the store.
    // Positions are recorded so the screen can offer to open the real Plex
    // Support page when you walk up to one.
    final adBack = vm.Vector3(x0 + 3.4, ceilY - 1.75, z1 - t / 2 - 0.07);
    final adFront = vm.Vector3(x1 - 5.0, ceilY - 1.75, z0 + t / 2 + 0.07);
    wallSign('ad_lux_back', tx?.adLuxurious, vm.Vector3(2.6, 1.3, 0.09), adBack);
    wallSign(
        'ad_lux_front', tx?.adLuxurious, vm.Vector3(2.6, 1.3, 0.09), adFront);
    adPanels
      ..clear()
      ..addAll([adBack, adFront]);

    // One more strip out over the open floor past the last corridor, so the
    // walk-around space isn't a dark trough.
    if (!halloween) {
      scene.add(Node(
        name: 'light_open',
        mesh: Mesh(
          CuboidGeometry(vm.Vector3(0.55, 0.05, l * 0.82)),
          lightMat,
        ),
        localTransform: vm.Matrix4.translation(
          vm.Vector3(x1 - 1.4, ceilY - 0.09, (z0 + z1) / 2),
        ),
      ));
    }
  }

  /// The back-wall brand sign's material, so the haunted layer can make the
  /// neon sputter.
  PhysicallyBasedMaterial? brandSignMaterial;

  /// The X coordinate of aisle [a]'s corridor center.
  double aisleCenterX(int a) => a * _aislePitch;

  /// World positions of the LuxuriousComputers sponsor panels. The screen
  /// uses these to detect that you are standing at one and facing it, so OK
  /// can open the real Plex Support page.
  final List<vm.Vector3> adPanels = [];

  // --- ceiling TV demo reel ----------------------------------------------
  // flutter_scene 0.16 (pinned to match this engine's flutter_gpu) has no way
  // to wrap a decoder's output as a texture: the only entry point is
  // gpuTextureFromImage, which does a GPU->CPU readback plus a fresh
  // allocation per call — ~10ms/frame on this class of device, and an
  // unbounded texture leak at 1.9GiB. So the store TV plays a REEL of the
  // library's own cover art rather than decoding video: same "something is
  // playing up there" read, at zero per-frame cost.
  PhysicallyBasedMaterial? _tvScreenMaterial;
  final List<StoreTitle> _reelTitles = [];
  int _reelIndex = 0;
  double _reelClock = 0;

  /// Seconds each title holds on the screen.
  static const double _reelHold = 4.0;

  /// Advances the demo reel. Cheap: it only reassigns an already-uploaded
  /// poster texture that the shelf is using anyway — nothing is created here.
  void updateDemoReel(double dt) {
    final mat = _tvScreenMaterial;
    if (mat == null || _reelTitles.isEmpty) return;
    _reelClock += dt;
    if (_reelClock < _reelHold && mat.baseColorTexture != null) return;
    _reelClock = 0;
    // Find the next title whose art has actually resolved.
    for (var i = 0; i < _reelTitles.length; i++) {
      _reelIndex = (_reelIndex + 1) % _reelTitles.length;
      final tex = _reelTitles[_reelIndex].texture;
      if (tex == null) continue;
      mat
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        // A lit CRT is brighter than the room, but this is additive on top of
        // the artwork, so keep it modest or the picture blows out.
        ..emissiveFactor = vm.Vector4(0.30, 0.30, 0.30, 1.0);
      return;
    }
  }

  // --- shoppers ----------------------------------------------------------
  final List<_Shopper> _shoppers = [];

  /// One translucent material per ghost shopper (Halloween only).
  final List<PhysicallyBasedMaterial> ghostMaterials = [];

  /// Public face of [_prop] for the haunted dressing layer.
  Node prop(String name, vm.Vector4 color, vm.Vector3 size, vm.Vector3 at,
          {vm.Vector4? emissive, double roughness = 0.6, double rotY = 0.0}) =>
      _prop(name, color, size, at,
          emissive: emissive, roughness: roughness, rotY: rotY);

  /// Public face of [_surface] for the haunted dressing layer.
  PhysicallyBasedMaterial surface(vm.Vector4 color,
          {gpu.Texture? tex, double roughness = 0.7}) =>
      _surface(color, tex: tex, roughness: roughness);

  /// Fixture metrics the dressing layer places props against.
  double get shelfBaseY => _shelfBaseY;
  double get shelfGapY => _shelfGapY;
  double get boxHeightM => _boxHeight;
  double get aisleWidth => _aisleWidth;

  /// A store with nobody in it reads as a diorama. These are deliberately few
  /// (each is 6 draw calls) and deterministic — seeded so screenshot diffs
  /// stay comparable between runs.
  void _buildShoppers() {
    final rnd = math.Random(1971);
    final count = reducedQuality ? 3 : 5;
    for (var i = 0; i < count; i++) {
      final skin = vm.Vector4(
        0.44 + rnd.nextDouble() * 0.34,
        0.32 + rnd.nextDouble() * 0.26,
        0.26 + rnd.nextDouble() * 0.22,
        1.0,
      );
      // Costume-bright on Halloween night, ordinary coats otherwise.
      final shirt = halloween
          ? [
              vm.Vector4(0.85, 0.35, 0.05, 1.0),
              vm.Vector4(0.35, 0.10, 0.45, 1.0),
              vm.Vector4(0.10, 0.45, 0.20, 1.0),
              vm.Vector4(0.55, 0.05, 0.10, 1.0),
            ][rnd.nextInt(4)]
          : [
              vm.Vector4(0.20, 0.28, 0.45, 1.0),
              vm.Vector4(0.45, 0.18, 0.18, 1.0),
              vm.Vector4(0.22, 0.22, 0.25, 1.0),
              vm.Vector4(0.30, 0.38, 0.28, 1.0),
            ][rnd.nextInt(4)];
      final pants = vm.Vector4(0.14, 0.15, 0.19, 1.0);
      final scale = 0.88 + rnd.nextDouble() * 0.24; // adults of varied height

      final s = _Shopper(
        aisle: rnd.nextInt(math.max(1, aisleCount)),
        z: rnd.nextDouble() * runLength,
        dir: rnd.nextBool() ? 1.0 : -1.0,
        dwell: rnd.nextDouble() * 4.0,
        scale: scale,
        phase: rnd.nextDouble() * 6.28,
      );

      // The store has been dead for years: on Halloween the customers are
      // the ones who never left. One translucent material per ghost so the
      // haunted layer can fade each in and out independently.
      final ghostMat = halloween
          ? (PhysicallyBasedMaterial()
            ..baseColorFactor = vm.Vector4(0.62, 0.82, 0.92, 0.34)
            ..emissiveFactor = vm.Vector4(0.10, 0.20, 0.24, 1.0)
            ..roughnessFactor = 0.3
            ..metallicFactor = 0.0
            ..alphaMode = AlphaMode.blend)
          : null;
      if (ghostMat != null) ghostMaterials.add(ghostMat);

      Node part(String n, vm.Vector4 c, vm.Vector3 size) {
        final node = ghostMat != null
            ? Node(
                name: 'ghost_${i}_$n',
                mesh: Mesh(CuboidGeometry(size), ghostMat),
              )
            : _prop('shopper_${i}_$n', c, size, vm.Vector3.zero());
        scene.add(node);
        return node;
      }

      // X = front-to-back (thin), Z = shoulder width. Getting these the wrong
      // way round made the torso a wide slab with the head apparently floating
      // over a gap.
      s.head = part('head', skin, vm.Vector3(0.20, 0.22, 0.19) * scale);
      s.torso = part('torso', shirt, vm.Vector3(0.20, 0.46, 0.38) * scale);
      s.armL = part('armL', shirt, vm.Vector3(0.10, 0.40, 0.10) * scale);
      s.armR = part('armR', shirt, vm.Vector3(0.10, 0.40, 0.10) * scale);
      s.legL = part('legL', pants, vm.Vector3(0.13, 0.46, 0.14) * scale);
      s.legR = part('legR', pants, vm.Vector3(0.13, 0.46, 0.14) * scale);
      _shoppers.add(s);
    }
  }

  /// Advances the shoppers. Cheap: no allocation of geometry or materials, we
  /// only rewrite each part's transform.
  void updateShoppers(double dt, vm.Vector3 cameraPos) {
    if (_shoppers.isEmpty) return;
    final runEnd = runLength;
    for (final s in _shoppers) {
      switch (s.state) {
        case _ShopperState.walking:
          // Ghosts drift; the living (the rest of the year) stride.
          s.z += s.dir * (halloween ? 0.42 : 0.85) * dt;
          s.phase += dt * 7.0;
          // Reached the end of the run: browse a while, then turn around.
          if (s.z < 0 || s.z > runEnd) {
            s.z = s.z.clamp(0.0, runEnd);
            s.dir = -s.dir;
            s.state = _ShopperState.browsing;
            s.dwell = 2.5 + (s.phase % 3.0);
          } else if ((s.z * 7).floor() % 23 == 0 && s.dwell <= 0) {
            // Occasionally stop to look at the shelf, like a real shopper.
            s.state = _ShopperState.browsing;
            s.dwell = 2.0 + (s.phase % 4.0);
          }
        case _ShopperState.browsing:
          s.dwell -= dt;
          // Keep the phase moving so the idle sway animates while stopped.
          s.phase += dt * 1.4;
          if (s.dwell <= 0) s.state = _ShopperState.walking;
      }

      // Walk the corridor, hugging its centre.
      final x = aisleCenterX(s.aisle) - _aisleWidth * 0.18;
      // Don't stand inside the player.
      final dx = x - cameraPos.x, dz = s.z - cameraPos.z;
      final dist = math.sqrt(dx * dx + dz * dz);
      final push = dist < 0.9 ? (0.9 - dist) : 0.0;
      final px = x + (dist > 1e-3 ? dx / dist : 1.0) * push;
      final pz = s.z + (dist > 1e-3 ? dz / dist : 0.0) * push;

      // Face along travel while walking; turn to the shelf while browsing.
      final yaw = s.state == _ShopperState.browsing
          ? math.pi // face -X, into the gondola
          : (s.dir > 0 ? math.pi / 2 : -math.pi / 2);

      // Swing is now an ANGLE in radians (the limbs rotate at the joint), not
      // a sideways offset — 0.42 rad is a ~24-degree stride, which reads as
      // walking rather than shuffling. Browsing keeps a tiny idle sway.
      final swing = halloween
          // A ghost doesn't walk: limbs trail and sway as it drifts.
          ? math.sin(s.phase * 0.35) * 0.10
          : s.state == _ShopperState.walking
              ? math.sin(s.phase) * 0.42
              : math.sin(s.phase * 0.4) * 0.04;
      // Footfall bob: twice per stride, since each step plants one foot.
      final bob = halloween
          // Hovering a hand's breadth off the carpet, rising and sinking.
          ? 0.16 + math.sin(s.phase * 0.45) * 0.06
          : s.state == _ShopperState.walking
              ? math.cos(s.phase * 2).abs() * 0.022
              : 0.0;
      final sc = s.scale;

      // Body-local offset -> world. vector_math's rotationY maps
      // (x,z) -> (x*cos + z*sin, -x*sin + z*cos), so compose the same way the
      // node's own rotationY does or the parts scatter off the torso.
      // Body frame -> world. Everything hangs off one base transform, so the
      // parts stay welded together however the shopper is turned.
      final base =
          vm.Matrix4.translation(vm.Vector3(px, bob, pz)) *
              vm.Matrix4.rotationY(yaw);

      void place(Node? n, vm.Vector3 local) {
        if (n == null) return;
        n.localTransform = base * vm.Matrix4.translation(local);
      }

      /// A limb that SWINGS FROM ITS JOINT. Rotating the box about its own
      /// centre makes the limb tilt in place like a see-saw; a real stride
      /// pivots at the hip/shoulder. So: translate to the joint, rotate, then
      /// push the limb's half-length back down so its top stays pinned there.
      void swingLimb(Node? n, double jointY, double sideZ, double angle,
          double halfLen) {
        if (n == null) return;
        n.localTransform = base *
            vm.Matrix4.translation(vm.Vector3(0, jointY, sideZ)) *
            vm.Matrix4.rotationX(angle) *
            vm.Matrix4.translation(vm.Vector3(0, -halfLen, 0));
      }

      final legHalf = 0.23 * sc; // legs are 0.46 tall
      final armHalf = 0.20 * sc; // arms are 0.40 tall
      // Hips at the top of the legs, shoulders at the top of the arms.
      final hipY = 0.46 * sc;
      final shoulderY = 0.90 * sc;

      swingLimb(s.legL, hipY, -0.09 * sc, swing, legHalf);
      swingLimb(s.legR, hipY, 0.09 * sc, -swing, legHalf);
      // Arms counter-swing against the legs, as they do when you walk.
      swingLimb(s.armL, shoulderY, -0.235 * sc, -swing * 0.8, armHalf);
      swingLimb(s.armR, shoulderY, 0.235 * sc, swing * 0.8, armHalf);

      place(s.torso, vm.Vector3(0, 0.69 * sc, 0));
      place(s.head, vm.Vector3(0, 1.03 * sc, 0));
    }
  }

  /// Attaches a printed sleeve to the back of [box] using [tex]. Only ever one
  /// exists at a time (the tape in hand); calling this for a new box tears the
  /// previous one down, so the GPU never holds a library of box backs.
  void attachBoxBack(StoreBox box, gpu.Texture tex) {
    detachBoxBack(box);
    final mat = PhysicallyBasedMaterial()
      ..baseColorTexture = tex
      // Multiply the sampled sleeve DOWN: the overhead key is bright enough to
      // wash a dark printed card to mid grey on its own.
      ..baseColorFactor = vm.Vector4(0.55, 0.55, 0.55, 1.0)
      // Near-zero lift. This sleeve is mostly a DARK field with light ink, so
      // any ambient add lifts the background far more (proportionally) than
      // the text and the card greys out to ~(106,106,107) — measured.
      ..emissiveFactor = vm.Vector4(0.02, 0.02, 0.02, 1.0)
      ..roughnessFactor = 0.9
      ..metallicFactor = 0.0;
    // Needs REAL thickness: at 0.004 the +/-X faces are degenerate slivers and
    // the sleeve rendered as flat unlit grey instead of sampling its map.
    final node = Node(
      name: 'boxback_${box.aisleIndex}_${box.slotColumn}_${box.rowIndex}',
      mesh: Mesh(
        CuboidGeometry(vm.Vector3(0.02, _boxHeight * 0.97, _boxWidth * 0.97)),
        mat,
      ),
    );
    scene.add(node);
    box
      ..backPanel = node
      ..backMaterial = mat
      ..backTexture = tex;
  }

  /// Removes and frees the printed sleeve, if any.
  void detachBoxBack(StoreBox box) {
    final node = box.backPanel;
    if (node != null) scene.remove(node);
    box.backTexture = null;
    box.backPanel = null;
    box.backMaterial = null;
  }

  MeshGeometry? _caseGeometry;

  /// Resting emissive of a case wearing real art.
  vm.Vector4 get _caseRestEmissive => halloween
      ? vm.Vector4(0.05, 0.05, 0.05, 1.0)
      : vm.Vector4(0.14, 0.14, 0.14, 1.0);

  /// One gondola: the fixture body, header valance and planks, a scrolling
  /// [RackFace] on each side, and a section sign on each side of the header.
  void _buildFixture(
    int f,
    VideoStoreData data, {
    required int? frontSection,
    required int backSection,
    required bool backStartsMidway,
  }) {
    final centerX = aisleCenterX(f);
    // The gondola fixture sits at the corridor's left edge and is stocked on
    // BOTH faces: the +X face fronts this corridor, the -X face fronts the
    // previous one (or the entry floor for aisle 0).
    final fixtureX = centerX - _aisleWidth / 2;
    final shelfX = fixtureX + 0.05 + _boxDepth / 2; // front (+X) case centres
    final backX = fixtureX - 0.05 - _boxDepth / 2; // back (-X) case centres
    final runLength = this.runLength;
    // Fixture panel stops just above the top row of stock, so the header
    // valance sits ON the merchandise instead of floating over a blank slab.
    final unitHeight =
        _shelfBaseY + (rows - 1) * _shelfGapY + _boxHeight / 2 + 0.22;

    final wallMat = _surface(
      halloween ? vm.Vector4(0.05, 0.06, 0.07, 1.0) : _shelfWhite,
      tex: halloween ? textures?.grimePanel : textures?.shelfPanel,
      roughness: 0.7,
    );
    scene.add(Node(
      name: 'wall_$f',
      mesh: Mesh(
        CuboidGeometry(vm.Vector3(0.1, unitHeight, runLength)),
        wallMat,
      ),
      localTransform: vm.Matrix4.translation(
        vm.Vector3(fixtureX, unitHeight / 2, runLength / 2),
      ),
    ));

    // Header valance across the top of the run with a thin accent stripe.
    final headerColor =
        halloween ? vm.Vector4(0.20, 0.05, 0.30, 1.0) : _bbBlue;
    final headerMat = PhysicallyBasedMaterial()
      ..baseColorFactor = headerColor
      ..emissiveFactor = _ambientLift(headerColor)
      ..roughnessFactor = 0.5;
    scene.add(Node(
      name: 'header_$f',
      mesh: Mesh(CuboidGeometry(vm.Vector3(0.44, 0.34, runLength)), headerMat),
      localTransform: vm.Matrix4.translation(
        vm.Vector3(fixtureX, unitHeight + 0.05, runLength / 2),
      ),
    ));
    final stripeMat = PhysicallyBasedMaterial()
      ..baseColorFactor =
          halloween ? vm.Vector4(0.85, 0.35, 0.05, 1.0) : _bbYellow
      ..emissiveFactor = halloween
          ? vm.Vector4(0.30, 0.12, 0.02, 1.0)
          : vm.Vector4(0.55, 0.44, 0.06, 1.0)
      ..roughnessFactor = 0.4;
    scene.add(Node(
      name: 'stripe_$f',
      mesh: Mesh(CuboidGeometry(vm.Vector3(0.46, 0.05, runLength)), stripeMat),
      localTransform: vm.Matrix4.translation(
        vm.Vector3(fixtureX, unitHeight - 0.14, runLength / 2),
      ),
    ));

    final plankColor = halloween
        ? vm.Vector4(0.08, 0.08, 0.09, 1.0)
        : vm.Vector4(0.80, 0.81, 0.83, 1.0);
    final plankMat = PhysicallyBasedMaterial()
      ..baseColorFactor = plankColor
      ..emissiveFactor = _ambientLift(plankColor)
      ..roughnessFactor = 0.6;

    void stockFace(int side, int sectionIndex, {bool midway = false}) {
      final bx = side == 0 ? shelfX : backX;
      for (var row = 0; row < rows; row++) {
        scene.add(Node(
          name: 'plank_${f}_${side}_$row',
          mesh: Mesh(
            CuboidGeometry(vm.Vector3(_boxDepth * 2.6, 0.03, runLength)),
            plankMat,
          ),
          localTransform: vm.Matrix4.translation(vm.Vector3(
            bx,
            _shelfBaseY + row * _shelfGapY - _boxHeight / 2 - 0.02,
            runLength / 2,
          )),
        ));
      }
      final face = RackFace(
        scene: scene,
        section: data.aisles[sectionIndex],
        sectionIndex: sectionIndex,
        fixtureIndex: f,
        side: side,
        boxX: bx,
        rows: rows,
        cols: maxSlotsPerRow,
        baseY: _shelfBaseY,
        gapY: _shelfGapY,
        spacing: _slotSpacing,
        boxExtents: vm.Vector3(_boxDepth, _boxHeight, _boxWidth),
        geometry: _caseGeometry!,
        restEmissive: _caseRestEmissive,
        tintFor: _spineTintColor,
      );
      if (midway) {
        face.scroll = face.scrollTarget = (face.maxScroll / 2).floorToDouble();
      }
      faces.add(face);
      _buildFaceSign(face, fixtureX, unitHeight);
    }

    if (frontSection != null) stockFace(0, frontSection);
    stockFace(1, backSection, midway: backStartsMidway);
  }

  /// A lit section sign hung on one side of a gondola's header, facing that
  /// face's corridor, showing the section's real name. With a section per
  /// FACE (not per corridor) the old single sign over the corridor would
  /// have named only one of the two runs you're standing between.
  void _buildFaceSign(RackFace face, double fixtureX, double unitHeight) {
    final tex = textures?.sectionSigns[face.section.signLabel];
    if (tex == null) return;
    final mat = PhysicallyBasedMaterial()
      ..baseColorTexture = tex
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
      // Low: additive on top of an already-dark sign field.
      ..emissiveFactor = vm.Vector4(0.08, 0.08, 0.08, 1.0)
      ..roughnessFactor = 0.35
      ..metallicFactor = 0.0;
    // Mounted ON the header valance's face (not floating over it): centred
    // on the header, it overhangs just enough to cover the stripe and still
    // clears the top tier of tapes (whose tops sit at unitHeight - 0.22).
    final x = fixtureX + face.outward * 0.245;
    final y = unitHeight + 0.08;
    scene.add(Node(
      name: 'face_sign_${face.sectionIndex}_${face.side}',
      mesh: Mesh(CuboidGeometry(vm.Vector3(0.04, 0.54, 2.2)), mat),
      localTransform: vm.Matrix4.translation(vm.Vector3(x, y, runLength / 2)),
    ));
  }

  // ---- Halcyon floor props ----------------------------------------------

  /// A short helper: a solid coloured cuboid node with ambient lift baked in.
  Node _prop(String name, vm.Vector4 color, vm.Vector3 size, vm.Vector3 at,
      {vm.Vector4? emissive, double roughness = 0.6, double rotY = 0.0}) {
    final mat = PhysicallyBasedMaterial()
      ..baseColorFactor = color
      ..emissiveFactor = emissive ?? _ambientLift(color)
      ..roughnessFactor = roughness
      ..metallicFactor = 0.0;
    return Node(
      name: name,
      mesh: Mesh(CuboidGeometry(size), mat),
      localTransform:
          vm.Matrix4.translation(at) * vm.Matrix4.rotationY(rotY),
    );
  }

  /// Low endcap "display" units capping each shelf run — the short blue plinth
  /// with a yellow topper sign you see at the end of a Blockbuster aisle. Kept
  /// SHORT (top ~0.9 m, well below the box wall) and placed at the FAR end of
  /// the run (high Z) plus against the shelf (low X), so from the camera's
  /// tight -X view they read as a low unit down the aisle — never a slab across
  /// the lens and never occluding the focused box.
  void _buildEndcaps(int aisleCount) {
    final runLength = (maxSlotsPerRow + 1) * _slotSpacing;
    final blue = halloween ? vm.Vector4(0.20, 0.05, 0.30, 1.0) : _bbBlue;
    for (var a = 0; a < aisleCount; a++) {
      // Sit it against the shelf line (same X as the boxes), at the run's end.
      final cx = aisleCenterX(a) - _aisleWidth / 2 + _boxDepth + 0.15;
      final cz = runLength + 0.25;
      // Blue plinth cabinet.
      scene.add(_prop('endcap_${a}_base', blue,
          vm.Vector3(0.5, 0.7, 0.6), vm.Vector3(cx, 0.35, cz),
          roughness: 0.5));
      // Yellow topper sign on top.
      scene.add(_prop('endcap_${a}_top', _bbYellow,
          vm.Vector3(0.55, 0.18, 0.65), vm.Vector3(cx, 0.79, cz),
          emissive: halloween
              ? vm.Vector4(0.30, 0.12, 0.02, 1.0)
              : vm.Vector4(0.55, 0.44, 0.06, 1.0),
          roughness: 0.4));
    }
  }

  /// A CRT TV cabinet hung from the ceiling, with a glowing screen face — the
  /// store's demo-reel monitor. Hung high and toward the run's far end so it
  /// reads as overhead background, not across the walking camera's view.
  void _buildHangingTv(int aisleCount) {
    final runLength = (maxSlotsPerRow + 1) * _slotSpacing;
    // Hang it near the shelf line at the far end of aisle 0's run, up high.
    final cx = aisleCenterX(0) - _aisleWidth / 2 + 0.4;
    final cz = runLength * 0.85;
    final y = rows * _shelfGapY + 0.35;
    // Dark cabinet.
    scene.add(_prop('tv_cab', vm.Vector4(0.06, 0.06, 0.07, 1.0),
        vm.Vector3(0.9, 0.7, 0.8), vm.Vector3(cx, y, cz),
        emissive: vm.Vector4(0.03, 0.03, 0.03, 1.0), roughness: 0.5));
    // Glowing screen face — on the +X side, toward the camera that looks -X.
    // Kept as its own material so the demo reel can swap artwork onto it each
    // few seconds (see updateDemoReel). A store TV that plays something is the
    // difference between a prop and a fixture.
    _tvScreenMaterial = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.4, 0.55, 0.75, 1.0)
      ..emissiveFactor = halloween
          ? vm.Vector4(0.15, 0.35, 0.25, 1.0)
          : vm.Vector4(0.35, 0.45, 0.6, 1.0)
      ..roughnessFactor = 0.3
      ..metallicFactor = 0.0;
    scene.add(Node(
      name: 'tv_screen',
      mesh: Mesh(
        CuboidGeometry(vm.Vector3(0.03, 0.5, 0.66)),
        _tvScreenMaterial!,
      ),
      localTransform: vm.Matrix4.translation(vm.Vector3(cx + 0.46, y, cz)),
    ));
    // Mount stem to the ceiling.
    scene.add(_prop('tv_stem', vm.Vector4(0.1, 0.1, 0.11, 1.0),
        vm.Vector3(0.08, 0.5, 0.08),
        vm.Vector3(cx, y + 0.55, cz),
        roughness: 0.6));
  }

  /// Per-frame rack + art update: slides scrolling racks, re-binds cases to
  /// whatever title/texture is current, and keeps wall one-sheets in step
  /// with the poster cache (which can EVICT a texture, so binding is checked
  /// every frame rather than applied once).
  void updateRacks(double dt, [vm.Vector3? cam]) {
    for (final f in faces) {
      f.update(dt);
      if (cam != null) f.cull(cam);
    }
    for (final art in _wallArt) {
      final tex = art.title.texture;
      if (identical(tex, art.material.baseColorTexture)) continue;
      if (tex != null) {
        art.material
          ..baseColorTexture = tex
          ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
          ..emissiveFactor = halloween
              ? vm.Vector4(0.05, 0.05, 0.05, 1.0)
              : vm.Vector4(0.16, 0.16, 0.16, 1.0);
      } else {
        final tint = _spineTintColor(art.title.key);
        art.material
          ..baseColorTexture = null
          ..baseColorFactor = tint
          ..emissiveFactor = _ambientLift(tint);
      }
    }
  }

  StoreBox? _focusBox;

  /// Marks [box] as the focused case (a neutral emissive lift — see
  /// [RackFace._applyMaterial] for why it must not be tinted) and clears the
  /// previous one. O(1): only the two affected cases are touched.
  void setFocus(StoreBox? box) {
    if (identical(box, _focusBox)) return;
    final prev = _focusBox;
    if (prev != null) {
      prev.focused = false;
      prev.face.refresh(prev);
    }
    _focusBox = box;
    if (box != null) {
      box.focused = true;
      box.face.refresh(box);
    }
  }

  /// The ordered list of titles the poster cache should hold right now:
  /// the face being browsed first (with a generous scroll-ahead margin), then
  /// faces the camera can see sorted by distance, then the rest, then the
  /// wall art and the ceiling TV's reel.
  List<StoreTitle> wantedTitles(vm.Vector3 cam, {RackFace? browsing}) {
    final out = <StoreTitle>[];
    final seen = <StoreTitle>{};
    void add(Iterable<StoreTitle> ts) {
      for (final t in ts) {
        if (seen.add(t)) out.add(t);
      }
    }

    // Six columns of scroll-ahead on the rack being browsed.
    if (browsing != null) add(browsing.wantedTitles(margin: 6));
    final ordered = [...faces]..sort((a, b) {
        // Faces whose posters look at the camera beat faces behind a gondola.
        final fa = a.facesToward(cam) ? 0 : 1, fb = b.facesToward(cam) ? 0 : 1;
        if (fa != fb) return fa - fb;
        return a.distanceTo(cam).compareTo(b.distanceTo(cam));
      });
    // The nearest few faces, then the wall one-sheets and the TV reel (they
    // are in view from almost anywhere), then everything else. On the reduced
    // tier the budget runs out partway through the far faces, which then wear
    // spine tints — you can't read a poster four aisles away anyway.
    var i = 0;
    for (; i < ordered.length && i < 4; i++) {
      if (identical(ordered[i], browsing)) continue;
      add(ordered[i].wantedTitles(margin: 1));
    }
    add([for (final w in _wallArt) w.title]);
    add(_reelTitles);
    for (; i < ordered.length; i++) {
      if (identical(ordered[i], browsing)) continue;
      add(ordered[i].wantedTitles(margin: 1));
    }
    return out;
  }

  /// [_spineTint] as an opaque RGBA colour.
  vm.Vector4 _spineTintColor(String key) {
    final t = _spineTint(key);
    return vm.Vector4(t.x, t.y, t.z, 1.0);
  }

  vm.Vector3 _spineTint(String key) {
    final h = key.hashCode & 0x7fffffff;
    final hue = (h % 360).toDouble();
    return _hsvToRgb(hue, 0.6, halloween ? 0.35 : 0.72);
  }

  vm.Vector3 _hsvToRgb(double h, double s, double v) {
    final c = v * s;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = v - c;
    double r = 0, g = 0, b = 0;
    if (h < 60) {
      r = c; g = x;
    } else if (h < 120) {
      r = x; g = c;
    } else if (h < 180) {
      g = c; b = x;
    } else if (h < 240) {
      g = x; b = c;
    } else if (h < 300) {
      r = x; b = c;
    } else {
      r = c; b = x;
    }
    return vm.Vector3(r + m, g + m, b + m);
  }
}
