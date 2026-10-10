import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart' as fscene;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../../focus/dpad_navigator.dart';
import '../../focus/key_event_utils.dart';
import '../../media/media_library.dart';
import '../../mixins/refreshable.dart';
import '../../navigation/main_screen_scope.dart';
import '../../providers/libraries_provider.dart';
import '../../services/device_performance.dart';
import '../../utils/media_image_helper.dart';
import '../../utils/media_navigation_helper.dart';
import 'store_textures.dart';
import 'store_theme.dart';
import 'video_store_2d_fallback.dart';
import 'video_store_3d.dart';
import 'video_store_data.dart';

/// The 3D video-store tab: a first-person, D-pad-walkable Blockbuster aisle
/// built on `flutter_scene`. Titles come from the signed-in Plex/Jellyfin
/// libraries at runtime; box art is streamed in as GPU textures.
///
/// Renders via a [CustomPainter] calling [fscene.Scene.render] every frame
/// (flutter_scene 0.18.1 has no `SceneView` widget). If Flutter GPU is
/// unavailable or the device is too weak to init the scene, this degrades to
/// the flat [VideoStore2DFallback] so the store is never a dead tab.
class VideoStoreScreen extends StatefulWidget {
  const VideoStoreScreen({super.key});

  @override
  State<VideoStoreScreen> createState() => _VideoStoreScreenState();
}

class _VideoStoreScreenState extends State<VideoStoreScreen> implements FocusableTab, Refreshable {
  List<MediaLibrary> _libraries = const [];
  GlobalKey<_VideoStoreContentState> _contentKey = GlobalKey();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final libraries = context.watch<LibrariesProvider>().libraries;
    if (listEquals(_libraries, libraries)) return;
    final restoreFocus = _contentKey.currentState?.hasContentFocus ?? false;
    _libraries = libraries;
    // Libraries arrive after profile binding and again after a server recovers.
    // Recreate the catalog and scene together so an empty initial snapshot does
    // not permanently strand the store. Unrelated provider notices keep the
    // same content state, camera and poster cache.
    _contentKey = GlobalKey();
    if (restoreFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) focusActiveTabIfReady();
      });
    }
  }

  @override
  void focusActiveTabIfReady() => _contentKey.currentState?.focusActiveTabIfReady();

  @override
  void refresh() => unawaited(context.read<LibrariesProvider>().refresh());

  @override
  Widget build(BuildContext context) => _VideoStoreContent(key: _contentKey);
}

class _VideoStoreContent extends StatefulWidget {
  const _VideoStoreContent({super.key});

  @override
  State<_VideoStoreContent> createState() => _VideoStoreContentState();
}

class _VideoStoreContentState extends State<_VideoStoreContent>
    with SingleTickerProviderStateMixin
    implements FocusableTab {
  bool get hasContentFocus => _focusNode.hasFocus || (_fallbackKey.currentState?.hasContentFocus ?? false);

  /// main_screen hands D-pad focus to the active tab through this. Without it
  /// the store relied on `autofocus: true`, which fights main_screen's
  /// programmatic focus control and left the remote stranded on the rail.
  @override
  void focusActiveTabIfReady() {
    if (!mounted) return;
    if (_initFailed) {
      _fallbackKey.currentState?.focusActiveTabIfReady();
      return;
    }
    _focusNode.requestFocus();
  }

  final _fallbackKey = GlobalKey<VideoStore2DFallbackState>();

  // --- render / scene state ---
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  bool _initFailed = false; // Flutter GPU / static-resource init blew up
  bool _sceneReady = false;
  bool _reducedQuality = false;

  VideoStoreScene? _store;

  /// Replaced in [_boot] with the reduced tier on weak boxes.
  VideoStoreData _data = VideoStoreData();
  final fscene.PerspectiveCamera _camera = fscene.PerspectiveCamera(
    fovRadiansY: 60 * vm.degrees2Radians,
    position: vm.Vector3(0, 1.6, -2),
    target: vm.Vector3(0, 1.6, 0),
    up: vm.Vector3(0, 1, 0),
  );

  // --- first-person navigation state (free-walk camera) ---
  // A true walk-the-store camera: UP/DOWN stride along the current heading,
  // LEFT/RIGHT turn it. The camera eases toward the wanted pose every tick so
  // walking reads as smooth motion through the aisles (perspective depth,
  // shelves receding) instead of a teleport between head-on shelf views.
  vm.Vector3 _camPos = vm.Vector3(0.6, VideoStoreScene.eyeHeight, -1.0);
  vm.Vector3 _wantPos = vm.Vector3(0.6, VideoStoreScene.eyeHeight, -1.0);
  double _yaw = math.pi / 2; // eased heading; pi/2 = looking +Z down the run
  double _wantYaw = math.pi / 2;

  /// The box the camera is standing near AND facing — what OK will pick up.
  /// Null while walking open floor.
  StoreBox? _focused;

  final FocusNode _focusNode = FocusNode();
  bool _launching = false; // OK pressed: playing a title, suppress input

  // --- pick-up state ---
  // walk → find → PICK UP → play. First OK on a shelved box lifts it off the
  // shelf and floats it, enlarged and face-on, in front of the camera. A
  // second OK plays it; Back or any arrow puts it back and resumes browsing.
  StoreBox? _pickedUp;
  StoreBox? _lastPicked; // keeps animating home for one release
  double _pickAnim = 0; // 0 = on shelf, 1 = fully in hand (eases each tick)

  /// 0 = cover art toward the viewer, 1 = turned over to the printed back.
  /// Eased, so the case physically rotates rather than cutting.
  bool _showBack = false;
  double _flipAnim = 0;

  // --- browse mode (shelf -> tier -> title) ------------------------------
  // Free-walking a whole store to reach one film is slow on a D-pad, so OK on
  // a shelf ENTERS that bay: the camera squares up to it, UP/DOWN pick the
  // shelf tier (top/middle/bottom) and LEFT/RIGHT run along that tier. BACK
  // steps out again. Free-walk is untouched until you enter a bay.
  /// How many key-repeat events the current hold has produced. Drives the
  /// walk/turn acceleration so holding a direction glides down a row.
  int _repeatRun = 0;

  /// True while standing at a LuxuriousComputers panel and facing it — OK
  /// then opens the real Plex Support page instead of entering a shelf.
  bool _atAdPanel = false;

  /// The store's own Plex support page. Verified live (HTTP 200, no redirect):
  /// the "Plex Fix Clinic" page on the Shopify storefront.
  static const String _plexSupportUrl = 'https://luxuriouscomputers.com/pages/plex-support';

  bool _browsing = false;

  /// The rack face being browsed. Its section is shelved in FULL: moving the
  /// selection past the end of the run scrolls the rack rather than stopping.
  RackFace? _browseFace;

  /// The selection, as an index into [_browseFace]'s whole section.
  int _browseIndex = 0;

  /// Seconds until the poster cache is next told what matters.
  double _wantClock = 0;

  // Rolling counters for the periodic stats log line.
  int _statFrames = 0;
  double _statClock = 0;
  int _statUpdateUs = 0;

  bool get _halloween => resolveHalloweenActive();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // Gate quality off device class up front so a Fire Stick builds fewer boxes.
    _reducedQuality = DevicePerformance.isReduced || DevicePerformance.isLowEndHardware;
    if (_reducedQuality) _data = VideoStoreData.reduced();
    debugPrint(
      '[VideoStore] reducedQuality=$_reducedQuality '
      '(isReduced=${DevicePerformance.isReduced} '
      'lowEnd=${DevicePerformance.isLowEndHardware})',
    );

    try {
      await fscene.Scene.initializeStaticResources();
    } catch (e, st) {
      // No Flutter GPU (old device, GPU flag off, emulator w/o Impeller) —
      // fall back to the 2D shelf so the tab still works.
      debugPrint('[VideoStore] Flutter GPU init failed, using 2D fallback: $e\n$st');
      if (mounted) setState(() => _initFailed = true);
      return;
    }

    if (!mounted) return;

    try {
      final store = VideoStoreScene(halloween: _halloween, reducedQuality: _reducedQuality);

      // Bake the surface maps (carpet, ceiling tile, wall paint, shelf panel,
      // wood, laminate) before the scene graph is built — the materials take
      // their texture at construction time.
      final textures = StoreTextures();
      await textures.load(halloween: _halloween);
      if (!mounted) return;
      store.textures = textures;

      // Pull the signed-in libraries and build the aisles.
      final libraries = context.read<LibrariesProvider>().libraries;
      await _data.load(context, libraries, halloween: _halloween);
      if (!mounted) return;

      // Section signs are baked from the REAL library names, so they can only be
      // made once the libraries are known — after _data.load, before build().
      for (final aisle in _data.aisles) {
        await textures.sectionSign(aisle.signLabel, halloween: _halloween);
      }
      if (!mounted) return;

      store.build(_data);
      _store = store;

      // Spawn at the store entrance: standing in aisle 0's corridor just
      // before the run, facing +Z down the aisle so the shelf wall recedes in
      // perspective on the left — an immediate "I'm inside a store" view.
      _wantPos = vm.Vector3(store.aisleCenterX(0) + 0.7, VideoStoreScene.eyeHeight, -1.0);
      _wantYaw = math.pi / 2;

      // Debug spawn for the screenshot harness. Driving the camera across the
      // store with blind D-pad presses to photograph a prop is unreliable — it
      // parks against whatever wall it hits. With
      //   flutter run --dart-define=STORE_SPAWN=checkout
      // (or the same define at build time) we start at the checkout looking at
      // it, so the snack corner can actually be reviewed.
      const spawn = String.fromEnvironment('STORE_SPAWN');
      if (spawn == 'checkout') {
        // Stand on the sales-floor side of the counter, looking +X at it.
        // Stand back and off to the -Z side so the counter, the hung sign, the
        // candy rack AND the cooler are all in frame at once — parked square on
        // the desk, the sign fills the lens and hides the rest of the corner.
        _wantPos = vm.Vector3(store.roomMaxX - 6.2, VideoStoreScene.eyeHeight, store.roomMinZ + 5.4);
        _wantYaw = -math.pi / 5;
      } else if (spawn == 'aisle') {
        // Stand at the mouth of aisle 0 looking down the run — the view that
        // actually frames shoppers walking the corridor.
        _wantPos = vm.Vector3(store.aisleCenterX(0) + 0.9, VideoStoreScene.eyeHeight, -1.5);
        _wantYaw = math.pi / 2;
      } else if (spawn == 'ad') {
        // Stand off the back wall's sponsor panel (ad_lux_back) looking at it.
        // ad_lux_back sits at (roomMinX+3.4, roomMaxZ-t/2-0.07). Stand 3m off it
        // on the same X, looking +Z straight at it — inside the 4.5m reach and
        // well within the facing cone, so _atAdPanel trips immediately.
        _wantPos = vm.Vector3(store.roomMinX + 3.4, VideoStoreScene.eyeHeight, store.roomMaxZ - 3.2);
        _wantYaw = math.pi / 2;
      } else if (spawn == 'tv') {
        // Stand back down aisle 0's corridor looking UP the run at the hanging
        // CRT, which sits near the far end at (shelfWall+0.4, rows*gap+0.35).
        // Well back down the corridor: the CRT hangs high near the far end, so
        // standing close puts it above the top of the frame.
        _wantPos = vm.Vector3(store.aisleCenterX(0) + 1.4, VideoStoreScene.eyeHeight, -2.0);
        _wantYaw = math.pi / 2;
      }
      _camPos = _wantPos.clone();
      _yaw = _wantYaw;
      _camera.position = _camPos;
      _camera.target = _camPos + _forward(_yaw) * 4.0;
      _updateFocused();
      _sceneReady = true;

      final ticker = createTicker(_onTick);
      _ticker = ticker;
      // TickerFuture never completes until disposed — fire-and-forget.
      unawaited(ticker.start());
      if (mounted) setState(() {});
    } catch (e, st) {
      // Building the flutter_scene graph can throw if Flutter GPU / Impeller
      // isn't actually available at construction time (e.g. the renderer policy
      // selected Skia). Fall back to the 2D shelf instead of hanging forever on
      // the "Opening the crypt…" loader (which only clears when _sceneReady).
      debugPrint('[VideoStore] scene build failed, using 2D fallback: $e\n$st');
      if (mounted) setState(() => _initFailed = true);
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero ? 0.0 : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;

    // Tell the poster cache what's near the camera a few times a second
    // (and immediately after a scroll), then stream in whatever is missing.
    final store = _store;
    _wantClock -= dt;
    if (store != null && _wantClock <= 0) {
      _wantClock = 0.25;
      _data.setWanted(store.wantedTitles(_camPos, browsing: _browsing ? _browseFace : null));
    }
    _data.pumpPosterQueue(context);

    // One health line every 5 s: measured fps on the real box, how many
    // poster textures are resident against the budget, and how much of the
    // library has been shelved. This is what the test harness greps.
    _statFrames++;
    _statClock += dt;
    if (_statClock >= 5.0) {
      final upd = _statUpdateUs / math.max(1, _statFrames) / 1000;
      final ren = _StorePainter.renderUs / math.max(1, _StorePainter.renderCount) / 1000;
      _statUpdateUs = 0;
      _StorePainter.renderUs = 0;
      _StorePainter.renderCount = 0;
      debugPrint(
        '[VideoStore] stats fps=${(_statFrames / _statClock).toStringAsFixed(1)} '
        'updateMs=${upd.toStringAsFixed(1)} renderCpuMs=${ren.toStringAsFixed(1)} '
        'resident=${_data.residentCount}/${_data.textureBudget} '
        'titles=${_data.totalTitles} paging=${_data.stillLoading} '
        'browsing=${_browsing ? '${_browseIndex + 1}/${_browseFace?.titles.length}' : '-'}',
      );
      _statFrames = 0;
      _statClock = 0;
    }

    // Smoothly ease the camera toward its wanted pose (walk + turn). The yaw
    // eases along the shortest arc so a 180° spin doesn't whip the long way.
    // Faster ease: at 6.0 a stride visibly "floated" to a stop, which made
    // repeated presses feel laggy and imprecise when walking a row.
    final k = (dt * 11.0).clamp(0.0, 1.0);
    _camPos = _lerp3(_camPos, _wantPos, k);
    var dYaw = _wantYaw - _yaw;
    while (dYaw > math.pi) {
      dYaw -= 2 * math.pi;
    }
    while (dYaw < -math.pi) {
      dYaw += 2 * math.pi;
    }
    _yaw += dYaw * k;
    _camera.position = _camPos;
    _camera.target = _camPos + _forward(_yaw) * 4.0;

    // Racks, shoppers (or ghosts), the demo reel and the haunted layer.
    final sw = Stopwatch()..start();
    _store?.update(dt, _camPos);
    _statUpdateUs += sw.elapsedMicroseconds;
    // A sliding rack re-binds its slots, so keep the focus on the SELECTED
    // title's case as it arrives.
    if (_browsing) _syncBrowseFocus();

    // Ease the picked-up box between shelf (0) and in-hand (1), then place it.
    final wantPick = _pickedUp != null ? 1.0 : 0.0;
    _pickAnim += (wantPick - _pickAnim) * (dt * 8.0).clamp(0.0, 1.0);
    final wantFlip = (_pickedUp != null && _showBack) ? 1.0 : 0.0;
    _flipAnim += (wantFlip - _flipAnim) * (dt * 7.0).clamp(0.0, 1.0);
    _updatePickedBox();

    // Drive a repaint. The CustomPainter re-renders the scene each frame.
    if (mounted) setState(() {});
  }

  /// Places the picked-up box: floats it out of the shelf toward the camera,
  /// scaled up and rotated to face the viewer head-on, so the poster fills the
  /// centre of the screen. When [_pickAnim] eases back to ~0 the box snaps home
  /// to its shelf slot.
  void _updatePickedBox() {
    final box = _pickedUp ?? _lastPicked;
    if (box == null) return;

    if (_pickAnim < 0.01 && _pickedUp == null) {
      // Fully returned — restore the exact resting transform and forget it.
      // (Includes the face rotation: boxes on a gondola's back run rest at
      // yaw pi, and restoring a bare translation would flip them inside out.)
      box.node.localTransform = box.restTransform;
      box.held = false;
      _lastPicked = null;
      return;
    }

    // In-hand target: ~0.9 m in front of the camera along its view direction,
    // at eye height, enlarged, with its poster (+X face) turned to the camera.
    final fwd = _forward(_yaw);
    // Hold a turned-over case further out: at the cover-art distance the
    // printed sleeve overflows the frame and you lose the top and bottom of
    // the text, which is the whole point of turning it over.
    final handPos = _camPos + fwd * (0.95 + 0.30 * _flipAnim);
    handPos.y = _camPos.y; // hold it level at eye height

    final t = Curves.easeOutCubic.transform(_pickAnim.clamp(0.0, 1.0));
    final pos = _lerp3(box.position, handPos, t);
    final scale = 1.0 + 1.6 * t; // grow to ~2.6x in hand

    // Yaw the box so its +X poster face points back at the camera, turning
    // from its resting facing (0 on a front run, pi on a back run) along the
    // shortest arc.
    //
    // vector_math's rotationY maps +X to (cos, 0, -sin), so pointing the face
    // normal along -fwd needs atan2(fwd.z, -fwd.x). The previous code used
    // atan2(-fwd.z, -fwd.x) — the reflected angle — and cancelled the
    // resulting flip with a rotationX(pi) roll. That pair leaves a net
    // MIRROR: box art came to hand with its title text reversed.
    final targetYaw = math.atan2(fwd.z, -fwd.x);
    var dYaw = targetYaw - box.faceYaw;
    while (dYaw > math.pi) {
      dYaw -= 2 * math.pi;
    }
    while (dYaw < -math.pi) {
      dYaw += 2 * math.pi;
    }
    // Turning the box over adds another half-turn, so the -X side (where the
    // printed sleeve panel lives) comes round to face the camera.
    final yaw = box.faceYaw + dYaw * t + math.pi * _flipAnim;

    final held =
        vm.Matrix4.translation(pos) * vm.Matrix4.rotationY(yaw) * vm.Matrix4.diagonal3(vm.Vector3(scale, scale, scale));
    box.node.localTransform = held;

    // Ride the sleeve on the case's -X face, in the case's own frame.
    final panel = box.backPanel;
    if (panel != null) {
      panel.localTransform = held * vm.Matrix4.translation(vm.Vector3(-(VideoStoreScene.boxDepth / 2) - 0.002, 0, 0));
    }
  }

  vm.Vector3 _lerp3(vm.Vector3 a, vm.Vector3 b, double t) => a + (b - a) * t;

  /// Horizontal forward vector for a heading. yaw 0 = +X, pi/2 = +Z.
  vm.Vector3 _forward(double yaw) => vm.Vector3(math.cos(yaw), 0, math.sin(yaw));

  /// One walking stride along the current heading (negative = backstep).
  /// Holding the key repeats the stride, so it reads as continuous walking.
  void _walk(double dist) {
    final store = _store;
    if (store == null) return;
    final next = _wantPos + _forward(_wantYaw) * dist;
    _wantPos = _clampToFloor(store, next);
    _updateFocused();
  }

  /// Turns the heading by [d] radians (positive = screen-LEFT; see _onKey).
  void _turn(double d) {
    _wantYaw += d;
    _updateFocused();
  }

  /// Keeps the camera on the sales floor and out of the shelf fixtures, so
  /// you can roam the whole store but never clip through a wall of boxes.
  vm.Vector3 _clampToFloor(VideoStoreScene store, vm.Vector3 p) {
    final aisles = math.max(1, store.aisleCount);
    final run = store.runLength;
    // Stay inside the room shell, half a metre clear of every wall — the old
    // bounds let the camera walk off the edge of the floor slab into the void.
    // 1.35 m, not the old 0.6: signage and framed art stand proud of the wall
    // face, and at 0.6 the camera ended up nose-against a sign with a single
    // letter filling the screen. A shopper reads a wall from arm's length +.
    const pad = 1.35;
    final minX = store.roomMinX + pad;
    final maxX = math.max(minX, store.roomMaxX - pad);
    var x = p.x.clamp(minX, maxX).toDouble();
    final minZ = store.roomMinZ + pad;
    final maxZ = math.max(minZ, store.roomMaxZ - pad);
    final z = p.z.clamp(minZ, maxZ).toDouble();
    // Shelf-fixture collision: each aisle's wall run is solid — push the
    // camera out to the wall's +X face instead of letting it walk through.
    // To reach the next aisle you walk around the end of the run, exactly
    // like a real store.
    if (z > -0.4 && z < run + 0.9) {
      for (var a = 0; a < aisles; a++) {
        final wx = store.shelfWallX(a);
        // The gondola is stocked on both faces now, so push the camera out to
        // whichever side it approached from rather than always to +X (which
        // would teleport a shopper in the previous corridor through the run).
        final d = x - wx;
        if (d.abs() < 0.5) x = d >= 0 ? wx + 0.5 : wx - 0.5;
      }
    }
    return vm.Vector3(x, VideoStoreScene.eyeHeight, z);
  }

  /// Finds the box the camera is close to AND facing — the pick-up target.
  /// Highlights it on the shelf and drives the marquee title card.
  void _updateFocused() {
    final store = _store;
    if (store == null) return;
    // In browse mode the SELECTION owns the focus — proximity must not
    // re-target it as the camera eases toward the chosen box.
    if (_browsing) return;
    final fwd = _forward(_wantYaw);

    // Are we standing at a sponsor panel and looking at it? Same
    // proximity-plus-facing rule the shelves use, with a longer reach since a
    // wall panel is read from further back than a box is picked off a shelf.
    _atAdPanel = false;
    for (final ad in store.adPanels) {
      final to = vm.Vector3(ad.x - _wantPos.x, 0, ad.z - _wantPos.z);
      final d = to.length;
      if (d > 4.5 || d < 1e-3) continue;
      to.scale(1 / d);
      if (to.dot(fwd) < 0.72) continue; // must be facing it fairly squarely
      _atAdPanel = true;
      break;
    }
    StoreBox? best;
    var bestD = 2.9; // reach: must be within ~3 m
    for (final b in store.boxes) {
      final to = vm.Vector3(b.position.x - _wantPos.x, 0, b.position.z - _wantPos.z);
      final d = to.length;
      if (d > bestD || d < 1e-3) continue;
      // Must be standing on the side the box's poster faces — otherwise you
      // could reach a back-run box through the solid gondola.
      final outward = math.cos(b.faceYaw);
      if ((_wantPos.x - b.position.x) * outward <= 0) continue;
      to.scale(1 / d);
      if (to.dot(fwd) < 0.55) continue; // ~57° cone — must be facing it
      // Prefer a box that has real cover art over a nearer one that is still
      // a blank placeholder tint. Otherwise walking up to a shelf mid-load
      // focuses — and hands you — a featureless coloured slab.
      if (best != null && !b.hasArtwork && best.hasArtwork) continue;
      if (best != null && b.hasArtwork && !best.hasArtwork) {
        best = b;
        bestD = d;
        continue;
      }
      best = b;
      bestD = d;
    }
    _focused = best;
    store.setFocus(best);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // BACK follows the app-wide convention (key_event_utils): swallow the
    // key-down, act on the key-up. The store used to act on key-down and let
    // the key-up bubble to main_screen, so ONE press both shelved the tape /
    // left the bay AND threw focus to the side rail (measured on the ONN).
    // On the open floor, return focus to the sidebar on the same key-up.
    if (event.logicalKey.isBackKey) {
      return handleBackKeyAction(event, () {
        if (_pickedUp != null) {
          _putBack();
        } else if (_browsing) {
          setState(_exitBrowse);
        } else {
          MainScreenFocusScope.focusSidebarOf(context);
        }
      });
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final store = _store;
    if (_launching) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (store == null) return KeyEventResult.ignored;

    final isOk =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA;

    if (isOk && event is KeyDownEvent) {
      if (_data.totalTitles == 0) {
        unawaited(context.read<LibrariesProvider>().refresh());
        return KeyEventResult.handled;
      }
      // Staged: OK on a shelf ENTERS that bay (shelf -> tier -> title), OK on
      // a selected title lifts it, OK on a held tape plays it.
      if (_pickedUp != null) {
        _play();
      } else if (_browsing) {
        if (_browseTarget != null) _pickUp();
      } else if (_focused != null) {
        setState(() => _enterBrowse(_focused!));
      } else if (_atAdPanel) {
        // Standing at the sponsor panel with no shelf in reach: OK opens the
        // store's Plex Support page. Checked AFTER _focused so it can never
        // steal a press meant for a shelf.
        unawaited(_openPlexSupport());
      }
      return KeyEventResult.handled;
    }
    if (isOk) return KeyEventResult.handled;

    // First-person controls: UP/DOWN walk the heading, LEFT/RIGHT turn it.
    // Key repeat (holding the D-pad) strides/turns continuously. While a box
    // is held, moving shelves it first (you don't wander with a tape floating
    // in front of your face).
    final bool held = _pickedUp != null;

    // Holding a tape: UP/DOWN turn the case over to read the printed back,
    // exactly like turning a box over in the shop. Walking is suppressed
    // anyway while a tape is in hand, so these keys are free.
    if (held) {
      if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) {
        setState(() => _showBack = !_showBack);
        return KeyEventResult.handled;
      }
    }

    // In a bay the D-pad selects rather than walks: UP/DOWN change SHELF TIER
    // (top/middle/bottom), LEFT/RIGHT run along that tier.
    if (_browsing && !held) {
      // Holding LEFT/RIGHT accelerates: the rack becomes a conveyor, so a
      // 2,000-title section is seconds away end to end, not minutes.
      final stride = event is KeyRepeatEvent ? math.min(1 + (_repeatRun ~/ 3), 5) : 1;
      if (event is KeyRepeatEvent) {
        _repeatRun = math.min(_repeatRun + 1, 30);
      } else {
        _repeatRun = 0;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() => _moveBrowse(dRow: 1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(() => _moveBrowse(dRow: -1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        // At the very START of the section, LEFT escapes to the nav rail like
        // every other tab (the "Store LEFT trap" fix). Anywhere else it
        // scrolls the rack back.
        if (_browseIndex < (_browseFace?.rows ?? 1)) {
          MainScreenFocusScope.focusSidebarOf(context);
          return KeyEventResult.handled;
        }
        setState(() => _moveBrowse(dCol: -stride));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        setState(() => _moveBrowse(dCol: stride));
        return KeyEventResult.handled;
      }
      // Transport / page / channel keys jump a whole letter of the alphabet.
      if (key == LogicalKeyboardKey.mediaFastForward ||
          key == LogicalKeyboardKey.mediaTrackNext ||
          key == LogicalKeyboardKey.pageDown ||
          key == LogicalKeyboardKey.channelDown ||
          key == LogicalKeyboardKey.gameButtonRight1) {
        setState(() => _jumpLetter(1));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaRewind ||
          key == LogicalKeyboardKey.mediaTrackPrevious ||
          key == LogicalKeyboardKey.pageUp ||
          key == LogicalKeyboardKey.channelUp ||
          key == LogicalKeyboardKey.gameButtonLeft1) {
        setState(() => _jumpLetter(-1));
        return KeyEventResult.handled;
      }
    }

    // Holding a direction should GLIDE, not stutter. A repeat event means the
    // key is down, so each successive repeat takes a bigger bite — walking a
    // long row used to be a dozen separate taps.
    final bool repeating = event is KeyRepeatEvent;
    if (repeating) {
      _repeatRun = math.min(_repeatRun + 1, 12);
    } else {
      _repeatRun = 0;
    }
    // 1.0x on a tap up to ~2.2x once you've held it for a moment.
    final double boost = 1.0 + _repeatRun * 0.10;

    if (key == LogicalKeyboardKey.arrowUp) {
      if (held) _putBack();
      setState(() => _walk(0.62 * boost));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (held) _putBack();
      setState(() => _walk(-0.62 * boost));
      return KeyEventResult.handled;
    }
    // The engine is LEFT-handed (camera.dart: right = up x forward), so with
    // forward = (cos yaw, 0, sin yaw) screen-right is DECREASING yaw. The old
    // signs turned the view the opposite way to the arrow pressed.
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (held) _putBack();
      setState(() => _turn(0.30 * boost));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (held) _putBack();
      setState(() => _turn(-0.30 * boost));
      return KeyEventResult.handled;
    }
    // Quick about-face, so turning around in an aisle is ONE press instead of
    // ten. Page keys don't exist on a TV remote, so this also takes the
    // rewind/next transport keys and the gamepad shoulder buttons — whatever
    // the box actually has.
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.mediaRewind ||
        key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.gameButtonLeft1 ||
        key == LogicalKeyboardKey.gameButtonRight1) {
      if (held) _putBack();
      setState(() => _turn(math.pi));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Enters browse mode on the rack face holding [seed], selecting it.
  void _enterBrowse(StoreBox seed) {
    if (seed.titleIndex < 0) return;
    _browseFace = seed.face;
    _browseIndex = seed.titleIndex;
    _browsing = true;
    _aimAtBrowseTarget();
  }

  /// Leaves browse mode and hands control back to free-walk.
  void _exitBrowse() {
    _browsing = false;
    _browseFace = null;
    _updateFocused();
  }

  /// The case currently showing the selected title, once the rack has slid
  /// far enough for it to be bound (null for a frame or two mid-slide).
  StoreBox? get _browseTarget {
    final face = _browseFace;
    if (!_browsing || face == null) return null;
    for (final b in face.slots) {
      if (b.active && b.titleIndex == _browseIndex) return b;
    }
    return null;
  }

  StoreTitle? get _browseTitle {
    final face = _browseFace;
    if (face == null) return null;
    final ts = face.titles;
    if (_browseIndex < 0 || _browseIndex >= ts.length) return null;
    return ts[_browseIndex];
  }

  /// Keeps focus pinned to the selected title's case while the rack slides.
  void _syncBrowseFocus() {
    final box = _browseTarget;
    if (!identical(box, _focused)) {
      _focused = box;
      _store?.setFocus(box);
    }
  }

  /// Stands the camera a comfortable distance off the selected case, facing
  /// the rack. While the rack SCROLLS the selection's column stays put, so
  /// the camera holds still and the tapes slide past it.
  void _aimAtBrowseTarget() {
    final store = _store;
    final face = _browseFace;
    if (store == null || face == null) return;
    // Stand square to the MIDDLE of the run, far enough back that the whole
    // rack is in frame: the selection moves across it and the tapes slide
    // under it. Chasing the selection put empty room in half the frame
    // whenever it neared an end of the run (measured on-device).
    _wantPos = vm.Vector3(face.boxX + face.outward * 2.35, VideoStoreScene.eyeHeight, face.centerZ);
    // Look back INTO the rack.
    _wantYaw = face.outward > 0 ? math.pi : 0.0;
    _syncBrowseFocus();
  }

  /// Steps the selection through the WHOLE section. [dRow] moves tier
  /// (up/down within a column), [dCol] moves whole columns along the rack;
  /// reaching within a column of either end of the run scrolls the rack.
  void _moveBrowse({int dRow = 0, int dCol = 0}) {
    final face = _browseFace;
    if (!_browsing || face == null) return;
    final n = face.titles.length;
    if (n == 0) return;
    _browseIndex = browseStep(index: _browseIndex, count: n, rows: face.rows, dRow: dRow, dCol: dCol);
    // Keep one column of context either side: the rack scrolls when the
    // selection gets within a column of the end of the run.
    face.scrollTarget = scrollFirstFor(
      col: _browseIndex ~/ face.rows,
      first: face.scrollTarget.round(),
      cols: face.cols,
      maxFirst: face.maxScroll,
    ).toDouble();
    _wantClock = 0; // re-prioritise posters for the new window NOW
    _aimAtBrowseTarget();
  }

  /// Jumps to the first title of the next/previous shelf letter.
  void _jumpLetter(int dir) {
    final face = _browseFace;
    final t = _browseTitle;
    if (face == null || t == null) return;
    final letters = _lettersOf(face);
    final li = letters.indexOf(t.shelfLetter) + dir;
    if (li < 0 || li >= letters.length) return;
    final idx = face.section.indexOfLetter(letters[li]);
    if (idx < 0) return;
    _browseIndex = idx;
    // Put the new letter's first column near the LEFT of the run, so the
    // whole run shows that letter.
    face.revealIndex(idx, atCol: 1);
    _wantClock = 0;
    _aimAtBrowseTarget();
  }

  /// The shelf letters present in [face]'s section, in order. Cached per
  /// (face, section size): the HUD asks every frame, and rescanning a
  /// 2,000-title section at 30 fps is real work on a Mali-G31 box.
  List<String> _lettersOf(RackFace face) {
    final n = face.titles.length;
    if (identical(face, _lettersFace) && n == _lettersCount) return _letters;
    final out = <String>[];
    for (final t in face.titles) {
      final l = t.shelfLetter;
      if (out.isEmpty || out.last != l) out.add(l);
    }
    _lettersFace = face;
    _lettersCount = n;
    _letters = out;
    return out;
  }

  RackFace? _lettersFace;
  int _lettersCount = -1;
  List<String> _letters = const [];

  /// The browsing title card: the title, where it sits in the whole
  /// section ("412 of 1,380"), a scroll bar for the rack, and the A–Z strip
  /// with the current shelf letter lit — the rack scrolls, so the card has
  /// to say how much more there is and how to get there fast.
  Widget _browseCard(StoreTitle title, Color accent) {
    final face = _browseFace;
    final n = face?.titles.length ?? 0;
    final letters = face == null ? const <String>[] : _lettersOf(face);
    final here = title.shelfLetter;
    final frac = n <= 1 ? 0.0 : _browseIndex / (n - 1);
    final more = _data.stillLoading ? '+' : '';

    String fmt(int v) {
      final s = v.toString();
      final b = StringBuffer();
      for (var i = 0; i < s.length; i++) {
        if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
        b.write(s[i]);
      }
      return b.toString();
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 1000),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.65), width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title.title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            '${title.year != null ? '${title.year}   •   ' : ''}'
            '${fmt(_browseIndex + 1)} of ${fmt(n)}$more'
            '   •   OK to take it down',
            style: TextStyle(color: accent, fontSize: 15),
          ),
          const SizedBox(height: 8),
          // Where this tape sits in the whole section.
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 5,
              width: 640,
              child: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Colors.white12)),
                  FractionallySizedBox(
                    widthFactor: frac.clamp(0.02, 1.0),
                    child: ColoredBox(color: accent),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // A–Z: letters that exist in this section, the current one lit.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 5,
            children: [
              for (final l in letters)
                Text(
                  l,
                  style: TextStyle(
                    color: l == here ? accent : Colors.white38,
                    fontSize: l == here ? 18 : 13,
                    fontWeight: l == here ? FontWeight.w900 : FontWeight.w500,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Opens the LuxuriousComputers Plex Support page in whatever browser the
  /// device has.
  ///
  /// Many Android TV boxes ship with NO browser at all, so a failed launch is
  /// the normal case, not an edge case — falling back to a dialog that shows
  /// the URL means the panel is still useful (you can type it on a phone)
  /// instead of a dead button that appears broken.
  Future<void> _openPlexSupport() async {
    final uri = Uri.parse(_plexSupportUrl);
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    final accent = _halloween ? const Color(0xFFFF6A00) : const Color(0xFFFFC400);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF12131A),
        title: const Text(
          'Plex Support',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This device has no browser. Visit the Plex Fix Clinic at:',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SelectableText(
              _plexSupportUrl,
              style: TextStyle(color: accent, fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('CLOSE', style: TextStyle(color: accent)),
          ),
        ],
      ),
    );
  }

  /// Lifts the faced box off the shelf into the viewer's "hand", and prints
  /// this title's sleeve onto the back of the case.
  void _pickUp() {
    final box = _focused;
    if (box == null) return;
    box.held = true;
    setState(() {
      _pickedUp = box;
      _lastPicked = box;
    });
    unawaited(_printBoxBack(box));
    unawaited(_loadHandArt(box));
  }

  /// The shelf poster is sized for arm's length; blown up 2.6x in hand it
  /// goes soft, so fetch a sharp copy for as long as the tape is held.
  Future<void> _loadHandArt(StoreBox box) async {
    final title = box.title;
    if (title == null) return;
    final tex = await _data.loadHiResPoster(context, title);
    if (!mounted || tex == null || _pickedUp != box || box.title != title) {
      return;
    }
    box.handTexture = tex;
    box.face.refresh(box);
  }

  /// Bakes the back-of-the-box artwork for [box] and attaches it. Baked per
  /// pick-up rather than per title so only ONE sleeve is ever resident.
  Future<void> _printBoxBack(StoreBox box) async {
    final store = _store;
    final textures = store?.textures;
    if (store == null || textures == null) return;
    final t = box.title;
    if (t == null) return;
    // Pull full metadata first: the library list query omits cast headshot
    // paths, so without this the sleeve can only draw silhouettes.
    await _data.hydrateDetails(context, t);
    if (!mounted || _pickedUp != box) return;
    // The fact strip, in the order a detail page reads: score, certificate,
    // runtime, year, studio. Resolution/audio-codec are NOT on MediaItem (they
    // live in the media parts), so they are genuinely absent rather than faked.
    final facts = <String>[
      if (t.ratingPercent != null) '${t.ratingPercent}%',
      if (t.contentRating?.isNotEmpty ?? false) t.contentRating!,
      if (t.runtime != null) t.runtime!,
      if (t.year != null) '${t.year}',
      if (t.studio?.isNotEmpty ?? false) t.studio!,
    ];

    // Hero art + up to 4 cast headshots. Fetched per pick-up and disposed with
    // the sleeve, so no library-wide image cache accumulates on a 1.9GiB box.
    if (!mounted) return;
    // Kick the backdrop off but don't await it yet — it resolves alongside the
    // headshots below rather than in series before them.
    final backdropFuture = _data.loadArtImage(context, t, t.backdropPath, maxWidth: 512, maxHeight: 288);
    // Headshots come from the per-item detail fetched above. A server that
    // still has no photo for an actor draws a silhouette plate.
    // In PARALLEL: four serial headshot round-trips on top of the detail fetch
    // and the backdrop made the sleeve take long enough that turning the box
    // over beat it to the punch.
    final heads = await Future.wait([
      for (final role in t.castRoles.take(4))
        _data.loadArtImage(context, t, role.thumbPath, maxWidth: 128, maxHeight: 160, imageType: ImageType.square),
    ]);
    final backdrop = await backdropFuture;

    final tex = await textures.boxBack(
      backdrop: backdrop,
      castHeads: heads,
      title: t.title,
      synopsis: t.summary ?? t.tagline ?? '',
      cast: t.cast,
      directors: t.directors,
      genres: t.genres,
      facts: facts,
      halloween: _halloween,
    );
    // The source images are baked INTO the sleeve texture, so free them now —
    // otherwise every pick-up leaks a backdrop plus four headshots.
    backdrop?.dispose();
    for (final h in heads) {
      h?.dispose();
    }
    if (!mounted || tex == null) return;
    // The player may already have shelved it while the bake ran.
    if (_pickedUp != box) return;
    store.attachBoxBack(box, tex);
  }

  /// Returns a held box to its shelf slot; the tick eases [_pickAnim] home and
  /// restores the resting transform.
  void _putBack() {
    final box = _pickedUp;
    if (box == null) return;
    // Free the printed sleeve with the tape — only the case in hand carries
    // one, so it must not survive shelving.
    _store?.detachBoxBack(box);
    box.handTexture = null;
    box.face.refresh(box);
    setState(() {
      _pickedUp = null;
      _showBack = false;
    });
  }

  Future<void> _play() async {
    // Play whatever's in hand (or faced, if OK was pressed straight through).
    final box = _pickedUp ?? _focused;
    if (box == null) return;
    setState(() => _launching = true);
    try {
      final t = box.title;
      if (t == null) return;
      await navigateToMediaItemDetails(context, t.item, isOffline: false);
    } finally {
      if (mounted) setState(() => _launching = false);
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _data.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initFailed) {
      // Hard fallback — Flutter GPU unavailable. Flat 2D shelf still plays.
      final transferFocus = _focusNode.hasFocus;
      if (transferFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fallbackKey.currentState?.focusActiveTabIfReady();
        });
      }
      return VideoStore2DFallback(key: _fallbackKey, halloween: _halloween);
    }

    final store = _store;
    final ready = _sceneReady && store != null;

    return Focus(
      focusNode: _focusNode,
      // No autofocus: main_screen focuses the active tab programmatically via
      // focusActiveTabIfReady(). Autofocusing here stole focus back after
      // every rebuild and fought the rail.
      onKeyEvent: _onKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready) _buildSceneSurface(store) else _buildLoading(),
          if (ready) _buildMarquee(store),
          if (ready && _data.totalTitles == 0)
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(16)),
                child: const Text(
                  'No movies loaded.\nConnect your Plex or Jellyfin server.\nPress OK to retry.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 20),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The flutter_scene 3D pass. On full-power devices we render it at native
  /// resolution (Size.infinite → the CustomPaint canvas is the whole screen).
  ///
  /// On reduced-quality (low-RAM / low-end) devices — e.g. a 1.9 GB Mali-G31
  /// Android TV box — a native-resolution offscreen RenderTarget cannot be
  /// allocated (Impeller reports ErrorOutOfDeviceMemory and the scene renders
  /// black). We keep real-time 3D instead of dropping to the 2D shelf by
  /// rendering the scene into a HALF-resolution CustomPaint and upscaling it
  /// with Transform.scale. Half the linear size = ~quarter the RenderTarget /
  /// MSAA / depth memory, which fits on these GPUs. The camera is unchanged, so
  /// only the raster resolution drops; the aisle, walk, and posters are intact.
  Widget _buildSceneSurface(VideoStoreScene store) {
    // Scene.render() sizes the draw area from canvas.getLocalClipBounds(),
    // which is UNBOUNDED (~1e9) under a Size.infinite CustomPaint — that made
    // flutter_scene request a billion-pixel texture (rejected, black frame).
    // LayoutBuilder hands us the real finite pixel box; we pass it as both the
    // paint size and an explicit render() viewport so every pass target is a
    // sane size.
    return LayoutBuilder(
      builder: (context, constraints) {
        var w = constraints.maxWidth;
        var h = constraints.maxHeight;
        if (!w.isFinite || w <= 0) w = 1280;
        if (!h.isFinite || h <= 0) h = 720;
        // On reduced-quality (low-RAM / low-end) devices — e.g. the 1.9 GB
        // Mali-G31 Android TV box — a native-resolution offscreen
        // RenderTarget can't be allocated (Impeller: ErrorOutOfDeviceMemory,
        // scene renders black). render() sizes every render-pass target as
        // (drawArea * pixelRatio); with no override it uses the view's
        // devicePixelRatio (full physical res) and each pass' R8G8B8A8 color
        // + depth allocation fails on the ~450 MB free UMA. Passing an
        // explicit small pixelRatio is the only lever that actually shrinks
        // those allocations (a Transform.scale wrapper does not — render()
        // re-multiplies by the platform view's dpr). 0.5 = quarter the target
        // memory; Flutter upscales the smaller texture to fill the surface.
        // Camera/aisle/walk/posters are unchanged — only raster res drops.
        final ratio = _reducedQuality ? 0.5 : null;
        return CustomPaint(painter: _StorePainter(store.scene, _camera, ratio, Size(w, h)), size: Size(w, h));
      },
    );
  }

  Widget _buildLoading() {
    return ColoredBox(
      color: _halloween ? const Color(0xFF05070A) : const Color(0xFF120E0A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _halloween ? 'Opening the crypt…' : 'Opening the store…',
              style: const TextStyle(color: Colors.white70, fontSize: 18),
            ),
          ],
        ),
      ),
    );
  }

  /// The overlaid store marquee + the focused title's name/year, so the user
  /// always sees what the OK button will play.
  Widget _buildMarquee(VideoStoreScene store) {
    final box = _pickedUp ?? _focused;
    final title = (_browsing && _pickedUp == null ? _browseTitle : null) ?? box?.title;
    final accent = _halloween ? const Color(0xFFFF6A00) : const Color(0xFFFFC400);
    final held = _pickedUp != null;
    // Section name from the box's source library (the "aisle").
    String? section;
    if (_browsing && !_showBack && _browseFace != null) {
      // From the RACK, not the case: mid-slide the selected case can be
      // unbound for a frame and the banner would blink.
      section = _browseFace!.section.signLabel;
    } else if (box != null &&
        !_showBack && // reading the sleeve: keep the frame clear of chrome
        box.aisleIndex >= 0 &&
        box.aisleIndex < _data.aisles.length) {
      section = _data.aisles[box.aisleIndex].signLabel;
    }
    // The prompt has to name the CURRENT stage or the staged controls are
    // undiscoverable on a remote with no labels.
    final String prompt;
    if (held) {
      prompt = _showBack
          ? '▲ ▼ turn it back  •  OK to play  •  BACK to shelve'
          : '▲ ▼ read the back  •  OK to play  •  BACK to shelve';
    } else if (_browsing) {
      prompt = 'press OK to take it down  •  BACK to step away';
    } else {
      prompt = 'press OK to browse this shelf';
    }
    final walkHint = _browsing
        ? '◀ ▶ scroll the rack (hold to fly)  •  ⏪ ⏩ jump a letter  •  BACK to step away'
        : _atAdPanel
        ? 'PLEX SUPPORT  •  press OK to open the Plex Fix Clinic'
        : 'HOLD ▲ to stride  •  ◀ ▶ turn  •  ⏮ about-face  •  OK at a rack';
    final bbBlue = _halloween ? const Color(0xFF3A0F4A) : const Color(0xFF0E39A0);
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.videocam_rounded, color: accent, size: 30),
                const SizedBox(width: 10),
                Text(
                  _halloween ? 'BLOCKBUSTA' : 'BEAM VIDEO',
                  style: TextStyle(
                    color: accent,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                    shadows: const [Shadow(blurRadius: 12, color: Colors.black)],
                  ),
                ),
              ],
            ),
            if (section != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                  decoration: BoxDecoration(
                    color: bbBlue,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: accent, width: 3),
                    boxShadow: const [BoxShadow(blurRadius: 16, color: Colors.black54)],
                  ),
                  child: Text(
                    section.toUpperCase(),
                    style: TextStyle(color: accent, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 4),
                  ),
                ),
              ),
            ],
            const Spacer(),
            // Holding a tape = you turned the box over: show the real back-of-
            // the-box copy rather than just a name, which is the whole point
            // of picking one up.
            // The rental card is the fallback for a tape whose sleeve hasn't
            // been printed yet. Once the case is turned over the info is ON
            // the box, so the card would just cover it.
            if (title != null && held && _showBack)
              // Turned over: the synopsis, cast and specs are PRINTED on the
              // sleeve, so the only overlay is a thin control hint. Anything
              // larger covers the very thing the player turned over to read.
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    prompt,
                    style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              )
            else if (title != null && held)
              Align(alignment: Alignment.bottomCenter, child: _rentalCard(title, accent, bbBlue, prompt))
            // Browsing a bay: show where you are in the row and that there is
            // MORE in each direction. Without this the shelf gives no hint
            // that left/right runs further or that other tiers exist.
            else if (title != null && _browsing)
              Align(alignment: Alignment.bottomCenter, child: _browseCard(title, accent))
            else if (title != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(12),
                    border: held ? Border.all(color: accent, width: 2) : null,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title.year != null ? '${title.year}   $prompt' : prompt,
                        style: TextStyle(
                          color: held ? accent : Colors.white70,
                          fontSize: 15,
                          fontWeight: held ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: _atAdPanel ? 0.78 : 0.45),
                    borderRadius: BorderRadius.circular(10),
                    // At a sponsor panel this is a real call to action, so give
                    // it the brand pink border rather than leaving it as
                    // ambient help text you'd scan past.
                    border: _atAdPanel ? Border.all(color: const Color(0xFFFF2D95), width: 2) : null,
                  ),
                  child: Text(
                    walkHint,
                    style: TextStyle(
                      color: _atAdPanel ? const Color(0xFFFF6E9F) : Colors.white70,
                      fontSize: _atAdPanel ? 17 : 15,
                      fontWeight: _atAdPanel ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The back of the box, styled as a rental card: title, the metadata strip a
/// video-store sticker carried (rating / year / runtime / studio), and the
/// synopsis. Every field on a MediaItem is optional, so this degrades to
/// whatever the server actually returned instead of showing empty rows.
Widget _rentalCard(StoreTitle title, Color accent, Color panel, String prompt) {
  final facts = <String>[
    if (title.contentRating != null && title.contentRating!.isNotEmpty) title.contentRating!,
    if (title.year != null) '${title.year}',
    if (title.runtime != null) title.runtime!,
    if (title.studio != null && title.studio!.isNotEmpty) title.studio!,
  ];
  final blurb = (title.tagline?.isNotEmpty ?? false) ? title.tagline! : (title.summary ?? '');

  return Container(
    // Wide enough to read from a couch, capped so it never spans a 4K screen.
    constraints: const BoxConstraints(maxWidth: 900),
    padding: const EdgeInsets.fromLTRB(26, 20, 26, 18),
    decoration: BoxDecoration(
      color: const Color(0xF00B0A10),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: accent, width: 3),
      boxShadow: const [BoxShadow(blurRadius: 24, color: Colors.black87)],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                title.title,
                style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900, height: 1.05),
              ),
            ),
            const SizedBox(width: 14),
            // Faux rental stamp, the sticker every ex-rental tape wore.
            Transform.rotate(
              angle: -0.06,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: accent, width: 2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'RENTAL',
                  style: TextStyle(color: accent, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 3),
                ),
              ),
            ),
          ],
        ),
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final f in facts)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    f,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ],
        if (blurb.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            blurb,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 18, height: 1.35),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          prompt,
          style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

/// Repaints the flutter_scene [scene] from [camera] every frame. Marked always
/// repaint because the parent drives a per-tick [setState].
class _StorePainter extends CustomPainter {
  _StorePainter(this.scene, this.camera, this.pixelRatio, this.viewportSize);

  final fscene.Scene scene;
  final fscene.PerspectiveCamera camera;

  /// Explicit render-target density override. `null` = use the view's
  /// devicePixelRatio (full res). A small value (e.g. 0.5) shrinks every
  /// render-pass target so weak GPUs can allocate them. See
  /// [_VideoStoreScreenState._buildSceneSurface].
  final double? pixelRatio;

  /// Finite logical draw area. Passed as an explicit render() viewport so
  /// flutter_scene never falls back to the unbounded canvas clip bounds
  /// (which produced a billion-pixel texture request → black frame).
  final Size viewportSize;

  /// CPU time spent inside scene.render (graph walk + command encoding),
  /// accumulated for the stats line. GPU time is NOT included: if fps is
  /// low while this is small, the GPU (fill rate) is the wall.
  static int renderUs = 0;
  static int renderCount = 0;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    _paintScene(canvas);
    renderUs += sw.elapsedMicroseconds;
    renderCount++;
  }

  void _paintScene(Canvas canvas) {
    scene.render(camera, canvas, viewport: Offset.zero & viewportSize, pixelRatio: pixelRatio);
  }

  @override
  // ALWAYS repaint. The scene is animated independently of this widget's
  // fields — shoppers walk and the held box eases every tick — so comparing
  // only pixelRatio/viewportSize froze the store the moment the camera came
  // to rest: shoppers stopped mid-stride until you moved again. The parent
  // drives a setState per tick, so this is once per frame either way.
  bool shouldRepaint(covariant _StorePainter old) => true;
}
