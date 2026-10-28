# 通信子系统验证记录 — 2026-10-26 驱动分层后

2026-10-27 复核补记：本轮重跑 `sim/run_comm.py` 的 13 项和 `sim/check_comm_vectors.py` 均通过；下文额外 8 种子与 PnR 数字保留为 2026-10-26 记录，本轮没有重新构建。

## 结论与范围

**13 项自检仿真全部通过，故障压力另跑 8 个种子全部通过；独立通信探针在 100 MHz 目标下 setup／hold 违规为 0／0，Fmax=100.016 MHz。最差 setup 余量仅 0.002 ns。**

本轮将独立 UART、HC-05 驱动、每路 transport 和 session_ctrl 从通信顶层拆出，保持 comm_top 的端口／参数默认值、v1 线上协议和业务顺序语义。消费者／配置后级为 mock，未覆盖真实 MIDI→fmap、EQ DSP、混响后级、App、HC-05 实物或板级整机。

## 1. 仿真与向量

命令：`python3 sim/run_comm.py`。源码来自 [sim/comm_sources.f](../../sim/comm_sources.f)。

| Testbench | 结果与覆盖 |
|---|---|
| tb_comm_fifo | PASS，深度 1／3／16，各 5000 周期随机流量 |
| tb_comm_uart | PASS，独立 bit 解码、8N1、采样偏差、坏 stop、break、假起始 |
| tb_comm_uart_rates | PASS，100 MHz 下 3 Mbaud 8x／16x、230400、NCO 等频边界、连续 break |
| tb_comm_hc05_status | PASS，有／无 STATE、去抖、复位 |
| tb_slip_frame_rx | PASS，固定向量、边界、错误、队列、pin／flush |
| tb_slip_frame_tx | PASS，回复向量、header／CRC 转义、背压、复位 |
| tb_frame_arbiter | PASS，8 帧 20 字节、帧锁定、来源、随机背压 |
| tb_midi_analyzer | PASS，215 事件、消息子集与异常边界 |
| tb_config_analyzer | PASS，参数、真实完成后 ACK、每源缓存、会话取消 |
| tb_comm_top | PASS，双串口端到端，26 事件、8 回复、3 次成功 mock 提交 |
| tb_comm_faults | PASS，实际 RX 溢出、来源隔离／重连、延迟配置完成、pin 帧收束，13 事件、10 回复、8 次 mock 提交 |
| tb_comm_drivers（新增） | PASS，独立 bit BFM 检查 UART／两种 HC-05 包装的背压、FIFO 溢出、flush、STATE 不清数据、无 STATE 连接未知、TX 不被 RX 清理截断 |
| tb_session_ctrl（新增） | PASS，错误分类、同拍取消、来源隔离、重启锁存、事件／帧／parser 退休屏障、connect 不绕过业务清理 |

重构前 11 项基线另跑并通过，结果保存在 `build/comm_pre_refactor/`。分层后原有 11 项 TB 与预期均保留，没有放宽断言或改线上向量。

各层还使用最小依赖清单独立编译：uart_driver 为 4 个文件、hc05_driver 为 6 个、transport_link 为 5 个、parser_dispatch 为 3 个、session_ctrl 为 1 个，均通过且无警告；日志在 `build/comm_boundaries/<module>.compile.log`。UART／HC-05 编译不需要协议包或解析器，parser 编译不需要 UART／transport。高速 UART TB 在 include 后补显式 timescale，消除原基线已有的时间单位继承警告，时序单位和测试断言不变。

统一结果为 `build/comm/results.json`，逐项 compile／run log 在同目录；最终编译日志无警告。故障种子 1、2、7、17、42、99、2026、65535 均通过，结果在 `build/comm/seed_<seed>/` 和 `build/comm/fault_seed_results.json`。

```bash
python3 sim/run_comm.py --test tb_comm_faults --seed 42 --out build/comm/seed_42
python3 sim/check_comm_vectors.py
```

向量检查核对 6 组固定帧、CRC29B1、EQ 编码、100 个随机分片／粘包流、共享分隔符与坏转义恢复。它是参考模型检查，不代替 RTL 仿真。

## 2. 重构后综合／时序

```bash
GOWIN_SH=/home/rubbishbro/gowin/IDE/bin/gw_sh python3 sim/check_comm_timing.py
```

| 项目 | 实测 |
|---|---|
| 工具 | Gowin V1.9.12.04 |
| 器件 | GW5AST-LV138FPG676AES，device B |
| 探针 | sim/synth/comm_probe.sv，BT_HAS_STATE=1 |
| 目标时钟 | 100.000 MHz，10.000 ns |
| 报告 Fmax | **100.016 MHz** |
| 最差 setup slack | **+0.002 ns** |
| 最差 hold slack | +0.202 ns |
| setup／hold 违规端点 | **0／0** |
| 分析路径／端点 | 9775／8922 |
| PnR Logic／Register／BSRAM | 3378／2891／6 |
| 组合环／通用时钟布线警告 | 无／无；最终日志无 WARN／ERROR |

报告时间为 2026-10-26 22:43:22（Asia/Shanghai）；UTC 时间保留在 JSON 中。报告路径：

```text
build/comm_timing/results.json
build/comm_timing/gowin.log
build/comm_timing/comm_probe/impl/pnr/comm_probe.tr
build/comm_timing/comm_probe/impl/pnr/comm_probe.rpt.txt
```

源码快照包含 16 份 RTL、统一源码清单、probe SV／CST／SDC／Tcl，共 21 文件，构建前后哈希一致。按路径排序、每行 `path + 空格 + SHA256 + 换行` 的清单摘要为：

```text
584ccb4d121dca4ae43982638aa745b06a557297ca2f0ca3442fa2662f58f130
```

单文件摘要见 results.json；任何相关源码／清单／约束变化后均需重新构建。

重构前结果为 100.371 MHz／+0.037 ns，旧汇报见 [重构前记录](../drivers/analyzer/archive/2026-10-26/HISTORY.md#old-timing)，对应构建报告已保存在 `build/comm_timing/pre_driver_refactor/`。它不能用于当前重构源码的签核。

## 3. 验证边界

- 当前 setup 余量只有 2 ps，属于低余量通过；层次和综合映射变化后必须使用新 PnR 结果，不能沿用旧余量。接真实消费者、改变参数／器件／工具均可能改变结果。
- SDC 只例外异步引脚／外部 reset，不切内部同步路径；G5 只是当前封装探针的专用时钟位置，其他 UART 引脚由工具放置。探针位流不是实际整机烧录文件。
- HC-05 驱动仅透明数据模式与可选 STATE，不含 AT 初始化、KEY／RESET 控制或实物连接验收；init_done 不代表蓝牙连接成功。
- source 清音／操作退休必须接真实消费者；已经被后级接收的配置等待真实完成，不能因隔离而假定已撤销。单个配置在途期间共享 parser 仍可能被慢后级阻塞。
- 未就绪 EQ 后级应明确返回 NOT_READY。当前没有所有忽略消息的独立统计或线上诊断查询命令。

## 2026-10-28 MIDI错误恢复增量

当前默认`ISOLATE_PROTOCOL_ERRORS=1`，所有低5位协议错误及MIDI语法错误均按源隔离；每源sticky bit4合并半帧超时/MIDI语法。`python3 sim/run_comm.py --out build/midi_fixes/comm_final`的13项通过，新增截断Off来源隔离、另一来源继续工作和真实恢复屏障检查；坏CRC/长度后的用例明确请求重建后才继续。这里更新的是默认错误恢复行为，未重跑上文8种子或PnR，历史时序数字不作为修改后证明。真实声部消费者的额外回归见[MIDI当前修复](../../docs/MIDI演奏与通信接入.md#midi-bank-fixes)。
