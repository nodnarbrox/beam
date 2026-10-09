#pragma once

#include <cmath>

namespace torrent_stream {

// Refill on every consumed piece, including cache hits. Waiting until the
// current piece is missing lets the wanted queue empty between cached windows.
template <typename HasPiece, typename RequestPiece>
void replenish_lookahead(int current, int end, HasPiece has_piece,
                         RequestPiece request_piece) {
    if (current < 0 || current > end) return;
    constexpr int ahead = 16;
    const int remaining = end - current;
    for (int offset = 0; offset <= ahead && offset <= remaining; ++offset) {
        const int piece = current + offset;
        if (!has_piece(piece)) {
            request_piece(piece, offset <= 2 ? 7 : 6, offset * 80);
        }
    }
}

inline float bitrate_from_duration(long long file_bytes, long long duration_ms) {
    if (file_bytes <= 0 || duration_ms <= 0 || duration_ms > 86400000) return 0.0f;
    return static_cast<float>(static_cast<double>(file_bytes) * 1000.0 /
                              static_cast<double>(duration_ms));
}

// Keep in sync with TorrentStreamService.initialBufferSeconds. The requested
// disk runway is bounded by the configured cache budget; it does not expand
// the protected in-memory head/tail cache.
inline long long initial_buffer_bytes(long long file_bytes, long long duration_ms,
                                      long long budget_bytes) {
    if (file_bytes <= 0 || duration_ms < 20000 || duration_ms > 86400000 ||
        budget_bytes <= 0) return 0;
    const long double wanted = std::ceil(static_cast<long double>(file_bytes) *
                                        20000.0L / duration_ms);
    if (wanted > budget_bytes) return 0;
    return static_cast<long long>(wanted);
}

}  // namespace torrent_stream
