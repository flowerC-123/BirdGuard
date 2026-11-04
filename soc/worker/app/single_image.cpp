#include "yolov8.h"
#include "model_contract.hpp"
#include <chrono>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>

int yolov8_detect_run(rknn_app_context_t *, cv::Mat, detect_result_group_t *);
static bool is_rv1126b() {
    std::ifstream f("/proc/device-tree/compatible", std::ios::binary);
    if (!f)
        f.open("/sys/firmware/devicetree/base/compatible", std::ios::binary);
    std::string value;
    while (std::getline(f, value, '\0'))
        if (value == "rockchip,rv1126b")
            return true;
    return false;
}
static int error(const char *stage, int code) {
    std::cerr << "RESULT status=ERROR stage=" << stage << " exit_code=" << code << '\n';
    return code;
}
static void dump_attr(const char *which, const rknn_tensor_attr &a) {
    std::cout << which << " index=" << a.index << " shape=";
    for (unsigned j = 0; j < a.n_dims && j < RKNN_MAX_DIMS; ++j)
        std::cout << (j ? "x" : "") << a.dims[j];
    std::cout << " fmt=" << a.fmt << " type=" << a.type << " quant=" << a.qnt_type << " zp=" << a.zp
              << " scale=" << a.scale << '\n';
}
int main(int argc, char **argv) {
    std::cout << std::unitbuf;
    if ((argc != 3 && argc != 4) || (argc == 4 && std::string(argv[3]) != "--expect-bird")) {
        std::cerr << "Usage: bird_single_image model.rknn image [--expect-bird]\n";
        return 2;
    }
    if (!is_rv1126b())
        return error("board_identity_not_rv1126b", 3);
    try {
        cv::Mat image = cv::imread(argv[2], cv::IMREAD_COLOR);
        if (image.empty() || image.type() != CV_8UC3)
            return error("image_read", 4);
        std::cout << "BOARD compatible=rockchip,rv1126b\nIMAGE width=" << image.cols
                  << " height=" << image.rows << " format=BGR_UINT8 opencv=" << CV_VERSION << '\n';
        rknn_app_context_t ctx = {};
        if (yolov8_detect_init(argv[1], &ctx) != 0)
            return error("model_init", 5);
        struct Release {
            rknn_app_context_t *p;
            ~Release() { yolov8_detect_release(p); }
        } release{&ctx};
        rknn_sdk_version version = {};
        if (rknn_query(ctx.rknn_ctx, RKNN_QUERY_SDK_VERSION, &version, sizeof(version)) !=
            RKNN_SUCC)
            return error("sdk_version_query", 6);
        version.api_version[255] = 0;
        version.drv_version[255] = 0;
        std::cout << "RKNN api=" << version.api_version << " driver=" << version.drv_version
                  << '\n';
        std::cout << "MODEL inputs=" << ctx.io_num.n_input << " outputs=" << ctx.io_num.n_output
                  << '\n';
        for (unsigned i = 0; i < ctx.io_num.n_input; ++i)
            dump_attr("INPUT", ctx.input_attrs[i]);
        for (unsigned i = 0; i < ctx.io_num.n_output; ++i)
            dump_attr("OUTPUT", ctx.output_attrs[i]);
        if (!model_contract(ctx.io_num, ctx.input_attrs, ctx.output_attrs))
            return error("unexpected_tensor_contract", 7);
        detect_result_group_t detections = {};
        const auto start = std::chrono::steady_clock::now();
        const int ret = yolov8_detect_run(&ctx, image, &detections);
        const double elapsed =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start)
                .count();
        if (ret != 0)
            return error("inference", 8);
        if (detections.count < 0 || detections.count > OBJ_NUMB_MAX_SIZE)
            return error("result_count", 9);
        int birds = 0;
        for (int i = 0; i < detections.count; ++i) {
            const auto &d = detections.results[i];
            if (d.cls_id < 0 || d.cls_id >= OBJ_CLASS_NUM || !std::isfinite(d.prop) || d.prop < 0 ||
                d.prop > 1)
                return error("invalid_detection", 9);
            if (d.cls_id == COCO_CLASS_BIRD)
                ++birds;
            std::cout << "DETECTION class_id=" << d.cls_id << " label=" << std::quoted(d.name)
                      << " confidence=" << std::setprecision(6) << d.prop << " left=" << d.box.left
                      << " top=" << d.box.top << " right=" << d.box.right
                      << " bottom=" << d.box.bottom << '\n';
        }
        std::cout << "RESULT status=" << (detections.count ? "DETECTIONS" : "NO_DETECTIONS")
                  << " count=" << detections.count << " bird_count=" << birds
                  << " run_return=0 single_call_ms=" << elapsed << '\n';
        if (argc == 4 && birds == 0) {
            std::cout << "ACCEPTANCE status=BIRD_NOT_DETECTED exit_code=10\n";
            return 10;
        }
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "Exception: " << e.what() << '\n';
        return error("exception", 11);
    }
}
