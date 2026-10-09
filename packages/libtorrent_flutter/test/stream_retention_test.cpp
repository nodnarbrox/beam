// Isolated native regression: exercise the production alert delivery and read
// path with synthetic pieces, without a torrent session, sockets or media.
#include "../src/torrent_bridge.cpp"

#include <cstdlib>
#include <iostream>
#include <sys/resource.h>

static void require(bool ok, const char* message) {
    if (!ok) { std::cerr << "FAIL: " << message << '\n'; std::exit(2); }
}

static size_t retained_bytes(StreamEngine& stream) {
    size_t bytes = 0;
    for (const auto& entry : stream.read_results) bytes += entry.second.data.capacity();
    for (const auto& entry : stream.cache->pieces) bytes += entry.second->buffer.capacity();
    return bytes;
}

static void deliver(StreamEngine& stream, int piece, const char* data, int size, bool ok = true) {
#ifdef RETENTION_FIXED
    // Simulate only the asynchronous disk completion, with the same request
    // registration as request_piece_read (no torrent session/network needed).
    stream.pending_piece_reads[piece] = stream.seek_generation.load();
#endif
    stream.on_piece_read(piece, data, size, ok);
}

static void finish_piece(StreamEngine& stream, int piece) {
#ifdef RETENTION_FIXED
    stream.retain_played_piece(piece);
#else
    // Exact old trailing-eviction policy: release the hot cache only. The
    // production read_piece_data/on_piece_read functions above are unchanged.
    stream.trailing_pieces.push_back(piece);
    while (stream.trailing_pieces.size() > StreamEngine::TRAILING_WINDOW) {
        const int old = stream.trailing_pieces.front();
        stream.trailing_pieces.pop_front();
        stream.cache->get_piece(old)->release();
    }
#endif
}

int main() {
    constexpr int piece_bytes = 256 * 1024;
#ifdef RETENTION_FIXED
    constexpr int pieces = 4096; // 1 GiB traversed, never retained at once.
#else
    constexpr int pieces = 256; // Safely cap the known-leaking baseline.
#endif
    StreamEngine stream;
    stream.cache = std::make_unique<TorrCache>();
    stream.cache->init(64 * 1024 * 1024, piece_bytes, pieces + 4, {});
    std::vector<char> payload(piece_bytes, 'v');
    size_t peak = 0;
    for (int p = 0; p < pieces; ++p) {
        // Actual HTTP reader prefetches two completed pieces. Alerts retain a
        // result and a hot-cache copy before read_piece_data consumes it.
        for (int ahead = p; ahead <= p + 2; ++ahead) {
            if (stream.cache->get_piece(ahead)->buffer.empty())
                deliver(stream, ahead, payload.data(), piece_bytes);
        }
        auto result = read_piece_data(&stream, p, 1);
        require(result.ok && result.data.size() == piece_bytes && result.data.front() == 'v', "piece data preserved");
        finish_piece(stream, p);
        peak = std::max(peak, retained_bytes(stream));
        if (p == 63 || p == 255 || p == pieces - 1)
            std::cout << "piece=" << p << " retained_bytes=" << retained_bytes(stream)
                      << " pending_results=" << stream.read_results.size() << '\n';
    }
#ifdef RETENTION_FIXED
    // Three trailing hot pieces plus two prefetched pieces in both stores.
    require(peak <= 7 * piece_bytes, "sequential retention bounded independently of file length");
    // A late duplicated completion must be released by trailing eviction too.
    deliver(stream, pieces - 4, payload.data(), piece_bytes);
    stream.discard_piece_data(pieces - 4);
    require(stream.read_results.count(pieces - 4) == 0, "eviction drops duplicate pending result");
    require(stream.cache->get_piece(pieces - 4)->buffer.empty(), "eviction drops duplicate hot cache");
    stream.on_piece_read(pieces - 4, payload.data(), piece_bytes, true);
    require(stream.cache->get_piece(pieces - 4)->buffer.empty(), "late evicted completion cannot resurrect payload");
    for (int seek = 0; seek < 200; ++seek) {
        const int p = (seek * 19) % pieces;
        deliver(stream, p, payload.data(), piece_bytes);
        stream.pending_piece_reads[p + 1] = stream.seek_generation.load();
        stream.seek_generation.fetch_add(1);
        stream.clear_piece_data();
        stream.on_piece_read(p + 1, payload.data(), piece_bytes, true);
        require(retained_bytes(stream) == 0, "seek releases both stores");
        stream.request_piece_read(p + 2, stream.seek_generation.load() - 1);
        require(stream.pending_piece_reads.empty(), "abandoned reader cannot request into new generation");
    }
    deliver(stream, 7, payload.data(), piece_bytes);
    require(read_piece_data(&stream, 7, 1).ok, "new read after seek works");
    require(read_piece_data(&stream, 7, 1).ok, "hot-cache reread works after pending result consumed");
    deliver(stream, 8, nullptr, 0, false);
    require(!read_piece_data(&stream, 8, 1).ok, "failed alert never returns valid data");
    stream.clear_piece_data();
    require(retained_bytes(stream) == 0, "cleanup returns retained bytes to zero");
    // During same-pack handoff, an old stream must ignore the new stream's
    // completion while the new owner still receives the verified piece.
    StreamEngine second;
    second.cache = std::make_unique<TorrCache>();
    second.cache->init(64 * 1024 * 1024, piece_bytes, 16, {});
    second.pending_piece_reads[7] = second.seek_generation.load();
    stream.on_piece_read(7, payload.data(), piece_bytes, true);
    second.on_piece_read(7, payload.data(), piece_bytes, true);
    require(retained_bytes(stream) == 0, "unrequested handoff alert ignored by old stream");
    require(read_piece_data(&second, 7, 1).ok, "requested handoff alert accepted by new stream");
    second.clear_piece_data();
    // Actual concurrent HTTP-reader wait semantics: one disk completion
    // satisfies both readers even though only one moves the pending result.
    ReadResult first_read, second_read;
    std::thread first_reader([&] { first_read = read_piece_data(&second, 10, 1000); });
    std::thread second_reader([&] { second_read = read_piece_data(&second, 10, 1000); });
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    {
        std::lock_guard<std::mutex> lock(second.read_mu);
        second.pending_piece_reads[10] = second.seek_generation.load();
    }
    second.on_piece_read(10, payload.data(), piece_bytes, true);
    first_reader.join();
    second_reader.join();
    require(first_read.ok && second_read.ok, "concurrent readers share one completion without starvation");
    second.clear_piece_data();
#else
    require(retained_bytes(stream) > pieces * piece_bytes, "baseline reproduces growing retained piece data");
#endif
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    std::cout << "peak_retained_bytes=" << peak << " peak_rss_kib=" << usage.ru_maxrss << '\n';
    std::cout << "PASS isolated production piece-retention regression\n";
}
