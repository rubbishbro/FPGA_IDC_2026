# Keyboard Board Bring-up

外接自绘键盘板的独立硬件测试工程。

- FPGA：Tang Mega 138K Pro / GW5AST-138B
- 时钟：50 MHz，P16
- 供电：3.3 V
- 数字接口：J22 / PMOD1
- ADC：ADCV_P，ADCV_N 接 GND
- 8×8 LED：使用现有 `led8x8` 驱动输出串行数据

当前没有修改 `FFT_spectrumshow/`、`rtl/core/` 或 `rtl/router/`。

---

## 0. 时钟

```text
clk      50 MHz，P16，直接来自板级晶振
clk_en   每 20 个 50 MHz 周期一个脉冲 = 2.5 MHz / 400 ns
```

`pad_driver` 的逻辑仍由 50 MHz 采样，但只在 `clk_en` 有效时推进，等价于 400 ns 节拍。
LED 串行协议、行扫描、ADC 节拍都用这个 400 ns 时基。
ADC 每通道约 100 us 更新一次，4×4 全扫约 1.6 ms。

---

## 1. 引脚

### 数字接口 J22 / PMOD1

| 键盘板信号 | FPGA 信号 | J22 pin | FPGA pin |
|---|---|---|---:|
| ROW0 | `row_s[0]` | 11 | C24 |
| ROW1 | `row_s[1]` | 9 | E25 |
| ROW2 | `row_s[2]` | 7 | L17 |
| ROW3 | `row_s[3]` | 5 | H14 |
| SEL0 | `mux_sel[0]` | 12 | B24 |
| SEL1 | `mux_sel[1]` | 10 | D25 |
| SEL2 | `mux_sel[2]` | 8 | L18 |
| LED_DAT | `led_dat` | 6 | H15 |

J22 电源：

```text
pin 1 / 2 = GND
pin 3 / 4 = +3V3
```

### ADC

```text
键盘板 ADC 输出 -> ADCV_P (N12)
ADCV_N (P11)   -> GND
```

GoWin ADC 由 `Gowin_ADC` 原语使用专用 ADCV 引脚，不需要在 `.cst` 里写普通 `IO_LOC`。

---

## 2. 工程结构

```text
keyboard_board/
  src/
    keyboard_board_top.sv   顶层：POR、400ns clk_en、ADC 亮度/固定图案
  board/
    keyboard_board.gprj     Gowin 工程
    keyboard_board.cst      J22 数字引脚约束
    timing.sdc              50 MHz 时钟约束 + LED 慢协议例外
    flow.tcl                综合 / PnR / bitstream
  README.md
```

复用：

```text
rtl/drivers/pad_driver.sv
rtl/drivers/pkg/clk_rst_pkg.sv
rtl/drivers/pkg/pad_driver_pkg.sv
rtl/drivers/gowin_adc/gowin_adc.v
rtl/math/math.sv
rtl/math/pkg/fxp_pkg.sv
```

`pad_driver` 内部已经包含：

```text
led8x8
sense4x4_joystick
shift_timer
```

所以没有重写矩阵扫描和 LED 逻辑。

---

## 3. 当前默认：ADC 原始亮度

```text
FIXED_CENTER4  = 0
FORCE_ADC_ZERO = 0
P_THRESH       = 0
BRIGHT_SHIFT   = 2
```

映射：

```text
cell_raw = fmap.flat_d[row*4 + col].val
cell_p   = (cell_raw > 0) ? (cell_raw >> 2) : 0

R = G = B = cell_p
```

也就是：

```text
空闲 -> 应接近黑
按压力度越大 -> 对应 2×2 区域越亮
```

`BRIGHT_SHIFT=2` 把最大亮度从 255 降到 63，避免 64 个像素全亮时电流过大。

注意：这是 8-bit 数字量直接映射，不是经过校准的电压值，也没有 gamma。

---

## 4. 固定图案自检

把 `FIXED_CENTER4` 设为 1：

```text
FIXED_CENTER4 = 1
```

LED 只亮最中心 2×2：

```text
(3,3) (3,4)
(4,3) (4,4)
```

这个模式不经过 ADC，用来单独验证 LED。

---

## 5. ADC=0 对照 bitstream

为了区分 ADC 和 LED/电源问题，已经生成：

```text
keyboard_board/board/impl/pnr/keyboard_board_adc0.fs
```

它把 `FORCE_ADC_ZERO` 置 1，所有像素数据强制为 0。

预期：

```text
整屏全黑
```

- 全黑：LED 数据路径和供电基本没问题，问题在 ADC/扫描；
- 仍然全亮/闪烁：LED 数据、供电、点阵控制器或地线问题。

正常 ADC 亮度版本仍是：

```text
keyboard_board/board/impl/pnr/keyboard_board.fs
```

---

## 6. ADC 值在现有代码中的用途

`sense4x4_joystick` 只做采集：

```text
ADC[13:6] -> fmap.flat_d[row*4+col].val
```

ADC 按 signed 14-bit 处理。负值钳到 0，避免未接/零输入时最高位为 1 被当成 0xFF 全亮。

现有主引擎里：

- `rtl/router` 用 `fmap` 做每个 slot 的 note_on/note_off 门限、激励幅度、包络和调制；
  但没有从 4×4 格子到音高的映射。
- `rtl/core/router_frontend` 只取 `fmap[7:0]` 作为压力，其他 15 格没有进入前端。
- 当前 `keyboard_board_top` 把 16 个 `fmap` 值映射到 8×8 点阵的 2×2 区块。

---

## 7. LED 写入方式

`led8x8` 的接口是：

```text
x[2:0], y[2:0], pix[23:0], wr
```

- `wr=1`：写 gram；
- `wr=0`：刷新整屏；
- 有效节拍 400 ns；
- 不能在 `S_TX` 期间写。

顶层每帧扫描 64 个像素：

```text
fill_idx = 0..63
x = fill_idx[2:0]
y = fill_idx[5:3]
```

写完后 `wr` 拉低约 2.4ms，让 `led8x8` 串行刷新。

---

## 8. 构建

```powershell
cd board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow.tcl
```

输出：

```text
board/impl/pnr/keyboard_board.fs
```

当前 ADC 亮度版本 PnR：

```text
SETUP slack : +10.032 ns
HOLD slack  : +0.275 ns
```

ADC 报告中出现：

```text
ADCV_P -> N12
ADCV_N -> P11
```

LED 串行协议是 400ns 级慢协议，`idx`/`gram` 到 `trig` 的路径在 `timing.sdc` 里设为 false path。

---

## 9. 上板验证

### 先烧 ADC=0 对照

```text
keyboard_board_adc0.fs
```

预期全黑。

### 再烧 ADC 亮度版本

```text
keyboard_board.fs
```

预期：

```text
不按键：所有 2×2 区块接近黑色
按压一个格子：对应 2×2 区块变亮
压力越大：亮度越高
```

### 对照结论

| `adc0` 结果 | `adc` 结果 | 判断 |
|---|---|---|
| 全黑 | 全亮/乱跳 | ADC 数据或扫描问题 |
| 全黑 | 正常变化 | ADC 通路正常 |
| 全亮 | 全亮 | LED 数据/供电/地线问题 |
| 闪烁 | 闪烁 | 供电电流或 LED 刷新问题 |

---

## 10. 已知限制

- 4×4 压力格子到音高的映射尚未实现。
- ADC 亮度是 8-bit 直接映射，没有校准/迟滞/gamma。
- 摇杆未接，`pos` 未使用。
- 如果行脉冲需要低有效，需要在顶层取反；当前沿用 `pad_driver` 原有 one-hot 高有效。
- LED 协议兼容性仍以实板中心四点测试为准。
