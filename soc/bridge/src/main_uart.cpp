#include "platform.hpp"
#include "roi_async_service.hpp"
#include <fstream>
#include <iostream>
#include <sstream>
#include <iomanip>
#include <filesystem>
#include <csignal>
#include <cstdlib>
#include <cmath>
#include <thread>
#include <chrono>
#include <deque>
#include <mutex>
#include <algorithm>
namespace fs = std::filesystem;

#if !defined(_WIN32) && defined(__GNUC__)
namespace roi {
std::unique_ptr<Transport> mmap_serial_transport(const std::string &) __attribute__((weak));
std::unique_ptr<Transport> serial_transport_fixed(const std::string &, unsigned)
    __attribute__((weak));
} // namespace roi
#endif
static volatile std::sig_atomic_t stopping = 0;
static void on_signal(int) { stopping = 1; }
static unsigned number(const std::string &s) {
    size_t at = 0;
    auto n = std::stoul(s, &at);
    if (at != s.size() || n > 0xffffffffu)
        throw std::invalid_argument("invalid integer");
    return unsigned(n);
}
struct Outgoing {
    roi::Bytes bytes;
    size_t offset = 0;
    uint32_t session = 0, request = 0;
    uint64_t due = 0, deadline = 0;
    unsigned repeats = 1;
};
int main(int argc, char **argv) {
    try {
        bool stdio = false, mmap_uart = false, fixed_baud = false, lenient_crc = false,
             persistent = false;
        std::string device, mock, worker, model, scratch, capture;
        unsigned baud = 1500000, worker_ms = 5000, max_requests = 0, reply_delay_ms = 0,
                 workers = 1, capacity = 4, request_ms = 5500, capture_limit = 64;
        if (const char *e = std::getenv("ROI_RESULT_EXT"))
            roi::g_result_ext = (e[0] != '0' && e[0] != '\0');
        for (int i = 1; i < argc; ++i) {
            std::string k = argv[i];
            if (k == "--stdio") {
                stdio = true;
                continue;
            }
            if (k == "--mmap-uart") {
                mmap_uart = true;
                continue;
            }
            if (k == "--fixed-baud") {
                fixed_baud = true;
                continue;
            }
            if (k == "--lenient-crc") {
                lenient_crc = true;
                continue;
            }
            if (k == "--result-ext") {
                roi::g_result_ext = true;
                continue;
            }
            if (k == "--persistent-worker") {
                persistent = true;
                continue;
            }
            if (k == "--help") {
                std::cerr << "soc_uart_bridge (--stdio --mock-script FILE | --device TTY --worker "
                             "EXE --model RKNN --scratch DIR)\n"
                          << "  [--baud 1500000] [--workers 1..4] [--queue-depth 4..16] "
                             "[--worker-ms 100..5000]\n"
                          << "  [--request-ms 100..5500] [--persistent-worker] [--result-ext] "
                             "[--capture-dir NEW_DIR --capture-limit 64]\n"
                          << "  [--reply-delay-ms 0..1000] [--max-requests N] [--mmap-uart | "
                             "--fixed-baud]\n"
                          << "Continuous receive with a bounded work queue.\n";
                return 0;
            }
            if (i + 1 >= argc)
                throw std::invalid_argument("option needs value");
            std::string v = argv[++i];
            if (k == "--device")
                device = v;
            else if (k == "--mock-script")
                mock = v;
            else if (k == "--worker")
                worker = v;
            else if (k == "--model")
                model = v;
            else if (k == "--scratch")
                scratch = v;
            else if (k == "--capture-dir")
                capture = v;
            else if (k == "--baud")
                baud = number(v);
            else if (k == "--worker-ms")
                worker_ms = number(v);
            else if (k == "--max-requests")
                max_requests = number(v);
            else if (k == "--reply-delay-ms")
                reply_delay_ms = number(v);
            else if (k == "--workers")
                workers = number(v);
            else if (k == "--queue-depth")
                capacity = number(v);
            else if (k == "--request-ms")
                request_ms = number(v);
            else if (k == "--capture-limit")
                capture_limit = number(v);
            else
                throw std::invalid_argument("unknown option: " + k);
        }
        if (stdio == !device.empty())
            throw std::invalid_argument("choose exactly one transport; no default serial device");
        if ((mmap_uart && fixed_baud) || ((mmap_uart || fixed_baud) && stdio))
            throw std::invalid_argument("choose one serial mode only");
        if (worker_ms < 100 || worker_ms > 5000 || workers < 1 || workers > 4 || capacity < 4 ||
            capacity > 16 || capacity < workers || request_ms < 100 || request_ms > 5500 ||
            reply_delay_ms > 1000 || reply_delay_ms >= request_ms || capture_limit < 1 ||
            capture_limit > 1024)
            throw std::invalid_argument("invalid worker/window/deadline configuration");
        const char *rep_env = std::getenv("REPLY_REPEAT");
        unsigned repeats = rep_env ? number(rep_env) : 3;
        if (repeats < 1 || repeats > 5)
            throw std::invalid_argument("REPLY_REPEAT must be 1..5");
        const bool simulated = !mock.empty();
        if (simulated && (!stdio || !worker.empty() || !model.empty() || persistent))
            throw std::invalid_argument("mock is stdio-only without real worker");
        if (!simulated && (worker.empty() || model.empty() || scratch.empty()))
            throw std::invalid_argument("explicit worker/model/scratch required");
        std::vector<std::string> actions;
        size_t action_index = 0, capture_index = 0;
        std::mutex infer_mutex;
        if (simulated) {
            std::ifstream in(mock);
            if (!in)
                throw std::runtime_error("cannot read mock action data");
            std::string s;
            while (std::getline(in, s)) {
                if (!s.empty() && s.back() == '\r')
                    s.pop_back();
                if (!s.empty())
                    actions.push_back(s);
            }
            std::cerr << "SIMULATION_ONLY: scripted decisions; no YOLO/RKNN inference; all replies "
                         "have SIMULATED flag.\n";
        } else {
            if (!fs::is_regular_file(worker) || !fs::is_regular_file(model) ||
                !fs::is_directory(scratch))
                throw std::runtime_error("missing explicit worker/model/scratch");
            worker = fs::absolute(worker).string();
            model = fs::absolute(model).string();
            scratch = fs::absolute(scratch).string();
        }
        if (!capture.empty() && !fs::create_directory(capture))
            throw std::runtime_error("capture-dir must be a new directory with existing parent");
#ifndef _WIN32
        std::vector<std::unique_ptr<roi::PersistentWorker>> residents;
        if (persistent)
            for (unsigned i = 0; i < workers; ++i) {
                residents.emplace_back(new roi::PersistentWorker(worker, model, scratch));
                residents.back()->warm();
            }
#else
        if (persistent)
            throw std::runtime_error(
                "persistent RKNN worker requires Linux; Windows is protocol simulation only");
#endif
        auto infer = [&](const roi::Crop &c, uint32_t budget, unsigned index) -> roi::Result {
            std::string action;
            {
                std::lock_guard<std::mutex> lock(infer_mutex);
                if (!capture.empty() && capture_index < capture_limit) {
                    std::ostringstream n;
                    n << "crop_" << std::setw(6) << std::setfill('0') << ++capture_index << ".ppm";
                    auto p = fs::path(capture) / n.str();
                    std::ofstream out(p, std::ios::binary);
                    auto data = roi::ppm_bytes(c);
                    out.write(data.data(), std::streamsize(data.size()));
                    if (!out)
                        throw std::runtime_error("capture write failed");
                    std::cerr << "CAPTURE " << n.str() << " frame=" << c.source_frame
                              << " roi=" << c.roi_id << " width=" << c.w << " height=" << c.h
                              << '\n';
                    if (capture_index == capture_limit)
                        std::cerr << "CAPTURE_LIMIT reached=" << capture_limit
                                  << " inference_continues=1\n";
                }
                if (simulated && action_index < actions.size())
                    action = actions[action_index++];
            }
            if (simulated) {
                roi::Result r;
                r.flags = roi::kSimulated;
                std::istringstream s(action);
                std::string name;
                s >> name;
                if (name == "delay") {
                    unsigned delay = 0;
                    if (!(s >> delay) || delay > 10000)
                        return r;
                    std::this_thread::sleep_for(std::chrono::milliseconds(std::min(delay, budget)));
                    if (delay >= budget) {
                        r.status = roi::InferenceTimeout;
                        return r;
                    }
                    s >> name;
                }
                if (name == "none") {
                    r.status = roi::Ok;
                    r.decision = roi::kNoBird;
                } else if (name == "bird") {
                    double score = 0;
                    std::string trailing;
                    if (!(s >> score) || !std::isfinite(score) || score < 0 || score > 1 ||
                        (s >> trailing))
                        return r;
                    r.status = roi::Ok;
                    r.decision = roi::kBird;
                    r.confidence = uint8_t(std::lround(score * 100));
                    if (score < 0.80)
                        r.confidence = std::min<uint8_t>(r.confidence, 79);
                } else if (name == "timeout")
                    r.status = roi::InferenceTimeout;
                return r;
            }
#ifndef _WIN32
            return persistent ? residents[index]->run(c, budget)
                              : roi::run_worker(c, worker, model, scratch, budget);
#else
            (void)index;
            throw std::runtime_error("RKNN worker requires Linux RV1126B");
#endif
        };
        std::unique_ptr<roi::Transport> io;
        if (stdio)
            io = roi::stdio_transport();
#ifndef _WIN32
        else if (mmap_uart) {
#if defined(__GNUC__)
            if (!roi::mmap_serial_transport)
                throw std::runtime_error("mmap transport is unavailable");
            io = roi::mmap_serial_transport(device);
#else
            throw std::runtime_error("mmap transport is unavailable");
#endif
        } else if (fixed_baud) {
#if defined(__GNUC__)
            if (!roi::serial_transport_fixed)
                throw std::runtime_error("fixed-baud platform not linked");
#endif
            io = roi::serial_transport_fixed(device, baud);
        } else
            io = roi::serial_transport(device, baud);
#else
        else
            throw std::runtime_error("physical UART access not provided by Windows test build");
#endif
        std::signal(SIGINT, on_signal);
        std::signal(SIGTERM, on_signal);
#ifndef _WIN32
        std::signal(SIGPIPE, SIG_IGN);
#endif
        roi::AsyncConfig cfg;
        cfg.workers = workers;
        cfg.capacity = capacity;
        cfg.worker_ms = worker_ms;
        cfg.request_ms = request_ms - reply_delay_ms;
        cfg.simulated = simulated;
        roi::AsyncService service(cfg, infer);
        roi::Parser parser;
        parser.lenient_crc = lenient_crc;
        std::deque<Outgoing> outgoing;
        uint8_t buffer[4096];
        uint64_t requests = 0, rx_bytes = 0, tx_bytes = 0, rxstat_next = 0;
        bool input_closed = false;
        std::cerr << "BIRD_ASYNC workers=" << workers << " queue_depth=" << capacity
                  << " request_ms=" << request_ms << " worker_ms=" << worker_ms
                  << " persistent=" << persistent << " strict_crc=" << !lenient_crc << '\n';
        std::cerr << "RESULT_EXT " << roi::g_result_ext
                  << " body_bytes=" << (roi::g_result_ext ? 16 : 8) << '\n';
        auto enqueue = [&](roi::Bytes reply, uint32_t sid, uint32_t rid, uint64_t due,
                           uint64_t deadline) {
            if (reply.empty())
                return;
            if (outgoing.size() >= 64)
                throw std::runtime_error(
                    "bounded reply queue saturated: peer flooding or output stalled");
            outgoing.push_back(Outgoing{std::move(reply), 0, sid, rid, due, deadline, repeats});
        };
        while (!stopping) {
            uint64_t now = roi::monotonic_ms();
            parser.expire(now);
            if (!input_closed) {
                int n = io->read_some(buffer, sizeof(buffer), 2);
                if (n < 0)
                    input_closed = true;
                else if (n > 0) {
                    rx_bytes += uint64_t(n);
                    now = roi::monotonic_ms();
                    for (const auto &packet : parser.feed(buffer, size_t(n), now)) {
                        if (packet.type != roi::kImage)
                            continue;
                        auto reply = service.submit(packet, now);
                        ++requests;
                        std::cerr << "REQUEST t_ms=" << now << " session=" << packet.session
                                  << " request=" << packet.request
                                  << " bytes=" << packet.body.size() << '\n';
                        enqueue(std::move(reply), packet.session, packet.request, now,
                                now + request_ms);
                        if (max_requests && requests >= max_requests) {
                            input_closed = true;
                            break;
                        }
                    }
                }
            }
            roi::Completion c;
            while (service.pop(c)) {
                const uint64_t due = roi::monotonic_ms() + reply_delay_ms;
                std::cerr << "PERF session=" << c.packet.session << " request=" << c.packet.request
                          << " queue_ms=" << c.queue_ms << " worker_ms=" << c.worker_ms
                          << " total_ms=" << c.total_ms << " reason=" << c.reason << '\n';
                enqueue(std::move(c.reply), c.packet.session, c.packet.request, due,
                        c.received_ms + request_ms);
            }
            now = roi::monotonic_ms();
            if (!outgoing.empty() && now >= outgoing.front().due) {
                auto &out = outgoing.front();
                if (!out.offset && now >= out.deadline) {
                    roi::Result timeout;
                    timeout.status = roi::InferenceTimeout;
                    if (simulated)
                        timeout.flags = roi::kSimulated;
                    out.bytes = roi::encode(roi::Packet{roi::kResult, out.session, out.request,
                                                        roi::result_body(timeout)});
                    out.deadline = now + 500;
                    out.repeats = 1;
                }
                if (now >= out.deadline)
                    throw std::runtime_error("reply transport stalled past bounded deadline");
                const int n =
                    io->write_some(out.bytes.data() + out.offset, out.bytes.size() - out.offset);
                if (n < 0 || size_t(n) > out.bytes.size() - out.offset)
                    throw std::runtime_error("reply transport disconnected");
                out.offset += size_t(n);
                tx_bytes += uint64_t(n);
                if (out.offset == out.bytes.size()) {
                    std::cerr << "REPLYSENT session=" << out.session << " request=" << out.request
                              << " status=" << unsigned(out.bytes[16])
                              << " decision=" << unsigned(out.bytes[17]) << " t_ms=" << now << '\n';
                    if (--out.repeats) {
                        out.offset = 0;
                        out.due = now + 1;
                    } else
                        outgoing.pop_front();
                }
            }
            if (now >= rxstat_next) {
                rxstat_next = now + 5000;
                auto stats = service.stats();
                std::cerr << "RXSTAT bytes=" << rx_bytes << " packets=" << parser.stats.packets
                          << " bad_header=" << parser.stats.bad_header
                          << " bad_crc=" << parser.stats.bad_crc << " noise=" << parser.stats.noise
                          << " timeouts=" << parser.stats.timeouts
                          << " crc_repaired=" << parser.stats.crc_repaired
                          << " peak_pending=" << stats.peak_pending
                          << " overload=" << stats.overload << '\n';
            }
            if (input_closed && !service.busy() && outgoing.empty())
                break;
            if (input_closed)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        service.stop();
        auto stats = service.stats();
        std::cerr << "SUMMARY requests=" << requests << " accepted=" << stats.accepted
                  << " completed=" << stats.completed
                  << " inference_calls=" << stats.inference_calls
                  << " cache_hits=" << stats.cache_hits
                  << " duplicate_pending=" << stats.duplicate_pending
                  << " overload=" << stats.overload << " expired=" << stats.expired
                  << " conflicts=" << stats.conflicts << " cancelled=" << stats.cancelled
                  << " peak_pending=" << stats.peak_pending
                  << " peak_running=" << stats.peak_running << " rx_bytes=" << rx_bytes
                  << " tx_bytes=" << tx_bytes << " bad_crc=" << parser.stats.bad_crc
                  << " incomplete_bytes=" << parser.buffered() << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "BRIDGE_ERROR " << e.what() << '\n';
        return 2;
    }
}
