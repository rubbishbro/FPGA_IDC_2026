# LED 距离等待状态 review（2026-11-03）

范围：当前未提交 diff 中的 `rtl/drivers/pad_led_effects.sv` 与
`sim/unit/board/tb_led_ram_scan.sv`。只读检查 + Verilator RTL 复跑；
**未重新综合、未 PnR、未上板**。工作区中 `instrument_system.sv`、
`midi_voice_top.sv` 的改动不属于本次 LED 修复，单独处理。

## 结论

1. **位置正确**：生产改动只在 `pad_led_effects` 既有的渲染 FSM 内，
   正好落在作者 `d3604c20` 所指的 `R_WAVE_ADDR -> R_DISTANCE` 边界；
   没有新增模块、package、ROM、表文件或端口。
2. **没有越过已有实现**：仍使用原 `wave_ram`/`wave_q`、`distance_rom`/
   `distance_q` 和原 FSM，没有另算一套距离，也没有改 `pad_driver.sv`、
   `pad_led_tables/*.mem`、`sources.f` 或板级连线。
3. **但推翻了作者“零额外拍”的假设**：`d3604c20` 的注释/提交说明称
   读延迟“藏在现有状态边界里，不增加拍数”，实际需要额外一拍；
   本修复把这一拍显式化为 `R_DISTANCE_WAIT`。功能上是修正，文档和
   时序预算需要同步更新。
4. **资源增量很小**：状态仍为 5 位（19→20 状态），预计 **+0 FF、
   +0 ALU、+0 BSRAM/SDPB、+0 DSP**，LUT 约 **+2~6**（估算，待新综合）；
   每帧最坏多 1,024 个 core clock，50 MHz 下约 20.5 us，占 5 ms 帧
   的 0.41%。
5. **验证有效**：新 TB 通过；把 `R_WAVE_ADDR` 恢复为直接进
   `R_DISTANCE` 的旧时序后，同一 TB 在 `slot=1 pad=15 pixel=0` 报
   `stale wave distance`，证明测试确实覆盖了本次缺陷。

## 1. 改动位置与边界

| 文件/位置 | 改动 | 是否越界 |
| --- | --- | --- |
| `rtl/drivers/pad_led_effects.sv:104-107` | 注释改为“wave_q 更新后再等一拍” | 否 |
| `rtl/drivers/pad_led_effects.sv:201-205` | enum 末尾追加 `R_DISTANCE_WAIT` | 否 |
| `rtl/drivers/pad_led_effects.sv:244-249` | `R_WAVE_ADDR` 先写 `wave_q`，下一拍再进 `R_DISTANCE` | 否 |
| `sim/unit/board/tb_led_ram_scan.sv:19-34, 47-57` | 增加连续三个不同起点的距离消费校验 | 否 |
| `sources.f` | 未改；`pad_led_effects.sv` 仍只有一条 | 否 |
| `rtl/drivers/pad_driver.sv`、`pad_led_tables/*.mem`、`pad_driver_pkg`、`clk_rst_pkg` | 未改 | 否 |
| `instrument_system.sv` / `midi_voice_top.sv` | 工作区另有未提交改动，与 LED 无关 | 不属于本次 |

- 模块仍只在 `rtl/platform/tang_mega_138k_pro/instrument_system.sv:95`
  实例化一次，端口/参数未变。
- 新状态追加在 enum **末尾**，原有 0~18 的编码不变；当前网表状态为
  5 位二进制（`state_4`、`state_1`、`state_0[3]`、`state_0[2]`、
  `state_0[0]` 共 5 个 DFF），20 个状态仍可用 5 位表示。
- TB 仍是原有 `tb_led_ram_scan` 的白盒风格，只是把“记录到达
  `R_DISTANCE`”扩展为“`distance_q` 与当前 `wave_q` 查表值一致”，
  与作者已用的 `dut.wave_ram`/`dut.state` 探针同一层级，没有新引入
  验证库或外部模型。

## 2. 为什么必须等这一拍

原实现：

```text
R_WAVE_ADDR: wave_q <= wave_ram[wave_idx]; state <= R_DISTANCE;
R_DISTANCE : 用 wave_q（新记录） + distance_q（上一记录的查表结果）
```

`distance_rom` 的读值寄存到 `distance_q`；综合可能把 64×12 表做成
LUT，但寄存器仍使读值晚一拍。于是 `distance_q` 在 `R_WAVE_ADDR` 沿
采到的是**上一条记录**的地址；同一拍里 `wave_q` 已是新起点，
`distance_q` 还是旧起点。修复后：

| 拍 | 状态 | 动作 |
| --- | --- | --- |
| t | `R_WAVE_ADDR` | `wave_q <= wave_ram[i]`；`state <= R_DISTANCE_WAIT` |
| t+1 | `R_DISTANCE_WAIT` | `wave_q` 已是第 i 条；`distance_q <= distance_rom[addr(wave_q)]` |
| t+2 | `R_DISTANCE` | `cur_age/cur_radius/cur_lag` 与新 `distance_q` 同属第 i 条 |

`R_DISTANCE_WAIT` 没有数据赋值，只占一个状态；不新增数据寄存器或
ROM，和“低资源、不加数据寄存器/ROM”的目标一致。

## 3. 验证结果

复跑命令（Verilator 5.054）：

```bash
python3 sim/run_led_protocol.py \
  --verilator build/verilator_env/bin/verilator \
  --out build/led_review_20261103/all
```

结果：

```text
PASS tb_led_protocol frames=5 pixels=320 gray_codes=256 GRB_MSB_first
PASS tb_led_pixel_ram frames=9 pixels=576 bits=13824 ce_periods=2..5 sampled_read_checks=13824
PASS tb_led_ram_scan wave_valid=0007 wave0=00000000000000 seen=1
PASS tb_pad_led_effects grayscale_phase_lock_retrigger_16waves_retirement_wire_reset
```

旧时序对照：用 `git show HEAD:rtl/drivers/pad_led_effects.sv` 生成
baseline，保持同一 TB，结果：

```text
%Fatal: tb_led_ram_scan.sv:31: stale wave distance slot=1 pad=15 pixel=0
```

说明测试不是“只证明新实现能跑”，而是能抓住原来的距离错位。

## 4. 资源估算

### 4.1 基线口径

最近一次整板综合（`build/pnr_20261103_24min`，11:56，早于本次修改）
的 LED 网表原语：

| 模块 | FF | ALU | LUT | INV | SDPB | pROM | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pad_led_effects` | 397 | 447 | 532 | 2 | 2 | 13 | 0 |
| `led8x8` | 33 | 0 | 79 | 3 | 1 | 0 | 0 |

整板同次综合：Logic 71,289（55,097 LUT + 16,192 ALU）、FF 37,010、
BSRAM 147。注意综合报告的 `u_pad_leds` 行（1533 FF/1000 LUT/16 BSRAM）
包含被推断进 RAM 的存储内容，不能直接当作增量口径；上表用网表原语
计数。

### 4.2 本次增量

| 资源 | 估算变化 | 依据 |
| --- | ---: | --- |
| FF | **0**（最坏 +1） | 19→20 状态仍为 5 位；若工具改 one-hot 才多 1 位 |
| ALU | **0** | 没有新增加/减/比较；距离比较原已存在 |
| LUT | **+2~6**（估） | 新增一个状态译码/次态项；未综合，不能给精确值 |
| BSRAM/SDPB | **0** | 仍用原 `wave_ram`/`distance_rom` |
| DSP | **0** | — |
| 数据寄存器/ROM | **0** | 只加控制状态，不加载荷 |

相对整板：LUT +0.004%~0.011%，FF/ALU/BSRAM 0%。相对 LED 模块：
LUT +0.4%~1.1%，其余 0%。

### 4.3 拍数/帧预算

最坏 16 条 wave 全有效、64 像素：每条有效 wave 多 1 个 core clock，
共 **1,024 core clocks**。50 MHz 下 **20.5 us**，5 ms 帧的 **0.41%**。
全遮挡路径实测（强制所有记录进入 shading 窗口，CE_PERIOD=4）：

| 版本 | 渲染+填充（CE 拍） | 换算 core clocks | 相对 5 ms 帧 |
| --- | ---: | ---: | ---: |
| 旧时序 | 2,418 | 9,672 | 3.87% |
| 新时序 | 2,673 | 10,692 | 4.28% |
| 差值 | +255 | **+1,020**（理论 1,024，采样边界差 4） | +0.41% |

因此默认 `FRAME_TICKS=12500` 下不会错过下一帧；LED 发送约 1.9 ms，
与渲染重叠，也不受影响。`FRAME_TICKS<6000` 的断言在 CE=1 时本来
就低于旧的最坏渲染（9,672），属于既有的参数保护缺口；默认板级
`pad_tick` 为 20 个 core clock 一拍，不受影响。

## 5. 发现的问题（不都属于本次 diff）

1. **文档仍写“零额外拍”**：`docs/调试记录.md:925` 的“原FSM调度及
   线上时序”和 `docs/LED与FF_ALU节点审查_20261102.md:116` 的
   “不改变FSM拍数”是 `0e421502` 时代的历史结论；`d3604c20` 之后
   已不成立，本次又显式加了一拍。建议在最新 LED 记录中注明，不要
   改历史段落。
2. **`tb_led_frame_snapshot.sv` 已失效**：它仍引用 `dut.snap_valid/
   snap_pad/snap_colour/snap_age/snap_birth_travel` 和 `dut.radius`，
   这些在 `d3604c20` 已删除；当前 lint 报 21 个 `%Error`。同时
   `docs/调试记录.md:940` 和 `run_led_protocol.py` 的旧说明仍称它
   在 `snapshot` 项运行，但当前脚本没有该项。这是 `d3604c20` 留下
   的验证缺口，不是本次修改引入；建议删除/重写该 TB 并同步文档，
   否则“整帧快照已验证”的说法不能继续引用。
3. **本次没有新的整板综合/PnR**：上面的 LUT 增量和 Fmax 影响是
   基于状态位宽与既有网表的估算；`+2~6 LUT`、`0 FF` 需要新综合
   确认，时序也要看新报告。
4. **提交边界**：工作区还有 `instrument_system.sv`、`midi_voice_top.sv`
   的无关改动。若只提交本次修复，应只 add
   `rtl/drivers/pad_led_effects.sv` 和 `sim/unit/board/tb_led_ram_scan.sv`，
   避免把 backend source 改动混进 LED 变更和资源基线。

## 6. 证据

- `build/led_review_20261103/all/verification.json`、`*.log`：四项 LED
  TB 通过。
- `build/led_review_20261103/baseline_run.log`：旧时序在同一 TB 上
  报 `stale wave distance`。
- `build/led_review_20261103/budget_base.log`、
  `budget_new.log`：渲染拍数对照。
- `build/led_review_20261103/resource_counts.txt`：LED 网表原语计数。
- `build/pnr_20261103_24min/instrument_board/impl/gwsynthesis/instrument_board.vg`、
  `instrument_board_syn.rpt.html`：综合基线与整板总量。
- `build/led_review_20261103/lint_snapshot.log`：`tb_led_frame_snapshot`
  失效的 21 个错误。
