import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show debugPrint;
import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as scene;

/// Procedurally-baked surface textures for the 3D store.
///
/// flutter_scene 0.16 ships no texture loader and the app has no image assets
/// for a store interior, so every surface would otherwise be a flat solid
/// colour — which is what makes an untextured 3D scene read as plastic toy
/// blocks instead of a room. Here we paint each surface into a `dart:ui`
/// canvas once at startup and upload it as a GPU texture, exactly the way the
/// poster pipeline in `video_store_data.dart` does.
///
/// Tiling is BAKED IN (the pattern is drawn repeatedly across the image)
/// because 0.16 exposes no sampler wrap mode — a cuboid face maps UV 0..1, so
/// one image must already contain all its repeats.
class StoreTextures {
  gpu.Texture? carpet;
  gpu.Texture? ceilingTile;
  gpu.Texture? wallPaint;
  gpu.Texture? shelfPanel;
  gpu.Texture? woodTrim;
  gpu.Texture? counterTop;

  /// Snack-counter dressing: a sheet of assorted candy-bar wrappers, a striped
  /// popcorn tub, and a lit cooler door with bottles behind it.
  gpu.Texture? candySheet;
  gpu.Texture? popcornBox;
  gpu.Texture? coolerFront;

  // Baked signage faces.
  gpu.Texture? signBrand;
  gpu.Texture? signNewReleases;
  gpu.Texture? signCheckout;
  gpu.Texture? signExit;

  /// Backlit LuxuriousComputers.com ad panel hung in-store.
  gpu.Texture? adLuxurious;

  /// One hung section sign per aisle, baked from the real library name so the
  /// store is navigable ("MOVIES" / "TV SHOWS" / whatever the server calls it)
  /// instead of rows of anonymous identical fixtures.
  final Map<String, gpu.Texture?> sectionSigns = {};

  // --- dead-store dressing (Halloween only) ---
  gpu.Texture? grimePanel; // fixture melamine, years of dust and handprints
  gpu.Texture? ceilingStained; // water-stained drop-ceiling tile
  gpu.Texture? bannerClosing; // STORE CLOSING / EVERYTHING MUST GO
  gpu.Texture? signRewind; // BE KIND, PLEASE REWIND
  gpu.Texture? signLateFees; // LATE FEES ARE FOREVER
  gpu.Texture? signClosedDoor; // taped to the front doors
  gpu.Texture? cautionTape;
  gpu.Texture? boardedWindow; // planks with moonlight between them
  gpu.Texture? fogPuff; // soft RGBA sprite for low-lying fog
  gpu.Texture? floorDebris; // scattered receipts, a dropped sleeve

  /// Bakes the printed BACK of a VHS box: synopsis, cast, crew and a spec
  /// block, laid out on the sleeve the way a real rental case was printed.
  /// Deliberately NOT cached — it is baked for one held tape at a time and
  /// disposed with it, so a whole library never sits in GPU memory.
  Future<gpu.Texture?> boxBack({
    required String title,
    required String synopsis,
    required List<String> cast,
    required List<String> directors,
    required List<String> genres,
    required List<String> facts,
    required bool halloween,
    /// Wide background art, bled behind the copy like a detail page's hero.
    ui.Image? backdrop,
    /// Cast headshots, parallel to the first entries of [cast].
    List<ui.Image?> castHeads = const [],
  }) {
    // 2:3 sleeve at readable density. 512x768 keeps text legible when the case
    // is held up to the camera without costing much on a Mali-G31.
    return _bake(512, 768, (canvas, size) {
      final bg = halloween ? const ui.Color(0xFF17111F) : const ui.Color(0xFF14161C);
      final ink = halloween ? const ui.Color(0xFFFF7A18) : const ui.Color(0xFFFAC81A);
      canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = bg);

      // Hero backdrop, cover-fitted across the top two-thirds and faded out
      // downward, the way a detail page bleeds art behind its copy. Drawn dim
      // so the text stays the readable thing on a sleeve held at arm's length.
      if (backdrop != null) {
        final iw = backdrop.width.toDouble(), ih = backdrop.height.toDouble();
        final target = ui.Rect.fromLTWH(0, 0, size.width, size.height * 0.62);
        final scale =
            math.max(target.width / iw, target.height / ih); // cover
        final dw = iw * scale, dh = ih * scale;
        canvas.save();
        canvas.clipRect(target);
        canvas.drawImageRect(
          backdrop,
          ui.Rect.fromLTWH(0, 0, iw, ih),
          ui.Rect.fromLTWH(
            target.center.dx - dw / 2,
            target.center.dy - dh / 2,
            dw,
            dh,
          ),
          ui.Paint(),
        );
        // Fade the art into the sleeve colour so the copy never sits on busy
        // pixels — a vertical gradient from mostly-clear at the top to solid
        // background at the bottom. (At 0x66 white + a 0.35 scrim on top, the
        // art was fetching fine but was too dim to actually see.)
        canvas.drawRect(
          target,
          ui.Paint()
            ..shader = ui.Gradient.linear(
              ui.Offset(0, target.top),
              ui.Offset(0, target.bottom),
              [bg.withValues(alpha: 0.10), bg.withValues(alpha: 0.72), bg],
              [0.0, 0.55, 1.0],
            ),
        );
        canvas.restore();
      }

      // Sleeve border.
      canvas.drawRect(
        ui.Rect.fromLTWH(10, 10, size.width - 20, size.height - 20),
        ui.Paint()
          ..color = ink
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 4,
      );

      double y = 34;
      void para(
        String text, {
        required double fontSize,
        required ui.Color color,
        ui.FontWeight weight = ui.FontWeight.w400,
        int maxLines = 99,
        double gap = 8,
        double letterSpacing = 0,
      }) {
        if (text.isEmpty) return;
        final b = ui.ParagraphBuilder(ui.ParagraphStyle(
          fontSize: fontSize,
          fontWeight: weight,
          textDirection: ui.TextDirection.ltr,
          maxLines: maxLines,
          ellipsis: '…',
        ))
          ..pushStyle(ui.TextStyle(
            color: color,
            letterSpacing: letterSpacing,
            // The top of the sleeve now carries hero art, so every line needs
            // its own drop shadow to stay readable over whatever is behind it.
            shadows: const [
              ui.Shadow(
                color: ui.Color(0xCC000000),
                offset: ui.Offset(0, 2),
                blurRadius: 6,
              ),
            ],
          ));
        b.addText(text);
        final p = b.build()
          ..layout(ui.ParagraphConstraints(width: size.width - 60));
        canvas.drawParagraph(p, ui.Offset(30, y));
        y += p.height + gap;
      }

      para(title.toUpperCase(),
          fontSize: 36, color: ink, weight: ui.FontWeight.w900, maxLines: 3,
          letterSpacing: 1);
      if (genres.isNotEmpty) {
        para(genres.take(3).join('  •  ').toUpperCase(),
            fontSize: 16, color: const ui.Color(0xFFBFC4CE),
            weight: ui.FontWeight.w700, letterSpacing: 2, gap: 14);
      }

      // Hairline under the masthead.
      canvas.drawRect(
        ui.Rect.fromLTWH(30, y, size.width - 60, 2),
        ui.Paint()..color = ink.withValues(alpha: 0.65),
      );
      y += 16;

      para(synopsis,
          fontSize: 21, color: const ui.Color(0xFFE8EAF0), maxLines: 11,
          gap: 18);

      if (cast.isNotEmpty) {
        para('CAST', fontSize: 15, color: ink,
            weight: ui.FontWeight.w900, letterSpacing: 3, gap: 8);
        // Headshot cards in a row, like a detail page's cast strip. Falls back
        // to a silhouette plate when a server has no photo for that actor.
        const cols = 4;
        final cw = (size.width - 60 - (cols - 1) * 10) / cols;
        final ch = cw * 1.18;
        for (var i = 0; i < math.min(cols, cast.length); i++) {
          final x = 30 + i * (cw + 10);
          final card = ui.Rect.fromLTWH(x, y, cw, ch);
          canvas.drawRect(card, ui.Paint()..color = const ui.Color(0xFF23262F));
          final head = i < castHeads.length ? castHeads[i] : null;
          if (head != null) {
            final iw = head.width.toDouble(), ih = head.height.toDouble();
            final s = math.max(cw / iw, ch / ih); // cover-crop to the card
            final dw = iw * s, dh = ih * s;
            canvas.save();
            canvas.clipRect(card);
            canvas.drawImageRect(
              head,
              ui.Rect.fromLTWH(0, 0, iw, ih),
              ui.Rect.fromLTWH(card.center.dx - dw / 2,
                  card.center.dy - dh / 2, dw, dh),
              ui.Paint(),
            );
            canvas.restore();
          } else {
            // Silhouette: a head and shoulders, so an empty card still reads
            // as a person rather than a broken image.
            final p = ui.Paint()..color = const ui.Color(0xFF3A3F4B);
            canvas.drawCircle(
                ui.Offset(card.center.dx, card.top + ch * 0.36), cw * 0.17, p);
            canvas.drawRRect(
              ui.RRect.fromRectAndRadius(
                ui.Rect.fromLTWH(card.left + cw * 0.18, card.top + ch * 0.56,
                    cw * 0.64, ch * 0.30),
                ui.Radius.circular(cw * 0.12),
              ),
              p,
            );
          }
          // Actor name under the card (first line only — "Name as Role" would
          // never fit at this width).
          final name = cast[i].split(' as ').first;
          final nb = ui.ParagraphBuilder(ui.ParagraphStyle(
            textAlign: ui.TextAlign.center,
            fontSize: 13,
            fontWeight: ui.FontWeight.w700,
            textDirection: ui.TextDirection.ltr,
            maxLines: 2,
            ellipsis: '…',
          ))
            ..pushStyle(ui.TextStyle(color: const ui.Color(0xFFD6DAE4)));
          nb.addText(name);
          final np = nb.build()..layout(ui.ParagraphConstraints(width: cw));
          canvas.drawParagraph(np, ui.Offset(x, y + ch + 4));
        }
        y += ch + 40;
      }
      if (directors.isNotEmpty) {
        para('DIRECTED BY', fontSize: 15, color: ink,
            weight: ui.FontWeight.w900, letterSpacing: 3, gap: 4);
        para(directors.take(2).join(', '),
            fontSize: 19, color: const ui.Color(0xFFD6DAE4), maxLines: 2,
            gap: 14);
      }

      // Spec strip pinned to the foot of the sleeve, like a real box.
      if (facts.isNotEmpty) {
        final fy = size.height - 62;
        canvas.drawRect(
          ui.Rect.fromLTWH(30, fy - 14, size.width - 60, 2),
          ui.Paint()..color = ink.withValues(alpha: 0.65),
        );
        final b = ui.ParagraphBuilder(ui.ParagraphStyle(
          fontSize: 17,
          fontWeight: ui.FontWeight.w700,
          textDirection: ui.TextDirection.ltr,
          maxLines: 2,
          ellipsis: '…',
        ))
          ..pushStyle(ui.TextStyle(color: ink, letterSpacing: 1));
        b.addText(facts.join('   •   '));
        final p = b.build()
          ..layout(ui.ParagraphConstraints(width: size.width - 60));
        canvas.drawParagraph(p, ui.Offset(30, fy));
      }
    });
  }

  /// Bakes a section sign on demand. Cached by [label]; safe to call per aisle.
  Future<gpu.Texture?> sectionSign(String label, {required bool halloween}) async {
    if (sectionSigns.containsKey(label)) return sectionSigns[label];
    final tex = await sign(
      label,
      background: halloween ? const ui.Color(0xFF2A0A45) : null,
      foreground: halloween ? const ui.Color(0xFFFF7A18) : null,
      width: 512,
      height: 128,
    );
    sectionSigns[label] = tex;
    return tex;
  }

  bool loaded = false;

  /// Bakes every surface. Failure of any one texture is non-fatal — the
  /// material just keeps its solid base colour.
  Future<void> load({required bool halloween}) async {
    carpet = await _bake(512, 512, (c, s) => _paintCarpet(c, s, halloween));
    ceilingTile = await _bake(512, 512, _paintCeilingTile);
    wallPaint = await _bake(256, 256, (c, s) => _paintWall(c, s, halloween));
    shelfPanel = await _bake(256, 256, _paintShelfPanel);
    woodTrim = await _bake(256, 256, _paintWood);
    counterTop = await _bake(256, 256, _paintCounterTop);
    candySheet = await _bake(256, 256, (c, s) => _paintCandySheet(c, s, halloween));
    popcornBox = await _bake(128, 256, (c, s) => _paintPopcornBox(c, s, halloween));
    coolerFront = await _bake(256, 256, _paintCoolerFront);

    // Wall signage. A big blank painted wall is the single loudest "this is an
    // empty 3D box" cue left once the fixtures are stocked, so every long wall
    // gets something to read.
    // The in-world sign has to agree with the HUD wordmark, which already
    // switches on the theme — baking the normal name here left a "BEAM VIDEO"
    // sign hanging in a store the UI called something else.
    signBrand = await sign(
      halloween ? 'BLOCKBUSTA' : 'BEAM VIDEO',
      background: halloween ? const ui.Color(0xFF2A0A45) : null,
      foreground: halloween ? const ui.Color(0xFFFF7A18) : null,
      width: 1024,
      height: 256,
    );
    // Every in-world sign follows the theme, not just the brand one — a
    // Blockbuster-blue CHECKOUT sign hanging in the purple/orange store was
    // the last piece of the old palette left on screen.
    final signBg = halloween ? const ui.Color(0xFF2A0A45) : null;
    final signFg = halloween ? const ui.Color(0xFFFF7A18) : null;
    signNewReleases =
        await sign('NEW RELEASES', background: signBg, foreground: signFg);
    signCheckout =
        await sign('CHECKOUT', background: signBg, foreground: signFg);
    signExit = await sign(
      'EXIT',
      background: const ui.Color(0xFF14161C),
      foreground: const ui.Color(0xFF35E06A),
      width: 256,
      height: 128,
    );
    // In-store advertising: a backlit poster panel on the wall, the kind of
    // co-branded ad a real rental store carried.
    adLuxurious = await _bake(512, 256, _paintLuxuriousAd);
    if (halloween) await _loadDeadStore();
    loaded = true;
  }

  /// The closed-down store: every surface here is something a real shuttered
  /// Blockbuster actually had — the liquidation banner, the rewind sign, the
  /// paper notice taped to the doors — so the place reads as ABANDONED rather
  /// than merely dark.
  Future<void> _loadDeadStore() async {
    grimePanel = await _bake(256, 256, _paintGrimePanel);
    ceilingStained = await _bake(512, 512, _paintCeilingStained);
    bannerClosing = await _bake(1024, 256, _paintClosingBanner);
    // A liquidating store doesn't advertise new releases.
    signNewReleases = bannerClosing ?? signNewReleases;
    signRewind = await _bake(512, 256, _paintRewindSign);
    signLateFees = await _bake(512, 256, _paintLateFees);
    signClosedDoor = await _bake(256, 320, _paintClosedNotice);
    cautionTape = await _bake(512, 64, _paintCautionTape);
    boardedWindow = await _bake(512, 512, _paintBoardedWindow);
    fogPuff = await _bake(256, 256, _paintFogPuff);
    floorDebris = await _bake(512, 512, _paintFloorDebris);
  }

  // --- dead-store painters -------------------------------------------------

  static void _text(
    ui.Canvas canvas,
    String text,
    ui.Rect box,
    ui.Color color, {
    double size = 40,
    ui.FontWeight weight = ui.FontWeight.w900,
    double spacing = 2,
    ui.TextAlign align = ui.TextAlign.center,
  }) {
    ui.Paragraph lay(double fs) {
      final b = ui.ParagraphBuilder(ui.ParagraphStyle(
        textAlign: align,
        fontSize: fs,
        fontWeight: weight,
        textDirection: ui.TextDirection.ltr,
      ))
        ..pushStyle(ui.TextStyle(color: color, letterSpacing: spacing))
        ..addText(text);
      return b.build()..layout(ui.ParagraphConstraints(width: box.width));
    }

    var p = lay(size);
    // Shrink to fit, same rule as [sign]: an overrun legend gets sliced by
    // the frame edge in-world.
    if (p.maxIntrinsicWidth > box.width) {
      p = lay(size * box.width / p.maxIntrinsicWidth);
    }
    canvas.drawParagraph(p, ui.Offset(box.left, box.center.dy - p.height / 2));
  }

  /// Seeded speckle: [n] soft dots of [color] with alpha in [a0, a1].
  static void _speckle(ui.Canvas canvas, ui.Size size, math.Random rnd, int n,
      ui.Color color, double r0, double r1, int a0, int a1) {
    for (var i = 0; i < n; i++) {
      canvas.drawCircle(
        ui.Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height),
        r0 + rnd.nextDouble() * (r1 - r0),
        ui.Paint()..color = color.withAlpha(a0 + rnd.nextInt(a1 - a0 + 1)),
      );
    }
  }

  static void _paintGrimePanel(ui.Canvas canvas, ui.Size size) {
    final rnd = math.Random(13);
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFF34373C));
    // Slot standards, like the clean panel, but rusted.
    for (final x in [size.width * 0.12, size.width * 0.88]) {
      canvas.drawRect(ui.Rect.fromLTWH(x - 3, 0, 6, size.height),
          ui.Paint()..color = const ui.Color(0xFF2A1E16));
    }
    _speckle(canvas, size, rnd, 900, const ui.Color(0xFF15161A), 0.6, 2.2, 30, 90);
    // Drip streaks running down from the shelf lips.
    for (var i = 0; i < 18; i++) {
      final x = rnd.nextDouble() * size.width;
      final top = rnd.nextDouble() * size.height * 0.6;
      canvas.drawRect(
        ui.Rect.fromLTWH(x, top, 1.5 + rnd.nextDouble() * 2,
            20 + rnd.nextDouble() * 90),
        ui.Paint()..color = const ui.Color(0x33100C08),
      );
    }
  }

  static void _paintCeilingStained(ui.Canvas canvas, ui.Size size) {
    final rnd = math.Random(29);
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFF3B3A36));
    // Fissured mineral-fibre pits.
    _speckle(canvas, size, rnd, 1400, const ui.Color(0xFF1E1D1A), 0.5, 1.6, 60, 140);
    // Water stains: concentric brown tide-rings, the signature of a roof
    // nobody has fixed since the store closed.
    for (var s = 0; s < 3; s++) {
      final c = ui.Offset(rnd.nextDouble() * size.width,
          rnd.nextDouble() * size.height);
      final r = 60 + rnd.nextDouble() * 110;
      for (var k = 0; k < 5; k++) {
        canvas.drawCircle(
          c.translate(rnd.nextDouble() * 10 - 5, rnd.nextDouble() * 10 - 5),
          r * (1 - k * 0.16),
          ui.Paint()
            ..color = const ui.Color(0xFF4A3218).withAlpha(40 + k * 12)
            ..style = k == 0 ? ui.PaintingStyle.stroke : ui.PaintingStyle.fill
            ..strokeWidth = 5,
        );
      }
    }
    // T-bar grid edge.
    canvas.drawRect(
      ui.Rect.fromLTWH(2, 2, size.width - 4, size.height - 4),
      ui.Paint()
        ..color = const ui.Color(0xFF1C1C1E)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 6,
    );
  }

  static void _paintClosingBanner(ui.Canvas canvas, ui.Size size) {
    // Vinyl liquidation banner: red on white, grommets, sun-faded and torn.
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFFE6E0D2));
    canvas.drawRect(
      ui.Rect.fromLTWH(10, 10, size.width - 20, size.height - 20),
      ui.Paint()
        ..color = const ui.Color(0xFFB3161C)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 10,
    );
    _text(canvas, 'STORE CLOSING',
        ui.Rect.fromLTWH(30, 18, size.width - 60, size.height * 0.52),
        const ui.Color(0xFFC0161D), size: 118, spacing: 6);
    _text(canvas, 'EVERYTHING MUST GO  •  ALL SALES FINAL',
        ui.Rect.fromLTWH(30, size.height * 0.58, size.width - 60, size.height * 0.30),
        const ui.Color(0xFF1B1B1D), size: 44, spacing: 3);
    for (final x in [24.0, size.width - 24]) {
      for (final y in [24.0, size.height - 24]) {
        canvas.drawCircle(ui.Offset(x, y), 8,
            ui.Paint()..color = const ui.Color(0xFF8E8E90));
      }
    }
    // Grime + a torn corner (painted as the wall showing through).
    final rnd = math.Random(5);
    _speckle(canvas, size, rnd, 500, const ui.Color(0xFF3A2E20), 0.8, 3.0, 20, 60);
    final tear = ui.Path()
      ..moveTo(size.width, size.height * 0.55)
      ..lineTo(size.width - 70, size.height)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(tear, ui.Paint()..color = const ui.Color(0xFF15161A));
  }

  static void _paintRewindSign(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFF0B1D4F));
    canvas.drawRect(
      ui.Rect.fromLTWH(8, 8, size.width - 16, size.height - 16),
      ui.Paint()
        ..color = const ui.Color(0xFFF2C21B)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 6,
    );
    _text(canvas, 'BE KIND',
        ui.Rect.fromLTWH(20, 20, size.width - 40, size.height * 0.42),
        const ui.Color(0xFFF2C21B), size: 84, spacing: 6);
    _text(canvas, 'PLEASE REWIND',
        ui.Rect.fromLTWH(20, size.height * 0.52, size.width - 40, size.height * 0.34),
        const ui.Color(0xFFFFFFFF), size: 54, spacing: 4);
    _speckle(canvas, size, math.Random(8), 400,
        const ui.Color(0xFF000000), 0.8, 2.5, 30, 80);
  }

  static void _paintLateFees(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFF14090A));
    _text(canvas, 'LATE FEES',
        ui.Rect.fromLTWH(16, 16, size.width - 32, size.height * 0.45),
        const ui.Color(0xFFE23A1E), size: 90, spacing: 5);
    _text(canvas, 'ARE FOREVER',
        ui.Rect.fromLTWH(16, size.height * 0.52, size.width - 32, size.height * 0.36),
        const ui.Color(0xFFEFE6D2), size: 60, spacing: 5);
    // Dried "blood" drips off the lettering.
    final rnd = math.Random(66);
    for (var i = 0; i < 14; i++) {
      final x = 40 + rnd.nextDouble() * (size.width - 80);
      final y = size.height * 0.42;
      final len = 18 + rnd.nextDouble() * 70;
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
            ui.Rect.fromLTWH(x, y, 4 + rnd.nextDouble() * 4, len),
            const ui.Radius.circular(3)),
        ui.Paint()..color = const ui.Color(0xCC8E0F0B),
      );
    }
  }

  static void _paintClosedNotice(ui.Canvas canvas, ui.Size size) {
    // A sheet of printer paper taped to the glass.
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFFD9D3C2));
    _text(canvas, 'THIS STORE',
        ui.Rect.fromLTWH(12, 18, size.width - 24, 50),
        const ui.Color(0xFF222222), size: 34, weight: ui.FontWeight.w800);
    _text(canvas, 'IS CLOSED',
        ui.Rect.fromLTWH(12, 70, size.width - 24, 50),
        const ui.Color(0xFF222222), size: 34, weight: ui.FontWeight.w800);
    _text(canvas, 'FOREVER',
        ui.Rect.fromLTWH(12, 124, size.width - 24, 64),
        const ui.Color(0xFFB3161C), size: 50);
    _text(canvas, 'Thank you for 29 years of movie nights.',
        ui.Rect.fromLTWH(14, 206, size.width - 28, 40),
        const ui.Color(0xFF3A3A3A), size: 16, weight: ui.FontWeight.w600,
        spacing: 0);
    _text(canvas, 'Please return all tapes to the drop box.',
        ui.Rect.fromLTWH(14, 244, size.width - 28, 40),
        const ui.Color(0xFF3A3A3A), size: 16, weight: ui.FontWeight.w600,
        spacing: 0);
    // Tape strips at the corners.
    for (final c in [const ui.Offset(0, 0), ui.Offset(size.width - 60, 0)]) {
      canvas.drawRect(ui.Rect.fromLTWH(c.dx, c.dy, 60, 18),
          ui.Paint()..color = const ui.Color(0x88F5EFC8));
    }
  }

  static void _paintCautionTape(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFFF2C21B));
    // Diagonal black hazard bands behind the legend.
    for (var x = -size.height; x < size.width; x += 56) {
      final band = ui.Path()
        ..moveTo(x, size.height)
        ..lineTo(x + 20, size.height)
        ..lineTo(x + 20 + size.height, 0)
        ..lineTo(x + size.height, 0)
        ..close();
      canvas.drawPath(band, ui.Paint()..color = const ui.Color(0x55111111));
    }
    _text(canvas, 'CAUTION  DO NOT ENTER  CAUTION',
        ui.Rect.fromLTWH(8, 0, size.width - 16, size.height),
        const ui.Color(0xFF111111), size: 38, spacing: 2);
  }

  static void _paintBoardedWindow(ui.Canvas canvas, ui.Size size) {
    // Moonlight behind: the gaps between planks are the only bright pixels,
    // which is what the (emissive) material lifts into cold slivers of light.
    canvas.drawRect(ui.Offset.zero & size,
        ui.Paint()..color = const ui.Color(0xFF9DB8E0));
    final rnd = math.Random(41);
    var y = -10.0;
    var i = 0;
    while (y < size.height) {
      final h = 62 + rnd.nextDouble() * 22;
      final tilt = (rnd.nextDouble() - 0.5) * 0.10;
      canvas.save();
      canvas.translate(size.width / 2, y + h / 2);
      canvas.rotate(tilt);
      final plank = ui.Rect.fromLTWH(-size.width * 0.6, -h / 2, size.width * 1.2, h);
      final shade = 0x3A + rnd.nextInt(0x18);
      canvas.drawRect(plank, ui.Paint()..color = ui.Color.fromARGB(255, shade, (shade * 0.72).round(), (shade * 0.5).round()));
      // Grain.
      for (var g = 0; g < 7; g++) {
        canvas.drawRect(
          ui.Rect.fromLTWH(-size.width * 0.6, -h / 2 + rnd.nextDouble() * h,
              size.width * 1.2, 1.4),
          ui.Paint()..color = const ui.Color(0x40150C06),
        );
      }
      // Nail heads.
      for (final nx in [-size.width * 0.42, size.width * 0.42]) {
        canvas.drawCircle(ui.Offset(nx, 0), 4,
            ui.Paint()..color = const ui.Color(0xFF1A1A1A));
      }
      canvas.restore();
      y += h + 6 + rnd.nextDouble() * 14; // the moonlit gap
      i++;
    }
    assert(i > 0);
    // Spray-painted X over the boards.
    final paint = ui.Paint()
      ..color = const ui.Color(0xCCC21A1A)
      ..strokeWidth = 16
      ..strokeCap = ui.StrokeCap.round;
    canvas.drawLine(const ui.Offset(60, 60),
        ui.Offset(size.width - 60, size.height - 60), paint);
    canvas.drawLine(ui.Offset(size.width - 60, 60),
        ui.Offset(60, size.height - 60), paint);
  }

  static void _paintFogPuff(ui.Canvas canvas, ui.Size size) {
    final c = size.center(ui.Offset.zero);
    final shader = ui.Gradient.radial(
      c,
      size.width / 2,
      [const ui.Color(0x88C8D6E6), const ui.Color(0x00C8D6E6)],
    );
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..shader = shader);
  }

  static void _paintFloorDebris(ui.Canvas canvas, ui.Size size) {
    // Transparent except for litter: receipts, a torn sleeve, dust.
    final rnd = math.Random(77);
    for (var i = 0; i < 14; i++) {
      canvas.save();
      canvas.translate(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height);
      canvas.rotate(rnd.nextDouble() * math.pi);
      final w = 30 + rnd.nextDouble() * 40, h = 60 + rnd.nextDouble() * 70;
      canvas.drawRect(ui.Rect.fromLTWH(-w / 2, -h / 2, w, h),
          ui.Paint()..color = const ui.Color(0xE0CFC8B6));
      for (var l = 0; l < 6; l++) {
        canvas.drawRect(
            ui.Rect.fromLTWH(-w / 2 + 5, -h / 2 + 8 + l * 9, w - 10 - rnd.nextDouble() * 12, 2.5),
            ui.Paint()..color = const ui.Color(0x88444444));
      }
      canvas.restore();
    }
    _speckle(canvas, size, rnd, 700, const ui.Color(0xFF2B2A26), 0.8, 2.6, 60, 160);
  }

  /// A LuxuriousComputers.com ad panel in the store's REAL brand, sampled from
  /// luxuriouscomputers.com: hot pink #FF2D95 on black, the pink rounded-square
  /// "LC" logo mark, and the site's own tagline. (An earlier version of this
  /// invented a gold-on-navy look that matched nothing.)
  static void _paintLuxuriousAd(ui.Canvas canvas, ui.Size size) {
    const black = ui.Color(0xFF000000);
    const pink = ui.Color(0xFFFF2D95); // announcement bar / logo tile
    const pinkLight = ui.Color(0xFFFF6E9F); // secondary accent
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = black);

    // Pink rule top and bottom, echoing the site's announcement bar.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.width, 10),
      ui.Paint()..color = pink,
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(0, size.height - 10, size.width, 10),
      ui.Paint()..color = pink,
    );

    void line(String text, double y, double fs, ui.Color c,
        {ui.FontWeight w = ui.FontWeight.w900,
        double ls = 2,
        double left = 0,
        double? width,
        ui.TextAlign align = ui.TextAlign.center}) {
      final b = ui.ParagraphBuilder(ui.ParagraphStyle(
        textAlign: align,
        fontSize: fs,
        fontWeight: w,
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
        ellipsis: '',
      ))
        ..pushStyle(ui.TextStyle(color: c, letterSpacing: ls));
      b.addText(text);
      final p = b.build()
        ..layout(ui.ParagraphConstraints(width: width ?? size.width));
      canvas.drawParagraph(p, ui.Offset(left, y));
    }

    // The "LC" logo tile: pink rounded square, white letters, left-aligned
    // like the site header.
    const tile = 74.0;
    final tileRect = ui.Rect.fromLTWH(30, 44, tile, tile);
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(tileRect, const ui.Radius.circular(16)),
      ui.Paint()..color = pink,
    );
    line('LC', tileRect.top + 16, 42, const ui.Color(0xFFFFFFFF),
        left: tileRect.left, width: tile, ls: 0);

    // Wordmark beside the mark.
    final textLeft = tileRect.right + 22;
    final textW = size.width - textLeft - 24;
    line('LUXURIOUS', 44, 38, const ui.Color(0xFFFFFFFF),
        left: textLeft, width: textW, align: ui.TextAlign.left, ls: 1);
    line('COMPUTERS', 84, 38, pink,
        left: textLeft, width: textW, align: ui.TextAlign.left, ls: 1);

    // The site's own promise, then the URL.
    line('Refurbished Macs  •  One-Year Warranty  •  Real People', 150, 20,
        const ui.Color(0xFFE9EAEC),
        w: ui.FontWeight.w600, ls: 0.5);
    line('LuxuriousComputers.com', 186, 32, pinkLight,
        w: ui.FontWeight.w900, ls: 1);
  }

  Future<gpu.Texture?> _bake(
    int w,
    int h,
    void Function(ui.Canvas canvas, ui.Size size) paint,
  ) async {
    try {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      );
      // A CuboidGeometry face samples its map VERTICALLY FLIPPED: the face UVs
      // put v=0 at the face's low (-Y) corner, while the uploaded image's
      // origin is its top-left. Noise maps don't care, but anything with text
      // or a top/bottom — signage, and the poster pipeline in
      // video_store_data.dart which applies the same correction — renders
      // upside-down unless it is pre-flipped here.
      //
      // (Measured, not assumed: a 180-degree pre-rotation left the art upright
      // but MIRRORED on-device, which is exactly R180 composed with the real
      // error, so the real error is a plain V flip.)
      canvas.translate(0, h.toDouble());
      canvas.scale(1, -1);
      paint(canvas, ui.Size(w.toDouble(), h.toDouble()));
      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      picture.dispose();
      final tex = await scene.gpuTextureFromImage(image);
      image.dispose();
      return tex;
    } catch (e) {
      debugPrint('[VideoStore] texture bake failed: $e');
      return null;
    }
  }

  // --- painters ----------------------------------------------------------

  /// Blockbuster's blue commercial loop carpet: a dark blue ground, a dense
  /// two-tone fleck (that's what stops a big floor reading as a flat gradient
  /// from a distance) and a faint repeating berber grid.
  static void _paintCarpet(ui.Canvas canvas, ui.Size size, bool halloween) {
    final base = halloween
        ? const ui.Color(0xFF0B0D12)
        : const ui.Color(0xFF15295E);
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = base);

    final rnd = math.Random(7);
    final light = ui.Paint()
      ..color = halloween
          ? const ui.Color(0x22303845)
          : const ui.Color(0x33507ACD);
    final dark = ui.Paint()
      ..color = halloween
          ? const ui.Color(0x44000000)
          : const ui.Color(0x44081840);
    // Fleck: ~9k specks is dense enough that no 2-3 px cluster repeats
    // visibly when the image is stretched over a 15 m floor.
    for (var i = 0; i < 9000; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height;
      final r = 0.6 + rnd.nextDouble() * 1.6;
      canvas.drawCircle(ui.Offset(x, y), r, rnd.nextBool() ? light : dark);
    }
    // Berber grid — 32 px cells, very low contrast.
    final grid = ui.Paint()
      ..color = const ui.Color(0x14000000)
      ..strokeWidth = 1;
    for (var i = 0; i <= size.width; i += 32) {
      final d = i.toDouble();
      canvas.drawLine(ui.Offset(d, 0), ui.Offset(d, size.height), grid);
      canvas.drawLine(ui.Offset(0, d), ui.Offset(size.width, d), grid);
    }
  }

  /// Suspended acoustic ceiling: 4x4 grid of tiles with metal T-bar runners
  /// and the fine perforations that make a real drop ceiling read as one.
  static void _paintCeilingTile(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFFCFD2D6),
    );
    final rnd = math.Random(11);
    final pore = ui.Paint()..color = const ui.Color(0x1A46505C);
    for (var i = 0; i < 5000; i++) {
      canvas.drawCircle(
        ui.Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height),
        0.7 + rnd.nextDouble(),
        pore,
      );
    }
    // T-bar runners: bright metal edge with a darker shadow line beside it.
    const cells = 4;
    final cell = size.width / cells;
    final bar = ui.Paint()..color = const ui.Color(0xFFEFF1F3);
    final shadow = ui.Paint()..color = const ui.Color(0x33333A44);
    for (var i = 0; i <= cells; i++) {
      final d = i * cell;
      canvas.drawRect(ui.Rect.fromLTWH(d - 3, 0, 6, size.height), bar);
      canvas.drawRect(ui.Rect.fromLTWH(d + 3, 0, 2, size.height), shadow);
      canvas.drawRect(ui.Rect.fromLTWH(0, d - 3, size.width, 6), bar);
      canvas.drawRect(ui.Rect.fromLTWH(0, d + 3, size.width, 2), shadow);
    }
  }

  /// Painted drywall: off-white with a FINE orange-peel speckle.
  ///
  /// The mottle here is deliberately tiny and low-alpha. An earlier version
  /// used 3-12 px blobs, which — stretched across a 12 m wall — read as grey
  /// storm clouds rather than paint. Wall panels are tiled ~2.5 m per image,
  /// so this speckle lands at roughly real orange-peel scale.
  static void _paintWall(ui.Canvas canvas, ui.Size size, bool halloween) {
    final base =
        halloween ? const ui.Color(0xFF14161C) : const ui.Color(0xFFE9EBEE);
    canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = base);
    final rnd = math.Random(23);
    final dark = ui.Paint()
      ..color = halloween ? const ui.Color(0x10000000) : const ui.Color(0x0C8892A0);
    final light = ui.Paint()..color = const ui.Color(0x10FFFFFF);
    for (var i = 0; i < 6000; i++) {
      canvas.drawCircle(
        ui.Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height),
        0.5 + rnd.nextDouble() * 1.1,
        rnd.nextBool() ? dark : light,
      );
    }
  }

  /// Retail shelving: white melamine panel with the fine vertical seams and
  /// the perforated standard strips real gondola shelving has.
  static void _paintShelfPanel(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFFDFE2E6),
    );
    final seam = ui.Paint()..color = const ui.Color(0x22707A88);
    for (var i = 0; i <= size.width; i += 64) {
      canvas.drawRect(ui.Rect.fromLTWH(i.toDouble(), 0, 2, size.height), seam);
    }
    // Slot standards: paired columns of notches.
    final notch = ui.Paint()..color = const ui.Color(0x3A5A6472);
    for (final cx in [size.width * 0.18, size.width * 0.82]) {
      for (var y = 6.0; y < size.height; y += 14) {
        canvas.drawRect(ui.Rect.fromLTWH(cx - 2, y, 4, 7), notch);
      }
    }
  }

  /// Warm wood for trim / counter fronts — banded grain, no repeats visible
  /// at the scale trim is used.
  static void _paintWood(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFF6B4A2E),
    );
    final rnd = math.Random(31);
    for (var i = 0; i < 160; i++) {
      final y = rnd.nextDouble() * size.height;
      final p = ui.Paint()
        ..color = ui.Color.fromARGB(
          40 + rnd.nextInt(50),
          40 + rnd.nextInt(60),
          25 + rnd.nextInt(40),
          10 + rnd.nextInt(25),
        )
        ..strokeWidth = 1 + rnd.nextDouble() * 3;
      canvas.drawLine(ui.Offset(0, y), ui.Offset(size.width, y + rnd.nextDouble() * 6 - 3), p);
    }
  }

  /// Speckled laminate counter top (the checkout desk surface).
  /// A rack face packed with assorted candy bars. Drawn as a grid of small
  /// bright wrappers with a lighter foil band and a dark gap between rows —
  /// what sells "impulse rack" is MANY small distinct colours, not one slab.
  static void _paintCandySheet(ui.Canvas canvas, ui.Size size, bool halloween) {
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFF15171E),
    );
    // Normal store = full sweet-shop spread. Halloween = orange/purple/black.
    const normal = [
      0xFFE23B2E, 0xFFF2A31B, 0xFF2F7DD1, 0xFF3FA34D, 0xFFB4318F,
      0xFFF0D330, 0xFF8B4A22, 0xFFE7E3D8, 0xFFD1263F, 0xFF5B3FA0,
    ];
    const spooky = [
      0xFFFF7A18, 0xFF7B1FA2, 0xFF1B1B1F, 0xFFE8E2D0, 0xFF54B948,
      0xFFFFB300, 0xFF4A148C, 0xFFD32F2F, 0xFF2E2E33, 0xFFFF9800,
    ];
    final palette = halloween ? spooky : normal;
    final rnd = math.Random(77);
    const cols = 6, rows = 8;
    final cw = size.width / cols, ch = size.height / rows;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final x = c * cw, y = r * ch;
        final color = ui.Color(palette[rnd.nextInt(palette.length)]);
        // Wrapper body, inset so the dark background reads as a shelf gap.
        canvas.drawRect(
          ui.Rect.fromLTWH(x + 1.5, y + 2.0, cw - 3.0, ch - 4.0),
          ui.Paint()..color = color,
        );
        // Foil highlight band across the middle of the wrapper.
        canvas.drawRect(
          ui.Rect.fromLTWH(x + 1.5, y + ch * 0.42, cw - 3.0, ch * 0.16),
          ui.Paint()..color = const ui.Color(0x33FFFFFF),
        );
        // Shadow under each bar so the rows read as stacked, not printed.
        canvas.drawRect(
          ui.Rect.fromLTWH(x + 1.5, y + ch - 4.0, cw - 3.0, 2.0),
          ui.Paint()..color = const ui.Color(0x55000000),
        );
      }
    }
  }

  /// Classic striped popcorn tub. Vertical red/white bands, darker rim.
  static void _paintPopcornBox(ui.Canvas canvas, ui.Size size, bool halloween) {
    final stripe =
        halloween ? const ui.Color(0xFFFF7A18) : const ui.Color(0xFFD8342B);
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFFF3EFE6),
    );
    const bands = 7;
    final bw = size.width / bands;
    for (var i = 0; i < bands; i += 2) {
      canvas.drawRect(
        ui.Rect.fromLTWH(i * bw, 0, bw, size.height),
        ui.Paint()..color = stripe,
      );
    }
    // Rolled rim at the top and a shadowed base.
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, size.width, size.height * 0.08),
      ui.Paint()..color = const ui.Color(0xFF8E1F19),
    );
    canvas.drawRect(
      ui.Rect.fromLTWH(0, size.height * 0.88, size.width, size.height * 0.12),
      ui.Paint()..color = const ui.Color(0x44000000),
    );
  }

  /// A drinks cooler door: dark glass, bright bottle shapes ranked behind it,
  /// and a specular streak so it reads as glass rather than a painted panel.
  static void _paintCoolerFront(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFF0E1A1E),
    );
    const bottleColors = [
      0xFFE2412F, 0xFF2B7BD4, 0xFF3FA34D, 0xFFE8A21B, 0xFFB0322F,
    ];
    final rnd = math.Random(19);
    const shelves = 4, perShelf = 6;
    final sh = size.height / shelves;
    final bw = size.width / perShelf;
    for (var s = 0; s < shelves; s++) {
      final y = s * sh;
      for (var b = 0; b < perShelf; b++) {
        final x = b * bw;
        final c = ui.Color(bottleColors[rnd.nextInt(bottleColors.length)]);
        // Bottle body.
        canvas.drawRect(
          ui.Rect.fromLTWH(x + bw * 0.18, y + sh * 0.20, bw * 0.64, sh * 0.62),
          ui.Paint()..color = c,
        );
        // Neck.
        canvas.drawRect(
          ui.Rect.fromLTWH(x + bw * 0.38, y + sh * 0.06, bw * 0.24, sh * 0.16),
          ui.Paint()..color = c,
        );
      }
      // Wire shelf line.
      canvas.drawRect(
        ui.Rect.fromLTWH(0, y + sh * 0.86, size.width, 2.0),
        ui.Paint()..color = const ui.Color(0x66FFFFFF),
      );
    }
    // Diagonal glass glare.
    canvas.save();
    canvas.translate(size.width * 0.62, 0);
    canvas.rotate(0.32);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, -size.height, size.width * 0.16, size.height * 3),
      ui.Paint()..color = const ui.Color(0x22FFFFFF),
    );
    canvas.restore();
  }

  static void _paintCounterTop(ui.Canvas canvas, ui.Size size) {
    canvas.drawRect(
      ui.Offset.zero & size,
      ui.Paint()..color = const ui.Color(0xFF2B2F3A),
    );
    final rnd = math.Random(41);
    for (var i = 0; i < 3000; i++) {
      canvas.drawCircle(
        ui.Offset(rnd.nextDouble() * size.width, rnd.nextDouble() * size.height),
        0.6 + rnd.nextDouble(),
        ui.Paint()
          ..color = ui.Color.fromARGB(
            60 + rnd.nextInt(120),
            180 + rnd.nextInt(60),
            180 + rnd.nextInt(60),
            190 + rnd.nextInt(60),
          ),
      );
    }
  }

  /// Bakes a lit sign face: coloured field, border, and centred text. Used for
  /// in-world section signage ("MOVIES", "NEW RELEASES", "EXIT").
  Future<gpu.Texture?> sign(
    String text, {
    // Deliberately darker than the wall band's blue: the sign material adds an
    // emissive lift ON TOP of this sampled colour, so a mid blue here bakes out
    // to pale lavender on-device. Pre-darkening lands it on Blockbuster blue.
    ui.Color? background,
    ui.Color? foreground,
    int width = 512,
    int height = 128,
  }) {
    // Nullable so a caller can pass a theme colour through unconditionally and
    // still get the default when that theme doesn't override it.
    final bg = background ?? const ui.Color(0xFF07225F);
    final fg = foreground ?? const ui.Color(0xFFFAC81A);
    return _bake(width, height, (canvas, size) {
      canvas.drawRect(ui.Offset.zero & size, ui.Paint()..color = bg);
      canvas.drawRect(
        ui.Rect.fromLTWH(6, 6, size.width - 12, size.height - 12),
        ui.Paint()
          ..color = fg
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 6,
      );
      // Lay the text out, then SHRINK to fit inside the border if it overruns.
      // A long legend ("BEAM VIDEO") at the nominal size overflowed the field
      // and the last glyph was sliced off by the frame edge in-world.
      final inset = size.width - 28;
      ui.Paragraph layOut(double fontSize) {
        final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
          textAlign: ui.TextAlign.center,
          fontSize: fontSize,
          fontWeight: ui.FontWeight.w900,
          textDirection: ui.TextDirection.ltr,
        ))
          ..pushStyle(ui.TextStyle(color: fg, letterSpacing: 3))
          ..addText(text.toUpperCase());
        return builder.build()
          ..layout(ui.ParagraphConstraints(width: size.width));
      }

      var fontSize = size.height * 0.52;
      var paragraph = layOut(fontSize);
      if (paragraph.maxIntrinsicWidth > inset) {
        fontSize *= inset / paragraph.maxIntrinsicWidth;
        paragraph = layOut(fontSize);
      }
      canvas.drawParagraph(
        paragraph,
        ui.Offset(0, (size.height - paragraph.height) / 2),
      );
    });
  }
}
