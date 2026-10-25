# Keyboard Board Bring-up

外接自绘 4×4 压力键盘板的独立 bring-up 工程。

## 当前状态

已上板确认基本显示逻辑可用：

- 按下某个压力点，对应 8×8 点阵的 2×2 区域变亮；
- 旁边灯不再大面积误亮；
- 8×8 点阵串行控制正常；
- ADC、mux、行扫描已联调。

当前版本还保留原驱动的摇杆通道扫描，等摇杆硬件到货后再处理。

## 硬件接口

- FPGA：Tang Mega 138K Pro / GW5AST-138
- 时钟：50 MHz，P16
- 供电：3.3 V
- 数字接口：J22 / PMOD1
- ADC：ADCV_P，ADCV_N 接 GND
- LED：8×8 自带控制器点阵，串行数据输入

### J22 引脚

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

ADC：

```text
键盘板 ADC 输出 -> ADCV_P (N12)
ADCV_N (P11)   -> GND
```

ADC 使用 Gowin 专用 ADC 引脚，不在 `.cst` 里写普通 `IO_LOC`。

## 时钟和基本节拍

```text
主时钟 clk       = 50 MHz
clk_en           = 每 20 个 clk 一次 = 400 ns
ADC 窗口         ≈ 102.4 us
压力矩阵一行     ≈ 4 × 102.4 us = 409.6 us
```

LED 串行协议：

```text
内部节拍       400 ns
一个 LED bit   3 × 400 ns = 1.2 us
整屏 1536 bit  ≈ 1.84 ms
加复位          ≈ 1.9 ms
```

顶层给 LED 留的刷新间隙：

```text
6000 × 400 ns = 2.4 ms
```

## 驱动结构

本工程没有修改 `rtl/drivers/pad_driver.sv`。
为了保留原驱动，同时修正板级问题，复制了一份到：

```text
keyboard_board/board/pad_driver_board.sv
```

板级工程使用本地副本。

内部模块：

```text
sense4x4_joystick
  ├─ shift_timer 行扫描
  ├─ Gowin_ADC
  └─ ch_s / fmap
led8x8
  └─ LED_DAT 串行输出
```

## 修复记录

### 1. 行扫描 2.5MHz bug

原驱动里行扫描使能是：

```verilog
(chn_s == 2'b11) & cr.clk_en
```

`chn_s == 3` 会持续约 100us，所以行线在这段时间里每 400ns 就移一次，实际是 2.5MHz 乱转。

本地副本改成单周期 `row_step`：

```verilog
wire adc_step = cr.clk_en & (cnt == '1) & adc_rdy;

always_ff @(posedge cr.clk or negedge cr.rst_n) begin
    if(!cr.rst_n)
        row_step <= 1'b0;
    else
        row_step <= (chn_s == 2'b11) & adc_step;
end

shift_timer row_scan (.cr({cr.clk, row_step, cr.rst_n}), .val(row_s));
```

仿真结果：

```text
row0 -> row1 : 409.6 us
row1 -> row2 : 409.6 us
row2 -> row3 : 409.6 us
row3 -> row0 : 409.6 us
```

### 2. 2×2 灯阵映射错位

旧顶层映射用了像素块内部低位，导致一个压力格子的 4 个像素去读 4 个不同压力值。

现在改成：

```verilog
wire [2:0] led_x = fill_idx[2:0];
wire [2:0] led_y = fill_idx[5:3];
wire [3:0] cell_idx = {led_y[2:1], led_x[2:1]};
```

即：

```text
压力格行 = LED y / 2
压力格列 = LED x / 2
cell_idx = 行*4 + 列
```

一个压力点只对应 2×2 四个像素。

### 3. mux 切换后 ADC 采样太早

本地副本加入了 10us 通道稳定时间：

```text
ch_s 变化
-> adc_req 保持低 25 个 400ns
-> 再启动 ADC
```

这也减少了强按一个点后，旁边通道读到残压而导致弱亮的问题。

### 4. 压力阈值

当前参数：

```text
P_THRESH    = 16
BRIGHT_SHIFT = 2
```

ADC 是 14-bit signed，电压模式约：

```text
实际电压 ≈ adc_val / 2048
```

顶层取 `adc_val[13:6]`，所以：

| 电压 | raw[7:0] |
|---:|---:|
| 0.25V | 8 |
| 0.50V | 16 |
| 0.75V | 24 |
| 1.00V | 32 |

`P_THRESH=16` 相当于约 0.5V。

## 当前显示行为

- 4×4 压力格子映射到 8×8 点阵的 16 个 2×2 区块；
- 亮度约为 `raw >> 2`；
- 未达到阈值的格子保持黑色；
- 固定测试模式可把 `FIXED_CENTER4` 设为 1，只亮中心 2×2。

## 构建

```powershell
cd board
& "D:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" flow.tcl
```

输出：

```text
keyboard_board/board/impl/pnr/keyboard_board.fs
```

当前 PnR：

```text
SETUP slack : +10.857 ns
HOLD slack  : +0.275 ns
```

## 仿真

```powershell
cd sim
& D:\gowin\win64\vlog.exe -sv ..\..\rtl\drivers\pkg\clk_rst_pkg.sv `
    ..\..\rtl\drivers\pkg\pad_driver_pkg.sv `
    ..\..\rtl\math\pkg\fxp_pkg.sv `
    ..\..\rtl\math\math.sv `
    ..\board\pad_driver_board.sv adc_stub.sv tb_row_scan.sv

& D:\gowin\win64\vsim.exe -c -do "run -all; quit" tb_row_scan
```

结果：

```text
=== ROW SCAN TEST PASSED: ~409.6 us per row ===
```

## 已知限制

- 4×4 压力到音高的映射尚未实现。
- 当前只验证压力点和 LED，不包含正式主引擎接入。
- 原驱动仍会扫描摇杆通道 4/5；未接摇杆时，某一行会比正常多保持约 200us。
- LED 点阵协议兼容性以实物 8×8 点阵为准。
- `rtl/drivers/pad_driver.sv` 保持原版；所有修改只在 `keyboard_board/board/pad_driver_board.sv`。

## 后续

1. 摇杆到货后决定通道 4/5 是独立读还是每行读；
2. 把 4×4 压力值映射到音符/引擎 slot；
3. 如需看原始 ADC 数值，再做一个最小 LCD/串口调试显示；
4. 如需稳定对称行脉冲，可暂时关闭摇杆扫描，只扫 16 个压力点。
