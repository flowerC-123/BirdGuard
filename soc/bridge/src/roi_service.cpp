#include "roi_service.hpp"
#include <cstdio>
#include <cstdlib>
#include <sstream>
#include <cmath>
#include <algorithm>
#include <map>
#include <stdexcept>
#include <limits>
namespace roi {

static double bird_min_conf() {
    const char *e = std::getenv("BIRD_CONF_MIN");
    if (e && *e) {
        try {
            const double v = std::stod(e);
            if (v >= 0.05 && v < 1.0)
                return v;
        } catch (const std::exception &) {
        }
    }
    return 0.30;
}
// Accepted bird detections use the FPGA display range 80..100.
static uint8_t map_conf(double best, double lo) {
    double m = (best - lo) / (1.0 - lo);
    if (!std::isfinite(m))
        m = 0;
    if (m < 0)
        m = 0;
    if (m > 1)
        m = 1;
    double v = std::lround(80.0 + m * 20.0);
    if (v < 80)
        v = 80;
    if (v > 100)
        v = 100;
    return uint8_t(v);
}

static int g_stale_log_left = 8;
Bytes Service::handle(const Packet &p) {
    if (p.type != kImage)
        return {};
    Result r;
    Crop c;
    std::string why;
    auto reply = [&](Result x) {
        if (simulated_)
            x.flags |= kSimulated;
        return encode(Packet{kResult, p.session, p.request, result_body(x)});
    };
    if (p.session == session_ && p.request == request_) {
        if (p.body == last_body_) {
            ++cache_hits;
            return last_reply_;
        }
        ++rejected;
        r.status = BadRequest;
        return reply(r);
    }

    if (p.session == session_ && p.request < request_ && g_stale_log_left > 0) {
        fprintf(stderr,
                "REQBACK session=0x%08x request=0x%08x < prev=0x%08x "
                "(request accepted as a new transaction)\n",
                p.session, p.request, request_);
        --g_stale_log_left;
    }
    if (!decode_crop(p.body, c, why)) {
        ++rejected;
        r.status = (why == "unsupported_format") ? Unsupported : BadRequest;
    } else {
        ++inference_calls;
        try {
            r = infer_(c);
            Result checked;
            if (!decode_result(result_body(r), checked))
                r = Result{};
        } catch (const std::exception &) {
            r = Result{};
        }
    }

    // Transform crop coordinates to the display grid with outward rounding.
    bool geom = r.has_box && r.status == Ok && r.decision == kBird && r.confidence >= 80 &&
                r.confidence <= 100 && r.flags == 0 && c.w && c.h && c.source_w && c.source_h;
    if (geom) {
        int64_t ew = c.w, eh = c.h, l = r.box_x, t = r.box_y, rr = int64_t(r.box_x) + r.box_w,
                bb = int64_t(r.box_y) + r.box_h;
        if (r.worker_box) {
            l = r.worker_l;
            t = r.worker_t;
            rr = int64_t(r.worker_r) + 1;
            bb = int64_t(r.worker_b) + 1;
            if (r.worker_enhanced) {
                geom = r.worker_iw == c.w && r.worker_ih == c.h && r.worker_ow && r.worker_oh;
                ew = r.worker_ow;
                eh = r.worker_oh;
            }
        }
        if (geom) {
            l = std::max<int64_t>(0, std::min(ew, l));
            rr = std::max<int64_t>(0, std::min(ew, rr));
            t = std::max<int64_t>(0, std::min(eh, t));
            bb = std::max<int64_t>(0, std::min(eh, bb));
            geom = rr > l && bb > t;
            if (geom) {
                const uint64_t dx = uint64_t(ew) * c.source_w, dy = uint64_t(eh) * c.source_h;
                const uint64_t x0 = (uint64_t(c.x) * ew + uint64_t(l) * c.w) * 320 / dx;
                const uint64_t y0 = (uint64_t(c.y) * eh + uint64_t(t) * c.h) * 240 / dy;
                const uint64_t x1 = ((uint64_t(c.x) * ew + uint64_t(rr) * c.w) * 320 + dx - 1) / dx;
                const uint64_t y1 = ((uint64_t(c.y) * eh + uint64_t(bb) * c.h) * 240 + dy - 1) / dy;
                geom = x1 > x0 && y1 > y0 && x1 <= 320 && y1 <= 240;
                if (geom) {
                    r.box_x = uint16_t(x0);
                    r.box_y = uint16_t(y0);
                    r.box_w = uint16_t(x1 - x0);
                    r.box_h = uint16_t(y1 - y0);
                }
            }
        }
    }
    if (!geom) {
        r.has_box = false;
        r.box_x = r.box_y = r.box_w = r.box_h = 0;
    }
    auto bytes = reply(r);
    session_ = p.session;
    request_ = p.request;
    last_body_ = p.body;
    last_reply_ = bytes;
    return bytes;
}
static std::map<std::string, std::string> fields(const std::string &line) {
    std::istringstream s(line);
    std::string word;
    std::map<std::string, std::string> m;
    while (s >> word) {
        auto at = word.find('=');
        if (at != std::string::npos)
            m[word.substr(0, at)] = word.substr(at + 1);
    }
    return m;
}
static long integer(const std::string &s) {
    size_t p = 0;
    long n = std::stol(s, &p);
    if (p != s.size())
        throw std::invalid_argument("integer");
    return n;
}
Result worker_result(int exit_code, const std::string &log) {
    Result r;
    if (exit_code != 0)
        return r;
    try {
        std::istringstream stream(log);
        std::string line;
        int count = 0, birds = 0, summary = 0;
        double best = 0;
        bool have_box = false, enhanced = false, scale_ok = true;
        unsigned enhance_count = 0;
        int64_t box_l = 0, box_t = 0, box_r = 0, box_b = 0, iw = 0, ih = 0, ow = 0, oh = 0;
        while (std::getline(stream, line)) {
            if (line.compare(0, 10, "DETECTION ") == 0) {
                if (summary != 0 || count >= 128)
                    return Result{};
                auto f = fields(line);
                long id = integer(f.at("class_id"));
                size_t end = 0;
                double confidence = std::stod(f.at("confidence"), &end);
                if (end != f.at("confidence").size() || id < 0 || id >= 80 ||
                    !std::isfinite(confidence) || confidence < 0 || confidence > 1)
                    return Result{};
                ++count;
                if (id == 14) {
                    ++birds;
                    if (confidence >= best) {
                        best = confidence;
                        have_box = false;
                        try {
                            int64_t L = integer(f.at("left")), T = integer(f.at("top")),
                                    R = integer(f.at("right")), B = integer(f.at("bottom"));
                            if (R >= L && B >= T && L >= -1048576 && T >= -1048576 &&
                                R <= 1048576 && B <= 1048576) {
                                box_l = L;
                                box_t = T;
                                box_r = R;
                                box_b = B;
                                have_box = true;
                            }
                        } catch (const std::exception &) {
                        }
                    }
                }
            } else if (line.compare(0, 8, "ENHANCE ") == 0) {
                enhanced = true;
                ++enhance_count;
                const auto at = line.find("input=");
                char sx = 0, sy = 0;
                std::string arrow;
                if (at == std::string::npos) {
                    scale_ok = false;
                    continue;
                }
                std::istringstream dims(line.substr(at + 6));
                if (!(dims >> iw >> sx >> ih >> arrow >> ow >> sy >> oh) || sx != 'x' ||
                    sy != 'x' || arrow != "->" || iw <= 0 || ih <= 0 || ow <= 0 || oh <= 0 ||
                    iw > 65535 || ih > 65535 || ow > 65535 || oh > 65535 || enhance_count != 1)
                    scale_ok = false;
            } else if (line.compare(0, 7, "RESULT ") == 0) {
                auto f = fields(line);
                ++summary;
                if (integer(f.at("run_return")) != 0 || integer(f.at("count")) != count ||
                    integer(f.at("bird_count")) != birds)
                    return Result{};
                if ((count == 0 && f.at("status") != "NO_DETECTIONS") ||
                    (count > 0 && f.at("status") != "DETECTIONS"))
                    return Result{};
            }
        }
        if (summary != 1)
            return r;
        r.status = Ok;
        if (birds && best >= bird_min_conf()) {
            r.decision = kBird;
            r.confidence = map_conf(best, bird_min_conf());
        } else {
            r.decision = kNoBird;
            r.confidence = kUnknown;
        }
        if (birds && best >= 0.80 && have_box && scale_ok) {
            const int64_t dw = enhanced ? ow : 1, dh = enhanced ? oh : 1, nw = enhanced ? iw : 1,
                          nh = enhanced ? ih : 1;
            const int64_t maxx = enhanced ? ow : 65535, maxy = enhanced ? oh : 65535;
            const int64_t l = std::max<int64_t>(0, std::min(maxx, box_l)),
                          rr = std::max<int64_t>(0, std::min(maxx, box_r + 1));
            const int64_t t = std::max<int64_t>(0, std::min(maxy, box_t)),
                          bb = std::max<int64_t>(0, std::min(maxy, box_b + 1));
            if (rr > l && bb > t) {
                const int64_t x0 = l * nw / dw, y0 = t * nh / dh, x1 = (rr * nw + dw - 1) / dw,
                              y1 = (bb * nh + dh - 1) / dh;
                if (x1 > x0 && y1 > y0 && x1 <= 65535 && y1 <= 65535) {
                    r.has_box = true;
                    r.box_x = uint16_t(x0);
                    r.box_y = uint16_t(y0);
                    r.box_w = uint16_t(x1 - x0);
                    r.box_h = uint16_t(y1 - y0);
                    r.worker_box = true;
                    r.worker_enhanced = enhanced;
                    r.worker_l = int32_t(box_l);
                    r.worker_t = int32_t(box_t);
                    r.worker_r = int32_t(box_r);
                    r.worker_b = int32_t(box_b);
                    r.worker_iw = uint32_t(iw);
                    r.worker_ih = uint32_t(ih);
                    r.worker_ow = uint32_t(ow);
                    r.worker_oh = uint32_t(oh);
                }
            }
        }
    } catch (const std::exception &) {
        return Result{};
    }
    return r;
}
} // namespace roi
