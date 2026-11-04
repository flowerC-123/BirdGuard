#pragma once
#include <cstdint>
#include <vector>
#include <string>
namespace roi {
using Bytes = std::vector<uint8_t>;
constexpr uint8_t kVersion = 1, kImage = 1, kResult = 0x81, kGray8 = 1, kRgb888 = 2;
constexpr size_t kCropMeta = 20, kMaxPixelsBytes = 16384, kMaxBody = kCropMeta + kMaxPixelsBytes;
constexpr uint64_t kGapMs = 250, kReceiveMs = 2500, kReplyMs = 6000;
constexpr uint8_t kSimulated = 1, kUnknown = 255, kNoBird = 0, kBird = 1;
enum Status : uint8_t {
    Ok = 0,
    BadRequest = 1,
    InferenceError = 2,
    Unsupported = 3,
    InferenceTimeout = 4,
    StaleRequest = 5
};
struct Packet {
    uint8_t type = 0;
    uint32_t session = 0, request = 0;
    Bytes body;
};
struct Crop {
    uint32_t source_frame = 0;
    uint16_t roi_id = 0, source_w = 0, source_h = 0, x = 0, y = 0, w = 0, h = 0;
    uint8_t format = 0;
    Bytes pixels;
};
struct Result {
    uint8_t status = InferenceError, decision = kUnknown, confidence = kUnknown, flags = 0;
    uint32_t processing_ms = 0;

    uint16_t box_x = 0, box_y = 0, box_w = 0, box_h = 0;
    bool has_box = false;

    bool worker_box = false, worker_enhanced = false;
    int32_t worker_l = 0, worker_t = 0, worker_r = 0, worker_b = 0;
    uint32_t worker_iw = 0, worker_ih = 0, worker_ow = 0, worker_oh = 0;
};

extern bool g_result_ext;
constexpr size_t kResultBodyV1 = 8, kResultBodyV2 = 16;
uint16_t crc16(const uint8_t *data, size_t n);
uint16_t get16(const Bytes &, size_t);
uint32_t get32(const Bytes &, size_t);
void put16(Bytes &, uint16_t);
void put32(Bytes &, uint32_t);
Bytes encode(const Packet &);
Bytes crop_body(const Crop &);
bool decode_crop(const Bytes &, Crop &, std::string &);
Bytes rgb_pixels(const Crop &);
Bytes result_body(const Result &);
bool decode_result(const Bytes &, Result &);
struct ParserStats {
    uint64_t packets = 0, noise = 0, bad_header = 0, bad_crc = 0, timeouts = 0, crc_repaired = 0;
};
class Parser {
    Bytes buffer_;
    uint64_t start_ = 0, last_ = 0;
    void drain(uint64_t, std::vector<Packet> &);

  public:
    ParserStats stats;

    bool lenient_crc = false;
    std::vector<Packet> feed(const uint8_t *, size_t, uint64_t now_ms);
    void expire(uint64_t now_ms);
    size_t buffered() const { return buffer_.size(); }
};
class ReplyGate {
    uint32_t session_ = 0, request_ = 0;
    uint64_t sent_ = 0;
    bool active_ = false, allow_sim_ = false;

  public:
    explicit ReplyGate(bool allow_simulated = false) : allow_sim_(allow_simulated) {}
    void begin(uint32_t s, uint32_t q, uint64_t final_tx_stop_bit_ms) {
        session_ = s;
        request_ = q;
        sent_ = final_tx_stop_bit_ms;
        active_ = true;
    }
    bool expire(uint64_t now) {
        if (active_ && now - sent_ >= kReplyMs) {
            active_ = false;
            return true;
        }
        return false;
    }
    bool accept(const Packet &, uint64_t, Result &);
    bool active() const { return active_; }
};
} // namespace roi
