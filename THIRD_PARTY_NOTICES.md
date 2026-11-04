# 第三方组件

| 组件 | 来源与用途 | 许可 |
| --- | --- | --- |
| 安路 FPGA IP | TD 生成的 PLL、FIFO、RAM、DDR 等硬件模块 | 保留文件内的安路版权声明 |
| 米联客视频参考模块 | MIPI、ISP、摄像头配置与视频时序参考 | 供学习使用，保留原始版权与使用说明 |
| Rockchip 推理示例与辅助代码 | RKNN 推理、图像处理与模型后处理 | 保留对应 Apache 许可及版权声明 |
| LLVM C++ 运行库 | 发布桥程序使用的 libc++、libc++abi 与 libunwind | 许可文本位于 `soc/bin/licenses/` |

TD、ModelSim、RKNN SDK 与 OpenCV 为构建或运行依赖，按各自发布渠道获取。模型通过运行配置指定，使用时遵循所选模型的许可。
