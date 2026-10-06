# 独立持续诊断音（diagnostic_tone）

**2026-10-05父会话已完成独立引脚仿真、真实Gowin综合/P&R及报告筛查。** 诊断SRAM文件：

```text
/home/rubbishbro/Desktop/FPGA_IDC_2026/build/diagnostic_tone_20261005/diagnostic_tone.fs
```

SHA256：`4d5276bb3737ad51862bb97e105224845564c33310efffb799ecf1c3304e93a0`（34,668,942bytes）。只用于持续测试音：Programmer选`GW5AST-138B → SRAM Mode → SRAM Program`，不写Flash、不按RECONFIG；无需按键启动。原歌曲版保持冻结，父会话未执行下载/Programmer。验收边界与证据见[`PARENT_REVIEW.md`](PARENT_REVIEW.md)。

本目录是一套**独立、最小化**的板级诊断工程，用于在**不经过歌曲/core**的情况下，
从 Tang Mega 138K Pro 的 PMOD2 输出一个稳定的已知方波，经由外部 MAX98357A
播放，以确认「PLL → I2S → 功放 → 喇叭」这条物理链路是否可用。

> **它不是主工程，也不替代主工程。** 它不实例化歌曲播放器、async FIFO、
> modal engine、body filter 或 mic；只用到 **现有的** `rtl/audio/i2s_amp_tx.sv`
> （只读复用）和一个只输出方波的 `tone_source`。

## 1. 文件

| 文件 | 作用 |
|---|---|
| `top.sv` | 顶层 `diagnostic_tone_top`：只例化音频 PLL + `tone_source` + `i2s_amp_tx` |
| `tone_source.sv` | 纯音频域方波采样源（48 点/周期） |
| `tone.cst` | 引脚约束（电气复用原生产 CST） |
| `tone.sdc` | 独立时序约束（不依赖生产 SDC） |
| `gowin_build.tcl` | 独立 Gowin 构建入口（不触碰 `build/gowin`） |
| `README.md` | 本文件 |

**未改动任何现有歌曲 / core / IP / ROM / SDC / CST / 测试文件。**

## 2. 数据流与时钟

```
clk (P16, 50 MHz)
  └─ Gowin_PLL_audio_12M5 (现有真实 IP, 无 100 MHz 核心 PLL)
        └─ clk_audio = 12.5 MHz
              ├─ tone_source        -> pcm[31:0] (左右相同)
              └─ i2s_amp_tx(CLK_DIV=4)
                    ├─ amp_bclk = clk_audio/4 = 3.125 MHz
                    ├─ amp_lrc  = BCLK/64    = 48.828125 kHz
                    └─ amp_din  = I2S 标准 16-bit 有效位
```

* `i2s_amp_tx` 的 `in_valid` 恒为 `1`，`diag_clear` 恒为 `0`；诊断音不会 underflow。
* `tone_source` 的 `ready` 直接接 `i2s_amp_tx.in_ready`（每帧一次的消费脉冲）。
  每次握手推进 `phase` 0..47，`phase<24` 出 `+1024`（`16'h0400`），其余出 `-1024`
  （`16'hfc00`），`{sample,sample}` 左右一致，`phase=47` 回 0。

### 频率与幅度

* 音调频率 = 48828.125 / 48 = **1017.252604166… Hz**（稳定连续方波）。
* 幅度 = 1024 / 32768 = 1/32 → **-30.10 dBFS**。
* 注意：12.5 MHz 是**真实 PLL 输出**，并非精确 12.288 MHz，所以 LRC 与音调都比
  标称 48 kHz 基准高约 **+1.725%**（约 +29.6 音分）。这是诊断助听音，**不是**
  经过校准的 48 kHz 音源。

## 3. 复位与 SD 使能策略

* 音频域 3FF 同步器：**异步 assert / 同步 release**。
  * `audio_locked` 一掉，`rst_sync` 被**异步清零**，`rst_n = rst_sync[2]` 随即下降，
    普通状态异步清 data；
  * 锁回后经 3 个 `clk_audio` 同步释放。
* `tone_source` 与 `i2s_amp_tx` **都用** `rst_n = rst_sync[2]`：**复位释放只由同步链末级
  输出驱动**，原始 50 MHz lock **不再组合进普通状态 CLEAR 树**（否则 async lock 会绕过
  同步器、在普通状态寄存器上造成 removal 违例）。
* `amp_sd = audio_locked & rst_n & tone_started`：
  * **失锁立即静音**（组合下降，同一周期）；
  * `tone_started` 是首次握手后的 sticky 标志，**重新锁定后要等首帧被接受才再启用**
    （即 `amp_sd` 不会在重新锁定瞬间就拉高）。
* 本设计**没有任何 reset/U4 按键端口**，因此**不依赖任何按钮**，也不会因为未确认的
  按键把功放锁死。

## 4. 接线

与主工程**相同的 3.3 V 接线**，MAX98357A 的 SD 为「高=左声道 / 低=关断」：

| FPGA 端口 | PMOD2 | 引脚 | MAX98357A |
|---|---|---|---|
| `amp_bclk` | IO0 | C21 | BCLK |
| `amp_lrc`  | IO1 | B20 | LRC / WS |
| `amp_din`  | IO2 | B19 | DIN |
| `amp_sd`   | IO3 | A17 | SD |
| `clk`      | —    | P16 | 50 MHz 晶振输入 |

* 电气参数（LVCMOS33 / DRIVE=8 / BANK_VCCIO=3.3 / SD PULLDOWN）**逐条复用**原
  `tang_mega_138k_pro.cst`，未引入任何新引脚事实。
* PMOD2 的 **Pin 1 方向 / 连接器朝向**仍需对照实物确认，不能凭照片推断。
* 请以 `../MAX98357A_WIRING.md` 为准做安全接线（扬声器跨接 OUTP/OUTN，任一端不得碰地
  或碰 GPIO）。

## 5. 构建（不烧录）

```bash
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
cd <repo root>
printf 'source rtl/platform/tang_mega_138k_pro/diagnostic_tone/gowin_build.tcl\n' | gw_sh -nocomp
```

* 输出目录由 `BUILD_DIR` 强制指定：默认 `<repo>/build/diagnostic_tone`；
  指向 `build/gowin` 会被直接拒绝，**不改动生产工程**。
* 器件 `GW5AST-LV138FPG676AES` / Device Version B，SystemVerilog-2017。
* 脚本只 `run syn` / `run pnr`，**不再从 Tcl 上下文输出任何报告**（gw_sh 在 P&R 后
  没有 SDC reporting 命令集，`get_ports` 无效）。完整 setup/hold 时序报告改由**激活的
  `tone.sdc` 配置**输出：SDC 尾部用不带引脚过滤的 `report_timing -max_paths 300` 扩大
  setup/hold 报告，flow 写入 `impl/pnr/diagnostic_tone.tr`；父会话从该**全报告**的
  Slow / Fast section 直接抽取三个 I2S 输出引脚极值，不以过滤标记或伪造 corner 标签替代。
* 本目录只提供 **SRAM 临时下载**用的诊断工程；脚本本身不执行 Programmer，
  也不产生「已烧录」结论。

## 6. 边界与诚实声明（重要）

* 这是**独立持续诊断音**，**不经过核心**；它**不代表歌曲路径 / core 通过**，只用于
  听/示波器确认 I2S 物理链路。
* 时序为**保守诊断预算**（`clk_audio` 加 0.400 ns setup uncertainty，未使用
  `set_clock_latency`）；**没有全 PVT 签核**，也不等于 datasheet 已签核结论。
* `tone.sdc` 的输出延时是 **C2O 路径包络 [0,40] ns**，与生产 SDC 同形，**不是外部
  I2S 的完整证书**，必须结合 RTL 边沿关系与独立板级/抖动预算另行判定。
* 3FF 复位同步链的 CLEAR hold 例外只按精确的 `rst_sync_*_s0/CLEAR` 命名裁剪，
  **实际寄存器名（`_s0` 后缀及层次前缀）需父会话在 PnR 网表上核实**；若不匹配，
  该例外自动失效，普通 hold/recovery/removal 检查仍然生效。
* **已完成独立数字仿真与真实构建/报告筛查，但本诊断版尚无实板播放/听音结果，父会话未执行烧录。**
  以上频率、幅度为RTL与时钟参数的推导/仿真值，不是实测结果；12.5 MHz非精确12.288 MHz。
