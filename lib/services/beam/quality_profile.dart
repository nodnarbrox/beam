import 'prowlarr_client.dart';
import 'release_quality.dart';

/// Sonarr/Radarr-style release scoring, ported into the app.
///
/// The arrs don't just grab the most-seeded release — they score every candidate
/// against a QUALITY PROFILE (preferred/rejected "custom formats", resolution
/// cutoffs, size sanity) and grab the highest-scoring ACCEPTABLE one. That model
/// is exactly what MediaBeam needs, because "best" differs per resolve mode:
///   * Real-Debrid  -> must avoid RD's blocked filename keywords entirely.
///   * Torrent      -> must have a magnet, and seeders matter far more.
/// Running the actual arr binaries on a 32-bit device isn't possible, but their
/// SCORING LOGIC ports cleanly and is the valuable part.
class CustomFormat {
  const CustomFormat({
    required this.name,
    required this.keywords,
    required this.score,
  });

  final String name;

  /// Case-insensitive substrings matched against the release title.
  final List<String> keywords;

  /// Positive = preferred, negative = penalised. A [rejectBelow] profile score
  /// can then filter the release out entirely.
  final int score;

  bool matches(String title) {
    final t = title.toUpperCase();
    for (final k in keywords) {
      if (t.contains(k.toUpperCase())) return true;
    }
    return false;
  }
}

/// A named set of formats + constraints, like an arr quality profile.
class QualityProfile {
  const QualityProfile({
    required this.name,
    this.formats = const [],
    this.minResolution = 0,
    this.maxResolution = 2160,
    this.requireMagnet = false,
    this.rejectBelow,
  });

  final String name;
  final List<CustomFormat> formats;
  final int minResolution;
  final int maxResolution;

  /// Torrent mode needs a real magnet: URI to stream.
  final bool requireMagnet;

  /// Releases scoring below this are rejected outright (null = never reject on
  /// score alone).
  final int? rejectBelow;

  /// Score a release: custom formats + a seeder/quality tiebreak.
  int score(ProwlarrResult r) {
    var s = 0;
    for (final f in formats) {
      if (f.matches(r.title)) s += f.score;
    }
    final q = ReleaseQuality.parse(r.title);
    // Resolution inside the window is worth a lot; outside it is penalised so
    // the device-capability ceiling still dominates.
    if (q.resolution >= minResolution && q.resolution <= maxResolution) {
      s += 50;
    } else if (q.resolution > maxResolution) {
      s -= 100;
    }
    // Mild seeder weighting so a healthy swarm breaks ties (log-ish buckets).
    final seeds = r.seeders;
    if (seeds >= 500) {
      s += 30;
    } else if (seeds >= 100) {
      s += 20;
    } else if (seeds >= 20) {
      s += 10;
    } else if (seeds <= 2) {
      s -= 20;
    }
    return s;
  }

  bool accepts(ProwlarrResult r) {
    if (requireMagnet && !r.hasMagnet) return false;
    final cut = rejectBelow;
    if (cut != null && score(r) < cut) return false;
    return true;
  }

  /// Best acceptable release, highest score first. Returns null when nothing
  /// qualifies (caller should fall back to its own ordering).
  ProwlarrResult? pick(List<ProwlarrResult> sources) {
    final ok = sources.where(accepts).toList();
    if (ok.isEmpty) return null;
    ok.sort((a, b) {
      final c = score(b).compareTo(score(a));
      return c != 0 ? c : b.seeders.compareTo(a.seeders);
    });
    return ok.first;
  }

  /// Sources ordered best-first under this profile (acceptable ones only).
  List<ProwlarrResult> rank(List<ProwlarrResult> sources) {
    final ok = sources.where(accepts).toList()
      ..sort((a, b) {
        final c = score(b).compareTo(score(a));
        return c != 0 ? c : b.seeders.compareTo(a.seeders);
      });
    return ok;
  }
}

// ---------------------------------------------------------------------------
// Built-in profiles
// ---------------------------------------------------------------------------

/// Formats every profile shares: reward clean scene/BluRay sources, punish
/// junk (cam/telesync) hard so it is never auto-picked.
const kCamKeywords = <String>[
  'CAM', 'CAMRIP', 'HDCAM', 'TELESYNC', 'HDTS', 'TS', 'TELECINE', 'HDTC', 'SCREENER', 'HDRIP.CAM',
];

/// Cam/telesync penalty. Normally -500 so junk can never win. When the user
/// enables [BeamConfig.allowCamReleases] it drops to a mild -60: still ranked
/// below every real release, but no longer disqualifying — so a title that ONLY
/// has cams (fresh cinema release) still plays instead of showing no sources.
CustomFormat _camFormat({required bool allowCam}) => CustomFormat(
      name: allowCam ? 'Cam/TS (allowed)' : 'Junk (cam)',
      keywords: kCamKeywords,
      score: allowCam ? -60 : -500,
    );

List<CustomFormat> _commonFormatsFor({required bool allowCam}) => <CustomFormat>[
      const CustomFormat(name: 'BluRay/REMUX', keywords: ['BLURAY', 'REMUX', 'BDRIP'], score: 40),
      const CustomFormat(name: 'IMAX', keywords: ['IMAX'], score: 15),
      const CustomFormat(name: 'PROPER/REPACK', keywords: ['PROPER', 'REPACK'], score: 10),
      _camFormat(allowCam: allowCam),
      const CustomFormat(name: 'Upscaled', keywords: ['UPSCALE', 'AI UPSCALE'], score: -80),
    ];

/// Real-Debrid profile: RD's May-2026 filename filter rejects cached files whose
/// NAME contains these keywords, so they're scored to oblivion rather than just
/// hidden — a WEBRip is worthless on RD no matter how many seeders it has.
QualityProfile realDebridProfile({bool allowCam = false}) => QualityProfile(
      name: 'Real-Debrid safe',
      formats: [
        ..._commonFormatsFor(allowCam: allowCam),
        for (final k in kRdBlockedKeywords)
          CustomFormat(name: 'RD-blocked: $k', keywords: [k], score: -1000),
      ],
      // Reject anything carrying an RD-blocked keyword (-1000). The cam penalty
      // is -500 when disallowed (also rejected) but only -60 when the user
      // allows cams, which stays above this cutoff so they remain pickable.
      rejectBelow: -100,
    );

/// Torrent profile: needs a magnet, and swarm health matters far more than on
/// RD (where the file is already cached remotely).
QualityProfile torrentProfile({bool allowCam = false}) => QualityProfile(
      name: 'Torrent stream',
      formats: [
        ..._commonFormatsFor(allowCam: allowCam),
        // Well-seeded release groups that reliably have healthy swarms.
        const CustomFormat(
            name: 'Popular groups', keywords: ['YTS', 'YIFY', 'RARBG'], score: 25),
      ],
      requireMagnet: true,
      // Cams are never rejected outright here (no score cutoff) — they just rank
      // last, so they only win when nothing better exists.
    );
