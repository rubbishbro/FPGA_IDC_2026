# sim/ — cocotb 验证环境

功能仿真用 **cocotb + Icarus Verilog**，Gowin 只负责综合/布局布线/烧录。
testbench 是 Python，和 `python/modal_sim/` 的参考实现同语言，**逐采样对拍**最省事。

## 1. 环境（已装好）

| 组件 | 版本 | 位置 |
|---|---|---|
| Icarus Verilog | **13.0** | `~/micromamba/envs/torch312/bin/iverilog` |
| cocotb | **2.1.0** | `torch312` 环境（pip 装的） |
| Python | 3.12.14 | `torch312` 环境（同时有 numpy/scipy，可直接对拍） |

**必须先把环境激活**，否则找不到 `iverilog`：

```bash
micromamba activate torch312     # 或者 export PATH=$HOME/micromamba/envs/torch312/bin:$PATH
```

## 2. 两个必踩的坑

1. **每个 RTL 文件都要有 `` `timescale 1ns/1ps ``**。
   iverilog 不给 `timescale` 时精度是 **1 秒**，cocotb 的 `Clock(dut.clk, 10, unit="ns")`
   会直接报 `Bad period: Unable to accurately represent 10(ns)`。
2. **iverilog 在 PATH 上**（见上）。`pip install` 的 cocotb 会用 `which iverilog` 找仿真器。

## 3. cocotb 2.1 的写法（与网上 1.x 教程不同，注意）

```python
from cocotb_tools.runner import get_runner   # 1.x 是 cocotb.runner，已改

runner = get_runner("icarus")
runner.build(sources=[...], hdl_toplevel="...", build_dir=..., waves=True)
runner.test(hdl_toplevel="...", test_module="...", test_dir=..., build_dir=..., waves=True)
```

```python
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

@cocotb.test()
async def t(dut):                      # 2.x：测试函数直接收 dut
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    ...
    await RisingEdge(dut.clk)
    await Timer(1, unit="ns")          # 躲开非阻塞赋值的更新时刻再采样
    v = int(dut.q.value)               # 2.x：value 是 LogicArray
```

**验"reset 后状态确定"**（`fpga_platform.md` §7 的要求）：
cocotb 是 4 态仿真，可以显式查 X——

```python
assert dut.q.value.is_resolvable, f"reset 后仍有 X: {dut.q.value}"
```

## 4. iverilog 13.0 的 SystemVerilog 支持边界（实测）

**可用**（放心写）：

* `logic` / `always_ff` / `always_comb` / `unique case` / `typedef enum`
* **packed `struct`**（当变量、当端口都行）
* `interface` + `modport`，**但只能在模块内部实例化**
* **立即断言** `assert (cond) else $error("...")`
* `generate for`、`for (int i=...)`、寄存器数组、数组元素赋值
* `function automatic` + `case`（**这是绕开"数组参数不支持"的正规办法**）
* `$clog2`、`package` / `import`、类型转换 `T'(x)`
* `$readmemh` 载入 ROM：`logic [47:0] rom [4096];` ← **系数表就用这个**
* 有符号乘加、算术右移 `>>>`、定宽转换 `24'(acc)`
* `real` + `$fwrite`（testbench 里写浮点参考很方便）

**不支持**（必须避开）：

| 写法 | 结果 | 替代 |
|---|---|---|
| `interface` 出现在**端口列表** | ❌ 语法错误 | 用离散端口（`input logic clk, ...`） |
| **SVA** `assert property (...)` | ❌ 语法错误 | 只能用立即断言；时序性质用 cocotb 写 |
| **unpacked array 参数** `parameter int C[N] = '{...}`、`localparam int C[4]` | ❌ `sorry: unpacked array parameters are not supported yet` | `function`+`case`、packed array、或 `initial` 填充 |

## 5. 为什么不用 Verilator（现阶段）

Verilator 更快、SV 支持更全、能跑 SVA，但它是 **2 态**仿真——**看不到 X**，
正好和我们最需要的"reset 后状态确定"检查相冲突；且 cocotb+Verilator 要 `--timing` 且不支持完整 VPI。
**结论：iverilog 做功能对拍（4 态，能抓 X），Verilator 留到后期需要跑长音频/大复音时的加速选项。**

## 6. Gowin 仍然不能完全省掉

功能正确性靠 cocotb；但**资源（LUT/FF/B-SRAM/DSP）和时序（Fmax）只有 Gowin 综合/布局布线报告能给**。
`fpga_platform.md` §8 的迁移判据也要求看综合报告。所以：

```
cocotb + iverilog  →  功能正确性、逐采样对拍、X 检查
Gowin IDE          →  综合/布局布线/时序报告 + 烧录
```
