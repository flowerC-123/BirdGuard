# 工程验证

## FPGA 仿真

仿真入口覆盖候选与巡检调度、单请求传输、流水传输、结果窗口、参考值显示和状态叠加。

```sh
python tests/fpga/run.py
```

工具通过 `MODELSIM_BIN` 或 `PATH` 查找 ModelSim / Questa。测试包含 8 组配置，并对流水传输生成的 5 个完整图像报文逐项校验元数据、像素和 CRC。

## SoC 测试

```sh
bash soc/deploy/build.sh
ctest --test-dir soc/build --output-on-failure
```

| 测试 | 覆盖内容 |
| --- | --- |
| 流式解析 | 31 项检查，400 个报文 |
| 异步服务 | 5,083 项检查，1,000 笔请求 |
| 双向进程通信 | 9 个收发场景 |

## FPGA 构建签核

构建入口在综合与布局布线之间核对设计输入、构建配置和综合数据库的哈希。完成布线后检查系统与显示时钟、建立与保持时序、跨时钟约束和位流文件，生成对应配置的发布位流。

```sh
python tools/build_fpga.py --profile single
python tools/build_fpga.py --profile pipelined
```

构建摘要保存在 `fpga/bitstreams/build_summary.json`。发布文件的 SHA-256 记录见仓库根目录 `SHA256SUMS`。

## 发布文件验证结果

| 配置 | 建立时间裕量 | 保持时间裕量 | 路由时序签核 |
| --- | ---: | ---: | --- |
| 单请求 | 0.103 ns | 0.020 ns | 通过 |
| 四请求流水 | 0.140 ns | 0.020 ns | 通过 |

两套配置的双向系统/显示跨时钟路径均通过 13 ns 约束检查。8 组 FPGA 仿真、3 项 SoC 测试和两种 AArch64 桥程序构建均通过。
