#include "platform.hpp"
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
namespace fs = std::filesystem;
static volatile std::sig_atomic_t stopping = 0;
static void on_signal(int) { stopping = 1; }
static unsigned number(const std::string &s) {
    size_t at = 0;
    auto n = std::stoul(s, &at);
    if (at != s.size() || n > 0xffffffffu)
        throw std::invalid_argument("invalid integer");
    return unsigned(n);
}
int main(int argc, char **argv) {
    try {
        bool stdio = false;
        std::string device, mock, worker, model, scratch, capture;
        unsigned baud = 115200, worker_ms = 5000, max_requests = 0, reply_delay_ms = 0;
        bool lenient_crc = false;

        if (const char *e = std::getenv("ROI_RESULT_EXT"))
            roi::g_result_ext = (e[0] != '0' && e[0] != '\0');

        bool mmap_uart = false;
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

            if (k == "--lenient-crc") {
                lenient_crc = true;
                continue;
            }
            if (k == "--result-ext") {
                roi::g_result_ext = true;
                continue;
            }
            if (k == "--help") {
                std::cerr
                    << "soc_uart_bridge (--stdio --mock-script FILE | --device TTY --worker EXE "
                       "--model RKNN --scratch DIR) [--baud 115200|921600] [--worker-ms 5000] "
                       "[--capture-dir NEW_DIR] [--max-requests N] [--reply-delay-ms 0]\n";
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
            else
                throw std::invalid_argument("unknown option");
        }
        if (stdio == !device.empty())
            throw std::invalid_argument("choose exactly one transport; no default serial device");
        if (worker_ms < 100 || worker_ms > 5000)
            throw std::invalid_argument(
                "worker-ms must be 100..5000; larger values require protocol budget revision");
        const bool simulated = !mock.empty();
        if (simulated && (!stdio || !worker.empty() || !model.empty()))
            throw std::invalid_argument("mock allowed only on stdio, without a real worker");
        if (!simulated && (worker.empty() || model.empty() || scratch.empty()))
            throw std::invalid_argument("explicit worker/model/scratch required");
        std::vector<std::string> actions;
        size_t action_index = 0, capture_index = 0;
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
        auto infer = [&](const roi::Crop &c) {
            if (!capture.empty()) {
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
                          << " format=" << unsigned(c.format)
                          << " payload_crc=" << roi::crc16(c.pixels.data(), c.pixels.size())
                          << '\n';
            }
            if (simulated) {
                roi::Result r;
                r.flags = roi::kSimulated;
                if (action_index >= actions.size())
                    return r;
                std::istringstream s(actions[action_index++]);
                std::string action;
                s >> action;
                if (action == "none") {
                    r.status = roi::Ok;
                    r.decision = roi::kNoBird;
                } else if (action == "bird") {
                    double score = 0;
                    std::string trailing;
                    if (!(s >> score) || !std::isfinite(score) || score < 0 || score > 1 ||
                        (s >> trailing))
                        return r;
                    r.status = roi::Ok;
                    r.decision = roi::kBird;
                    r.confidence = uint8_t(std::lround(score * 100));
                } else if (action == "timeout")
                    r.status = roi::InferenceTimeout;
                return r;
            }
#ifndef _WIN32
            return roi::run_worker(c, worker, model, scratch, worker_ms);
#else
            throw std::runtime_error(
                "RKNN worker requires Linux RV1126B; Windows is protocol simulation only");
#endif
        };
        std::unique_ptr<roi::Transport> io;
        std::cerr << "RESULT_EXT " << (roi::g_result_ext ? 1 : 0)
                  << " body_bytes=" << (roi::g_result_ext ? 16 : 8)
                  << " (仅当 FPGA roi_result_rx.v 已放开 body_len 校验时才应为 1)\n";
        if (stdio)
            io = roi::stdio_transport();
#ifndef _WIN32
        else
            io = mmap_uart ? roi::mmap_serial_transport(device)
                           : roi::serial_transport(device, baud);
#else
        else
            throw std::runtime_error(
                "physical UART access not provided by this Windows test build");
#endif
        std::signal(SIGINT, on_signal);
        std::signal(SIGTERM, on_signal);
#ifndef _WIN32
        std::signal(SIGPIPE, SIG_IGN);
#endif
        roi::Parser parser;
        parser.lenient_crc = lenient_crc;
        roi::Service service(infer, simulated);
        uint64_t requests = 0;
        uint8_t buffer[1024];

        uint64_t rx_bytes = 0, rx_reads = 0, rxstat_next = roi::monotonic_ms() + 5000;
        while (!stopping) {
            int n = io->read_some(buffer, sizeof(buffer), 20);
            const uint64_t now = roi::monotonic_ms();
            parser.expire(now);
            if (n < 0)
                break;
            if (n == 0) {
            }
            if (n > 0) {
                rx_bytes += uint64_t(n);
                ++rx_reads;
            }
            if (now >= rxstat_next) {
                rxstat_next = now + 5000;
                std::cerr << "RXSTAT bytes=" << rx_bytes << " reads=" << rx_reads
                          << " packets=" << parser.stats.packets
                          << " bad_header=" << parser.stats.bad_header
                          << " bad_crc=" << parser.stats.bad_crc << " noise=" << parser.stats.noise
                          << " timeouts=" << parser.stats.timeouts
                          << " crc_repaired=" << parser.stats.crc_repaired
                          << " buffered=" << parser.buffered() << "\n";
            }
            if (n <= 0)
                continue;
            for (const auto &packet : parser.feed(buffer, size_t(n), now)) {
                if (packet.type != roi::kImage)
                    continue;

                std::cerr << "REQUEST t=" << (now / 1000.0);
                if (packet.body.size() >= 20) {
                    std::cerr << " frame=" << roi::get32(packet.body, 0)
                              << " roi=" << roi::get16(packet.body, 4)
                              << " box=" << roi::get16(packet.body, 10) << ","
                              << roi::get16(packet.body, 12) << " " << roi::get16(packet.body, 14)
                              << "x" << roi::get16(packet.body, 16)
                              << " len=" << packet.body.size();
                } else {
                    std::cerr << " len=" << packet.body.size();
                }
                std::cerr << " session=0x" << std::hex << packet.session << std::dec
                          << " request=0x" << std::hex << packet.request << std::dec << '\n';
                auto reply = service.handle(packet);

                roi::Packet pending;
                if (!reply.empty() && reply_delay_ms) {
                    const uint64_t deadline = roi::monotonic_ms() + reply_delay_ms;
                    while (!stopping && roi::monotonic_ms() < deadline) {
                        int n = io->read_some(buffer, sizeof(buffer), 5);
                        if (n > 0) {
                            rx_bytes += uint64_t(n);
                            ++rx_reads;
                            const uint64_t t = roi::monotonic_ms();
                            parser.expire(t);
                            for (auto &p : parser.feed(buffer, size_t(n), t))
                                if (p.type == roi::kImage)
                                    pending = std::move(p);
                        }
                    }
                }

                const char *rep_env = std::getenv("REPLY_REPEAT");
                const int rep_raw = rep_env ? std::atoi(rep_env) : 3;
                const int rep_times = rep_raw > 0 ? rep_raw : 1;
                for (int rep = 0; rep < rep_times; ++rep) {
                    if (!roi::write_all(
                            reply, [&](const uint8_t *p, size_t z) { return io->write_some(p, z); },
                            roi::monotonic_ms, roi::monotonic_ms() + 1000))
                        throw std::runtime_error("reply write failure/timeout");
                    if (rep + 1 < rep_times)
                        std::this_thread::sleep_for(std::chrono::microseconds(800));
                }

                if (reply.size() >= 24)
                    std::cerr << "REPLYSENT request=0x" << std::hex << packet.request << std::dec
                              << " bytes=" << reply.size() << " status=" << unsigned(reply[16])
                              << " decision=" << unsigned(reply[17])
                              << " conf=" << unsigned(reply[18]) << " flags=" << unsigned(reply[19])

                              << (reply.size() >= 32
                                      ? " box=" +
                                            std::to_string(unsigned(reply[24]) | unsigned(reply[25])
                                                                                     << 8) +
                                            "," +
                                            std::to_string(unsigned(reply[26]) | unsigned(reply[27])
                                                                                     << 8) +
                                            " " +
                                            std::to_string(unsigned(reply[28]) | unsigned(reply[29])
                                                                                     << 8) +
                                            "x" +
                                            std::to_string(unsigned(reply[30]) | unsigned(reply[31])
                                                                                     << 8)
                                      : std::string())
                              << '\n';

                if (!pending.body.empty()) {
                    auto reply2 = service.handle(pending);
                    if (!reply2.empty()) {
                        if (!roi::write_all(
                                reply2,
                                [&](const uint8_t *p, size_t z) { return io->write_some(p, z); },
                                roi::monotonic_ms, roi::monotonic_ms() + 1000))
                            throw std::runtime_error("pending reply write failure/timeout");
                        if (reply2.size() >= 24)
                            std::cerr << "REPLYSENT(pending) request=0x" << std::hex
                                      << pending.request << std::dec << " bytes=" << reply2.size()
                                      << " status=" << unsigned(reply2[16])
                                      << " decision=" << unsigned(reply2[17])
                                      << " conf=" << unsigned(reply2[18])
                                      << " flags=" << unsigned(reply2[19]) << '\n';
                    }
                }
                ++requests;
                if (max_requests && requests >= max_requests) {
                    stopping = 1;
                    break;
                }
            }
        }
        std::cerr << "SUMMARY requests=" << requests
                  << " inference_calls=" << service.inference_calls
                  << " cache_hits=" << service.cache_hits << " rejected=" << service.rejected
                  << " bad_crc=" << parser.stats.bad_crc
                  << " bad_header=" << parser.stats.bad_header
                  << " receive_timeouts=" << parser.stats.timeouts
                  << " incomplete_bytes=" << parser.buffered() << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "BRIDGE_ERROR " << e.what() << '\n';
        return 2;
    }
}
