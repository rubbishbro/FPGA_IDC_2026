# 真 FFT 频谱显示 完整设计蓝图（v2 音频域架构）

> v2 变更：FFT 及所有计算移入**音频域 MCLK**，跨时钟点从 2 个减到 1 个。
> 时域乒乓在 MCLK 域内用简单计数，频域乒乓是唯一跨时钟点（像素域读）。
> 目标：48kHz 音频 → 1024 点 FFT → 128 柱频谱显示。

---

## 一、时钟架构（三个时钟，两级域）

```
clk     50MHz  晶振
  └→ PLL → pix_clk  33.33MHz   像素域（显示扫描、光点、绘制）
  └→ (音频系统) → MCLK 12.288MHz  音频域（采样、时域、FFT、映射）= 256×48k
               → Fs   48kHz      采样率（由 MCLK 分频或外部给）
```

**关键**：MCLK 与 Fs 同源（256 倍），与 pix_clk 无关（PLL 输出）。
音频域所有逻辑跑 MCLK；像素域所有逻辑跑 pix_clk。

```
       音频域 (MCLK 12.288MHz)              像素域 (pix_clk 33.33MHz)
┌─────────────────────────────────────┐   ┌──────────────────────────┐
│ 采样数据(48k) → audio_if → 时域乒乓    │   │                         │
│                → fft_ctrl → FFT_Top   │   │                         │
│                → spectrum_map → 频域乒乓│──→ 双触发同步 sel ──→ 像素读 │
└─────────────────────────────────────┘   └──────────────────────────┘
     ↑ 同域，无握手需求                         ↑ 唯一跨时钟点：sel 翻转
```

---

## 二、模块分工与计算职责

### 1. audio_if —— 位宽截取 + 采样有效标志

**职责**：把外部音频模块的 32bit 输出转成 16bit，并把"每采样一拍"的标志同步进 MCLK 域。

```
input  audio_clk/Fs 48k      // 音频采样有效
input  audio_in[31:0]        // 32bit 合成输出（有效位未知，预留适配）
input  mclk 12.288MHz        // 音频域高速时钟
output xn_re[15:0]           // 截取后的 16bit（送时域乒乓）
output xn_valid              // 每采样一拍脉冲（MCLK 域）
```

**计算职责**：
- 位宽截取：`xn_re = (ADAPT=="HI") ? audio_in[31:16] : audio_in[30:15]`（ADAPT 可配）
- xn_valid 双触发器同步：`Fs 域 → MCLK 域`（因 MCLK=256×Fs 同源，风险低，仍同步保稳）

### 2. time_buffer —— 时域乒乓（音频域内）

**职责**：双块时域 RAM（A/B 各 1024×16bit），音频写一块、FFT 读另一块，攒满标志。

```
input  mclk
input  xn_re[15:0], xn_valid        // 音频写侧（MCLK 域）
output buf_full                     // 攒满 1024 点 → 1（MCLK 域，内部标志）
input  ack                          // FFT 算完 → 清 buf_full、切写块
output fft_data[15:0]               // FFT 读侧数据
input  fft_addr[9:0], fft_rd        // FFT 读侧
input  fft_sel                      // FFT 当前读哪块
```

**计算职责**：
- 写侧（MCLK）：`xn_valid` 来→写 `ram[wr_sel][wr_cnt]`，wr_cnt++；`wr_cnt==1024`→`buf_full=1`
- 读侧（MCLK）：`fft_rd` 来→读 `ram[fft_sel][fft_addr]`（fft_sel = wr_sel 取反）
- `ack` 到：清 buf_full、wr_sel 取反、wr_cnt=0

> 全部 MCLK 域，无跨时钟，`buf_full/ack` 是同域握手。

### 3. fft_ctrl —— FFT 控制状态机（MCLK 域）

**职责**：串起"读时域 → 启动 FFT → 收频域 → 写频域乒乓"。

**状态**：
```
IDLE ─buf_full=1→ READ_TD（读时域 1024 点喂 xn_re）
     ─喂完→ START（拉 start）
     ─busy 计算中→ COLLECT（soud=1 时逐点收 xk_re/xk_im）
     ─eoud=1→ MAP_DONE（通知 spectrum_map 写频域乒乓）→ 翻转频域 sel
     ─→ ACK（拉 ack 清 buf_full）→ IDLE
```

**计算职责**：纯控制，不含数学运算。

### 4. FFT_Top —— Gowin FFT IP（1024 点，MCLK 域）

**职责**：时域→频域。`xn_re` 喂 1024 点，输出 `xk_re/xk_im`（前 512 为有效 bin）。

### 5. spectrum_map —— bin→柱高（MCLK 域，核心数学）

**职责**：把频域 bin 变成 128 柱柱高 + 超调目标。

```
input  mclk
input  xk_re[15:0], xk_im[15:0], soud   // FFT 逐点输出（soud=1 有效）
output bar_w[9:0], bar_we               // 写频域乒乓
output bar_addr[6:0]
```

**计算职责（逐拍，soud 每 bin 一拍）**：
```
① 幅值近似（免 sqrt）：
   re_abs=|xk_re|; im_abs=|xk_im|;
   mag = (re_abs>im_abs) ? re_abs+(im_abs>>2) : im_abs+(re_abs>>2);  // ~2%误差

② bin→柱（对数频率轴，替换原"4bin/柱线性"方案）：
   横坐标用对数轴（人耳感知是对数），128 柱等比覆盖 f_low..f_high：
     柱 n 边界频率 = f_low × (f_high/f_low)^(n/128)   （≈每柱0.078倍频程）
   bin k 频率 = k × fs/N（线性）→ 用预计算 ROM 映射：
     ROM bin2bar[0..511] = 每 bin 属哪柱（512×7bit）
     柱号 = bin2bar_rom[bin]
     同柱内取 max（低频柱吞多 bin，高频柱少 bin，>f_high 的 bin 落最后一柱或丢弃）
   注：bin 0（DC）丢弃，第一柱从 bin 1 开始

③ 对数缩放（20*log10）→ 0..479 柱高：
   查 256 项 ROM（mag[15:8] 索引 → 8bit 对数值）
   再映射 0..479
   （纵轴 dB 与横轴对数频率是独立的两个维度，各自独立实现）

④ 超调目标 = 柱高 × 1.2，clamp 479（存 ov_ram，复用现有光点）
```

**时序**：512 有效 bin，soud 每点一拍 → 映射 + 写频域乒乓共 ~512 拍。
**ROM 生成**：bin2bar 表在 fs/N 固定后（48k/1024=46.875Hz/bin）预计算，改 f_low/f_high 只换 ROM 内容，spectrum_map 逻辑不动。

### 6. freq_buffer —— 频域乒乓（唯一跨时钟点）

**职责**：双块频域 RAM（bar_h/ov 各 128×10bit），FFT 写一块、像素读另一块。

```
input  mclk                       // 写侧时钟
input  bar_w[9:0], bar_we, bar_addr[6:0]   // FFT 写
input  pix_clk                    // 读侧时钟
output q_y[9:0], q_ov[9:0]        // 像素读
input  pix_addr[6:0]
output sel_sync                   // 同步到像素域的翻转信号
```

**计算职责**：
- 写侧（MCLK）：写 `bar_ram[wr_sel]`，算完 128 柱 → 翻转 wr_sel、拉 sel
- **sel 双触发器同步到 pix_clk 域**（唯一跨时钟点）
- 读侧（pix_clk）：读 `bar_ram[sel_sync]`（永远完整一块）

---

## 三、缓冲矩阵

| 缓冲 | 写 | 读 | 容量 | 域 |
|---|---|---|---|---|
| 时域 A | 音频(MCLK) | FFT(MCLK) | 1024×16bit | 音频域 |
| 时域 B | 音频(MCLK) | FFT(MCLK) | 1024×16bit | 音频域 |
| 频域 bar_h[0/1] | FFT(MCLK) | 像素(pix_clk) | 128×10bit ×2 | 跨时钟 |
| 频域 ov[0/1] | FFT(MCLK) | 像素(pix_clk) | 128×10bit ×2 | 跨时钟 |

---

## 四、时序规划（关键）

### 4.1 攒点周期
```
MCLK = 256 × 48k = 12.288 MHz（周期 81.4ns）
Fs    = 48 kHz（采样间隔 20.83μs = 256 MCLK 拍）
攒满 1024 点 = 1024 × 20.83μs = 21.33 ms
```

### 4.2 FFT 计算耗时（MCLK 12.288MHz）
```
时域输入：1024 拍 = 83μs
蝶形计算：~1.5万拍 ≈ 1.2ms
频域输出：1024 拍 = 83μs（512 有效 bin）
总计：~1.3ms << 21.3ms（攒点周期）✓ 富余 16 倍
```

### 4.3 乒乓流水时序图
```
音频域（MCLK）:
  写A |=========== 21.3ms 攒满 ===========| buf_full → 切写B
      读取+FFT+映射A (1.3ms)  ← 与写B并行
  写B |=========== 21.3ms 攒满 ===========| buf_full → 切写A
      读取+FFT+映射B (1.3ms)
  写A |=========== 21.3ms 攒满 ===========| ...

像素域（pix_clk）:
  读频域 sel=0 一整帧(19.1ms) → sel 翻转到 1 → 读块1一整帧 → ...
```

**关键保证**：
- FFT 处理 1.3ms，音频攒点 21.3ms → 音频永不追赶 FFT（流水无阻塞）
- 频域 sel 翻转发生在任意时刻，但像素读的始终是"完整一块"（双缓冲），无撕裂

### 4.4 频域更新率 vs 显示帧率
```
频域更新：每 21.3ms 一次（46.9Hz）
显示帧：每 19.1ms 一帧（52.4Hz）
sel 翻转对像素是"整块切换"，两速率不同步无影响（双缓冲兜底）
```

---

## 五、跨时钟同步点（全工程只有 1 处）

```
音频域 sel (MCLK) ──双触发器──→ sel_sync (pix_clk)  → 像素选读哪块频域RAM
```

写法：
```verilog
reg sel_s1, sel_s2;
always @(posedge pix_clk) begin sel_s1 <= sel; sel_s2 <= sel_s1; end
assign sel_sync = sel_s2;
```

> 其余全部同域（MCLK 或 pix_clk），无需同步。

---

## 六、参数表

| 参数 | 值 | 位置 |
|---|---|---|
| FFT 点数 | 1024 | IP 固定 |
| 输入位宽 | 16 | IP 固定（32 截取）|
| 音频采样率 | 48 kHz | 系统 |
| MCLK | 12.288 MHz (256×48k) | 系统 |
| 有效 bin | 512（0..511）| 实输入对称（bin0 DC 丢弃）|
| 柱数 | 128 | 屏幕 |
| **频率轴** | **对数（20Hz..20kHz 等比）** | spectrum_map 的 bin2bar ROM |
| bin2bar ROM | 512×7bit 预计算 | fs/N 固定后生成 |
| 幅值 | max+0.25min 近似 | spectrum_map |
| 对数 | 20·log10 查 256 ROM | spectrum_map |
| 超调 | 柱高×1.2 clamp 479 | spectrum_map |
| FFT 耗时 | ~1.3ms | 时序 |
| 攒点周期 | 21.3ms | 时序 |

---

## 七、修改计划（分阶段，每步可验证）

| 阶段 | 内容 | 验证 |
|---|---|---|
| **P1** | 4 新模块骨架：audio_if/time_buffer/fft_ctrl/spectrum_map/freq_buffer，假正弦喂入 | 仿真：柱高正确、乒乓无竞争 |
| **P2** | 实例化 FFT_Top，串通"时域→FFT→映射→频域"整链路 | 仿真：1kHz→bin21 出峰 |
| **P3** | top.v 接入，page_sel 真假 FFT 切换 | 上板：假 vs 真柱对比 |
| **P4** | 接真音频合成模块，调 ADAPT 位宽 | 上板：真实频谱 |
| **P5** | 时序报告确认 slack>0 + 撕裂检查 | 上板+时序 |

**P1 不碰现有显示路径**：先证明"FFT 计算链 + 乒乓 + 跨时钟同步"在仿真里正确。

---

## 八、与现有工程的接缝

| 现有模块 | 改动 |
|---|---|
| `top.v` | 加 mclk/audio_in 端口；实例化 6 新模块；pix_clk 侧接 freq_buffer 读 |
| `data_source.v` | FFT 页数据源改为从 freq_buffer 读（q_y/q_ov 接口不变）；假数据保留对比 |
| `lcd_fft.v` | **不改**（光点/灯阵/颜色照常）|
| `lcd_draw.v` | **不改** |
| `lcd_timing.v` | **不改** |
| `800_480_screen.cst` | 加 mclk/audio_in 引脚约束 |

> 守住的架构不变式：**像素路径只查表，数据源输出 = 频域乒乓整块**。

---

## 九、FFT 核前面模块 待确定问题（需与音频合成模块协商确认）

> 这些参数直接影响 audio_if / time_buffer / bin2bar ROM 的实现，
> **必须拿到同学那边的确切信息后才能动手写代码**。以下每项都列了"为什么需要 + 影响什么"。

### A. 音频输出侧（最关键）

| # | 待确定 | 为什么需要 | 影响 |
|---|---|---|---|
| A1 | **MCLK 具体频率**（假设 256×48k=12.288MHz）| FFT 及所有音频域逻辑的时钟 | 时序预算、bin2bar ROM 依赖 fs |
| A2 | **MCLK 与 48kHz 采样是否同源**（一个 PLL 分频？）| 决定 xn_valid 同步难度 | 同源→低风险双触发即可；不同源→要握手 |
| A3 | **32bit 音频数据的有效位数**（高 16 位？还是 24 位有效？）| 决定 ADAPT 截取哪一段 | audio_if 的位宽截取 |
| A4 | **32bit 数据的格式**（I2S 左对齐 / 右对齐 / 二进制补码）| 决定截取起点 + 符号处理 | audio_if 截取 + 是否取反 |
| A5 | **音频采样率是否真的是 48kHz** | bin→频率映射 | bin2bar ROM 用 fs/N 生成 |
| A6 | **输出是否有"每采样一拍"的有效标志**（xn_valid/FSYNC）| 音频域采样写入触发 | time_buffer 写侧 |
| A7 | **音频模块能否暂停/反压**（填满时可否停一拍）| 决定时域乒乓是否需要 | 可暂停→单缓冲；不能→必须双缓冲（当前蓝图按双缓冲）|

### B. 频率轴参数

| # | 待确定 | 为什么需要 | 影响 |
|---|---|---|---|
| B1 | **频率显示范围 f_low / f_high**（默认 20Hz..20kHz？）| 对数横轴的两端 | bin2bar ROM 内容 |
| B2 | **音源实际频率范围**（合成模块输出的最低/最高有效频率）| 定 f_low/f_high 更合理 | bin2bar ROM + DC 处理 |
| B3 | **DC（bin0）是否丢弃** | 直流分量会顶满第一柱 | spectrum_map |

### C. 实现取舍（需你/同学拍板）

| # | 待确定 | 选项 | 影响 |
|---|---|---|---|
| C1 | **纵轴是否用 dB** | 用（20log10）或线性 | spectrum_map 是否查 log ROM |
| C2 | **FFT 输入要不要窗函数**（汉宁等）| 要（频谱泄漏小）或不要（省资源）| spectrum_map 前加窗乘法，或跳过 |
| C3 | **频谱平滑**（帧间泄漏积分）| 要（稳）或不要（响应快）| spectrum_map 输出后加 `new=max(old×k,new)` |

---

### 下一步（等同学答复后）

1. 拿到 A1/A2/A5 → 定 MCLK 频率、确认同源 → 生成 bin2bar ROM
2. 拿到 A3/A4/A6/A7 → 定 audio_if 截取 + time_buffer 写侧握手
3. 拿到 B1/B2 → 定 f_low/f_high → 生成 bin2bar ROM
4. C1/C2/C3 → 定 spectrum_map 功能范围
5. 全部确认后 → 开始 **P1**（4 模块骨架 + 假正弦仿真）