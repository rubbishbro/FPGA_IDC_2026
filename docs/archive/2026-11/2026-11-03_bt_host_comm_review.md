# 蓝牙 / 上位机 / 本机通信审查与仿真报告

日期：2026-11-03。范围：`rtl/comm/`、`rtl/drivers/{uart,bluetooth_hc05}/`、`rtl/platform/tang_mega_138k_pro/` 的蓝牙接线、`web/midi-editor/` 的 v1/v2 串口上位机、`sim/unit/comm/` 与 `sim/unit/board/` 的相关测试。

本报告只做源码审查和 RTL 仿真；没有连接实体 HC-05、没有重新综合/布线/烧录，也没有 Questa/PnR 结论。引脚结论必须用实物通断/示波器复核后才能当作定论。

> 2026-11-03 更新：用户反馈“波特率锁死在 115200、改不了”，已先修改上位机解除锁定（见第 6 节）；RTL 和 CST 未改。

## 0. 结论摘要

1. **RTL 的 v1 蓝牙链路本身在 9600、50 MHz 下是工作的**。`tb_integration_bt_recovery_business` 用生产 `instrument_board_top`、真实 9600 位时间和独立主机 CRC/SLIP 模型通过 46 项检查，包括蓝牙帧错误隔离、32 位空闲恢复、无陈旧回复、蓝牙/有线隔离。
2. **昨天“蓝牙通信失败”更像链路配置/接线问题，而不是协议状态机损坏**。当前主机 v1 被界面强制为 115200，而板端蓝牙 UART 是 9600；界面里根本没有 9600 选项。专门仿真复现：9600 主机能进配置，115200 主机一个有效帧都进不来，而且错误计数仍为 0（静默失败）。
3. **界面仍把 v2 标成“蓝牙 UART”，但生产 RTL 已经没有 v2 codec/session**。用户按界面提示选 v2 连蓝牙，必然握手失败；选 v1 又会被强制 115200。也就是说，当前 UI 没有任何一条可用的蓝牙路径。
4. **CST 把蓝牙 RX/TX 改到了 T23/R23，而原理图上这两个球是 SDRAM_D13/D12（J23 SDRAM 连接器）**；上一版 R16/R17 和 STATE T24 都在 PMOD0 排针 J22 上。若 HC-05 仍插在 PMOD0，这次改脚会让 RX/TX 完全悬空；若模块确实接在 J23，则 STATE 又在另一个排针上，且要确认 SDRAM 模块未安装/不会总线争用。此条是当前最高风险的硬件项。
5. **测试现状不能支撑“已经验收”**：
   - 大型“independent”协议 TB 当前 94 项检查、**10 项失败**，其中多项是 TB 自身写错/状态污染，不是 RTL 问题（详见第 4 节）。
   - 默认 `run_comm.py` 只跑 8 个单元 TB，不跑蓝牙集成/主机 UI；`run_board.py` 的蓝牙用 1.5625 Mbaud 加速，且 DUT 与解码器共用同一个参数，无法发现生产默认值错误。
   - 新增的 BT/keymap 集成 TB 仍是未跟踪文件，没有进入默认回归；`run_record_uart.py` 在本机因缺少 `-MAKEFLAGS` 编译失败。
   - 网页原 77 项测试里约 45 项是 v2 死路径；v1 串口测试用 2 Mbaud/115200，从未测过 9600；原测试也没有覆盖 `app.mjs` 的波特率强制逻辑（本次已补 2 项）。

---

## 1. 审查范围与方法

阅读并交叉检查：

- 协议与文档：`docs/通信协议约定.md`、`docs/上板测试.md`、`docs/板级引脚.md`。
- RTL：`rtl/comm/comm_top.sv`、`transport_link.sv`、`slip_frame_rx/tx.sv`、`session_ctrl.sv`、`rtl/drivers/uart/*`、`rtl/drivers/bluetooth_hc05/*`、`rtl/platform/tang_mega_138k_pro/{instrument_board_top,instrument_system}.sv`、`instrument_board.cst`。
- 上位机：`web/midi-editor/src/{app,serial,protocol,serial-v2,protocol-v2}.mjs`、`index.html`。
- 测试：`sim/unit/comm/*`、`sim/unit/board/tb_instrument_board.sv`、`sim/run_comm.py`、`sim/run_board.py`、`sim/run_record_uart.py`、`web/midi-editor/tests/*`。
- 原理图：`reference_agent_readfirst/tang_mega_138k_pro_basic_resources/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf` 第 5 页（J6/J7/J8 连接器表）、第 16 页（PMOD0 J22、SDRAM J23）。

仿真使用仓库内 Verilator 5.054（`build/verilator_env/bin/verilator`）。新增的审查用 TB 只放在 `build/review_sim/`，未改生产 RTL。

---

## 2. 关键发现

### 2.1 P0：主机 v1 强制 115200，板端蓝牙是 9600，且界面没有 9600 选项

证据：

- 板端默认：`rtl/platform/tang_mega_138k_pro/instrument_board_top.sv:3` `BT_BAUD=9600`；`rtl/comm/comm_top.sv:8` `BT_BAUD = 9600`；`rtl/platform/tang_mega_138k_pro/instrument_system.sv:127` 把它接到 `comm_top`。
- 文档：`docs/通信协议约定.md:5`、`docs/上板测试.md:11`、`docs/板级引脚.md:36` 都写蓝牙 9600、有线 115200。
- 上位机：`web/midi-editor/src/app.mjs:163` 在 v1 下执行 `if(!v2)$('baud').value='115200';`，`:164` 在 v1 下禁用波特率下拉框，`:208` 连接时用 `Number($('baud').value)`。
- 下拉框 `web/midi-editor/index.html:65` 只有 115200/230400/460800/921600/1000000/2000000，**没有 9600**；`:64` 把 v1 标成“板载有线 UART”，把 v2 标成“蓝牙 UART / 测试串口”。

影响：使用 v1 连蓝牙时，Web Serial 一定以 115200 打开；使用 v2 连蓝牙时，板端没有 v2。两条路都不通。

仿真复现（`build/review_sim/tb_review_bt_baud.sv`，生产 `comm_top`，`BT_BAUD=9600`）：

```text
CHECK PASS bt_host_9600_matches_board_cfg_valid
INFO  bt_host_9600_matches_board error_sticky=0x0000 rx_err_bt=0 false_start=0 rx_stb=9 q=00
CHECK PASS bt_host_115200_vs_board_9600_cfg_valid          # cfg_valid 始终为 0
OBSERVE bt_host_115200_vs_board_9600 baud mismatch is silent:
        cfg_valid=0, error_sticky=0x0000, rx_error_count[1]=0,
        false_start=0, rx_stb=1 (garbage bytes only)
PASS tb_review_bt_baud checks=2
```

即：9600 主机进来 9 个字节、无错误；115200 主机只被当成 1 个垃圾字节，**没有任何错误计数**。这解释了为什么现场可能“完全没反应，但诊断里也看不到 CRC/帧错误”。现场导出的 `midi-link-diagnostic.json` 里 `link.baud` 会记录主机实际打开的波特率；如果它是 115200，就可以直接确认这条。

修复建议（按优先级）：

1. 在 `index.html` 的波特率下拉框增加 `9600`。
2. v1 不再强制 115200；增加“链路类型/设备”选择（有线 115200、蓝牙 9600），或至少允许手动选 9600。
3. 文档与 UI 文案统一：蓝牙走 v1 9600，不是 v2。
4. 增加一个主机侧回归：mock Web Serial，断言选蓝牙时实际 `open({baudRate:9600})`。

### 2.2 P0：界面仍提供 v2 蓝牙，但生产 RTL 已删除 v2

证据：

- `web/midi-editor/index.html:64`：`v2 · 蓝牙 UART / 测试串口`。
- `web/midi-editor/src/app.mjs` 仍实例化 `serialV2`；`web/midi-editor/src/serial-v2.mjs:152,247` 默认 115200 并发送 v2 HELLO。
- `web/midi-editor/src/protocol-v2.mjs` 定义 `VERSION=0x02`、`HELLO=0x01` 等 v2 帧。
- 生产 RTL `rtl/comm/slip_frame_rx.sv` 只接受 `TYPE_MIDI(0x01)`/`TYPE_CONFIG(0x02)`；没有 v2 version/session/heartbeat。
- 文档明确：`docs/通信协议约定.md:5` 写“蓝牙 v2 上位机链路不属于本次同步范围”；`docs/上板测试.md:11` 写“当前源码没有v2心跳/会话层，不能用v2测试”；`docs/推送状态_20261103.md:32` 记录了 v2 body 被当作 v1 解析的已知歧义。

影响：用户看到“v2 = 蓝牙”的文案，选 v2 后板端会把 v2 的第一个字节 `0x02` 当作 v1 TYPE=CONFIG，后续字段错位，最多回一个 v1 错误/不回复，v2 握手超时。**这是界面与 RTL 的直接矛盾，不是用户操作错误。**

修复建议：

- 短期：删除/隐藏 v2 选项，蓝牙统一走 v1 9600；把 v2 代码和测试标记为“非当前产品路径”。
- 如果确实要保留 v2：需要把 `comm_v2_codec`/`transport_v2_link`/session 逻辑重新加回 RTL 并做完整回归；这不是本次修蓝牙的最小改动。

### 2.3 P0（需实物确认）：蓝牙 RX/TX 引脚 T23/R23 是 SDRAM 引脚，不是 PMOD0

当前 CST：

```text
// rtl/platform/tang_mega_138k_pro/instrument_board.cst:60-65
// Bluetooth TX -> FPGA RX (T23); FPGA TX (R23) -> Bluetooth RX.
IO_LOC "uart_rx[1]" T23;
IO_LOC "uart_tx[1]" R23;
IO_LOC "bt_state" T24;
```

原理图（Dock 4071f，第 5 页连接器表、第 16 页 PMOD0/SDRAM 连接器）：

- `T24 ,3 PMOD0_IO7`，`T23 ,3 SDRAM_D13`，`R23 ,3 SDRAM_D12`。
- PMOD0 J22：`R16=PMOD0_IO2`、`R17=PMOD0_IO3`、`T24=PMOD0_IO7`。
- SDRAM 连接器 J23：`SDRAM_D13 T23` 在 pin 13，`SDRAM_D12 R23` 在 pin 14。

上一版（commit `7ffbd805` 之前）是 `R16/R17`，与 `bt_state=T24` 同属 PMOD0 排针。`7ffbd805` 把 RX/TX 改成 T23/R23，但 STATE 仍留在 T24。这有两种可能：

1. HC-05 仍插在 PMOD0：新的 RX/TX 实际接在 SDRAM 数据线上，蓝牙完全不通；这是本次最可疑的“改脚后失败”。
2. HC-05 确实改接到 J23 的 SDRAM 排针：T23/R23 才成立，但 STATE 又跨到 PMOD0；同时必须确认 J23 上没有 SDRAM 模块、不会和 SDRAM 数据线争用。若板上有 SDRAM 模块，T23/R23 是被驱动的，不能当 UART 用。

建议：

- 先用万用表/示波器确认 HC-05 的 TX/RX/STATE 实际通到哪三个 FPGA 球。
- 如果模块在 PMOD0：把 CST 恢复为 `R16/R17`（并保留 `T24` STATE），重新构建测试。
- 如果模块在 J23：在 `docs/板级引脚.md` 明确写“J23 SDRAM 排针、SDRAM 未安装”，并在板级测试中加一个引脚连通性/回环检查；不要只以“CST 能通过”当作“引脚检查通过”。
- 无论哪种情况，`bt_state=T24` 与 RX/TX 不在同一个排针这一点需要在文档和实物上自洽。

### 2.4 P1：波特率错配是“静默失败”，现有诊断看不到

`rtl/comm/comm_top.sv` 的 `error_sticky` 只累计 `overflow/break/framing/protocol/midi`（`rtl/comm/session_ctrl.sv:31-37`），没有把 `comm_uart_rx` 的 `false_start` 计入；`comm_top` 也没有把 `rx_false_start` 接到任何计数器。上面的 115200→9600 仿真里，`false_start=0`、`error_sticky=0`，只有 1 个垃圾字节。

另外 `rtl/platform/tang_mega_138k_pro/instrument_system.sv:128` 把 `link_fault_pending`、`error_sticky`、`rx_error_count` 都留空（`.link_fault_pending(),.error_sticky(),.rx_error_count()`），主机无法查询链路故障；蓝牙 MIDI 又没有 ACK/重发，现场只能看到“没反应”。

建议：

- 给 `false_start` 增加计数（独立的 16/32 位计数器或诊断位），至少能区分“波特率错/线没接/模块没发”。
- 通过一条诊断配置命令、LCD 状态页或调试寄存器导出 `error_sticky`/`rx_error_count`/`source_quarantine`；网页“导出通信诊断”目前只能看到主机侧 RX 字节，看不到板端物理层错误。
- 在 `docs/上板测试.md` 增加“蓝牙 9600 下 error_sticky/rx_error_count 应为 0；若为 0 但仍无回复，检查波特率和引脚”的判据。

### 2.5 P1：默认回归没有覆盖蓝牙 9600、也没有覆盖主机 UI

- `sim/run_comm.py:18` 的 `TESTS` 只有 8 个单元 TB；没有 `tb_integration_bt_recovery_business`、`tb_integration_keymap_config`、`tb_protocol_doc_independent`。
- `sim/unit/board/tb_instrument_board.sv:3,19`：`UART_BAUD=1_562_500`，并把这个值同时接到 `.BT_BAUD(UART_BAUD)` 和测试自己的 `comm_uart_rx` 解码器。DUT 和测试模型共用同一个参数，且蓝牙不是生产 9600；它无法发现 `BT_BAUD` 默认值或主机波特率错误。
- 新增的 BT/keymap 集成 TB 在 `git status` 中是 `??`（未跟踪），不会进入任何自动回归；它们需要单独运行 `sim/run_integration_bt_recovery_business.py` / `run_integration_keymap_config.py` / `run_keymap_held_only.py`。
- `sim/run_record_uart.py:50-55` 的 Verilator 命令没有 `-MAKEFLAGS "CXX=g++ ..."`，本机运行时直接调用 `x86_64-conda-linux-gnu-c++` 失败；其他集成 runner 都有这行。应统一。
- `web/midi-editor/tests/run.mjs` 原运行 77 项（本次新增 2 项后 79 项），其中 v2 相关约 45 项（`protocol-v2.test.mjs` 22、`serial-v2.test.mjs` 20、`protocol-v2-recovery.test.mjs` 3）；v1 `serial.test.mjs` 使用 2,000,000/115200，没有 9600；原测试没有 `app.mjs` 的 UI 行为测试（本次补的是静态回归，不代替真实浏览器 UI 测试）。

建议：

- 把 BT 集成 TB 加入 `run_comm.py` 或单独的 `run_regression.py`；至少加入一个“生产默认 `BT_BAUD` 不被覆盖”的断言。
- `tb_instrument_board` 增加参数化 `WIRED_BAUD`/`BT_BAUD` 两个独立参数（默认 115200/9600），而不是一个 `UART_BAUD` 同时喂两边。
- 网页增加“设备=有线/蓝牙”的端到端测试，断言 `port.open` 的 `baudRate` 分别为 115200/9600。
- 修复 `run_record_uart.py` 的编译参数；把 `build/review_*` 之外的正式结果路径写进文档。

---

## 3. 仿真结果

所有命令在仓库根目录执行；日志在 `build/review_*`。

| # | 仿真 | 结果 | 说明 |
|---|---|---|---|
| 1 | `python3 sim/run_integration_bt_recovery_business.py --out build/review_bt_current` | **PASS 46 checks**，56.5 s | 生产板顶层、9600 蓝牙、真实 UART 引脚；帧错误隔离、32 位空闲恢复、无陈旧回复、有线/蓝牙隔离 |
| 2 | `python3 sim/run_keymap_held_only.py --out build/review_keymap_held` | **PASS 5 checks**，107 s | 按住不松 500 ms 内回 04、表不变；100 ms 松手回 00 并提交 |
| 3 | `python3 sim/run_integration_keymap_config.py --out build/review_keymap_integration` | **PASS 45 checks**，92 s | 当前源码重跑；keymap 顺序、缓存、held-pad、配置隔离 |
| 4 | `python3 sim/run_comm_protocol_doc.py --out build/review_protocol_current` | **FAIL 94 checks / 10 fails**，289 s | 失败多为 TB 期望/顺序问题，见第 4 节 |
| 5 | 手工编译 `tb_instrument_board -GRECORD_TEST=1 -GUART_BAUD=115200` | **PASS** | `on=2 off=1 END_before_ACK`；`recording_uart.hex` 经网页解码：8 帧、2 个音符 |
| 6 | `node web/midi-editor/tests/check-rtl-take.mjs build/review_record_current/recording_uart.hex ...` | **PASS** | RTL UART → FrameReader → 新轨道 → MIDI 往返；2 个音符 |
| 7 | `npm --prefix web/midi-editor test` | **PASS 79/79** | 新增 9600/UI 回归；原有用例中约 45 项仍是 v2 死路径 |
| 8 | `build/review_sim/obj_bt_baud/bt_baud` | **PASS 2 checks + OBSERVE** | 9600 主机可配置；115200 主机无 cfg_valid，且错误计数仍为 0 |

关键正向结论：**BT v1 的 RTL 路径（9600、50 MHz、64 字节帧、SLIP/CRC、quarantine、32 位空闲恢复）在仿真中是通的**；不要把“昨天失败”直接归因于 `session_ctrl`/`slip_frame_rx` 逻辑而重写协议。

`run_record_uart.py` 本机失败说明：脚本生成的命令缺少 `-MAKEFLAGS`，与 `run_integration_bt_recovery_business.py` 不一致；上面的第 5 项是用相同源表和 `-MAKEFLAGS "CXX=g++ LINK=g++ AR=ar CFG_CXXFLAGS_PCH_I=-include"` 手工编译后运行的。

---

## 4. 测试质量审查：哪些是“针对性/无意义”，哪些不是

### 4.1 结论先说

- **不是所有测试都无意义**。`tb_integration_bt_recovery_business`、`tb_keymap_held_only`、`tb_integration_keymap_config` 都驱动生产板顶层和真实 UART 位时间，主机侧 CRC/SLIP 是独立实现；它们验证的是可观察行为（是否回复、结果码、恢复时间、表是否提交），不是把 DUT 内部信号抄一遍。这些是本次审查中可信的证据。
- **问题最大的是大型 `tb_protocol_doc_independent`**：它名义上“independent”，实际把 94 项检查串在一个共享状态的长序列里，失败项里有明确的 TB 自身错误；当前 10 项失败不能作为 RTL 结论，也不能作为回归门禁。
- **默认回归与生产路径脱节**：真正覆盖 9600 的 TB 不在 `run_comm.py`/`run_board.py` 里；默认板级测试用加速波特率，DUT 和解码器共用参数；网页测试大部分在测已删除的 v2。

### 4.2 大型协议 TB 的 10 项失败逐条归类

| 失败项 | 实际观察 | 判断 |
|---|---|---|
| `v2_frame_not_accepted_as_v1` | 板端回 1 帧 | **TB 期望与已定决策矛盾**。`docs/推送状态_20261103.md` 明确接受“v2 body 若字节上构成合法 v1 帧，会按 v1 解析并回 CMD=00 RES=01”；`tb_protocol_doc_independent.sv:641` 仍要求“不回复”。 |
| `record_type82_start_end` | 6 帧中 0 个 TYPE82 start/end | **TB 捕获问题**。同一源码的专用板级录制测试通过（`on=2 off=1 END_before_ACK`），网页也能解码 8 帧/2 音符；应查 `tb_protocol_doc_independent` 的 monitor/marker，而不是 RTL。 |
| `record_duplicate_stop_no_events` | “1 extra frame” | **TB 期望错误**。重复 STOP 按协议 §5 必须重放结果，重放本身就是一个 TYPE80 帧；`:719-725` 用 `frm_total[0]==fails_before` 统计所有帧，必然失败。应只统计 TYPE82 事件。 |
| `record_duplicate_start_no_restart` | `active=1 extra_frames=2` | **TB 对缓存假设错误**。`:727-736` 在中间已经发过 SEQ=0x54 的 STOP；`config_analyzer` 每来源只有一项最近缓存（`cache_valid[ctx_source]`/`cache_seq`），SEQ=0x51 已被 0x54 覆盖，板端把它当新请求重新执行是符合设计的。应在紧接着的同一事务内重发，或单列缓存测试。 |
| `record_bt_start_no_take` | `rec_active=1` | **上一条的级联污染**：重复 START 重新起了一个 take，后续 BT START 检查看到 active=1。不是蓝牙“创建了 take”。 |
| `record_failed_take_start_00` | 实际回 04 BUSY | 同上，前一个 take 仍 active，START 正确回 04。 |
| `record_failed_stop_06` | 实际回 03 | 同上，当前没有匹配的失败 take，STOP 正确回 03。 |
| `keymap_held_pad_500ms_deadline` | 500 ms 内无回复 | **TB 复位后没等到 bridge/keymap idle**。`:906-919` 只等 `core_n/audio_valid/have_commit` 加 20 ms；聚焦 TB 的 `reboot_and_wait`（`tb_keymap_held_only.sv:456-471`）还等 `bridge_state==0`、`keymap_inflight==0`。请求在 bridge 忙时被丢，当然没有回复。 |
| `keymap_held_pad_reply_after_release` | 松手后仍无回复 | 同上。 |
| `bt_break_error_counted` | `error_sticky=0x6000` | **TB 位号写错**。蓝牙是 g=1，错误位在 `[15:8]`；`0x6000` 的 bit13/14 正是 framing/break。测试却查 `error_sticky[6]`（有线 break 位），`:1024`。RTL 是对的。 |

因此，按当前源码，**10 项失败里没有一项能直接证明生产 RTL 的蓝牙/录制/按键功能坏了**；但这也说明该 TB **不能作为“独立验收”**，需要拆分/修正后再当门禁。

### 4.3 哪些测试是有效的、但覆盖偏窄

- `tb_integration_bt_recovery_business.sv`：46 项，覆盖真实 9600、真实 UART 引脚、独立 CRC/SLIP、quarantine/恢复/隔离。有效性高；但它把 `.BT_BAUD(9600)` 写死，不能发现“生产默认值/主机 UI”错误，也没有覆盖主机端。恢复时间检查只有下限（`>= 32 bit times * 0.95`），没有上限；建议补一个“≤500 ms 主机期限/≤10 ms 预期”的上界，否则恢复过慢也会 PASS。日志里 `%0t` 显示 ps 再接字面 `ns`，`INFO ...=3338333000 ns` 实际是 3.338 ms，容易误读。
- `tb_keymap_held_only.sv`：5 项，聚焦 held-pad 边界；行为断言有效，但只覆盖“单事务、无前置污染”的场景，且大量读 `dut.u_system.u_sound.*` 内部信号，属于白盒定向测试，不是端到端验收。
- `tb_integration_keymap_config.sv`：45 项，覆盖 keymap + 配置顺序、缓存、held-pad；比大 TB 可靠，但同样是白盒内部信号 + 固定顺序。
- `tb_instrument_board`：默认 `UART_BAUD=1_562_500`，且 `.BT_BAUD(UART_BAUD)`；它验证的是“加速、DUT/解码器同参数”的路径，不是生产 9600。作为功能冒烟可以，作为蓝牙波特率验收不行。
- 网页 `frame_vectors.json`：头部注明由独立 Python `binascii.crc_hqx` 生成，CRC/SLIP 向量不是 JS 自己生成的；这部分是有效的独立向量。`rtl_tx_start.hex` 明确来自 RTL TX；`performance_vectors.json` 是请求/期望向量，来源未在文件头标注，建议补一行 provenance。

### 4.4 建议的测试整改

1. 修大 TB 的 6 类问题（位号、重复帧计数、缓存覆盖、v2 期望、复位等待、TYPE82 捕获），或者把它拆成“每类一个独立复位”的小 TB；在修好前不要把它当 gate。
2. 把 BT/keymap 集成 TB 加入默认回归；给 `run_comm.py` 增加一个 `integration` 组，或新建 `run_regression.py`。
3. 给 `tb_instrument_board` 拆 `WIRED_BAUD`/`BT_BAUD` 两个参数，默认 115200/9600，并增加“不覆盖参数时 DUT 内部 `BT_BAUD==9600`”的断言。
4. 网页增加 `app.mjs` 的 UI 测试：选择蓝牙 → `open` 的 `baudRate=9600`；选择有线 → 115200；v2 选项不存在或明确不可用。
5. 修 `run_record_uart.py` 的 `-MAKEFLAGS`；统一所有 Verilator runner 的编译参数和结果路径。

---

## 5. 建议的修复顺序（最小闭环）

1. **先确认 HC-05 的物理接线**：用通断/示波器确认 TX/RX/STATE 到 T23/R23/T24 还是 R16/R17/T24。若在 PMOD0，恢复 R16/R17；若在 J23，确认 SDRAM 未安装并在文档写明。
2. **统一链路配置**：HC-05 配 9600；网页增加 9600 选项，v1 不再强制 115200，增加“有线/蓝牙”选择；移除或隐藏 v2。
3. **加诊断**：`false_start` 计数、`error_sticky/rx_error_count/quarantine` 导出；网页诊断 JSON 记录实际 `baud`（已有）和板端错误（需新增）。
4. **再跑仿真**：BT 集成 TB + keymap 集成 TB + 专用 record TB + 网页测试；修大 TB 后再跑全量。
5. **最后上板**：冷启动、蓝牙 9600 下配置回复、演奏、断线重连、错误注入；确认不是只看“网页显示已连接”。

---

## 6. 本次修复：解除 115200 锁定（2026-11-03）

用户反馈“锁死在 115200，改不了”，已修改上位机：

- `web/midi-editor/index.html`：新增“连接方式”选择（有线 USB-UART · 115200 / HC-05 蓝牙 · 9600）；波特率下拉框增加 `9600`；协议标签与提示改为“蓝牙走 v1 9600，v2 当前固件不支持”。
- `web/midi-editor/src/app.mjs`：删除 v1 下强制 `115200` 和禁用波特率下拉框的逻辑；v1 下波特率可改；选择蓝牙时自动切到 `v1 + 9600` 并同步内部 `serial`，避免协议下拉框显示 v1 但内部仍是 v2。连接方式保存在 `localStorage`，刷新后仍保留，避免下次实测又回到有线 115200。
- 测试：`web/midi-editor/tests/serial.test.mjs` 增加 9600/8N1 `open` 断言；新增 `web/midi-editor/tests/ui.test.mjs`，防止再次强制 115200 或移除 9600；`npm --prefix web/midi-editor test` **79/79 PASS**，`npm run check` PASS。
- 未改 RTL 和 CST；HC-05 模块本身仍需配置为 9600，引脚仍需按第 2.3 节用实物确认。

## 7. 未验证边界

- 没有实体 HC-05、没有示波器/逻辑分析仪；引脚结论以原理图为准，需实物复核。
- 没有重新综合/布线/烧录；本报告不构成 pin timing/PnR/实板验收。
- 大型协议 TB 的 10 项失败已归类为 TB 问题，但没有逐项改测试；修复后应重新跑全量。
- 网页 v2 代码没有删除，只是判定为非当前产品路径；如果产品仍要求 v2，需要单独恢复 RTL 并重做协议回归。

---

## 附录：本次生成的证据

- `build/review_bt_current/results.json`、`run.log`：BT 集成 46 项 PASS。
- `build/review_keymap_held/results.json`、`run.log`：held-pad 5 项 PASS。
- `build/review_keymap_integration/results.json`、`run.log`：keymap 集成 45 项 PASS（当前源码重跑）。
- `build/review_protocol_current/results.json`、`run.log`：大 TB 94 项/10 失败及分类。
- `build/review_record_current/record2.log`、`recording_uart.hex`、`recorded2.mid`：板级录制 PASS + 网页解码 PASS。
- `build/review_sim/tb_review_bt_baud.sv`、`build/review_sim/bt_baud_run.log`：9600 vs 115200 静默失败复现。
- `build/review_web_test_after_link_sync.log`：网页 79/79 PASS（含新增 9600/UI 回归）。
