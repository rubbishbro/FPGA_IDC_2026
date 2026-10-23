# 独立核心时钟观测（diagnostic_core_clock / clock_probe_top）

**2026-10-08父独立构建完成**：可下载`build/diagnostic_core_clock_20261008/gowin/core_clock_probe/impl/pnr/core_clock_probe.fs`（SRAM only），SHA256 `97b0a0d9c53e75725e70322b8487d99bddb89fef2cd63b01f2803474d68e0f13`。真实工程`build/diagnostic_core_clock_20261008/gowin/core_clock_probe/core_clock_probe.gprj`。

实际输出PLL→OBUF→B21已核对。报告setup/hold/recovery/removal及78条MPW均针对50MHz初始化支路，**没有100MHz内部时序负载，不能宣称100MHz MPW签核通过**。实际测量等待用户；完整记录、已知警告和测量指南见交付目录README。冻结构建后这里只修正文档/注释，未改变电路或约束命令。

本目录是一套**独立、最小化**的板级观测工程：把现有的真实 100 MHz 核心 PLL 输出
（`clk_core`）**直接**引到一根引脚，供示波器测量其高低电平、频率与占空比。它用于确认
「50 MHz 晶振 → 真实 `Gowin_PLL_core_100M` → 100 MHz → 焊盘」这条物理链路是否可用。

> **它不是主工程，也不替代主工程。** 它不实例化歌曲播放器、async FIFO、modal engine、
> 体滤波器、麦克风、音频 PLL 或 I2S 发送器；只在顶层例化现有的真实核心 PLL IP，
> 并对得到的 `clk_core` 作 `assign clk_probe = clk_core` 直通输出。
>
> 实现者（opencode-go/deepseek-v4.1-flash）只交付 RTL/约束/脚本/文档；随后父会话
> 独立冻结源文件、运行真实综合/P&R、核对综合网表、实际引脚及完整报告。
> 下载文件与验收范围见本文件末尾及 `build/diagnostic_core_clock_20261008/README.md`。
> 无人替用户操作 Programmer，实板测量仍待用户完成。

## 1. 文件（本次新增，均不修改任何现有生产文件或其它测试）

| 文件 | 作用 |
|---|---|
| `top.sv` | 顶层 `clock_probe_top`：只例化核心 PLL，`clk_probe = clk_core` 直通，`amp_sd = 0` |
| `clock_probe.cst` | 3 个引脚的约束（clk / clk_probe / amp_sd） |
| `clock_probe.sdc` | 50 MHz 输入时钟 + 100 MHz 生成时钟，并展开 setup/hold/recovery/removal/MPW 报告 |
| `sources.f` | 唯一的源文件清单（相对 SOURCE_ROOT），由构建 Tcl 读取并校验 |
| `gowin_build.tcl` | 独立 Gowin 构建入口（不触碰 `build/gowin`，不覆盖已建工程） |
| `README.md` | 本文件 |

**未改动任何现有歌曲 / core / IP / ROM / 生产SDC / 生产CST / 测试文件。** 全部 IP 与只读 RTL
均为**只读引用**：`ip/pll_init.v`、`ip/pll_core_100m/gowin_pll_core_100m.v` 与
`..._mod.v`。生产 IP 的 SHA 必须与冻结快照逐个一致（由父会话核对，不是本实现的声明）。

## 2. 数据流与时钟

```text
clk (P16, 50 MHz 晶振)
  └─ Gowin_PLL_core_100M (现有真实 IP；clkin=clk, init_clk=clk, lock=未使用)
        └─ clk_core = 100.000 MHz
              └─ assign clk_probe = clk_core   (不门控 / 不倒相 / 不分频)
                    └─ OBUF → B21 / J26 pin12

amp_sd = 1'b0  (常量；J26 pin5 / A17，仅把现有 MAX98357A 置于安全静音)
```

* `clk_core` 由**现有真实厂商 PLL IP** 生成，PLL 参数（`IDIV_SEL=1 FBDIV_SEL=1
  MDIV_SEL=14 ODIV0_SEL=7` → VCO 700 MHz / 7 = 100 MHz）**不改动**。
* 输出路径保持直通，综合/布局后应为 **PLL CLKOUT0 → OBUF → 焊盘**，没有 LUT/DFF 再生成。
* **没有**任何内部 100 MHz DSP/RAM/逻辑负载：本工程不冒充生产内部端点的 MPW 实验。
* **不带音频 PLL**、不接 U4 复位（U4 物理极性/有效电平在用户侧尚未闭环，故不接、不假设）。

## 3. 引脚与接线（3 pin）

目标板：Tang Mega 138K Pro Dock，GW5AST-LV138FPG676A / FPG676。

| 端口 | 引脚 | 位置 | 电气 |
|---|---|---|---|
| `clk` | P16 | — | 输入，`PULL_MODE=NONE DRIVE=OFF BANK_VCCIO=3.3`（官方示例） |
| `clk_probe` | B21 | **PMOD2 / J26 pin12** | `LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3` |
| `amp_sd` | A17 | PMOD2 / J26 pin5 | `LVCMOS33 PULL_MODE=DOWN DRIVE=8 BANK_VCCIO=3.3` |

* B21 = `PMOD2_IO4` = J26 第 12 脚，A17 = `PMOD2_IO3` = J26 第 5 脚；来源为
  `reference_agent_readfirst/tang_mega_138k_pro_basic_resources/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf`
  （J26/PMOD2 网表块）。B21 作为调试输出此前已获用户授权。
* 本文件**不猜测 SLEWRATE**（现有已验证约束里没有该事实，故不写）。
* 接线前必须对照实物确认 J26 第 1 脚方向与 GND：**J26 的 GND 在第 3、4 脚**，
  不能仅凭照片或本文件推断物理朝向。

## 4. amp_sd 与功放安全

`amp_sd` 设计为**常量 0**。对 MAX98357A，SD=0 为 **shutdown**（安全静音），因此：

* 无需修改 MAX98357A 的 GAIN；
* 稳妥起见，首次测量时**先断开 MAX98357A 供电**，或确认 SD 常 0，二选一即可保证功放静音。

## 5. 构建（只建工程，不烧录；请父会话执行真实构建）

```bash
export LD_LIBRARY_PATH="$HOME/gowin/IDE/lib:$LD_LIBRARY_PATH"
cd <repo root>
printf 'source rtl/platform/tang_mega_138k_pro/diagnostic_core_clock/gowin_build.tcl\n' | gw_sh -nocomp
```

* 这是已验证的 `gw_sh -nocomp` + stdin `source` 方式（同
  `diagnostic_tone/gowin_build.tcl`），不猜测额外 CLI。
* 器件：`GW5AST-LV138FPG676AES` / Device Version B，SystemVerilog-2017。
  **用户实际硅片型号/速度等级/是否 ES 仍未确认**，器件字符串不等于实物已核实。
* 源根：优先 `SOURCE_ROOT` 环境变量（父会话冻结快照根），否则由本脚本位置向上定位，
  再退回当前目录；选中的根必须含 `sources.f`。
* 输出目录：唯一专用 `build/diagnostic_core_clock`，可用 `BUILD_DIR` 覆盖为新专用路径；
  落入 `build/gowin` 或含 `song_synthesis` 的路径会被拒绝；已存在 `core_clock_probe.gprj`
  或 `core_clock_probe/impl` 时直接 error，`create_project` 不使用 `-force`，绝不覆盖已建工程。
* 脚本只 `run syn` / `run pnr`，**不执行 Programmer**、不产生「已烧录」结论。

**用户下载（SRAM only）：** 待父会话真实构建产出 `.fs` 后，Programmer 选
`GW5AST-138B → SRAM Mode → SRAM Program`；**不写 Flash、不按 RECONFIG**。断电后需重新下载。

## 6. 测量步骤（示波器 / 探头）

1. **探头设置：** 优先使用**短地弹簧**、**10×** 探头、**1 MΩ** 输入。**禁止** 50 Ω 直接
   终端，也**禁止**把地夹接到功放 OUT−；地只接公共地。
2. **接地：** 探头地（短地弹簧）接 **J26 pin3/4（GND）**，探针接 **B21 / J26 pin12**。
3. **带宽建议：** 示波器/探头建议**至少 200 MHz（更高更好）**；采样率 **≥ 1 GS/s**，
   越高越好。
4. **先看整体：** 确认是**约 100 MHz** 的稳定方波——名义周期 **10 ns**，高/低电平各**约
   5 ns（50% 占空比）**。
5. **再测参数：** 幅度、频率（frequency）、以 50% 门限读高/低电平（high/low @50%）、
   占空比（duty）。
6. **锁稳后再读统计：** 待 PLL 锁定、波形稳定后，再使用示波器的 capture/统计功能读取
   频率/占空比/幅度统计。

**诚实声明：** 有限的示波器/探头带宽、IO 传输延迟与阈值设置都会影响读数（B21 到示波器
之间存在不可避免的探针/线缆负载）。因此上述测量是**物理观测**，**不构成保真度保证**，
也不等于内部逻辑端点上的波形。

## 7. 边界与诚实声明（重要）

* `clk_probe` 是**观察时钟口**：本 SDC **不写 `set_output_delay`**，因为这里**没有外部
  同步接收端的 setup/hold 截止时间**。本实验**不冒充**已签核的 I/O 约束，也不从本测量
  推断生产 I/O 时序已通过。
* 本 SDC **刻意不写** `set_clock_latency` / `false_path` / `clock_groups` /
  `set_clock_uncertainty` 等无依据的「假数」约束。
* 本设计的**基础负载布局与生产不同**，**不能替代生产 100 端点 / 全 PVT 的 MPW 验证**。
* **不能**仅凭「名义 50% 占空比」就认定 STA 正确或错误：必须由父会话读取真实
  setup/hold/recovery/removal 与 MPW 报告判断；`report_min_pulse_width` 未命中对象
  （"Nothing to report!"）或 Ignored/Inactive 约束由父会话在真实报告上核对。
* **尚未填写**：bitstream 路径、时序 PASS 结论、SHA256 —— 均留待父会话真实构建后填写。
* 本实现**未运行**真实 Gowin 构建/GUI/Programmer；以上频率/参数为 RTL 与 PLL 参数推导值，
  不是实测结果。实板测量结果待用户回报，不等同全温压/PVT 或生产放行。
