// Copyright (c) 2023 by Rockchip Electronics Co., Ltd. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <vector>

#include "yolov8.h"

#include "file_utils.h"

using namespace cv;

static Scalar colorArray[10] = {
    Scalar(255, 0, 0, 255),   Scalar(0, 255, 0, 255),   Scalar(0, 0, 139, 255),
    Scalar(0, 100, 0, 255),   Scalar(139, 139, 0, 255), Scalar(209, 206, 0, 255),
    Scalar(0, 127, 255, 255), Scalar(139, 61, 72, 255), Scalar(0, 255, 0, 255),
    Scalar(255, 0, 0, 255),
};

int plot_one_box(cv::Mat src, int x1, int x2, int y1, int y2, char *label, int colour) {
    int tl = round(0.002 * (src.rows + src.cols) / 2) + 1;
    rectangle(src, cv::Point(x1, y1), cv::Point(x2, y2), colorArray[colour], 3);

    int tf = max(tl - 1, 1);

    int base_line = 0;
    cv::Size t_size = getTextSize(label, FONT_HERSHEY_SIMPLEX, (float)tl / 3, tf, &base_line);
    int x3 = x1 + t_size.width;
    int y3 = y1 - t_size.height - 3;

    rectangle(src, cv::Point(x1, y1), cv::Point(x3, y3), colorArray[colour], -1);
    putText(src, label, cv::Point(x1, y1 - 2), FONT_HERSHEY_SIMPLEX, (float)tl / 3,
            cv::Scalar(255, 255, 255, 255), tf, 8);
    return 0;
}

static int letter_box(cv::Mat input_image, cv::Mat *output_image, int model_input_size) {
    int input_width, input_height;

    input_width = input_image.cols;
    input_height = input_image.rows;
    float ratio;
    ratio = min((float)model_input_size / input_width, (float)model_input_size / input_height);

    int new_width, new_height;
    new_width = round(ratio * input_width);
    new_height = round(ratio * input_height);

    int height_padding = 0;
    int width_padding = 0;
    int top = 0;
    int bottom = 0;
    int left = 0;
    int right = 0;
    if (new_width >= new_height) {
        height_padding = new_width - new_height;
        if ((height_padding % 2) == 0) {
            top = (int)((float)(height_padding / 2));
            bottom = (int)((float)(height_padding / 2));
        } else {
            top = (int)((float)(height_padding / 2));
            bottom = (int)((float)(height_padding / 2)) + 1;
        }
    } else {
        width_padding = new_height - new_width;
        if ((width_padding % 2) == 0) {
            left = (int)((float)(width_padding / 2));
            right = (int)((float)(width_padding / 2));
        } else {
            left = (int)((float)(width_padding / 2));
            right = (int)((float)(width_padding / 2)) + 1;
        }
    }

    cv::Mat resize_img;

    cv::resize(input_image, resize_img, cv::Size(new_width, new_height));
    cv::copyMakeBorder(resize_img, *output_image, top, bottom, left, right, cv::BORDER_CONSTANT,
                       cv::Scalar(0, 0, 0));

    return 0;
}

static int scale_coords(detect_result_group_t *detect_result_group, int img_width, int img_height,
                        int model_size) {
    for (int i = 0; i < detect_result_group->count; i++) {
        detect_result_t *det_result = &(detect_result_group->results[i]);

        int x1 = det_result->box.left;
        int y1 = det_result->box.top;
        int x2 = det_result->box.right;
        int y2 = det_result->box.bottom;

        if (img_width >= img_height) {
            int image_max_len = img_width;
            float gain;
            gain = (float)model_size / image_max_len;
            int resized_height = img_height * gain;
            int height_pading = (model_size - resized_height) / 2;
            y1 = (y1 - height_pading);
            y2 = (y2 - height_pading);
            x1 = int(x1 / gain);
            y1 = int(y1 / gain);
            x2 = int(x2 / gain);
            y2 = int(y2 / gain);

            det_result->box.left = x1;
            det_result->box.top = y1;
            det_result->box.right = x2;
            det_result->box.bottom = y2;
        } else {
            int image_max_len = img_height;
            float gain;
            gain = (float)model_size / image_max_len;
            int resized_width = img_width * gain;
            int width_pading = (model_size - resized_width) / 2;
            x1 = (x1 - width_pading);
            x2 = (x2 - width_pading);
            x1 = int(x1 / gain);
            y1 = int(y1 / gain);
            x2 = int(x2 / gain);
            y2 = int(y2 / gain);

            det_result->box.left = x1;
            det_result->box.top = y1;
            det_result->box.right = x2;
            det_result->box.bottom = y2;
        }
    }

    return 0;
}

int yolov8_detect_init(const char *model_path, rknn_app_context_t *app_ctx) {

    int ret;
    int model_len = 0;
    char *model_data = nullptr;
    rknn_context ctx = 0;
    bool ctx_initialized = false;
    rknn_input_output_num io_num;
    rknn_tensor_attr *input_attrs = nullptr;
    rknn_tensor_attr *output_attrs = nullptr;

    model_len = read_data_from_file(model_path, &model_data);
    if (model_data == nullptr) {
        logPrint(LOG_ERROR, "load_model fail! path=%s", model_path);
        return -1;
    }

    ret = rknn_init(&ctx, model_data, model_len, 0, nullptr);
    if (ret < 0) {
        logPrint(LOG_ERROR, "rknn_init fail! ret=%d", ret);
        free(model_data);
        return -1;
    }
    ctx_initialized = true;
    free(model_data);
    model_data = nullptr;

    ret = rknn_query(ctx, RKNN_QUERY_IN_OUT_NUM, &io_num, sizeof(io_num));
    if (ret != RKNN_SUCC) {
        logPrint(LOG_ERROR, "rknn_query IN_OUT_NUM fail! ret=%d", ret);
        goto cleanup;
    }

    input_attrs = (rknn_tensor_attr *)malloc(io_num.n_input * sizeof(rknn_tensor_attr));
    if (!input_attrs) {
        logPrint(LOG_ERROR, "malloc input_attrs fail!");
        goto cleanup;
    }
    memset(input_attrs, 0, io_num.n_input * sizeof(rknn_tensor_attr));
    for (uint32_t i = 0; i < io_num.n_input; i++) {
        input_attrs[i].index = i;
        ret = rknn_query(ctx, RKNN_QUERY_INPUT_ATTR, &(input_attrs[i]), sizeof(rknn_tensor_attr));
        if (ret != RKNN_SUCC) {
            logPrint(LOG_ERROR, "rknn_query INPUT_ATTR fail! ret=%d", ret);
            goto cleanup;
        }
    }

    output_attrs = (rknn_tensor_attr *)malloc(io_num.n_output * sizeof(rknn_tensor_attr));
    if (!output_attrs) {
        logPrint(LOG_ERROR, "malloc output_attrs fail!");
        goto cleanup;
    }
    memset(output_attrs, 0, io_num.n_output * sizeof(rknn_tensor_attr));
    for (uint32_t i = 0; i < io_num.n_output; i++) {
        output_attrs[i].index = i;
        ret = rknn_query(ctx, RKNN_QUERY_OUTPUT_ATTR, &(output_attrs[i]), sizeof(rknn_tensor_attr));
        if (ret != RKNN_SUCC) {
            logPrint(LOG_ERROR, "rknn_query OUTPUT_ATTR fail! ret=%d", ret);
            goto cleanup;
        }
    }

    app_ctx->rknn_ctx = ctx;
    app_ctx->is_quant = (output_attrs[0].qnt_type == RKNN_TENSOR_QNT_AFFINE_ASYMMETRIC &&
                         output_attrs[0].type == RKNN_TENSOR_INT8);
    app_ctx->io_num = io_num;
    app_ctx->input_attrs = input_attrs;
    app_ctx->output_attrs = output_attrs;

    if (input_attrs[0].fmt == RKNN_TENSOR_NCHW) {
        app_ctx->model_channel = input_attrs[0].dims[1];
        app_ctx->model_height = input_attrs[0].dims[2];
        app_ctx->model_width = input_attrs[0].dims[3];
    } else {
        app_ctx->model_height = input_attrs[0].dims[1];
        app_ctx->model_width = input_attrs[0].dims[2];
        app_ctx->model_channel = input_attrs[0].dims[3];
    }

    return 0;

cleanup:

    if (output_attrs)
        free(output_attrs);
    if (input_attrs)
        free(input_attrs);
    if (ctx_initialized)
        rknn_destroy(ctx);
    return -1;
}

int yolov8_detect_release(rknn_app_context_t *app_ctx) {
    if (app_ctx->input_attrs != NULL) {
        free(app_ctx->input_attrs);
        app_ctx->input_attrs = NULL;
    }
    if (app_ctx->output_attrs != NULL) {
        free(app_ctx->output_attrs);
        app_ctx->output_attrs = NULL;
    }
    if (app_ctx->rknn_ctx != 0) {
        rknn_destroy(app_ctx->rknn_ctx);
        app_ctx->rknn_ctx = 0;
    }
    return 0;
}

int yolov8_detect_run(rknn_app_context_t *app_ctx, cv::Mat image,
                      detect_result_group_t *od_results) {
    int ret;

    std::vector<rknn_input> inputs(app_ctx->io_num.n_input);
    std::vector<rknn_output> outputs(app_ctx->io_num.n_output);
    const float nms_threshold = NMS_THRESH;
    const float box_conf_threshold = BOX_THRESH;
    int img_width = image.cols;
    int img_height = image.rows;

    memset(od_results, 0x00, sizeof(*od_results));
    memset(inputs.data(), 0, inputs.size() * sizeof(rknn_input));
    memset(outputs.data(), 0, outputs.size() * sizeof(rknn_output));

    cv::Mat letter_image;
    letter_box(image, &letter_image, app_ctx->model_width);

    inputs[0].index = 0;
    inputs[0].type = RKNN_TENSOR_UINT8;
    inputs[0].fmt = RKNN_TENSOR_NHWC;
    inputs[0].size = app_ctx->model_width * app_ctx->model_height * app_ctx->model_channel;
    inputs[0].buf = letter_image.data;

    ret = rknn_inputs_set(app_ctx->rknn_ctx, app_ctx->io_num.n_input, inputs.data());
    if (ret < 0) {
        logPrint(LOG_ERROR, "rknn_inputs_set fail! ret=%d", ret);
        return -1;
    }

    ret = rknn_run(app_ctx->rknn_ctx, nullptr);
    if (ret < 0) {
        logPrint(LOG_ERROR, "rknn_run fail! ret=%d", ret);
        return -1;
    }

    for (uint32_t i = 0; i < app_ctx->io_num.n_output; i++) {
        outputs[i].index = i;
        outputs[i].want_float = (!app_ctx->is_quant);
    }
    ret = rknn_outputs_get(app_ctx->rknn_ctx, app_ctx->io_num.n_output, outputs.data(), nullptr);
    if (ret < 0) {
        logPrint(LOG_ERROR, "rknn_outputs_get fail! ret=%d", ret);
    }

    post_process(app_ctx, outputs.data(), box_conf_threshold, nms_threshold, od_results);

    scale_coords(od_results, img_width, img_height, app_ctx->model_width);

    rknn_outputs_release(app_ctx->rknn_ctx, app_ctx->io_num.n_output, outputs.data());

    return ret;
}

int yolov8_detect_capture(rknn_app_context_t *app_ctx, cv::Mat &src, std::vector<int> &objClass,
                          std::vector<double> &objConf, std::vector<std::vector<int>> &splitBox) {
    detect_result_group_t detect_result_group;
    int ret = yolov8_detect_run(app_ctx, src, &detect_result_group);
    if (ret != 0) {
        logPrint(LOG_ERROR, "init_yolov8_model fail! ret=%d", ret);
        return -1;
    }

    char text[256];
    int hasBird = 0;
    for (int i = 0; i < detect_result_group.count && hasBird < 10; i++) {
        detect_result_t *det_result = &(detect_result_group.results[i]);
        if (strcmp(det_result->name, "bird") != 0) {
            continue;
        }
        hasBird = hasBird + 1;
        objClass.push_back(COCO_CLASS_BIRD);
        objConf.emplace_back(det_result->prop);
        splitBox.push_back({det_result->box.left, det_result->box.right, det_result->box.top,
                            det_result->box.bottom});
        sprintf(text, "%s %.1f%%", det_result->name, det_result->prop * 100);
        plot_one_box(src, det_result->box.left, det_result->box.right, det_result->box.top,
                     det_result->box.bottom, text, i % 10);
    }
    return hasBird;
}
