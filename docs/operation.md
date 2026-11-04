# 构建与运行

## FPGA

使用安路 Tang Dynasty（TD）构建工程，Python 运行构建入口。`TD_BIN` 指定 TD 可执行文件目录，也可从 `PATH` 查找工具。

```powershell
python tools/build_fpga.py --profile single
python tools/build_fpga.py --profile pipelined
```

生成过程与报告位于 `build/fpga/`，完成后的位流位于 `fpga/bitstreams/`。

TD 图形界面可直接打开[单请求工程](../fpga/project/single/birdguard.al)或[流水工程](../fpga/project/pipelined/birdguard.al)。

| 配置 | 位流 | 最大在途请求 | 配套 SoC 桥 |
| --- | --- | ---: | --- |
| 单请求 | `birdguard_single.bit` | 1 | 异步桥或同步桥 |
| 流水 | `birdguard_pipelined.bit` | 4 | 异步桥 |

在 TD 配套 BitWriter 中选择 `PROGRAM_SRAM`，下载所需位流。流水配置与异步桥配合，使接收与推理交叠进行。

上电自加载使用同目录中的 `birdguard_single_compress.bit` 或 `birdguard_pipelined_compress.bit`，在 BitWriter 中选择 `PROGRAM_FLASH` 写入 FPGA 配置 Flash。SoC 侧配置下文的自启动服务。

## SoC

板端构建使用 CMake 与 C++ 编译器。推理程序还使用 RKNN SDK 和 OpenCV。

```sh
# 构建串口桥
bash soc/deploy/build.sh

# 构建串口桥与推理程序
RKNN_SDK=/opt/rknn-sdk bash soc/deploy/build.sh

# 启动识别链路
sudo env ROI_MODEL=/opt/models/bird.rknn bash soc/deploy/run.sh
```

构建产物位于 `soc/build/bin/`。`ROI_BRIDGE`、`ROI_WORKER` 和 `ROI_MODEL` 分别指定桥、推理程序与模型。模型输入输出约定见 [SoC 说明](../soc/README.md)。

默认配置使用内存映射 UART、单个推理工作线程和四个队列槽位。结果体使用 8 字节；设置 `ROI_RESULT_EXT=1` 可使用包含坐标的 16 字节结果体。

## 启动步骤

1. 按[接线表](hardware.md)连接两板 UART、摄像头和 HDMI 显示器。
2. 保持 FPGA 全局复位，配置所需位流。
3. 启动 SoC 桥与推理程序，确认串口接收入口就绪。
4. 释放 FPGA 全局复位，观察候选框、识别状态与取图框。

板端自启动服务和环境配置位于 `soc/deploy/`，安装步骤见 [SoC 说明](../soc/README.md)。

## 画面与控制

板上按键选择检测方式、颜色范围和显示视图。候选框展示前端检测位置，识别状态随回包更新。`SNAP` 虚线框标记最近一次识别取图区域，`REF` 标记电压栏使用的参考数值。

有效鸟类结果触发蜂鸣器控制，动作由保持和冷却状态管理。
