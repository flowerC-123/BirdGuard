#include "roi_protocol.hpp"
#include <chrono>
#include <iostream>
#include <stdexcept>
using namespace roi;
static int checks = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        ++checks;                                                                                  \
        if (!(c))                                                                                  \
            throw std::runtime_error("check failed: " #c);                                         \
    } while (0)
int main() {
    try {
        Crop c;
        c.source_frame = 10;
        c.roi_id = 2;
        c.source_w = 320;
        c.source_h = 240;
        c.x = 10;
        c.y = 20;
        c.w = 128;
        c.h = 128;
        c.format = kGray8;
        c.pixels = Bytes(16384, 83);
        const auto wire = encode(Packet{kImage, 11, 12, crop_body(c)});
        for (size_t chunk : {size_t(1), size_t(2), size_t(7), size_t(15), size_t(16), size_t(127),
                             size_t(1024), size_t(4096), wire.size()}) {
            Parser p;
            std::vector<Packet> got;
            for (size_t at = 0; at < wire.size(); at += chunk) {
                auto n = std::min(chunk, wire.size() - at);
                auto part = p.feed(wire.data() + at, n, 100);
                got.insert(got.end(), part.begin(), part.end());
            }
            CHECK(got.size() == 1 && got[0].session == 11 && got[0].request == 12 &&
                  got[0].body == crop_body(c));
            CHECK(p.stats.bad_crc == 0 && p.stats.bad_header == 0 && p.buffered() == 0);
        }
        {
            Parser p;
            Bytes bad(wire.begin(), wire.begin() + 16);
            bad[14] ^= 1;
            CHECK(p.feed(bad.data(), bad.size(), 100).empty());
            CHECK(p.stats.bad_header == 1);
            CHECK(p.buffered() < 16);
            auto good = p.feed(wire.data(), wire.size(), 101);
            CHECK(good.size() == 1);
        }
        {
            Parser p;
            Bytes bad = wire;
            bad.back() ^= 1;
            bad.insert(bad.end(), wire.begin(), wire.end());
            auto got = p.feed(bad.data(), bad.size(), 100);
            CHECK(got.size() == 1);
            CHECK(p.stats.bad_crc == 1);
        }
        {
            Parser p;
            Bytes many(200000, 0x61);
            many.insert(many.end(), wire.begin(), wire.end());
            auto got = p.feed(many.data(), many.size(), 100);
            CHECK(got.size() == 1);
            CHECK(p.stats.noise == 200000);
            CHECK(p.buffered() == 0);
        }
        {
            Parser p;
            p.feed(wire.data(), 500, 100);
            p.expire(350);
            CHECK(p.stats.timeouts == 1);
            CHECK(p.buffered() == 0);
            CHECK(p.feed(wire.data(), wire.size(), 351).size() == 1);
        }
        const unsigned iterations = 400;
        Parser p;
        const auto start = std::chrono::steady_clock::now();
        for (unsigned i = 0; i < iterations; ++i) {
            for (size_t at = 0; at < wire.size(); at += 4096)
                p.feed(wire.data() + at, std::min<size_t>(4096, wire.size() - at), 100);
        }
        const double ms =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start)
                .count();
        CHECK(p.stats.packets == iterations);
        std::cout << "PASS parser checks=" << checks << " packets=" << iterations
                  << " bytes=" << iterations * wire.size() << " elapsed_ms=" << ms << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL " << e.what() << '\n';
        return 1;
    }
}
