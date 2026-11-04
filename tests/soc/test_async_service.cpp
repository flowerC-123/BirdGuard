#include "roi_async_service.hpp"
#include "platform.hpp"
#include <chrono>
#include <thread>
#include <iostream>
#include <set>
#include <atomic>
#include <stdexcept>
using namespace roi;
static std::atomic<int> checks{0};
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        ++checks;                                                                                  \
        if (!(c))                                                                                  \
            throw std::runtime_error("check failed: " #c);                                         \
    } while (0)
static void delay(unsigned ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }
static Packet packet(uint32_t request, uint32_t session = 1) {
    Crop c;
    c.source_frame = request;
    c.roi_id = uint16_t(request % 4);
    c.source_w = 320;
    c.source_h = 240;
    c.x = 10;
    c.y = 20;
    c.w = 4;
    c.h = 4;
    c.format = kGray8;
    c.pixels = Bytes(16, uint8_t(request));
    return Packet{kImage, session, request, crop_body(c)};
}
static Result result() {
    Result r;
    r.status = Ok;
    r.decision = kBird;
    r.confidence = 95;
    r.has_box = true;
    r.box_x = 1;
    r.box_y = 1;
    r.box_w = 2;
    r.box_h = 2;
    return r;
}
static Result decode(const Bytes &bytes) {
    Parser p;
    auto v = p.feed(bytes.data(), bytes.size(), monotonic_ms());
    CHECK(v.size() == 1);
    Result r;
    CHECK(decode_result(v[0].body, r));
    return r;
}
static std::vector<Completion> collect(AsyncService &service, unsigned count,
                                       unsigned timeout = 2000) {
    std::vector<Completion> values;
    const auto deadline = monotonic_ms() + timeout;
    while (values.size() < count && monotonic_ms() < deadline) {
        Completion c;
        while (service.pop(c))
            values.push_back(std::move(c));
        delay(1);
    }
    CHECK(values.size() == count);
    return values;
}
int main() {
    try {
        g_result_ext = true;
        {
            std::atomic<bool> entered{false}, release{false};
            AsyncConfig cfg;
            AsyncService service(cfg, [&](const Crop &, uint32_t, unsigned) {
                entered = true;
                auto deadline = monotonic_ms() + 500;
                while (!release && monotonic_ms() < deadline)
                    delay(1);
                return result();
            });
            const auto begin = monotonic_ms();
            for (unsigned i = 1; i <= 4; ++i)
                CHECK(service.submit(packet(i), monotonic_ms()).empty());
            CHECK(monotonic_ms() - begin < 100);
            CHECK(service.stats().peak_pending == 4);
            CHECK(service.submit(packet(1), monotonic_ms()).empty());
            auto changed = packet(1);
            changed.body.back() ^= 1;
            CHECK(decode(service.submit(changed, monotonic_ms())).status == BadRequest);
            CHECK(decode(service.submit(packet(5), monotonic_ms())).status == InferenceError);
            release = true;
            auto done = collect(service, 4);
            std::set<uint32_t> ids;
            for (const auto &c : done) {
                ids.insert(c.packet.request);
                auto r = decode(c.reply);
                CHECK(r.status == Ok && r.decision == kBird);
                CHECK(r.has_box && r.box_x == 11 && r.box_y == 21 && r.box_w == 2 && r.box_h == 2);
            }
            CHECK(ids == std::set<uint32_t>({1, 2, 3, 4}));
            CHECK(service.stats().inference_calls == 4);
            CHECK(service.stats().duplicate_pending == 1);
            CHECK(decode(service.submit(packet(2), monotonic_ms())).status == Ok);
            CHECK(service.stats().cache_hits == 1);
            CHECK(decode(service.submit(changed, monotonic_ms())).status == BadRequest);
            CHECK(service.submit(packet(100), monotonic_ms()).empty());
            collect(service, 1);
            CHECK(service.submit(packet(8), monotonic_ms()).empty());
            collect(service, 1);
        }
        {
            AsyncConfig cfg;
            cfg.workers = 2;
            AsyncService service(cfg, [](const Crop &c, uint32_t, unsigned) {
                delay(c.source_frame == 1 ? 120 : 10);
                return result();
            });
            service.submit(packet(1), monotonic_ms());
            service.submit(packet(2), monotonic_ms());
            auto done = collect(service, 2);
            CHECK(done[0].packet.request == 2);
            CHECK(done[1].packet.request == 1);
            CHECK(service.stats().peak_running == 2);
        }
        {
            std::atomic<bool> entered{false};
            AsyncConfig cfg;
            AsyncService service(cfg, [&](const Crop &, uint32_t, unsigned) {
                entered = true;
                delay(60);
                return result();
            });
            service.submit(packet(1, 1), monotonic_ms());
            auto limit = monotonic_ms() + 500;
            while (!entered && monotonic_ms() < limit)
                delay(1);
            CHECK(entered);
            service.submit(packet(2, 1), monotonic_ms());
            service.submit(packet(1, 2), monotonic_ms());
            CHECK(decode(service.submit(packet(3, 1), monotonic_ms())).status == StaleRequest);
            auto done = collect(service, 1);
            CHECK(done[0].packet.session == 2);
            CHECK(service.stats().cancelled == 2);
            Completion extra;
            CHECK(!service.pop(extra));
        }
        {
            AsyncConfig cfg;
            cfg.request_ms = 50;
            cfg.worker_ms = 200;
            AsyncService service(cfg, [](const Crop &, uint32_t budget, unsigned) {
                CHECK(budget <= 50);
                delay(70);
                return result();
            });
            service.submit(packet(1), monotonic_ms());
            service.submit(packet(2), monotonic_ms());
            auto done = collect(service, 2);
            for (const auto &c : done)
                CHECK(decode(c.reply).status == InferenceTimeout);
            CHECK(service.stats().inference_calls == 1);
            CHECK(service.stats().expired == 2);
        }
        {
            AsyncConfig cfg;
            cfg.simulated = true;
            AsyncService service(cfg, [](const Crop &c, uint32_t, unsigned) {
                if (c.source_frame == 1)
                    throw std::runtime_error("model failure");
                return result();
            });
            service.submit(packet(1), monotonic_ms());
            service.submit(packet(2), monotonic_ms());
            auto done = collect(service, 2);
            CHECK(decode(done[0].reply).status == InferenceError);
            CHECK(decode(done[1].reply).status == Ok);
            for (auto &c : done)
                CHECK((decode(c.reply).flags & kSimulated) != 0);
        }
        {
            AsyncConfig cfg;
            cfg.workers = 4;
            AsyncService service(cfg, [](const Crop &c, uint32_t, unsigned) {
                delay(c.source_frame % 3);
                return result();
            });
            const unsigned count = 1000;
            unsigned sent = 0, received = 0;
            std::set<uint32_t> seen;
            const auto deadline = monotonic_ms() + 10000;
            while (received < count && monotonic_ms() < deadline) {
                while (sent < count && sent - received < 4) {
                    ++sent;
                    CHECK(service.submit(packet(sent), monotonic_ms()).empty());
                }
                Completion c;
                while (service.pop(c)) {
                    CHECK(seen.insert(c.packet.request).second);
                    CHECK(decode(c.reply).status == Ok);
                    ++received;
                }
                delay(1);
            }
            CHECK(received == count);
            CHECK(service.stats().inference_calls == count);
            CHECK(service.stats().overload == 0);
            CHECK(service.stats().peak_pending <= 4);
        }
        std::cout << "PASS async_service checks=" << checks.load() << " stress_requests=1000\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL " << e.what() << '\n';
        return 1;
    }
}
