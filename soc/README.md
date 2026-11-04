# SoC 图像识别服务

RV1126B 接收 FPGA 发送的识别区域，调用 RKNN 推理程序，并通过 UART 回传鸟类判定。异步桥使用一个推理工作线程和四个队列槽位，将图像接收与推理衔接；同步桥配合单请求 FPGA 配置使用。

## 目录

| 目录 | 内容 |
| --- | --- |
| `bridge/` | 异步接收、请求队列与回包处理 |
| `bridge_sync/` | 同步接收与推理桥 |
| `worker/` | 单图和常驻 RKNN 推理程序 |
| `deploy/` | 构建、启动与自启动服务 |
| `bin/` | AArch64 Linux 桥程序 |

## 构建

板端使用 CMake、C++ 编译器、Python 和 Bash。推理程序依赖 RV1126B RKNN SDK 与 OpenCV 的 `core`、`imgproc`、`imgcodecs` 组件。启动脚本使用 `flock` 管理 UART 进程独占。

在仓库根目录执行：

```sh
bash soc/deploy/build.sh
RKNN_SDK=/opt/rknn-sdk bash soc/deploy/build.sh
ctest --test-dir soc/build --output-on-failure
```

第一条命令构建两种桥和协议测试；第二条同时构建推理程序。构建产物写入 `soc/build/bin/`。`RKNN_LIBRARY`、`RKNN_INCLUDE_DIR`、`OpenCV_DIR` 可分别指定运行库、头文件和 OpenCV CMake 配置位置。交叉编译时使用 `CROSS` 指定 AArch64 编译器前缀。

## 模型与推理

模型由 `ROI_MODEL` 指定。推理程序按以下张量约定加载检测模型：

| 项目 | 约定 |
| --- | --- |
| 目标平台 | RV1126B |
| 输入 | 单幅 640 × 640 三通道图像 |
| 输出 | 9 个 NCHW INT8 量化张量 |
| 输出网格 | 80 × 80、40 × 40、20 × 20 |
| 每组输出通道 | 边界分布 64、类别 80、汇总分数 1 |
| 鸟类类别 | COCO 类别编号 14 |

图像经等比例缩放和黑色补边后，以 UINT8 NHWC 数据交给 RKNN。桥默认采用 `BIRD_CONF_MIN=0.30` 筛选鸟类检测，将达标分数映射为 80–100 的 FPGA 接口等级。

模型获取与转换可参考 [Rockchip 检测模型示例](https://github.com/airockchip/rknn_model_zoo/tree/main/examples/yolov8)。模型与 SDK 通过各自发布渠道获取。

## 运行

```sh
sudo env ROI_MODEL=/opt/models/bird.rknn bash soc/deploy/run.sh
```

| 环境变量 | 默认配置或用途 |
| --- | --- |
| `ROI_BRIDGE` | `soc/build/bin/soc_uart_bridge` |
| `ROI_WORKER` | `soc/build/bin/bird_single_image` |
| `ROI_MODEL` | RKNN 模型的完整路径 |
| `ROI_DEVICE` | `/dev/ttyFIQ0` |
| `MMAP_UART` | `1`，使用内存映射 UART |
| `ROI_LENIENT_CRC` | `1`，启用图像体 CRC 容错；`0` 使用严格校验 |
| `ROI_RESULT_EXT` | `0`，8 字节结果体；`1` 附加检测框坐标 |
| `BIRD_CONF_MIN` | `0.30`，鸟类模型分数门限 |
| `REPLY_REPEAT` | `3`，每笔结果的发送次数 |

业务串口为 1,500,000 baud。启动入口保持零额外回包延迟，默认调用单图推理程序。使用 `ROI_BRIDGE` 可选择 `soc_uart_bridge_sync`。FPGA 重新配置后，重启 SoC 服务以开始新的请求会话。

## 自启动

将工程放置于 `/opt/birdguard`，完成构建并配置模型后，在仓库根目录执行：

```sh
sudo install -m 644 soc/deploy/birdguard.service /etc/systemd/system/birdguard.service
sudo install -m 600 soc/deploy/birdguard.env.example /etc/birdguard.env
sudoedit /etc/birdguard.env
sudo systemctl daemon-reload
sudo systemctl enable --now birdguard.service
```

`/etc/birdguard.env` 保存模型路径和运行参数。服务在启动延时后进入图像接收状态。

```sh
sudo systemctl restart birdguard.service
sudo systemctl status birdguard.service
journalctl -u birdguard.service -f
```
