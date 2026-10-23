# 歌曲启动无声：DS与父会话综合网表复审

> 历史归档：保留当轮记录，不代表当前状态；当前只读[工程汇报](../../../工程汇报.md)

日期：2026-10-07。范围：审查已有歌曲版本，不修改生产RTL、不重新运行Gowin、不下载硬件。

**本文件记录修复前的故障审查。用户随后授权修复；最终保留的最小功能修复与时序未放行状态见[元数据修复验收](song_metadata_fix_review.md)，不将本文件末尾的“未改核心”作为最新工作区状态。**

## 结论与证据等级

**已确认原歌曲综合网表的启动功能与冻结RTL不同：首音符需要27个模态，但bank的装载记账`low_unloaded[0]`停在16，导致首帧无法运行，`playback_ready`始终为0。**

这精确复现用户的“BCLK/LRC运行、DIN零、SD低”表现，是目前有直接复现实验支持的首要原因。但本次没有实板读取内部状态，不把功能仿真等同于物理实测，也不宣称排除了所有复位、时序或硅片读取风险。

DS先提出并复现该问题；父会话另写同条件、带断言的夹具，使用**原始综合网表和完整未修改的厂商原语库**重新编译、复跑，不使用DS裁剪原语库或PLL stub。

## 1. 测试对象与边界

- 原歌曲文件：`build/song_synthesis_core100_20261007/parent_core100.fs`。
- 原综合文件：`/tmp/opencode/core100-review/build/parent_core100/impl/gwsynthesis/parent_core100.vg`。
- 网表SHA256：`0d44438e9c0482db814650a427e0ec8631072b3ca8cb11aa8f55a4ab2a68fa7b`。
- 原语库：`/home/rubbishbro/gowin/IDE/simlib/gw5a/prim_sim.v`，SHA256 `7109c2568188627465d218bc099cf72f12e90807c21d4d862d2335b499043544`。
- RTL对照来自`/tmp/opencode/core100-review/parent_source_snapshot/`，实际32声部、48模态、guitar箱体、NOTE_GAP=12000、真实ROM。
- 两者都使用100MHz核心时钟、12.5MHz音频时钟，复位在1001ns释放，运行300µs。
- 直接实例化`audio_demo_core`，外部提供时钟/复位；**不覆盖PLL、PLL_INIT、U4、板级复位、布局布线延迟或PVT**。综合模块的端口被工具改名，夹具按原网表连接。
- 原网表未修改；vendor库未修改；未为了通过测试替换ROM、bank、lane、body、FIFO或I2S。

## 2. 父会话独立对照结果

同一夹具的原始日志带断言结果如下。tick和load按有效拍计数，不把一个脉冲的上升/下降沿误写成两次完成；时间以ns打印。

| 300µs观察窗内的量 | 冻结RTL | 原综合网表 |
|---|---:|---:|
| 核心采样节拍 | 14 | 14 |
| 成功装载完成脉冲 | 1 | 1 |
| voice0所需模态数 | 27 | 27 |
| bank的`low_unloaded[0]` | **27** | **16** |
| 引擎输出有效拍 | 14 | **0** |
| FIFO写侧full（窗末） | 0 | 0 |
| 首次`playback_ready=1` | 23,510ns | **从未发生** |
| DIN高电平（核心负沿采样计数） | 3424 | **0** |
| BCLK变化（同样采样计数） | 1873 | 1873 |
| 窗末歌曲/引擎/bank状态 | IDLE/IDLE/IDLE | **S_SAMPLEW/E_WAIT/IDLE** |

这里DIN计数只用于确认是否有活动，不是完整I2S逐位解码验收；本次没有将全部14帧PCM与黄金逐位比较。

### 因果干预（仅仿真夹具，不是修复）

父会话还进行了第三组测试：**原网表、原原语库和时钟保持不变，仅在load_done之后，在testbench中force六位`low_unloaded[0]`为27。**

结果首个`playback_ready`在23,510ns拉高，14次引擎输出、3424个DIN高采样点，与RTL对照的上述计数一致。该实验说明错误记账本身足以阻断首帧，也说明纠正这一元数据后现有后级能产生输出。

**force不是可交付修复，不会进入生产RTL/网表/bitstream，也不构成修复版数值或时序验收。**它只提供因果定位证据；不能据此声称综合网表其余音符、全声部、reset后重装载都已等价。

## 3. 为什么`ready`无法拉高

本次要区分三种ready：

1. **TX FIFO的写ready：不是首个阻塞点。**复位后FIFO非满，可以接收；但上游没有产生首个PCM valid。
2. **引擎sample_ready：首帧请求进入后，引擎转入E_WAIT，等不到bank结果，不能回到空闲。**
3. **对外`playback_ready`：只在首个`core_tx_valid && core_tx_ready`后置1。**上游没有输出，FIFO自然没有该握手，功放SD继续被门控为低。

链路如下：

```text
音频帧节拍正常
  → 首音符ROM装载完成，engine记录n_modes=27
  → bank装载记账却为16
  → 27 > 16，首帧被判“系数未装全”
  → bank留在IDLE，不发out_valid
  → engine停E_WAIT，song停S_SAMPLEW
  → 箱体没有输入、PCM没有valid、FIFO没有写入
  → playback_ready保持0 → SD低；空FIFO继续发送零帧
```

代码证据：

- `rtl/core/modal_poly_bank.sv:82`：`coeff_loaded`逐声部位图。
- `rtl/core/modal_poly_bank.sv:146–153`、`:183`：最低未加载模态索引计算及存储。
- `rtl/core/modal_poly_bank.sv:323–328`：cfg握手时更新位图和最低未加载索引。
- `rtl/core/modal_poly_bank.sv:190–196`、`:331–346`：`n_modes > low_unloaded`拒绝；错误时不进入运行。
- `rtl/core/modal_engine.sv:250–253`：bank错误向外映射为engine错误5。
- `rtl/core/modal_engine.sv:306–309`：E_DRIVE进入E_WAIT；只等bank out_valid回空闲，没有bank拒绝恢复路径。
- `rtl/audio/song_player.sv`的S_SAMPLEW：只等engine_out_valid。
- `rtl/audio/audio_demo_core.sv:368–373`：首个FIFO写握手后设置playback_ready。

原生产wrapper丢弃错误输出，综合会优化这些观测路径；本次原网表夹具未声称实际观测到错误5脉冲。错误5是根据RTL拒绝路径及转发定义给出的预期。

## 4. 综合映射问题：已知与待厘清

综合日志明确提取了`coeff_loaded`和`low_unloaded` RAM；**提取日志不能单独证明二者最终都在BSRAM**，网表中low_unloaded仍可见DFF寄存器。

原网表的`coeff_loaded`最终映射为两个SDPB，在原网表126710、126730行附近。它们写宽1、读宽32，`READ_MODE=0`、`OCE=GND`，读口仍是同步存储器读，不是RTL任意数组组合读取。

**后续DS逐拍追踪，父会话再用独立断言核实：不是“同步读晚一拍”，也不是两个RAM的选片/地址混叠。问题位于RAM读回到`lowest_missing`下一值的综合组合逻辑。**

两块RAM以`cfg_mode[4]`选片，片内位地址为`{cfg_mode[5],cfg_mode[3:0]}`。父会话在全部27个cfg握手前，将RAM原始读回与此前已接受的配置逐位比较，**全部正确**；按这一地址规则重组的48位逻辑位图也与独立记录完全一致。

然后比较`lowest_missing(正确位图 | 当前配置位)`与原网表实际`low_unloaded`寄存器的组合D输入：

| 正在配置的mode（从0计数） | 正确下一值 | 原网表下一值 |
|---|---:|---:|
| 0～15 | 1～16 | 1～16 |
| 16 | 17 | 17 |
| 17 | **18** | **16** |
| 18～26 | **19～27** | **16** |

例如配置mode17时，RAM0=`0000FFFF`，RAM1=`00000001`：此前mode0～16已经全部存在，再加当前mode17，正确最低缺失值应为18。原网表D输入却是16，随后记账寄存器退回16。**这证明此前已写入RAM1的mode16没有正确参与这一下一值计算，不是读回少了一拍。**

父会话映射断言结果：`configs=27, mismatches=10`，差异恰为mode17～26，所有原始RAM读回断言通过。此次只覆盖首音符、voice0、mode0～26；不把观察推广为所有高模态位、声部或任意配置顺序的穷尽结论，也不据此判断Gowin工具内部具体是哪一步出错。

修复方向应是让此元数据明确以寄存器实现，或以等价、可验证的结构表达组合位图读取；不猜测某个`ram_style`属性一定被Gowin接受。保持合法/非法帧协议、任意模态配置顺序、clear后系数有效性、冻结数值算法和II3不变。

## 5. 对先前验收与四线计划的修正

- 先前RTL整链通过仍是RTL证据；箱体综合网表通过仍是箱体证据。**它们不能证明歌曲bank/engine的综合映射等价。此次发现正式歌曲网表功能失败，原歌曲文件不能继续按“功能已通过、只剩硬件接线”来处理。**
- 原100MHz setup/hold结果不替代功能等价检查；MPW、PLL模型和近零setup余量仍是独立OPEN项。
- 四线观测版目前没有生成。不必先大量复制集成层：可优先引出现有公开的`engine_busy/error_valid/error_code/core_sample_pulse`，减少扰动。
- 若保留错误优先的卡点码，本次问题按RTL预计报告`E`（engine错误5），不是简单进度码4。`E`不通用于“就是装载记账错”，因为其他bank拒绝也映射为5。
- 新增观测可能改变综合推断，必须检查该版本RAM映射，并做综合网表功能验证。调试版偶然出声也不能单独证明原版为何失败。
- 启动underflow通常会发生；只观察underflow_sticky会把正常的启动欠载与持续欠载混在一起，不能据此直接判错。

## 6. 复跑与下一步

父会话夹具及日志在`/tmp/opencode/song-ready-parent-review/`，DS原分析夹具在`/tmp/opencode/song-ready-ds-review/`。父会话复跑：

```bash
python3 -u /tmp/opencode/song-ready-parent-review/run_review.py
```

该脚本编译冻结RTL、原网表，以及**仅测试用途**的元数据force干预，共三组；库和网表的SHA、完整命令记录到`inputs_and_commands.json`。活动数据通路的门级仿真较慢，需留出数分钟。第二组的`CONFIRMED_ORIGINAL_NETLIST_FAILURE`是失败复现成功，**不是设计验收PASS**。

脚本默认现包含上述三组启动测试以及第四组逐拍映射断言；单独快速复跑映射断言：

```bash
python3 -u /tmp/opencode/song-ready-parent-review/run_review.py --mapping-only
```

单独运行保存`mapping_audit_run.log`及`mapping_inputs_and_commands.json`，不会覆盖早先三组日志/记录。

建议下一步：对已确认的元数据下一值映射差异做最小实现修复，先RTL回归及**修复后的真实综合网表**验证，随后真实100MHz时序检查，再交付独立SRAM测试文件。不得用降低时钟、强拉SD、跳过合法性检查或仿真force制作可下载版本。

**本次故障review结束时没有修改冻结核心，没有交付新歌曲/调试bitstream，也没有操作Programmer。后续授权修复结果见[修复验收](song_metadata_fix_review.md)。用户新增的代码阅读注释保留不动。**
