import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'video_store_3d.dart';

/// How a ceiling tube behaves. A dead store's lighting is never uniform: most
/// tubes limp along dim, some are gone, a few strobe, and one always buzzes.
enum _TubeMood { steady, dead, strobe, buzz }

class _Tube {
  _Tube(this.material, this.mood, this.seed);
  final PhysicallyBasedMaterial material;
  final _TubeMood mood;
  final double seed;

  /// Current brightness 0..1 (drives emissive and the room light level).
  double level = 1;
  double _burst = 0; // strobe: seconds left in the current stutter
  double _next = 0; // strobe: seconds until the next stutter
}

/// A drifting sheet of floor fog.
class _Fog {
  _Fog(this.node, this.base, this.size, this.phase);
  final Node node;
  final vm.Vector3 base;
  final double size;
  final double phase;
}

class _Bat {
  _Bat(this.node, this.anchor, this.phase);
  final Node node;
  final vm.Vector3 anchor;
  final double phase;
}

/// The Halloween layer: the video store closed down years ago, and tonight
/// something is still working the late shift.
///
/// Everything here is ADDED on top of the normal store build, and the whole
/// layer is cosmetic — if a texture bake or a Blender prop fails to load, that
/// piece is simply absent, never an error. Budget: roughly 120 nodes on the
/// full tier, about half on reduced quality (the ONN has held ~550 total).
///
/// Lighting in flutter_scene 0.16 is one directional light plus per-material
/// emissive (no point lights), so every "light" in the dead store is an
/// emissive surface whose level is animated, and the directional key is
/// modulated by the tubes' average brightness so the whole room dims when a
/// tube dies — which is what sells a flicker as LIGHT rather than as a sticker
/// changing colour.
class HauntedStore {
  HauntedStore(this.store);

  final VideoStoreScene store;
  Scene get scene => store.scene;

  final math.Random _rnd = math.Random(1031); // deterministic for screenshots
  final List<_Tube> _tubes = [];
  final List<_Fog> _fog = [];
  final List<_Bat> _bats = [];
  final List<PhysicallyBasedMaterial> _windowMats = [];
  final List<PhysicallyBasedMaterial> _beamMats = [];
  final List<PhysicallyBasedMaterial> _glowMats = []; // pumpkins, candles
  double _clock = 0;

  // Lightning: seconds until the next strike, and time into the current one.
  double _nextStrike = 7.0;
  double _strike = -1;

  late final double _baseKey;
  late final vm.Vector3 _baseKeyColor;

  bool get _lite => store.reducedQuality;

  /// Checkout desk centre (mirrors VideoStoreScene._buildCheckout).
  double get _cx => store.roomMaxX - 2.2;
  double get _cz => store.roomMinZ + 2.6;

  void build() {
    final light = scene.directionalLight;
    // Cold moonlight key instead of the old sickly green: the room is lit by
    // what comes through the boards and by the tubes that still work.
    // 1.4, not 2.6: at 2.6 the whole store read flat mid-grey on the ONN —
    // lit, not dead. The tubes, lanterns and candles are the light sources.
    if (light != null) {
      light.color = vm.Vector3(0.62, 0.70, 0.95);
      light.intensity = 1.4;
    }
    _baseKey = light?.intensity ?? 1.4;
    _baseKeyColor = light?.color.clone() ?? vm.Vector3(0.62, 0.70, 0.95);

    _buildTubes();
    _buildCeilingDamage();
    _buildWindows();
    _buildDoors();
    _buildSigns();
    _buildFog();
    _buildDebris();
    unawaited(_loadProps());
  }

  // --- tubes ---------------------------------------------------------------

  void _buildTubes() {
    final housingColor = vm.Vector4(0.10, 0.10, 0.11, 1.0);
    final xs = <double>[
      // Left corridor (aisle 0's back face), every corridor, and the open
      // floor by the checkout.
      store.shelfWallX(0) - store.aisleWidth / 2,
      for (var a = 0; a < store.aisleCount; a++) store.aisleCenterX(a),
      store.roomMaxX - 1.4,
    ];
    final z0 = store.roomMinZ + 1.4, z1 = store.roomMaxZ - 1.4;
    final step = _lite ? 3.0 : 2.4;
    final y = store.ceilingY - 0.06;
    var i = 0;
    for (final x in xs) {
      for (var z = z0; z <= z1; z += step) {
        // 2x4 troffer: dark housing, lens panel inset below it.
        scene.add(store.prop('tube_housing_$i', housingColor,
            vm.Vector3(0.64, 0.05, 1.26), vm.Vector3(x, y, z),
            emissive: vm.Vector4(0.01, 0.01, 0.01, 1.0), roughness: 0.5));
        final roll = _rnd.nextDouble();
        final mood = roll < 0.52
            ? _TubeMood.steady
            : roll < 0.70
                ? _TubeMood.strobe
                : roll < 0.86
                    ? _TubeMood.dead
                    : _TubeMood.buzz;
        final mat = PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.85, 0.92, 0.88, 1.0)
          ..roughnessFactor = 0.4
          ..metallicFactor = 0.0;
        scene.add(Node(
          name: 'tube_lens_$i',
          mesh: Mesh(CuboidGeometry(vm.Vector3(0.52, 0.02, 1.14)), mat),
          localTransform: vm.Matrix4.translation(vm.Vector3(x, y - 0.035, z)),
        ));
        _tubes.add(_Tube(mat, mood, _rnd.nextDouble() * 100)
          ..level = mood == _TubeMood.dead ? 0 : 1
          .._next = 1 + _rnd.nextDouble() * 5);
        i++;
      }
    }
    _applyTubes();
  }

  void _stepTubes(double dt) {
    for (final t in _tubes) {
      switch (t.mood) {
        case _TubeMood.steady:
          // A tired ballast: slow, shallow breathing.
          t.level = 0.78 + 0.08 * math.sin(_clock * 1.3 + t.seed);
        case _TubeMood.dead:
          t.level = 0.0;
        case _TubeMood.buzz:
          // 60 Hz hum made visible: fast, shallow shimmer.
          t.level = 0.62 + 0.18 * math.sin(_clock * 37 + t.seed).abs();
        case _TubeMood.strobe:
          if (t._burst > 0) {
            t._burst -= dt;
            // Hard on/off stutter inside the burst.
            t.level = math.sin(_clock * 55 + t.seed) > 0.1 ? 1.0 : 0.04;
            if (t._burst <= 0) t._next = 1.5 + _rnd.nextDouble() * 6.0;
          } else {
            t._next -= dt;
            t.level = 0.05; // mostly out
            if (t._next <= 0) t._burst = 0.25 + _rnd.nextDouble() * 1.1;
          }
      }
    }
    _applyTubes();
  }

  void _applyTubes() {
    for (final t in _tubes) {
      final l = t.level;
      // Cold, slightly green fluorescent. Emissive is ADDED to the lit base,
      // so this reads as the tube's own glow.
      t.material.emissiveFactor =
          vm.Vector4(0.55 * l, 0.72 * l, 0.62 * l, 1.0);
      t.material.baseColorFactor = l < 0.1
          ? vm.Vector4(0.25, 0.26, 0.27, 1.0) // a dead tube is grey glass
          : vm.Vector4(0.85, 0.92, 0.88, 1.0);
    }
  }

  double get _tubeAverage {
    if (_tubes.isEmpty) return 1;
    var s = 0.0;
    for (final t in _tubes) {
      s += t.level;
    }
    return s / _tubes.length;
  }

  // --- ceiling ---------------------------------------------------------------

  void _buildCeilingDamage() {
    final y = store.ceilingY - 0.035;
    final holeMat = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.0, 0.0, 0.0, 1.0)
      ..emissiveFactor = vm.Vector4(0, 0, 0, 1)
      ..roughnessFactor = 1.0
      ..metallicFactor = 0.0;
    final tileMat = store.surface(vm.Vector4(0.23, 0.22, 0.20, 1.0),
        tex: store.textures?.ceilingStained, roughness: 0.95);
    final n = _lite ? 4 : 7;
    for (var i = 0; i < n; i++) {
      final x = store.roomMinX + 1.5 + _rnd.nextDouble() * (store.roomMaxX - store.roomMinX - 3);
      final z = store.roomMinZ + 1.5 + _rnd.nextDouble() * (store.roomMaxZ - store.roomMinZ - 3);
      // The void where a tile used to be.
      scene.add(Node(
        name: 'ceiling_hole_$i',
        mesh: Mesh(CuboidGeometry(vm.Vector3(0.6, 0.012, 1.2)), holeMat),
        localTransform: vm.Matrix4.translation(vm.Vector3(x, y, z)),
      ));
      // Every other hole still has its tile, hanging by one edge.
      if (i.isEven) {
        final hinge = vm.Vector3(x, y, z - 0.6);
        scene.add(Node(
          name: 'ceiling_dangle_$i',
          mesh: Mesh(CuboidGeometry(vm.Vector3(0.6, 0.02, 1.2)), tileMat),
          localTransform: vm.Matrix4.translation(hinge) *
              vm.Matrix4.rotationX(0.85 + _rnd.nextDouble() * 0.4) *
              vm.Matrix4.translation(vm.Vector3(0, 0, 0.6)),
        ));
      }
    }
  }

  // --- windows + moonlight ---------------------------------------------------

  void _buildWindows() {
    final tex = store.textures?.boardedWindow;
    if (tex == null) return;
    final x = store.roomMaxX - 0.1;
    for (final z in [store.roomMaxZ - 1.5, store.roomMinZ + 1.1]) {
      final mat = PhysicallyBasedMaterial()
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        // The moonlit gaps are the only bright texels, so an emissive MAP of
        // the same image makes exactly the slivers glow.
        ..emissiveTexture = tex
        ..emissiveFactor = vm.Vector4(0.22, 0.24, 0.30, 1.0)
        ..roughnessFactor = 0.8
        ..metallicFactor = 0.0;
      _windowMats.add(mat);
      scene.add(Node(
        name: 'window_$z',
        mesh: Mesh(CuboidGeometry(vm.Vector3(0.06, 1.7, 2.0)), mat),
        localTransform: vm.Matrix4.translation(vm.Vector3(x, 1.55, z)),
      ));
      // Fake god-rays: two faint translucent blades slanting in and down
      // from the window. Cheap (two quads) and they catch the fog.
      for (var k = 0; k < 2; k++) {
        final beam = PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.70, 0.80, 1.0, 0.07)
          ..emissiveFactor = vm.Vector4(0.10, 0.12, 0.16, 1.0)
          ..roughnessFactor = 1.0
          ..metallicFactor = 0.0
          ..alphaMode = AlphaMode.blend;
        _beamMats.add(beam);
        scene.add(Node(
          name: 'moonbeam_${z}_$k',
          mesh: Mesh(CuboidGeometry(vm.Vector3(2.6, 0.9, 0.02)), beam),
          localTransform: vm.Matrix4.translation(
                  vm.Vector3(x - 1.2, 1.15, z - 0.45 + k * 0.9)) *
              vm.Matrix4.rotationZ(-0.55),
        ));
      }
    }
  }

  // --- doors -----------------------------------------------------------------

  void _buildDoors() {
    final dx = store.roomMaxX - 1.6; // under the EXIT sign
    final z = store.roomMinZ + 0.13;
    final glass = PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(0.05, 0.07, 0.10, 0.72)
      ..emissiveFactor = vm.Vector4(0.03, 0.04, 0.07, 1.0)
      ..roughnessFactor = 0.1
      ..metallicFactor = 0.0
      ..alphaMode = AlphaMode.blend;
    final frame = vm.Vector4(0.12, 0.12, 0.13, 1.0);
    for (final side in [-1.0, 1.0]) {
      final x = dx + side * 0.47;
      scene.add(store.prop('door_frame_$side', frame,
          vm.Vector3(0.94, 2.2, 0.05), vm.Vector3(x, 1.1, z - 0.02),
          roughness: 0.4));
      scene.add(Node(
        name: 'door_glass_$side',
        mesh: Mesh(CuboidGeometry(vm.Vector3(0.78, 1.9, 0.02)), glass),
        localTransform: vm.Matrix4.translation(vm.Vector3(x, 1.12, z + 0.02)),
      ));
      // Push bar.
      scene.add(store.prop('door_bar_$side', vm.Vector4(0.55, 0.56, 0.58, 1.0),
          vm.Vector3(0.7, 0.05, 0.06), vm.Vector3(x, 1.02, z + 0.07),
          roughness: 0.3));
    }
    // Chain looped through the push bars: alternating links.
    for (var i = 0; i < 9; i++) {
      final t = i / 8.0;
      final x = dx - 0.42 + t * 0.84;
      final sag = math.sin(t * math.pi) * 0.12;
      scene.add(store.prop(
        'chain_$i',
        vm.Vector4(0.30, 0.30, 0.32, 1.0),
        i.isEven ? vm.Vector3(0.10, 0.035, 0.012) : vm.Vector3(0.10, 0.012, 0.035),
        vm.Vector3(x, 1.02 - sag, z + 0.11),
        roughness: 0.35,
      ));
    }
    // Padlock.
    scene.add(store.prop('padlock', vm.Vector4(0.55, 0.45, 0.16, 1.0),
        vm.Vector3(0.07, 0.09, 0.03), vm.Vector3(dx, 0.86, z + 0.12),
        roughness: 0.3));

    final notice = store.textures?.signClosedDoor;
    if (notice != null) {
      scene.add(_texturedPanel('closed_notice', notice,
          vm.Vector3(0.34, 0.42, 0.012), vm.Vector3(dx + 0.47, 1.50, z + 0.045),
          emissive: 0.05));
    }
    final tape = store.textures?.cautionTape;
    if (tape != null) {
      for (final a in [0.62, -0.62]) {
        scene.add(Node(
          name: 'caution_door_$a',
          mesh: Mesh(CuboidGeometry(vm.Vector3(2.3, 0.11, 0.01)),
              _panelMaterial(tape, emissive: 0.06)),
          localTransform:
              vm.Matrix4.translation(vm.Vector3(dx, 1.2, z + 0.16)) *
                  vm.Matrix4.rotationZ(a),
        ));
      }
    }
  }

  // --- signs -----------------------------------------------------------------

  void _buildSigns() {
    final tx = store.textures;
    if (tx == null) return;
    // LATE FEES ARE FOREVER, high on the left wall facing the floor.
    final lateFees = tx.signLateFees;
    if (lateFees != null) {
      scene.add(_texturedPanel(
        'sign_late_fees',
        lateFees,
        vm.Vector3(0.05, 1.0, 2.0),
        vm.Vector3(store.roomMinX + 0.14, store.ceilingY - 1.05,
            (store.roomMinZ + store.roomMaxZ) / 2),
        emissive: 0.06,
      ));
    }
    // BE KIND, PLEASE REWIND over the return bin — one chain snapped, so it
    // swings from a single rod at a drunken angle.
    final rewind = tx.signRewind;
    if (rewind != null) {
      final at = vm.Vector3(_cx - 1.5, store.ceilingY - 1.05, _cz + 2.4);
      scene.add(Node(
        name: 'sign_rewind',
        mesh: Mesh(CuboidGeometry(vm.Vector3(0.05, 0.6, 1.2)),
            _panelMaterial(rewind, emissive: 0.05)),
        localTransform: vm.Matrix4.translation(at) * vm.Matrix4.rotationX(0.38),
      ));
      scene.add(store.prop('sign_rewind_rod', vm.Vector4(0.1, 0.1, 0.11, 1.0),
          vm.Vector3(0.03, store.ceilingY - at.y - 0.2, 0.03),
          vm.Vector3(at.x, (at.y + 0.2 + store.ceilingY) / 2, at.z + 0.55),
          roughness: 0.5));
    }
  }

  // --- fog + debris -----------------------------------------------------------

  void _buildFog() {
    final tex = store.textures?.fogPuff;
    if (tex == null) return;
    final n = _lite ? 7 : 14;
    for (var i = 0; i < n; i++) {
      final size = 2.4 + _rnd.nextDouble() * 2.2;
      final mat = PhysicallyBasedMaterial()
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 0.9)
        ..emissiveFactor = vm.Vector4(0.05, 0.06, 0.08, 1.0)
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0
        ..alphaMode = AlphaMode.blend;
      final base = vm.Vector3(
        store.roomMinX + 1 + _rnd.nextDouble() * (store.roomMaxX - store.roomMinX - 2),
        0.10 + _rnd.nextDouble() * 0.22,
        store.roomMinZ + 1 + _rnd.nextDouble() * (store.roomMaxZ - store.roomMinZ - 2),
      );
      final node = Node(
        name: 'fog_$i',
        mesh: Mesh(PlaneGeometry(width: size, depth: size), mat),
      );
      scene.add(node);
      _fog.add(_Fog(node, base, size, _rnd.nextDouble() * 6.28));
    }
  }

  void _buildDebris() {
    final tex = store.textures?.floorDebris;
    if (tex == null) return;
    final mat = PhysicallyBasedMaterial()
      ..baseColorTexture = tex
      ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
      ..emissiveFactor = vm.Vector4(0.03, 0.03, 0.03, 1.0)
      ..roughnessFactor = 1.0
      ..metallicFactor = 0.0
      ..alphaMode = AlphaMode.mask
      ..alphaCutoff = 0.4;
    final n = _lite ? 4 : 8;
    for (var i = 0; i < n; i++) {
      final x = store.roomMinX + 1 + _rnd.nextDouble() * (store.roomMaxX - store.roomMinX - 2);
      final z = store.roomMinZ + 1 + _rnd.nextDouble() * (store.roomMaxZ - store.roomMinZ - 2);
      scene.add(Node(
        name: 'debris_$i',
        mesh: Mesh(PlaneGeometry(width: 1.6, depth: 1.6), mat),
        localTransform: vm.Matrix4.translation(vm.Vector3(x, 0.03, z)) *
            vm.Matrix4.rotationY(_rnd.nextDouble() * 6.28),
      ));
    }
  }

  // --- Blender props ---------------------------------------------------------

  /// Loads the .glb props built in Blender (tools/blender) and stages them
  /// round the store.
  ///
  /// ORIENTATION: the assets are authored facing glTF +Z, but flutter_scene's
  /// runtime importer flips Z on the scene root (glTF is right-handed, the
  /// engine left-handed — see runtime_importer.dart). So an asset's FRONT
  /// faces engine -Z at yaw 0, and rotationY(t) turns it to (-sin t, 0,
  /// -cos t): yaw 0 faces -Z, pi faces +Z, pi/2 faces -X, -pi/2 faces +X. Each asset is loaded ONCE and cloned per placement;
  /// any asset that fails to load is skipped — the store never depends on it.
  Future<void> _loadProps() async {
    Future<Node?> load(String name) async {
      try {
        return await Node.fromGlbAsset('assets/store3d/$name.glb');
      } catch (e) {
        debugPrint('[VideoStore] prop $name unavailable: $e');
        return null;
      }
    }

    final pumpkin = await load('jack_o_lantern');
    final small = await load('pumpkin_small');
    final candles = await load('candles');
    final skeleton = await load('skeleton');
    final stone = await load('tombstone');
    final bat = await load('bat');
    final tape = await load('vhs_tape');
    final cart = await load('shopping_cart');
    final webCorner = await load('cobweb_corner');
    final webSag = await load('cobweb_sag');

    for (final web in [webCorner, webSag]) {
      if (web != null) _softenAlpha(web);
    }

    // Glowing materials (carved faces, flames) flicker like real flame.
    for (final src in [pumpkin, candles]) {
      if (src != null) _collectGlow(src);
    }

    void place(Node? src, String name, vm.Vector3 at,
        {double yaw = 0, double scale = 1, double tiltX = 0, double tiltZ = 0}) {
      if (src == null) return;
      final n = src.clone()..name = name;
      n.localTransform = vm.Matrix4.translation(at) *
          vm.Matrix4.rotationY(yaw) *
          vm.Matrix4.rotationX(tiltX) *
          vm.Matrix4.rotationZ(tiltZ) *
          vm.Matrix4.diagonal3Values(scale, scale, scale);
      scene.add(n);
    }

    final runEnd = store.runLength;
    // Jack-o'-lanterns on every endcap, grinning back up the corridor (the
    // spawn view looks +Z, so they face -Z: yaw 0).
    for (var a = 0; a < store.aisleCount; a++) {
      final ex = store.aisleCenterX(a) - store.aisleWidth / 2 + 0.24;
      place(pumpkin, 'endcap_pumpkin_$a', vm.Vector3(ex, 0.88, runEnd + 0.25),
          yaw: (_rnd.nextDouble() - 0.5) * 0.5);
    }
    // The checkout: the clerk who never clocked out, a lantern and candles.
    // Both face -X, out across the counter to the sales floor.
    place(skeleton, 'clerk', vm.Vector3(_cx + 0.85, 0, _cz - 0.15),
        yaw: math.pi / 2);
    place(pumpkin, 'counter_pumpkin', vm.Vector3(_cx - 0.15, 1.065, _cz + 1.15),
        yaw: math.pi / 2);
    place(candles, 'counter_candles', vm.Vector3(_cx - 0.25, 1.065, _cz - 1.25),
        yaw: 0.4);
    // A pumpkin patch by the dead doors.
    final door = vm.Vector3(store.roomMaxX - 3.3, 0, store.roomMinZ + 1.0);
    for (var i = 0; i < 5; i++) {
      place(small, 'patch_$i',
          door + vm.Vector3(_rnd.nextDouble() * 1.2, 0, _rnd.nextDouble() * 0.9),
          yaw: _rnd.nextDouble() * 6.28, scale: 0.8 + _rnd.nextDouble() * 0.5);
    }
    // Faces +Z, into the store, greeting you as you turn from the doors.
    place(pumpkin, 'patch_lantern', door + vm.Vector3(0.6, 0, 0.3),
        yaw: math.pi + 0.2);
    // A row of headstones down the left wall: the store's own graveyard.
    final zs = [0.18, 0.5, 0.82];
    for (var i = 0; i < zs.length; i++) {
      final z = store.roomMinZ + (store.roomMaxZ - store.roomMinZ) * zs[i];
      place(stone, 'grave_$i', vm.Vector3(store.roomMinX + 0.55, 0, z),
          // Faces +X, out from the left wall into the corridor.
          yaw: -math.pi / 2 + (_rnd.nextDouble() - 0.5) * 0.25,
          tiltZ: (_rnd.nextDouble() - 0.5) * 0.12);
      place(small, 'grave_pumpkin_$i',
          vm.Vector3(store.roomMinX + 0.95, 0, z + 0.45),
          yaw: _rnd.nextDouble() * 6.28);
    }
    // Bats roosting under the ceiling over the corridors.
    if (bat != null) {
      final count = _lite ? 3 : 7;
      for (var i = 0; i < count; i++) {
        final a = i % math.max<int>(1, store.aisleCount);
        final anchor = vm.Vector3(
          store.aisleCenterX(a) + (_rnd.nextDouble() - 0.5) * 1.6,
          store.ceilingY - 0.45 - _rnd.nextDouble() * 0.4,
          0.6 + _rnd.nextDouble() * (runEnd - 0.4),
        );
        final n = bat.clone()..name = 'bat_$i';
        scene.add(n);
        _bats.add(_Bat(n, anchor, _rnd.nextDouble() * 6.28));
      }
    }
    // Tapes nobody rewound, dropped along the fixture bases.
    final tapes = _lite ? 5 : 11;
    for (var i = 0; i < tapes; i++) {
      final a = i % math.max<int>(1, store.aisleCount);
      final x = store.shelfWallX(a) + 0.32 + _rnd.nextDouble() * 0.5;
      final z = 0.3 + _rnd.nextDouble() * (runEnd - 0.3);
      place(tape, 'floor_tape_$i', vm.Vector3(x, 0.0, z),
          yaw: _rnd.nextDouble() * 6.28);
      // Every third drop is a little stack of two.
      if (i % 3 == 0) {
        place(tape, 'floor_tape_${i}_b', vm.Vector3(x + 0.02, 0.026, z + 0.01),
            yaw: _rnd.nextDouble() * 6.28);
      }
    }
    // The cart somebody rode into the new-release wall on the last night.
    place(cart, 'cart', vm.Vector3(store.roomMaxX - 4.2, 0, runEnd * 0.62),
        yaw: 0.7);
    // Webs: every ceiling corner of the room, and sagging between tubes.
    // The corner web hangs from its origin toward +X and -Y (the Z flip
    // doesn't touch X), so each is yawed to send +X along the corner's
    // diagonal INTO the room: rotationY(t) maps +X to (cos t, 0, -sin t).
    final cy = store.ceilingY - 0.02;
    final corners = [
      (store.roomMinX + 0.1, store.roomMinZ + 0.1, -math.pi / 4),
      (store.roomMaxX - 0.1, store.roomMinZ + 0.1, -3 * math.pi / 4),
      (store.roomMinX + 0.1, store.roomMaxZ - 0.1, math.pi / 4),
      (store.roomMaxX - 0.1, store.roomMaxZ - 0.1, 3 * math.pi / 4),
    ];
    for (var i = 0; i < corners.length; i++) {
      final (x, z, yaw) = corners[i];
      place(webCorner, 'web_corner_$i', vm.Vector3(x, cy, z), yaw: yaw, scale: 1.6);
    }
    if (webSag != null) {
      final count = _lite ? 3 : 6;
      for (var i = 0; i < count; i++) {
        final a = i % math.max<int>(1, store.aisleCount);
        place(webSag, 'web_sag_$i',
            vm.Vector3(store.aisleCenterX(a) + 0.5,
                store.ceilingY - 0.05, 1.2 + (i ~/ 2) * 2.4),
            yaw: math.pi / 2, scale: 1.3);
      }
    }
    debugPrint('[VideoStore] haunted props placed: '
        'pumpkin=${pumpkin != null} skeleton=${skeleton != null} '
        'bat=${bat != null} webs=${webCorner != null} tape=${tape != null}');
  }

  /// Alpha-MASK threads alias into scattered sparkle at a distance on this
  /// resolution (measured on the ONN); BLEND lets partial coverage fade.
  void _softenAlpha(Node n) {
    final mesh = n.mesh;
    if (mesh != null) {
      for (final p in mesh.primitives) {
        final m = p.material;
        if (m is PhysicallyBasedMaterial && m.alphaMode == AlphaMode.mask) {
          m.alphaMode = AlphaMode.blend;
        }
      }
    }
    for (final c in n.children) {
      _softenAlpha(c);
    }
  }

  void _collectGlow(Node n) {
    final mesh = n.mesh;
    if (mesh != null) {
      for (final p in mesh.primitives) {
        final m = p.material;
        if (m is PhysicallyBasedMaterial &&
            (m.emissiveFactor.x + m.emissiveFactor.y + m.emissiveFactor.z) > 0.05) {
          _glowMats.add(m);
          _glowBase.add(m.emissiveFactor.clone());
        }
      }
    }
    for (final c in n.children) {
      _collectGlow(c);
    }
  }

  final List<vm.Vector4> _glowBase = [];

  // --- per-frame -------------------------------------------------------------

  void update(double dt, vm.Vector3 cam) {
    _clock += dt;
    _stepTubes(dt);

    // Candle/pumpkin flame: two incommensurate sines + a little noise.
    for (var i = 0; i < _glowMats.length; i++) {
      final b = _glowBase[i];
      final f = 0.78 +
          0.14 * math.sin(_clock * 9.1 + i) +
          0.08 * math.sin(_clock * 23.7 + i * 2.3);
      _glowMats[i].emissiveFactor = vm.Vector4(b.x * f, b.y * f, b.z * f, 1.0);
    }

    // Fog drifts in slow loops and breathes.
    for (final f in _fog) {
      final t = _clock * 0.06 + f.phase;
      f.node.localTransform = vm.Matrix4.translation(vm.Vector3(
            f.base.x + math.sin(t) * 0.9,
            f.base.y,
            f.base.z + math.cos(t * 0.8) * 0.7,
          )) *
          vm.Matrix4.rotationY(t * 0.3);
    }

    // Bats hang and twitch; now and then one shivers its wings.
    for (final b in _bats) {
      final t = _clock + b.phase;
      final flap = math.sin(t * 0.9) > 0.92 ? math.sin(t * 40).abs() : 0.15;
      b.node.localTransform = vm.Matrix4.translation(
              b.anchor + vm.Vector3(0, math.sin(t * 1.3) * 0.03, 0)) *
          vm.Matrix4.rotationY(t * 0.2) *
          vm.Matrix4.rotationX(math.pi) * // roosting upside-down
          vm.Matrix4.diagonal3Values(0.75 + 0.35 * flap, 1, 1);
    }

    // Ghost shoppers fade in and out, each on its own clock.
    for (var i = 0; i < store.ghostMaterials.length; i++) {
      final a = 0.10 + 0.26 * (0.5 + 0.5 * math.sin(_clock * 0.45 + i * 1.7));
      store.ghostMaterials[i].baseColorFactor =
          vm.Vector4(0.62, 0.82, 0.92, a);
    }

    // Brand sign: the neon has a bad transformer.
    final brand = store.brandSignMaterial;
    if (brand != null) {
      final s = math.sin(_clock * 3.1) + math.sin(_clock * 7.7);
      final on = s > -1.2;
      brand.emissiveFactor = on
          ? vm.Vector4(0.10, 0.10, 0.10, 1.0)
          : vm.Vector4(0.0, 0.0, 0.0, 1.0);
      brand.baseColorFactor =
          on ? vm.Vector4(1, 1, 1, 1) : vm.Vector4(0.35, 0.35, 0.38, 1);
    }

    // Lightning through the boards.
    var flash = 0.0;
    if (_strike >= 0) {
      _strike += dt;
      // Double-stroke: bright, gap, brighter, fade.
      final t = _strike;
      flash = t < 0.07
          ? 1.0
          : t < 0.16
              ? 0.1
              : t < 0.24
                  ? 1.3
                  : math.max(0.0, 1.3 - (t - 0.24) * 3.0);
      if (t > 0.8) {
        _strike = -1;
        _nextStrike = 9 + _rnd.nextDouble() * 14;
      }
    } else {
      _nextStrike -= dt;
      if (_nextStrike <= 0) _strike = 0;
    }
    for (final m in _windowMats) {
      final k = 0.22 + flash * 1.1;
      m.emissiveFactor = vm.Vector4(k, k * 1.05, k * 1.3, 1.0);
    }
    for (final m in _beamMats) {
      m.baseColorFactor = vm.Vector4(0.70, 0.80, 1.0, 0.07 + flash * 0.12);
    }

    // The key light follows the tubes (and the storm).
    final light = scene.directionalLight;
    if (light != null) {
      final avg = _tubeAverage;
      light.intensity = _baseKey * (0.55 + 0.55 * avg) + flash * 5.0;
      light.color = flash > 0.05
          ? vm.Vector3(0.80, 0.86, 1.0)
          : _baseKeyColor;
    }
  }

  // --- helpers -----------------------------------------------------------------

  PhysicallyBasedMaterial _panelMaterial(gpu.Texture tex, {double emissive = 0.06}) =>
      PhysicallyBasedMaterial()
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..emissiveFactor = vm.Vector4(emissive, emissive, emissive, 1.0)
        ..roughnessFactor = 0.55
        ..metallicFactor = 0.0;

  Node _texturedPanel(String name, gpu.Texture tex, vm.Vector3 size,
          vm.Vector3 at, {double emissive = 0.06}) =>
      Node(
        name: name,
        mesh: Mesh(CuboidGeometry(size), _panelMaterial(tex, emissive: emissive)),
        localTransform: vm.Matrix4.translation(at),
      );
}
