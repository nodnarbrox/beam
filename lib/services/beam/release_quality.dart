/// Parses release quality signals from a scene/torrent title so the app can
/// (a) show quality badges and (b) pick a LOWER-quality alternate for instant
/// play when a client's bandwidth can't keep up (adaptive quality).
///
/// Everything is best-effort regex over the release name — the same heuristics
/// Sonarr/Radarr use. Higher [rank] = higher visual quality.
class ReleaseQuality {
  const ReleaseQuality({
    required this.resolution,
    required this.source,
    required this.rank,
    required this.hdr,
    required this.codec,
  });

  /// e.g. 2160, 1080, 720, 480, or 0 when unknown.
  final int resolution;

  /// e.g. 'BluRay', 'WEB-DL', 'WEBRip', 'HDTV', 'DVD', 'CAM', or ''.
  final String source;

  /// Composite ordering key: resolution-dominant, source as tiebreaker.
  final int rank;

  final bool hdr;

  /// 'x265'/'HEVC', 'x264'/'AVC', 'AV1', or ''.
  final String codec;

  String get label {
    final res = resolution > 0 ? '${resolution}p' : '';
    final parts = [
      if (res.isNotEmpty) res,
      if (source.isNotEmpty) source,
      if (hdr) 'HDR',
      if (codec.isNotEmpty) codec,
    ];
    return parts.isEmpty ? 'Unknown' : parts.join(' · ');
  }

  static const _sourceRank = <String, int>{
    'BluRay': 60,
    'REMUX': 65,
    'WEB-DL': 50,
    'WEBRip': 45,
    'HDTV': 35,
    'DVD': 25,
    'CAM': 5,
    'TS': 6,
  };

  factory ReleaseQuality.parse(String title) {
    final t = title.toLowerCase();

    int resolution = 0;
    if (RegExp(r'\b(2160p|4k|uhd)\b').hasMatch(t)) {
      resolution = 2160;
    } else if (RegExp(r'\b1440p\b').hasMatch(t)) {
      resolution = 1440;
    } else if (RegExp(r'\b1080p\b').hasMatch(t)) {
      resolution = 1080;
    } else if (RegExp(r'\b720p\b').hasMatch(t)) {
      resolution = 720;
    } else if (RegExp(r'\b(480p|sd)\b').hasMatch(t)) {
      resolution = 480;
    }

    String source = '';
    if (RegExp(r'\bremux\b').hasMatch(t)) {
      source = 'REMUX';
    } else if (RegExp(r'\bblu-?ray\b|\bbdrip\b|\bbrrip\b').hasMatch(t)) {
      source = 'BluRay';
    } else if (RegExp(r'\bweb-?dl\b|\bwebdl\b').hasMatch(t)) {
      source = 'WEB-DL';
    } else if (RegExp(r'\bweb-?rip\b|\bwebrip\b|\bweb\b').hasMatch(t)) {
      source = 'WEBRip';
    } else if (RegExp(r'\bhdtv\b').hasMatch(t)) {
      source = 'HDTV';
    } else if (RegExp(r'\bdvd').hasMatch(t)) {
      source = 'DVD';
    } else if (RegExp(r'\bcam\b|\bcamrip\b|\bhdcam\b').hasMatch(t)) {
      source = 'CAM';
    } else if (RegExp(r'\bhdts\b|\btelesync\b|\bts\b').hasMatch(t)) {
      source = 'TS';
    }

    final hdr = RegExp(r'\bhdr(10)?\b|\bdolby ?vision\b|\bdv\b').hasMatch(t);

    String codec = '';
    if (RegExp(r'\b(x265|hevc|h\.?265)\b').hasMatch(t)) {
      codec = 'x265';
    } else if (RegExp(r'\b(x264|avc|h\.?264)\b').hasMatch(t)) {
      codec = 'x264';
    } else if (RegExp(r'\bav1\b').hasMatch(t)) {
      codec = 'AV1';
    }

    final rank = resolution * 100 + (_sourceRank[source] ?? 0);

    return ReleaseQuality(
      resolution: resolution,
      source: source,
      rank: rank,
      hdr: hdr,
      codec: codec,
    );
  }
}

/// Keywords Real-Debrid's content filter (activated May 2026, DSA/French-law
/// compliance) blocks in CACHED filenames. A release whose name contains any of
/// these will fail to resolve on RD even when the torrent itself is fine, so the
/// Real-Debrid auto-pick should prefer releases WITHOUT them (BluRay/REMUX
/// scene names usually pass; WEB/WEBRip/YTS ones usually don't).
///
/// Measured 2026-08-22 against the live indexer: 6/6 top results for a 2025
/// title and 5/6 for a 2026 title contained a blocked keyword, while an older
/// BluRay-heavy catalogue title had 0/8 — so without this filter the RD path
/// breaks for most recent releases.
const List<String> kRdBlockedKeywords = [
  'WEB-DL', 'WEBRip', 'WEB DL', 'AMZN', 'YTS', 'RARBG',
];

/// True when [result] title avoids every [kRdBlockedKeywords] entry, i.e. it is
/// likely to actually resolve through Real-Debrid.
bool rdFilterSafeTitle(String title) {
  final t = title.toUpperCase();
  for (final k in kRdBlockedKeywords) {
    if (t.contains(k.toUpperCase())) return false;
  }
  return true;
}
