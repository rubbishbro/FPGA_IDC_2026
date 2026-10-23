# RTL 接口与编码规范（本工程采用）

> 来源：lowRISC Verilog Coding Style Guide + THU verilog-coding-standard（VCS 系列）
> 目标：接口正规化 + 内部算法规范化。所有模块按此标准对照重构。
> 原则：**每改一个模块前先探讨，改完综合验证 + 时序门禁（slack>0）**

---

## 一、命名规范

### 1.1 信号命名（snake_case）
- 全小写，单词下划线分隔：`bar_height`, `peak_hold`, `fft_busy`
- 不缩写（除非标准）：`data_in` 而非 `din`, `write_enable` 而非 `we`

### 1.2 极性后缀（_n 表示低有效）
- `rst_n` = 低有效复位（0=复位，1=不复位）
- `we` = 高有效写使能；`we_n` = 低有效写使能
- 混用时显式转换：`assign rst = ~rst_n;`

### 1.3 端口方向后缀（lowRISC 风格）
- 输入信号：`_i` 后缀 → `clk_i`, `data_i`, `valid_i`
- 输出信号：`_o` 后缀 → `data_o`, `valid_o`, `ready_o`
- 参数：`Width` / `Depth`（UpperCamelCase）或全大写常量

### 1.4 时钟/复位命名
- `clk_i`（输入时钟）
- `rst_ni`（输入低有效复位，lowRISC 风格）

### 1.5 前缀（THU VCS 风格，可选）
- 寄存器：`r_` 前缀（可选）
- 组合：`w_` 前缀（可选）
- 时钟域：`fft_`, `disp_` 前缀标明所属

---

## 二、类型规则（VCS-004）

| 场景 | 类型 |
|---|---|
| 时序逻辑（always @(posedge clk)）| `reg`，非阻塞 `<=` |
| 组合逻辑（always @(*) / assign）| `wire`，阻塞 `=` 或 assign |
| 常量 | `wire` + assign（如 `assign one = 1'b1;`）|
| 参数 | `parameter`（可调）`localparam`（模块内常量）|

---

## 三、always 块规则

### 3.1 一个信号只在一个 always 块赋值（VCS-005）
- 同一信号禁止出现在多个 always 块

### 3.2 组合用 always @(*) 或 assign（VCS-006/007/008）
- 组合 always 内**只用阻塞赋值 =**
- **每个分支必须赋值**（否则产生 latch）
- 不列敏感信号列表：`always @(*)` 而非 `always @(a,b,c)`

### 3.3 时序用 always @(posedge clk)（VCS-009/011）
- 时序 always 内**只用非阻塞赋值 <=**
- 复位：`always @(posedge clk or negedge rst_n)`
- 用 `if (rst_n)` 检查，不用 `negedge` 触发（VCS-012）

---

## 四、接口设计规范

### 4.1 模块端口统一风格
```verilog
module spectrum_map #(
    parameter  N_BARS   = 128,
    parameter  HEIGHT_W = 10
) (
    input               clk_i,
    input               rst_ni,
    // 输入：FFT bin
    input  [15:0]       xk_re_i,
    input  [15:0]       xk_im_i,
    input  [9:0]        bin_idx_i,
    input               bin_valid_i,
    // 输出：柱高
    output [6:0]        bar_addr_o,
    output [9:0]        bar_w_o,
    output [9:0]        ov_w_o,
    output              bar_we_o,
    output              frame_done_o
);
```

### 4.2 复位策略统一
- 全模块用 `rst_ni`（低有效）
- 同步复位或异步复位要统一（本工程现用异步复位 `negedge rst_n`，保持）

### 4.3 时钟域划分明确
- 每模块标注所属时钟域（pix_clk / audio_clk）
- 跨时钟用同步器，不裸连

---

## 五、注释规范

- 端口和参数必须注释（lowRISC 要求）
- 模块头部注释：功能、数据流、时钟域、关键时序
- `//` 行注释为主
- 自解释的内部信号可不注释

---

## 六、重构范围（按从底到上）

| 模块 | 现名 | 规范化目标 |
|---|---|---|
| `freq_pingpong` | 7bit 索引、端口无 _i/_o | 参数化 + _i/_o + 注释 |
| `spectrum_map` | bin2bar/bar_max/smooth 混合 | 分阶段状态机 + 端口规范 |
| `lcd_fft` | 光点逻辑 | 参数化 + _i/_o |
| `lcd_draw` | page_sel 选择 | 端口规范 |
| `top` | 顶层 | 实例化规范 |

---

## 七、验证流程（每模块改完）

1. ModelSim 编译（无 error）
2. 综合 + 查 timing_paths slack > 0
3. 上板确认功能不变

**按此顺序，从底层 `freq_pingpong` 开始，改前先探讨。**

---

## 八、本次重构的 6 条核心原则（辩证后定稿）

> 风格规范是"表面"，真正目的是**消除毛刺/延迟/误读**。以下原则每条都有
> CDC 实践或编码规范依据（见括号标注），重构时以"消除实际 bug 风险"为优先。

| # | 原则 | 依据/理由 |
|---|---|---|
| **P1** | **RAM/数组读写地址一律寄存器化** | 组合索引→毛刺→误读（本工程光点晃动已踩过）；"register combinational signal before crossing"（EDN CDC）|
| **P2** | **状态机用握手信号，不数硬编码拍数** | 数拍数→FFT 输出数/时序一变就崩；应靠 `eoud`/`frame_done` 等握手 |
| **P3** | **组合逻辑每分支必须赋值**（防 latch）| THU VCS-008：否则产生 latch |
| **P4** | **一信号一 always；时序非阻塞、组合阻塞** | THU VCS-005/007/011 |
| **P5** | **跨时钟交接处留 2-FF 同步器接口** | CDC 资料：2-flip-flop synchronizer；发送域先寄存（去毛刺）|
| **P6** | **端口加 `_i/_o` + 参数化** | lowRISC：便于复用、审查 |

### 辩证取舍（不强求的规范）
- **纯 Verilog**（Gowin 兼容优先，不转 SystemVerilog）
- **`_i/_o` 只对新重构模块**，旧模块连线不改（避免大规模回归）
- 命名统一 snake_case + `rst_ni`（低有效）

---

## 九、接口职责边界（重要决定记录）

> **原则：模块只对"自己该负责的"做保护，不堵上游的错误输入。**

### 9.1 数据正确性由上游保证（不在下游堵）

**`freq_pingpong` 的写对齐（P1）决策**：
- **不**在乒乓内部寄存对齐 `wr_addr/wr_bar/wr_we`
- 因为：乒乓假设上游（`spectrum_map`）给的地址/数据/使能**同步且正确**
- 若乒乓自己再寄存，会引入**额外一拍延迟**，反而与上游错位
- **正确归属**：写数据对齐由**上游 `spectrum_map` 自己保证**（改 spectrum_map 时实施）

### 9.2 模块自己做边界保护（该做的）

**`freq_pingpong` 写地址越界 clamp**：
- 越界写地址（`>= N_BARS`）**丢弃**，防止写坏内存
- 这是乒乓自己该做的（存储安全）

### 9.3 时钟域交接由乒乓负责

**`freq_pingpong` 改双时钟接口**（`wr_clk_i`/`rd_clk_i`）：
- 写侧（音频域）用 `wr_clk_i`，读侧（显示域）用 `rd_clk_i`
- 中间 `rd_sel` 用 **2-FF 同步器**（同域时退化，跨域时正确）
- **这是乒乓的职责**：跨时钟交接属于存储层

### 9.4 遗留记录（防遗忘）

- **`spectrum_map` 输出对齐**：地址/数据/使能必须同拍对齐，是上游责任，**改 spectrum_map 时实施**
- **真音频域（MCLK）对接时**：乒乓 `rd_sel` 同步器将真正生效，届时验证跨时钟正确性

---

## 十、跨时钟处理学习记录（2026-10-02）

> 参考：Clifford Cummings 异步 FIFO（`docs/ref/`，240 stars 的 `dpretet/async_fifo` 实现）。
> 结论：**我们"2 块乒乓"场景比 FIFO 更适合用状态机（EMPTY/FULL），不需要格雷码指针。**

### 10.1 async_fifo 学到的手段（可复用）

| 手段 | async_fifo 做法 | 我们工程对照 |
|---|---|---|
| **格雷码指针** | `wgraynext = (wbinnext>>1)^wbinnext`，跨时钟只变 1bit | 乒乓 2 块 `full_ptr` 天然 1bit ✓ 无需格雷码 |
| **full/empty 判断** | `wfull = (wgraynext == {~rptr[高位],rptr[低]})` 指针比较 | 乒乓用 `block_state==EMPTY` 更简单 ✓ |
| **写使能** | `wclken && !wfull` | `wr_ready && wr_valid` 同理 ✓ |
| **读方式可选** | `generate` 选 组合读(fallthrough) / 寄存器读(registered) | 可参考做波形快速读口 |
| **双口 RAM** | `fifomem` 写口(wclk)+读口(rclk) | time_pingpong 三端口已是双口 |

### 10.2 关键结论

1. **乒乓(2块) vs FIFO(深度N)**：乒乓适合读写交替、攒满再处理；FIFO适合连续流。
   我们"寻满1024→FFT处理"用乒乓正确。
2. **>2块乒乓时**：需引入格雷码指针（见 `docs/ref/wptr_full.v`）。
3. **波形快速读口**：若要低延迟读，参考 `fifomem.v` 的 FALLTHROUGH（组合读+锁存）。

### 10.3 源码保存位置

`docs/ref/`：async_fifo.v, wptr_full.v, rptr_empty.v, sync_r2w.v, sync_w2r.v, fifomem.v, async_bidir_fifo.v