# rtl/math

从 `history/rtl/math` 迁入的定点/CORDIC 依赖：

```text
math.sv          cart2polar / polar2cart / sqrt / inv
pkg/fp_intf.sv   sfp/ufp 接口
pkg/fp_ops.sv    基于接口的定点运算模块
pkg/fxp_pkg.sv   当前工程的 fxp_pkg（原有）
```

`fp_ops.sv` 使用 SystemVerilog interface 端口；Icarus 对 interface 端口支持不完整，
Gowin/XSim 侧按原工程方式使用。
