#define main r20_reference_single_image_main
#include "single_image.cpp"
#undef main
#include <sstream>
static int infer_image(rknn_app_context_t &ctx, const std::string &path) {
    cv::Mat image = cv::imread(path, cv::IMREAD_COLOR);
    if (image.empty() || image.type() != CV_8UC3)
        return error("image_read", 4);
    detect_result_group_t detections = {};
    const auto start = std::chrono::steady_clock::now();
    const int ret = yolov8_detect_run(&ctx, image, &detections);
    const double elapsed =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
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
                  << " top=" << d.box.top << " right=" << d.box.right << " bottom=" << d.box.bottom
                  << '\n';
    }
    std::cout << "RESULT status=" << (detections.count ? "DETECTIONS" : "NO_DETECTIONS")
              << " count=" << detections.count << " bird_count=" << birds
              << " run_return=0 single_call_ms=" << elapsed << '\n';
    return 0;
}
int main(int argc, char **argv) {
    std::cout << std::unitbuf;
    if (argc != 3 || std::string(argv[2]) != "--stream") {
        std::cerr << "Usage: bird_persistent_image model.rknn --stream\n";
        return 2;
    }
    if (!is_rv1126b())
        return error("board_identity_not_rv1126b", 3);
    try {
        rknn_app_context_t ctx = {};
        if (yolov8_detect_init(argv[1], &ctx) != 0)
            return error("model_init", 5);
        struct Release {
            rknn_app_context_t *p;
            ~Release() { yolov8_detect_release(p); }
        } release{&ctx};
        if (!model_contract(ctx.io_num, ctx.input_attrs, ctx.output_attrs))
            return error("unexpected_tensor_contract", 7);
        std::cout << "BIRD_READY 1\n";
        for (;;) {
            char header[128] = {};
            if (!std::cin.getline(header, sizeof(header)))
                return std::cin.eof() ? 0 : 2;
            std::istringstream fields(header);
            std::string marker, tail;
            uint64_t seq = 0;
            size_t bytes = 0;
            if (!(fields >> marker >> seq >> bytes) || marker != "BIRD_RUN" || !seq || !bytes ||
                bytes > 4096 || (fields >> tail))
                return 2;
            std::string path(bytes, '\0');
            std::cin.read(&path[0], std::streamsize(bytes));
            if (size_t(std::cin.gcount()) != bytes || std::cin.get() != '\n' ||
                path.find('\0') != std::string::npos)
                return 2;
            int code = 0;
            try {
                code = infer_image(ctx, path);
            } catch (const std::exception &e) {
                std::cerr << e.what() << '\n';
                code = 11;
            }
            std::cout << "BIRD_DONE " << seq << ' ' << code << '\n';
        }
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return error("exception", 11);
    }
}
