#ifndef _RKNN_YOLOV8_POSTPROCESS_H_
#define _RKNN_YOLOV8_POSTPROCESS_H_

#include <stdint.h>
#include <vector>
#include "rknn_api.h"

#define OBJ_NAME_MAX_SIZE 64
#define OBJ_NUMB_MAX_SIZE 128
#define OBJ_CLASS_NUM 80
#define NMS_THRESH 0.45
#define BOX_THRESH 0.25

typedef struct _BOX_RECT {
    int left;
    int right;
    int top;
    int bottom;
} BOX_RECT;

typedef struct {
    char name[OBJ_NAME_MAX_SIZE];
    BOX_RECT box;
    float prop;
    int cls_id;
} detect_result_t;

typedef struct {
    int id;
    int count;
    detect_result_t results[OBJ_NUMB_MAX_SIZE];
} detect_result_group_t;

int post_process(rknn_app_context_t *app_ctx, void *outputs, float conf_threshold,
                 float nms_threshold, detect_result_group_t *od_results);

#endif
