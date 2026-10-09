#include "../src/stream_lookahead.h"

#include <cassert>
#include <cmath>
#include <iostream>
#include <map>
#include <set>
#include <utility>

using Requests = std::map<int, std::pair<int, int>>;

static Requests schedule(int current, int end, const std::set<int>& cached) {
    Requests requests;
    torrent_stream::replenish_lookahead(current, end,
        [&](int piece) { return cached.count(piece) != 0; },
        [&](int piece, int priority, int deadline) {
            requests.emplace(piece, std::make_pair(priority, deadline));
        });
    return requests;
}

int main() {
    // Regression: an entirely cached current window still extends downloading
    // as the HTTP reader advances, before reaching a missing current piece.
    std::set<int> cached;
    for (int p = 0; p <= 16; ++p) cached.insert(p);
    assert(schedule(0, 100, cached).empty());
    auto advanced = schedule(1, 100, cached);
    assert(advanced.size() == 1 && advanced.count(17));
    assert(advanced.at(17) == std::make_pair(6, 1280));

    auto missing = schedule(20, 100, {});
    assert(missing.size() == 17);
    assert(missing.at(20) == std::make_pair(7, 0));
    assert(missing.at(22) == std::make_pair(7, 160));
    assert(missing.at(23) == std::make_pair(6, 240));
    assert(missing.count(37) == 0);

    auto tail = schedule(98, 100, {98, 100});
    assert(tail.size() == 1 && tail.at(99) == std::make_pair(7, 80));
    assert(schedule(101, 100, {}).empty());
    assert(schedule(-1, 100, {}).empty());

    // Scheduling has no retained cursor: a backward seek gets its own window.
    auto backward = schedule(4, 100, {4, 7});
    assert(backward.size() == 15 && backward.count(5) && backward.count(20));
    assert(backward.count(21) == 0 && backward.count(98) == 0);
    // A second stream's requests are independent of the first stream's cache.
    assert(schedule(1, 100, {}).size() == 17);

    // A 2.4GB / 40-minute source needs 1MB/s; 20MB is 20 seconds, not
    // the 55 seconds implied by the old 6600-second size-only estimate.
    const float bitrate = torrent_stream::bitrate_from_duration(2400000000LL, 2400000);
    assert(std::abs(bitrate - 1000000.0f) < 0.01f);
    assert(std::abs(20000000.0f / bitrate - 20.0f) < 0.01f);
    assert(torrent_stream::bitrate_from_duration(1000, 0) == 0);
    assert(torrent_stream::bitrate_from_duration(1000, -1) == 0);
    assert(torrent_stream::bitrate_from_duration(1000, 86400001) == 0);
    assert(torrent_stream::bitrate_from_duration(0, 1000) == 0);
    assert(torrent_stream::bitrate_from_duration(86400000, 86400000) == 1000);
    // Exact duration must also grow the startup disk runway beyond the old
    // 8MiB head, otherwise a 20-second startup wait could never complete.
    constexpr long long budget = 128LL * 1024 * 1024;
    assert(torrent_stream::initial_buffer_bytes(2400000000LL, 2400000, budget) == 20000000);
    assert(torrent_stream::initial_buffer_bytes(2400000001LL, 2400000, budget) == 20000001);
    assert(torrent_stream::initial_buffer_bytes(2400000000LL, 2400000, 8 * 1024 * 1024) == 0);
    assert(torrent_stream::initial_buffer_bytes(2400000000LL, 1000, budget) == 0);
    assert(torrent_stream::initial_buffer_bytes(1000000, 20000, budget) == 1000000);
    std::cout << "Native lookahead and exact-duration checks passed\n";
}
