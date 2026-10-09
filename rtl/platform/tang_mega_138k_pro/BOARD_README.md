# 板级构建与下载操作

进度、资源和验收结论统一见[工程汇报](../../../docs/工程汇报.md)。此页只保留操作入口，不再维护重复状态。

## 构建入口

- `sources.f`：真实综合源列表，不含仿真PLL模型。
- `board_top.sv`：生产综合顶层，开启guitar共享箱体，ROM采用绝对路径。
- `gowin_build.tcl`、`build.sh`：Gowin真实综合/布局布线入口。
- `tang_mega_138k_pro.cst`、`tang_mega_138k_pro.sdc`：管脚和时序约束。
- `board_build.json`：机器可读清单，保留原声明`GW5AST-LV138FPG676A`；既有实际构建使用`GW5AST-LV138FPG676AES`、版本B，实物型号待核实。清单中的旧产物状态不替代统一汇报。
- [真实PLL说明](ip/README.md)：核心100MHz、音频12.5MHz。

在仓库根目录执行结构预检查：

```bash
python3 rtl/platform/tang_mega_138k_pro/preflight.py --no-tool
```

退出0只表示该脚本覆盖的文件、ROM、PLL接口与约束一致，不代表时序或实板通过。需要重新构建时使用`build.sh`并保留独立输出，不能覆盖已验证候选。

## 接线与临时下载

接线只按[功放与喇叭接线说明](MAX98357A_WIRING.md)。下载使用用户已有`flash.sh`和绝对`.fs`路径，末尾参数`2`表示SRAM；不要使用Flash操作参数，也不要按RECONFIG加载旧Flash。

```bash
bash /home/rubbishbro/Desktop/FPGA_IDC_2026/rtl/platform/tang_mega_138k_pro/flash.sh /home/rubbishbro/Desktop/FPGA_IDC_2026/build/song_sram_trial_v5_20261008/song_sram_trial_v5.fs 2
```

每次下载替换当前运行设计，断电不保留。下载由用户操作，助手不操作Programmer。若CLI报找不到数据文件，先检查绝对路径与参数，不改成Flash下载。

独立诊断的操作说明：[持续测试音](diagnostic_tone/README.md)、[100MHz时钟引脚观测](diagnostic_core_clock/README.md)。它们不是歌曲工程的一部分，不能与歌曲同时运行。
