# PnR 同步快照 2026-11-03

本目录用于把当前 PnR 的网表、时序报告、构建日志和设置同步到远端；不包含
40 MB 的 `.fs` 位流文件。

## 构建结果

```text
Project : instrument_board
Device  : GW5AST-LV138FPG676AES
Start   : 2026-11-03 11:57:35 +08:00
End     : 2026-11-03 12:13:05 +08:00
Duration: 15m30s of a 24m hard cap
Verdict : INSTRUMENT_BOARD_PNR_DONE
          INSTRUMENT_BOARD_TIMING_ACCEPTED
```

### 资源

| 项 | 使用 | 占比 |
|---|---:|---:|
| Logic | 72,001 / 138,240 | 53% |
| CLS | 51,389 / 69,120 | 75% |
| Register | 38,155 / 139,140 | 28% |
| BSRAM | 195 / 340 | 58% |
| DSP | 187.5 / 298 | 63% |

### 时序

| Check | Worst slack | Violations |
|---|---:|---:|
| Setup | +1.049 ns | 0 |
| Hold | +0.181 ns | 0 |
| Recovery | +10.29 ns | 0 |
| Removal | +0.27 ns | 0 |
| Min pulse | +4.30 ns | 0 |
| Max delay | +6.828 ns | 0 |

Fmax:

```text
clk_core : 52.766 MHz (target 50 MHz)
clk_audio: 17.616 MHz (target 12.5 MHz)
clk_pix  : 37.279 MHz (target 33.333 MHz)
clk50    : 352.454 MHz
```

### 位流（不随本目录提交）

```text
build/pnr_20261103_24min_v2/instrument_board/impl/pnr/instrument_board.fs
size   : 41,860,955 bytes
sha256 : 8c8bfa6ff155797fb5dc0b1611569216e799f588c59fbeec62a597ce79d869bc
```

构建目录曾被并发任务移动到
`build/pnr_20261103_eng1_shared/pnr_20261103_24min_v2/`；本快照从该实际产物复制，
并在 `build/pnr_20261103_24min_v2/` 恢复了包含 `.fs`、报告和验收 JSON 的副本。

## 本目录内容

```text
netlist/instrument_board.vg                 综合后网表
reports/instrument_board.rpt.txt           PnR 资源/时序报告
reports/instrument_board.tr                时序数据库
reports/instrument_board.timing_paths      时序路径
reports/acceptance.json                    板级引脚/时序验收
logs/flow.log                              Gowin 完整构建日志
logs/monitor.log                           30 秒进度日志
logs/status.log                            开始/结束状态
settings/instrument_board.gprj             Gowin 工程
settings/instrument_board.gprj.user        用户设置
settings/instrument_board.cst              引脚约束
settings/instrument_board.sdc              时序约束
settings/build_profile.json                构建 profile
settings/instrument_board_process_config.json
SHA256SUMS                                  关键文件校验
```

## 当前测试状态

已通过：

- `sim/run_keymap_held_only.py`：5/5
- `tb_integration_keymap_config`：45/45
- `tb_integration_bt_recovery_business`：46/46
- `run_comm`：8/8
- `run_record_uart`：compile / record / web_decode
- `run_ui`：4/4

大顺序 `tb_protocol_doc_independent` 仍只作诊断，不作为门禁。

## 复现命令

```bash
INSTRUMENT_BUILD_DIR="$PWD/build/pnr_20261103_24min_v2" \
BOARD_PNR=1 \
timeout 1440 /home/rubbishbro/gowin/IDE/bin/gw_sh \
  rtl/platform/tang_mega_138k_pro/build.tcl
```

注意：当前快照的时序/资源结论只对应当前 `midi_voice_top`/`instrument_system`
以及 `PCM_HEADROOM_BITS=0`、逐乐器 RMS 增益、复音增益临时 bypass 的工作树。
