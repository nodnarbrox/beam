import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'video_store_data.dart';

/// Which world direction is SCREEN-RIGHT for a camera looking along a
/// horizontal [forward]. MEASURED, not derived: in the on-device spawn frame
/// (camera looking +Z) the aisle-0 fixture at -X and the sponsor panel left of
/// centre both render on the LEFT, so screen-right is +X when looking +Z. That
/// is the mirror of a textbook right-handed lookAt, which is why this is a
/// named helper instead of an inline cross product.
vm.Vector3 screenRightOf(vm.Vector3 forward) =>
    vm.Vector3(forward.z, 0, -forward.x);

/// Where the browse selection lands after one D-pad step through a section of
/// [count] titles filed in columns of [rows] (top-down, then the next column).
///
/// [dRow] +1 = UP a tier (earlier in the column), -1 = DOWN. [dCol] moves whole
/// columns. Past the start it clamps to the first column; past the end it
/// lands on the last column at the nearest tier that column actually has
/// (the final column is usually short).
int browseStep({
  required int index,
  required int count,
  required int rows,
  int dRow = 0,
  int dCol = 0,
}) {
  if (count <= 0) return 0;
  var idx = index.clamp(0, count - 1);
  if (dRow != 0) {
    final next = idx % rows - dRow;
    if (next >= 0 && next < rows && idx - dRow < count && idx - dRow >= 0) {
      idx -= dRow;
    }
  }
  if (dCol != 0) {
    final target = idx + dCol * rows;
    if (target < 0) {
      idx = idx % rows;
    } else if (target >= count) {
      final lastCol = (count - 1) ~/ rows;
      idx = math.min(lastCol * rows + idx % rows, count - 1);
    } else {
      idx = target;
    }
  }
  return idx;
}

/// The first visible column that keeps [col] on screen with one column of
/// context either side of it (the rack scrolls when the selection gets within
/// a column of the end of the run), clamped to [0, maxFirst].
int scrollFirstFor({
  required int col,
  required int first,
  required int cols,
  required int maxFirst,
}) {
  var f = first;
  if (col < f + 1) {
    f = col - 1;
  } else if (col > f + cols - 2) {
    f = col - (cols - 2);
  }
  return f.clamp(0, math.max(0, maxFirst));
}

/// Which section title pool slot ([slotColumn], [row]) shows at scroll
/// position [scroll], and where along the run it sits. `position` is the
/// screen-order column (0 = leftmost visible; fractional while sliding);
/// `index` is -1 when the slot is outside the run or past the section's end.
({int index, double position}) slotBinding({
  required double scroll,
  required int slotColumn,
  required int row,
  required int rows,
  required int cols,
  required int count,
}) {
  final base = scroll.floor();
  final p = slotColumn - (scroll - base);
  final idx = (base + slotColumn) * rows + (rows - 1 - row);
  final inRun = p > -0.5 && p < cols - 0.5;
  return (index: inRun && idx >= 0 && idx < count ? idx : -1, position: p);
}

/// A VHS rental case: a box whose FRONT (+X) face carries the whole poster
/// and whose spines/top/bottom sample thin strips from the poster's matching
/// edges, so the art reads as a printed sleeve WRAPPED round the case.
///
/// A plain [CuboidGeometry] maps the full 0..1 image onto all six faces, which
/// squashes the entire poster onto each spine — the single loudest "these are
/// textured boxes" tell on a shelf seen at an angle.
///
/// The front face copies CuboidGeometry's +X corner order and UVs exactly
/// (u along +Z, v up +Y), so the existing V-flip correction on the poster
/// pipeline applies unchanged.
MeshGeometry vhsCaseGeometry(vm.Vector3 extents) {
  final ex = extents.x / 2, ey = extents.y / 2, ez = extents.z / 2;
  const wrap = 0.035; // fraction of the poster that wraps onto a spine
  final corners = <vm.Vector3>[
    vm.Vector3(-ex, -ey, -ez),
    vm.Vector3(ex, -ey, -ez),
    vm.Vector3(ex, ey, -ez),
    vm.Vector3(-ex, ey, -ez),
    vm.Vector3(-ex, -ey, ez),
    vm.Vector3(ex, -ey, ez),
    vm.Vector3(ex, ey, ez),
    vm.Vector3(-ex, ey, ez),
  ];
  // Same winding + normals as flutter_scene's buildCuboidArrays.
  const faces = <(List<int>, List<double>)>[
    ([0, 1, 2, 3], [0, 0, -1]), // -Z spine
    ([1, 5, 6, 2], [1, 0, 0]), //  +X front (poster)
    ([5, 4, 7, 6], [0, 0, 1]), //  +Z spine
    ([4, 0, 3, 7], [-1, 0, 0]), // -X back (sleeve panel covers it in hand)
    ([3, 2, 6, 7], [0, 1, 0]), //  +Y top
    ([4, 5, 1, 0], [0, -1, 0]), // -Y bottom
  ];
  double uz(double z) => (z + ez) / (2 * ez);
  double vy(double y) => (y + ey) / (2 * ey);
  // 0 at the front face, 1 at the back face.
  double back(double x) => (ex - x) / (2 * ex);

  final positions = Float32List(24 * 3);
  final normals = Float32List(24 * 3);
  final uvs = Float32List(24 * 2);
  final indices = <int>[];
  for (var f = 0; f < faces.length; f++) {
    final (ids, n) = faces[f];
    final base = f * 4;
    for (var i = 0; i < 4; i++) {
      final v = base + i;
      final c = corners[ids[i]];
      positions[v * 3] = c.x;
      positions[v * 3 + 1] = c.y;
      positions[v * 3 + 2] = c.z;
      normals[v * 3] = n[0];
      normals[v * 3 + 1] = n[1];
      normals[v * 3 + 2] = n[2];
      double u, vv;
      switch (f) {
        case 0: // -Z spine: continues from the front's u=0 edge
          u = wrap * back(c.x);
          vv = vy(c.y);
        case 2: // +Z spine: continues from the front's u=1 edge
          u = 1 - wrap * back(c.x);
          vv = vy(c.y);
        case 4: // top: continues from the poster's top edge (v=1)
          u = uz(c.z);
          vv = 1 - wrap * back(c.x);
        case 5: // bottom: continues from the poster's bottom edge (v=0)
          u = uz(c.z);
          vv = wrap * back(c.x);
        default: // front and back: the whole poster
          u = uz(c.z);
          vv = vy(c.y);
      }
      uvs[v * 2] = u;
      uvs[v * 2 + 1] = vv;
    }
    indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
  }
  return MeshGeometry.fromArrays(
    positions: positions,
    normals: normals,
    texCoords: uvs,
    indices: indices,
  );
}

/// A single case on a rack. It is a SLOT, not a title: as the rack scrolls
/// the same node is re-bound to whichever title now occupies its place.
class StoreBox {
  StoreBox({
    required this.node,
    required this.material,
    required this.face,
    required this.rowIndex,
    required this.slotColumn,
  });

  final Node node;
  final PhysicallyBasedMaterial material;
  final RackFace face;

  /// Shelf tier, 0 = bottom.
  final int rowIndex;

  /// Which physical column of the rack's node pool this slot is (0..cols).
  final int slotColumn;

  /// The title currently shelved in this slot (null = empty slot, hidden).
  StoreTitle? title;

  /// Index of [title] within the face's section.
  int titleIndex = -1;

  /// World position of the case at rest (moves as the rack scrolls).
  vm.Vector3 position = vm.Vector3.zero();

  /// True while this slot's title is on screen (inside the run).
  bool active = false;

  /// While the player holds this case, the rack leaves its transform alone.
  bool held = false;

  /// The texture currently sampled by [material] (null = spine tint).
  gpu.Texture? boundTexture;

  /// A one-off hi-res poster swapped in while the case is in hand.
  gpu.Texture? handTexture;

  bool focused = false;

  /// The printed sleeve on the BACK of this case. A cuboid mesh has one
  /// material for all six faces, so the box back is its own thin panel node,
  /// created only for the tape currently in hand and torn down with it.
  Node? backPanel;
  PhysicallyBasedMaterial? backMaterial;
  gpu.Texture? backTexture;

  // --- compatibility with the free-walk / browse code ---
  int get aisleIndex => face.sectionIndex;
  int get faceIndex => face.side;
  double get faceYaw => face.yaw;
  bool get hasArtwork => boundTexture != null || handTexture != null;

  /// The transform this box returns to when it is not in hand.
  vm.Matrix4 get restTransform =>
      vm.Matrix4.translation(position) * vm.Matrix4.rotationY(faceYaw);
}

/// One face of a gondola, shelving an ENTIRE section as a scrolling rack.
///
/// Titles are filed A–Z in reading order: down each column top-to-bottom,
/// then the next column to the SCREEN-RIGHT. The face owns a fixed pool of
/// `rows x (cols + 1)` case nodes; [scroll] (in columns, animated) decides
/// which slice of the section they show. The extra column is the case that
/// slides in from one end while another slides out of the other, squeezed as
/// it crosses the end of the run so nothing pops.
class RackFace {
  RackFace({
    required this.scene,
    required this.section,
    required this.sectionIndex,
    required this.fixtureIndex,
    required this.side,
    required this.boxX,
    required this.rows,
    required this.cols,
    required this.baseY,
    required this.gapY,
    required this.spacing,
    required this.boxExtents,
    required this.geometry,
    required this.restEmissive,
    required this.tintFor,
  }) {
    final wr = screenRightOf(vm.Vector3(-outward, 0, 0));
    _screenRightZ = wr.z >= 0 ? 1.0 : -1.0;
    // Every case hangs off ONE parent: a face that can't be seen is skipped
    // with a single visibility flag instead of 40 per-node bound tests (the
    // flat ~800-node root cost 45-75 ms/frame of render CPU on the ONN).
    group = Node(name: 'rack_${sectionIndex}_$side');
    scene.add(group);
    for (var k = 0; k <= cols; k++) {
      for (var r = 0; r < rows; r++) {
        final mat = PhysicallyBasedMaterial()
          ..roughnessFactor = 0.38 // glossy clamshell plastic
          ..metallicFactor = 0.0;
        final node = Node(
          name: 'case_${sectionIndex}_${k}_$r',
          mesh: Mesh(geometry, mat),
        );
        node.visible = false;
        group.add(node);
        slots.add(StoreBox(
          node: node,
          material: mat,
          face: this,
          rowIndex: r,
          slotColumn: k,
        ));
      }
    }
    _layout(force: true);
  }

  final Scene scene;
  final StoreAisle section;

  /// Index of [section] within [VideoStoreData.aisles].
  final int sectionIndex;
  final int fixtureIndex;

  /// 0 = the +X face of the gondola, 1 = the -X face.
  final int side;

  /// X of the case centres on this face.
  final double boxX;
  final int rows;

  /// Visible columns along the run.
  final int cols;
  final double baseY, gapY, spacing;
  final vm.Vector3 boxExtents;
  final MeshGeometry geometry;

  /// Resting emissive for a case wearing real art (theme-dependent).
  final vm.Vector4 restEmissive;

  /// Placeholder spine tint for a title whose poster isn't resident.
  final vm.Vector4 Function(String key) tintFor;

  final List<StoreBox> slots = [];

  /// Parent of every case node on this face (identity transform, so the
  /// cases' transforms stay world-space).
  late final Node group;

  /// Hides the whole face when the camera can't see it: standing on the
  /// gondola's other side (the cases are behind the fixture panel) or too
  /// far away to read. A held case is never hidden with its face.
  void cull(vm.Vector3 cam, {double maxDistance = 15.0}) {
    final show = slots.any((b) => b.held) ||
        (facesToward(cam) && distanceTo(cam) < maxDistance);
    if (group.visible != show) group.visible = show;
  }

  /// Z sign of screen-right for a camera facing this rack.
  late final double _screenRightZ;

  double get yaw => side == 0 ? 0.0 : math.pi;

  /// +1 when the posters face +X, -1 when they face -X.
  double get outward => side == 0 ? 1.0 : -1.0;

  List<StoreTitle> get titles => section.titles;

  int get columnCount => (titles.length + rows - 1) ~/ rows;

  /// Furthest the rack can scroll (first visible column).
  int get maxScroll => math.max(0, columnCount - cols);

  /// Current (animated) and target first-visible column.
  double scroll = 0;
  double scrollTarget = 0;

  /// True while the rack is still sliding toward [scrollTarget].
  bool get sliding => (scrollTarget - scroll).abs() > 0.002;

  double get runLength => (cols + 1) * spacing;
  double get centerZ => runLength / 2;

  /// Z along the run for a case at screen-order position [p] (0 = leftmost
  /// visible column, may be fractional while sliding).
  double zForPosition(double p) => _screenRightZ > 0
      ? (p + 1) * spacing
      : (cols - p) * spacing;

  /// The world position of visible column [col], tier [row] at rest.
  vm.Vector3 slotPosition(double col, int row) =>
      vm.Vector3(boxX, baseY + row * gapY, zForPosition(col));

  /// Section index of the title shown at visible column [col], tier [row].
  int titleIndexAt(int col, int row) =>
      (scrollTarget.round() + col) * rows + (rows - 1 - row);

  /// Scrolls so that section title [index] is visible, putting its column at
  /// visible position [atCol] when possible. Returns the visible column the
  /// title ends up in.
  int revealIndex(int index, {int atCol = 0}) {
    final col = index ~/ rows;
    final first = (col - atCol).clamp(0, maxScroll);
    scrollTarget = first.toDouble();
    return col - first;
  }

  /// Nudges the target by [dCols] columns (clamped). Returns how far it
  /// actually moved.
  int scrollBy(int dCols) {
    final before = scrollTarget.round();
    final after = (before + dCols).clamp(0, maxScroll);
    scrollTarget = after.toDouble();
    return after - before;
  }

  int _lastTitleCount = -1;
  double _laidOutScroll = double.nan;

  /// Advances the scroll animation and re-binds slots. Cheap when idle: only
  /// identity checks run unless the rack is moving or its section grew.
  void update(double dt) {
    if (sliding) {
      // Critically damped-ish glide; fast enough that a held key reads as a
      // conveyor rather than a slideshow.
      final k = (dt * 12.0).clamp(0.0, 1.0);
      scroll += (scrollTarget - scroll) * k;
      if ((scrollTarget - scroll).abs() < 0.002) scroll = scrollTarget;
    }
    _layout(force: titles.length != _lastTitleCount);
    _bindTextures();
  }

  void _layout({bool force = false}) {
    if (!force && scroll == _laidOutScroll) return;
    _laidOutScroll = scroll;
    _lastTitleCount = titles.length;
    for (final b in slots) {
      // Slot column k shows logical column floor(scroll)+k at position
      // k-frac: the case leaving one end re-enters at the other.
      final bind = slotBinding(
        scroll: scroll,
        slotColumn: b.slotColumn,
        row: b.rowIndex,
        rows: rows,
        cols: cols,
        count: titles.length,
      );
      final p = bind.position;
      final idx = bind.index;
      b.active = idx >= 0;
      if (!b.active) {
        b.node.visible = false;
        b.title = null;
        b.titleIndex = -1;
        continue;
      }
      final t = titles[idx];
      if (!identical(b.title, t)) {
        b.title = t;
        b.titleIndex = idx;
        b.boundTexture = null;
        _applyMaterial(b, force: true);
      }
      b.position = slotPosition(p, b.rowIndex);
      if (b.held) continue;
      b.node.visible = true;
      // Squeeze the case into the end of the run as it crosses it, like a
      // tape sliding behind the end panel, instead of popping in or out.
      final squeeze = (math.min(p + 0.5, cols - 0.5 - p) * 2).clamp(0.05, 1.0);
      b.node.localTransform = vm.Matrix4.translation(b.position) *
          vm.Matrix4.rotationY(yaw) *
          vm.Matrix4.diagonal3Values(1, 1, squeeze);
    }
  }

  void _bindTextures() {
    for (final b in slots) {
      if (!b.active) continue;
      final want = b.title?.texture;
      if (!identical(want, b.boundTexture)) {
        b.boundTexture = want;
        _applyMaterial(b);
      }
    }
  }

  /// Emissive for a case that is the current focus. Kept NEUTRAL: a tinted
  /// highlight is added on top of the art and the held tape came to hand
  /// washed magenta when this was purple (measured).
  static final vm.Vector4 _focusLift = vm.Vector4(0.16, 0.16, 0.16, 1.0);

  void _applyMaterial(StoreBox b, {bool force = false}) {
    final m = b.material;
    final tex = b.handTexture ?? b.boundTexture;
    if (tex != null) {
      m
        ..baseColorTexture = tex
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..emissiveFactor = b.focused ? _focusLift : restEmissive;
    } else {
      final tint = tintFor(b.title?.key ?? '');
      m
        ..baseColorTexture = null
        ..baseColorFactor = tint
        ..emissiveFactor = b.focused
            ? vm.Vector4(0.22, 0.20, 0.18, 1.0)
            : vm.Vector4(tint.x * 0.10, tint.y * 0.10, tint.z * 0.10, 1.0);
    }
  }

  /// Re-applies [b]'s material after its focus/hand state changed.
  void refresh(StoreBox b) => _applyMaterial(b);

  /// Visible slots, grouped by tier (index = row) and ordered left→right on
  /// screen. Used by browse mode.
  List<List<StoreBox>> visibleTiers() {
    final tiers = List.generate(rows, (_) => <StoreBox>[]);
    for (final b in slots) {
      if (!b.active) continue;
      tiers[b.rowIndex].add(b);
    }
    for (final t in tiers) {
      t.sort((a, b) => a.titleIndex.compareTo(b.titleIndex));
    }
    return tiers;
  }

  /// Titles this face wants resident: what it shows now, plus [margin]
  /// columns either side so a scroll lands on art rather than tints.
  Iterable<StoreTitle> wantedTitles({int margin = 1}) sync* {
    final first = math.max(0, scrollTarget.round() - margin);
    final last = math.min(columnCount - 1, scrollTarget.round() + cols - 1 + margin);
    // Visible columns first, then the margins, so a tight budget keeps what
    // is on screen.
    final visFirst = scrollTarget.round();
    final visLast = math.min(columnCount - 1, visFirst + cols - 1);
    for (var c = visFirst; c <= visLast; c++) {
      for (var r = 0; r < rows; r++) {
        final i = c * rows + r;
        if (i < titles.length) yield titles[i];
      }
    }
    for (var c = first; c <= last; c++) {
      if (c >= visFirst && c <= visLast) continue;
      for (var r = 0; r < rows; r++) {
        final i = c * rows + r;
        if (i < titles.length) yield titles[i];
      }
    }
  }

  /// Distance from [p] to the middle of this face, on the XZ plane.
  double distanceTo(vm.Vector3 p) {
    final dx = p.x - boxX, dz = p.z - centerZ;
    return math.sqrt(dx * dx + dz * dz);
  }

  /// Whether [p] is standing on the side this face's posters look at.
  bool facesToward(vm.Vector3 p) => (p.x - boxX) * outward > 0;
}
