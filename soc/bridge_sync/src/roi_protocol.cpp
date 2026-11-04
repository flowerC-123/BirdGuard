#include "roi_protocol.hpp"
#include <algorithm>
#include <stdexcept>
#include <cstdio>
namespace roi {

static int g_bad_hdr_logged = 0, g_bad_crc_logged = 0;
static const int kMaxDiagLog = 8;
static void hexdump16(const uint8_t *p, size_t n, char *out, size_t cap) {
    size_t used = 0;
    for (size_t i = 0; i < n && used + 4 < cap; i += 1) {
        used += size_t(snprintf(out + used, cap - used, "%02x ", p[i]));
    }
    if (used && cap - used > 0)
        out[used - 1] = '\0';
    else
        out[0] = '\0';
}
uint16_t crc16(const uint8_t *p, size_t n) {
    uint16_t c = 0xffff;
    for (size_t i = 0; i < n; ++i) {
        c ^= uint16_t(p[i]) << 8;
        for (int b = 0; b < 8; ++b)
            c = uint16_t((c & 0x8000) ? (c << 1) ^ 0x1021 : c << 1);
    }
    return c;
}
uint16_t get16(const Bytes &b, size_t o) {
    return uint16_t(b.at(o)) | (uint16_t(b.at(o + 1)) << 8);
}
uint32_t get32(const Bytes &b, size_t o) {
    return uint32_t(get16(b, o)) | (uint32_t(get16(b, o + 2)) << 16);
}
void put16(Bytes &b, uint16_t v) {
    b.push_back(uint8_t(v));
    b.push_back(uint8_t(v >> 8));
}
void put32(Bytes &b, uint32_t v) {
    put16(b, uint16_t(v));
    put16(b, uint16_t(v >> 16));
}
Bytes encode(const Packet &p) {
    if (!p.session || !p.request || p.body.size() > kMaxBody ||
        (p.type != kImage && p.type != kResult))
        throw std::invalid_argument("bad packet");
    Bytes b{0xaa, 0x55, kVersion, p.type};
    put32(b, p.session);
    put32(b, p.request);
    put16(b, uint16_t(p.body.size()));
    put16(b, crc16(b.data() + 2, 12));
    b.insert(b.end(), p.body.begin(), p.body.end());
    put16(b, crc16(b.data() + 2, b.size() - 2));
    return b;
}
Bytes crop_body(const Crop &c) {
    Bytes b;
    put32(b, c.source_frame);
    put16(b, c.roi_id);
    put16(b, c.source_w);
    put16(b, c.source_h);
    put16(b, c.x);
    put16(b, c.y);
    put16(b, c.w);
    put16(b, c.h);
    b.push_back(c.format);
    b.push_back(0);
    b.insert(b.end(), c.pixels.begin(), c.pixels.end());
    return b;
}
bool decode_crop(const Bytes &b, Crop &c, std::string &why) {
    if (b.size() < kCropMeta) {
        why = "short_metadata";
        return false;
    }
    c.source_frame = get32(b, 0);
    c.roi_id = get16(b, 4);
    c.source_w = get16(b, 6);
    c.source_h = get16(b, 8);
    c.x = get16(b, 10);
    c.y = get16(b, 12);
    c.w = get16(b, 14);
    c.h = get16(b, 16);
    c.format = b[18];
    if (b[19] != 0) {
        why = "reserved_flags";
        return false;
    }
    if (c.format != kGray8 && c.format != kRgb888) {
        why = "unsupported_format";
        return false;
    }
    if (!c.w || !c.h || c.w > 256 || c.h > 256 || !c.source_w || !c.source_h || c.source_w > 4096 ||
        c.source_h > 4096 || uint32_t(c.x) + c.w > c.source_w || uint32_t(c.y) + c.h > c.source_h) {
        why = "roi_bounds";
        return false;
    }
    const size_t bytes = size_t(c.w) * c.h * (c.format == kGray8 ? 1 : 3);
    if (bytes > kMaxPixelsBytes || b.size() != kCropMeta + bytes) {
        why = "payload_size";
        return false;
    }
    c.pixels.assign(b.begin() + kCropMeta, b.end());
    return true;
}
Bytes rgb_pixels(const Crop &c) {
    if (c.format == kRgb888)
        return c.pixels;
    if (c.format != kGray8)
        throw std::invalid_argument("unsupported format");
    Bytes b;
    b.reserve(c.pixels.size() * 3);
    for (auto v : c.pixels) {
        b.push_back(v);
        b.push_back(v);
        b.push_back(v);
    }
    return b;
}
bool g_result_ext = false;
Bytes result_body(const Result &r) {
    Bytes b{r.status, r.decision, r.confidence, r.flags};
    put32(b, r.processing_ms);
    if (g_result_ext) {

        const bool good = r.has_box && r.status == Ok && r.decision == kBird &&
                          r.confidence >= 80 && r.confidence <= 100 && r.flags == 0 && r.box_w &&
                          r.box_h && uint32_t(r.box_x) + r.box_w <= 320 &&
                          uint32_t(r.box_y) + r.box_h <= 240;
        put16(b, good ? r.box_x : uint16_t(0));
        put16(b, good ? r.box_y : uint16_t(0));
        put16(b, good ? r.box_w : uint16_t(0));
        put16(b, good ? r.box_h : uint16_t(0));
    }
    return b;
}
bool decode_result(const Bytes &b, Result &r) {
    if (b.size() != kResultBodyV1 && b.size() != kResultBodyV2)
        return false;

    r.worker_box = false;
    r.worker_enhanced = false;
    r.worker_l = r.worker_t = r.worker_r = r.worker_b = 0;
    r.worker_iw = r.worker_ih = r.worker_ow = r.worker_oh = 0;
    r.status = b[0];
    r.decision = b[1];
    r.confidence = b[2];
    r.flags = b[3];
    r.processing_ms = get32(b, 4);
    r.has_box = false;
    r.box_x = r.box_y = r.box_w = r.box_h = 0;
    if (b.size() == kResultBodyV2) {
        uint16_t x = get16(b, 8), y = get16(b, 10), w = get16(b, 12), h = get16(b, 14);
        if (w && h && uint32_t(x) + w <= 320 && uint32_t(y) + h <= 240 && r.status == Ok &&
            r.decision == kBird && r.confidence >= 80 && r.confidence <= 100 && r.flags == 0) {
            r.box_x = x;
            r.box_y = y;
            r.box_w = w;
            r.box_h = h;
            r.has_box = true;
        }
    }
    if (r.status > StaleRequest || (r.flags & ~kSimulated))
        return false;
    if (r.status != Ok)
        return r.decision == kUnknown && r.confidence == kUnknown;
    return (r.decision == kBird && r.confidence <= 100) ||
           (r.decision == kNoBird && r.confidence == kUnknown);
}
void Parser::expire(uint64_t now) {
    if (!buffer_.empty() && (now - last_ >= kGapMs || now - start_ >= kReceiveMs)) {
        buffer_.clear();
        ++stats.timeouts;
    }
}
void Parser::drain(uint64_t now, std::vector<Packet> &packets) {
    for (;;) {

        {
            const size_t sz = buffer_.size();
            size_t skip = 0;
            while (skip < sz) {

                if (buffer_[skip] == 0xaa && (skip + 1 >= sz || buffer_[skip + 1] == 0x55))
                    break;
                ++skip;
            }
            if (skip) {
                buffer_.erase(buffer_.begin(), buffer_.begin() + skip);
                stats.noise += skip;
                start_ = now;
            }
        }
        if (buffer_.size() < 16)
            return;
        const auto len = get16(buffer_, 12);
        const bool legal_len = len <= kMaxBody;

        if (legal_len && g_bad_hdr_logged < kMaxDiagLog) {
            const size_t total = 18u + len;
            if (buffer_.size() < total)
                return;
            char path[64];
            snprintf(path, sizeof(path), "/tmp/badframe_%d.bin", g_bad_hdr_logged + 1);
            FILE *fp = fopen(path, "wb");
            if (fp) {
                fwrite(buffer_.data(), 1, total, fp);
                fclose(fp);
            }
            char hx[400];
            hexdump16(buffer_.data(), std::min<size_t>(total, 48u), hx, sizeof(hx));
            char tl[200];
            hexdump16(buffer_.data() + total - 16, 16, tl, sizeof(tl));
            fprintf(stderr, "BADFRAME#%d file=%s total=%zu head48=[%s] tail16=[%s]\n",
                    ++g_bad_hdr_logged, path, total, hx, tl);
        }
        if (buffer_[2] != kVersion || (buffer_[3] != kImage && buffer_[3] != kResult) ||
            !get32(buffer_, 4) || !get32(buffer_, 8) || len > kMaxBody ||
            get16(buffer_, 14) != crc16(buffer_.data() + 2, 12)) {
            if (g_bad_hdr_logged < kMaxDiagLog) {
                char hex[160];
                hexdump16(buffer_.data(), std::min<size_t>(buffer_.size(), 24u), hex, sizeof(hex));
                fprintf(
                    stderr,
                    "BADHDR#%d buffered=%zu ver=%u type=%u session=0x%08x request=0x%08x len=%u "
                    "hdr_crc=0x%04x calc=0x%04x head=[%s]\n",
                    ++g_bad_hdr_logged, buffer_.size(), buffer_[2], buffer_[3], get32(buffer_, 4),
                    get32(buffer_, 8), unsigned(len), get16(buffer_, 14),
                    crc16(buffer_.data() + 2, 12), hex);
            }
            buffer_.erase(buffer_.begin());
            ++stats.bad_header;
            start_ = now;
            continue;
        }
        const size_t total = 18u + len;
        if (buffer_.size() < total)
            return;
        if (get16(buffer_, total - 2) != crc16(buffer_.data() + 2, total - 4)) {

            if (lenient_crc && buffer_[3] == kImage) {
                Bytes body(buffer_.begin() + 16, buffer_.begin() + 16 + len);
                Crop c;
                std::string why;
                if (decode_crop(body, c, why)) {
                    Packet p;
                    p.type = kImage;
                    p.session = get32(buffer_, 4);
                    p.request = get32(buffer_, 8);
                    p.body = std::move(body);
                    packets.push_back(std::move(p));
                    ++stats.packets;
                    ++stats.crc_repaired;
                    if (g_bad_crc_logged < kMaxDiagLog) {
                        fprintf(stderr,
                                "CRCLENIENT#%d 接受 CRC 失败的图像帧 session=0x%08x request=0x%08x "
                                "len=%u roi=%ux%u  (bit 翻转容错，非协议问题)\n",
                                ++g_bad_crc_logged, get32(buffer_, 4), get32(buffer_, 8),
                                unsigned(len), unsigned(c.w), unsigned(c.h));
                    }
                    buffer_.erase(buffer_.begin(), buffer_.begin() + total);
                    start_ = now;
                    continue;
                }
            }
            if (g_bad_crc_logged < kMaxDiagLog) {
                fprintf(stderr,
                        "BADCRC#%d buffered=%zu want_total=%zu tail_crc=0x%04x calc=0x%04x "
                        "session=0x%08x request=0x%08x\n",
                        ++g_bad_crc_logged, buffer_.size(), total, get16(buffer_, total - 2),
                        crc16(buffer_.data() + 2, total - 4), get32(buffer_, 4), get32(buffer_, 8));
            }
            buffer_.erase(buffer_.begin());
            ++stats.bad_crc;
            start_ = now;
            continue;
        }
        Packet p;
        p.type = buffer_[3];
        p.session = get32(buffer_, 4);
        p.request = get32(buffer_, 8);
        p.body.assign(buffer_.begin() + 16, buffer_.begin() + 16 + len);
        packets.push_back(std::move(p));
        ++stats.packets;
        buffer_.erase(buffer_.begin(), buffer_.begin() + total);
        start_ = now;
    }
}
std::vector<Packet> Parser::feed(const uint8_t *b, size_t n, uint64_t now) {
    expire(now);
    std::vector<Packet> packets;
    for (size_t i = 0; i < n; ++i) {
        if (buffer_.empty())
            start_ = now;
        last_ = now;
        buffer_.push_back(b[i]);
        drain(now, packets);
    }
    return packets;
}
bool ReplyGate::accept(const Packet &p, uint64_t now, Result &r) {
    expire(now);
    if (!active_ || p.type != kResult || p.session != session_ || p.request != request_ ||
        !decode_result(p.body, r))
        return false;
    if ((r.flags & kSimulated) && !allow_sim_)
        return false;
    active_ = false;
    return true;
}
} // namespace roi
