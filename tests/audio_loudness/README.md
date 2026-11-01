# 独立音频响度测试

2026-11-01。用于区分数字合成链路幅度、串行编码和后级模拟电路问题。
这是独立小工程，不接入主工程 sources.f，不依赖其录音/菜单/Flash/合成引擎，也不修改生产音频模块。

## 两个测试

| 测试 | 顶层 | 数字路径 |
|---|---|---|
| 1：后级响度基准 | `test1_reference_top` | 已知幅度 PCM16 方波 → 独立移位寄存器发送器 → 外接 I2S + 板载 PT8211 |
| 2：项目编码模块 | `test2_project_top` | 相同方波 → 当前 `rtl/audio/i2s_amp_tx.sv` / `pt8211_tx.sv` → 相同接口 |

测试1的两个串行发送格式均独立实现，不调用项目音频发送模块。测试2直接引用当前项目源码，没有复制冻结版本。两者共享方波、按键和输出寄存器；不经过 Q24→PCM 换算、声像、FIFO 或混响，以相同的已知数字幅度比较编码器和后级。

两者使用板载50MHz输入，无PLL；I2S的CLK_DIV=16，PT8211的CLK_DIV=32，因此输出速率与主工程相同：

- 采样率：50MHz/1024 = **48.828125kHz**。
- 方波：正48帧、负48帧，频率 **508.6263Hz**，零直流分量。
- 外接标准I2S：BCLK=3.125MHz，WS低左高右，每侧32bit时隙，一位延迟、16bit PCM、余位零。
- 板载PT8211：BCK=1.5625MHz，WS低右高左，每侧16bit，Japanese/LSBJ格式。
- 两组接口同时输出同一对样本，使能在复位时拉低、释放复位后拉高。
- 两者串行输出共同经过一拍50MHz寄存器，保持BCLK/WS/DIN相对关系。

## 上板使用

上电/复位默认：**左右同时发声，PCM = ±16384，约 −6.02dBFS**。不做居中0.707衰减。

- **KEY0（F15）**：每按一次切换幅度。默认16384 → 32767 → 4096 → 8192 → 16384循环；对应约−6/0/−18/−12dBFS。比较两份位流时先复位，使用相同档位。
- **KEY1（G15）**：左右同时 → 仅左 → 仅右 → 左右同时。静音侧发送PCM=0。
- **RST_N（G16）**：恢复默认幅度与双声道。按键有20ms防抖，长按不会连发。

板载音频从J29的3.5mm接口试听；外接接口使用A19这一组。若外接的是单声道MAX98357A，其声道选择由硬件配置决定；检查左右建议用板载PT8211的双声道模拟输出。

先比较测试1和测试2的默认档位，再用KEY0比较其他档位，用KEY1确认左右。

| 实听结果 | 优先检查 |
|---|---|
| 两者都响且相同 | 合成输出幅度、PCM换算、主链路增益 |
| 测试1响，测试2明显异常 | 项目串行编码或所用模块/参数版本 |
| 两者都小，满幅档仍小 | DAC/功放增益、供电、模拟接线、音箱输入音量；同时确认接口格式匹配 |
| 板载正常、外接异常，或反过来 | 对应接口的接线、使能及接收格式 |

本工程提供已知数字幅度，实际模拟增益仍需听感或测量DAC输出电压判断。

## 引脚

约束逐项取自当前 `rtl/platform/tang_mega_138k_pro/instrument_board.cst`，不用历史DIN=B21配置。A20当前为DIN，没有新增GAIN端口。

| 信号 | 引脚 | 用途 |
|---|---|---|
| clk | P16 | 50MHz输入 |
| rst_n | G16 | 低有效复位 |
| key0 / key1 | F15 / G15 | 幅度 / 声道 |
| amp_bclk | A19 | 外接I2S BCLK |
| amp_ws | A18 | 外接I2S LRCLK |
| amp_din | A20 | 外接I2S数据 |
| amp_sd | A17 | 外接功放使能，高有效 |
| dac_bck | E22 | 板载PT8211 BCK |
| dac_ws | F24 | 板载PT8211 WS |
| dac_din | G24 | 板载PT8211 DIN |
| dac_pa_en | H17 | 板载耳放使能，高有效 |

只声明这12个测试端口，没有驱动屏幕、Flash、通信或PAD。器件沿用主工程 `GW5AST-LV138FPG676AES`、版本B。

## 仿真与构建

以下命令在仓库根目录执行。Questa与Gowin需要正常的本机许可环境。

```bash
python3 tests/audio_loudness/run_sim.py

QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software \
  AUDIO_TEST=1 /home/rubbishbro/gowin/IDE/bin/gw_sh tests/audio_loudness/build.tcl
QT_QPA_PLATFORM=minimal QT_QUICK_BACKEND=software QT_OPENGL=software \
  AUDIO_TEST=2 /home/rubbishbro/gowin/IDE/bin/gw_sh tests/audio_loudness/build.tcl
```

构建输出隔离在 `build/audio_loudness/test1`、`test2`，各自有可用Gowin工程。下载文件：

- `build/audio_loudness/test1/test1_reference_top/impl/pnr/test1_reference_top.fs`
- `build/audio_loudness/test2/test2_project_top/impl/pnr/test2_project_top.fs`

构建脚本自动检查12引脚与当前主工程一致，检查50MHz目标、setup/hold/recovery/removal/最小脉宽；未通过验收的位流重命名为 `.fs.UNVALIDATED`。

仿真独立从两组串行线解码，验证有效载荷、I2S补零、BCLK周期、左右顺序、全部4×3幅度/声道组合、正负半周期、按键防抖/长按、复位静音与恢复；同时逐拍对比两个实现。仿真证据在 `build/audio_loudness/sim/results.json` 与 `simulation.log`，物理验收在各测试目录的 `acceptance.json`。未自动下载到开发板。

## 本次实际验证

- 最终仿真通过：1429帧，独立I2S/PT8211线端解码及两份实现逐拍一致，覆盖四档幅度、三种声道、正负值、按键循环与复位恢复。
- 测试1：综合/PnR通过，50MHz目标，Fmax=52.165MHz；最差setup=+0.830ns，hold=+0.247ns。
- 测试2：综合/PnR通过，50MHz目标，Fmax=51.072MHz；最差setup=+0.420ns，hold=+0.247ns。
- 两份均为setup/hold零违例，recovery/removal/最小脉宽检查通过，12个引脚与当前主工程一致。
- 直接使用P16输入，不经PLL，工具报告普通时钟路由提示PR1014；以上数据为该实际路由的物理时序结果，没有放宽50MHz目标。
- `build.log`、`acceptance.json`、源码与位流SHA256的 `fingerprints.json` 保存在各测试输出目录。两份 `.fs` 已生成，尚未下载或实听。
