# MIDI 解析参考与首版解析合同

查阅日期：2026-10-26。这里的“参考实现”不是经 MIDI Association 认证的标准 IP。标准含义以 MIDI 规范为准，开源实现仅供状态机结构／测试参考，不能盲目照搬。

## 1. 网上查阅的来源

### 1.1 MIDI Association：标准消息与控制器表

- [Summary of MIDI 1.0 Messages](https://midi.org/summary-of-midi-1-0-messages)
- [MIDI 1.0 Control Change Messages](https://midi.org/midi-1-0-control-change-messages)

用途：核对状态号、数据字节数、14-bit bend、CC1/7/11/64/120/123。公开表是摘要，不等于完整 Detailed Specification；不声称已取得或逐项实现全部规范。

### 1.2 Arduino MIDI Library：主要状态机参考

- 项目：[FortySevenEffects/arduino_midi_library](https://github.com/FortySevenEffects/arduino_midi_library)
- 本次读取 master commit：`2d64cc3c2ff85bbee654a7054e36c59694d8d8e4`。
- [固定版本 MIDI.hpp](https://github.com/FortySevenEffects/arduino_midi_library/blob/2d64cc3c2ff85bbee654a7054e36c59694d8d8e4/src/MIDI.hpp)：重点看 `parse()`、`resetInput()`、`handleNullVelocityNoteOnAsNoteOff()`。
- 文件内许可：MIT。本次未复制或引入源码；将来复制／改编须保留许可声明。

值得参考：

- 分开保存 running status、pending index、expected length。
- Cn/Dn 只有一个数据字节，不把所有消息都按三个字节切分。
- 实时消息插入时保留正在拼装的普通消息。
- SysEx 独立处理，零力度 Note On 归一化为 Note Off。
- transport 与消息回调分层，与我们的 UART／parser／event FIFO 分离一致。

不能直接移植的部分：递归读串口、C++ 回调／模板、动态 SysEx 处理、1-based channel API、MIDI Thru 等不适合照搬到 FPGA。畸形输入恢复也要按本项目合同重写并测，不能仅因代码成熟就宣称完全标准兼容。

### 1.3 Mido：主机消息工具，不作完整原始流黄金模型

- [Parsing MIDI Bytes](https://mido.readthedocs.io/en/stable/messages/parsing.html)
- 本次读取 main commit：`7c1de5df224a5f0c602af8158c8fc25497ad351b`。
- [固定版本 tokenizer.py](https://github.com/mido/mido/blob/7c1de5df224a5f0c602af8158c8fc25497ad351b/mido/tokenizer.py)，MIT。

可用于上位机生成／核对显式状态消息、SMF 事件转换和基本消息字段。但本次审阅该 tokenizer 发现：完整消息后 `_status=0`，未保持 running status；实时字节在非 SysEx 中会清 `_status`，与 MIDI 实时消息可插入普通消息的需求不一致。

所以不能只用 `mido.Parser()` 的结果证明我们的 running status／实时插入实现正确。相关边界必须写独立向量，以规范规则核对。

### 1.4 Tang Nano 的 Verilog：仅最简硬件案例

- 项目：[kingyoPiyo/Tang-Nano_MIDI_Sounder](https://github.com/kingyoPiyo/Tang-Nano_MIDI_Sounder)，MIT。
- 本次读取 master commit：`a015c80d9b11c7e7a6c3d28a26fdfb9ba16f6d1c`。
- [固定版本 src/MIDI_Decoder.v](https://github.com/kingyoPiyo/Tang-Nano_MIDI_Sounder/blob/a015c80d9b11c7e7a6c3d28a26fdfb9ba16f6d1c/src/MIDI_Decoder.v)。

只有简单的 8n/9n → 两个数据字节 → RAM 的状态机。没有我们的 CC、Program Change、Pitch Bend，也未处理零力度归一化、running status、实时插入等完整边界，还把 voice/RAM 管理混入解析器。**可参考字节 valid 接口，不选它作为本项目完整 parser。**

交叉解释资料：[SparkFun MIDI Tutorial / Advanced Messages](https://learn.sparkfun.com/tutorials/midi-tutorial/advanced-messages)，用于核对 SysEx 中实时字节不中断、其他 status 会终止 SysEx 并开始新消息。教程不是规范替代物。

## 2. 解析器的输入／输出边界

输入是已经过外层 CRC 验证的 MIDI payload 字节，`data:u8 / valid / ready`，另带 `frame_start / frame_end` 边界，边界与对应字节交付一致。未来独立测试可直接注入这些字节，不需要真正 UART 或 HC-05。

输出是 MIDI event 的 `valid / ready / data`，接 event FIFO。输出受阻时必须保持数据稳定，输入可反压；不自行覆盖未交付事件。

不在此模块做：音符→slot、力度→压力、踏板保持、音色换表、弯音 Hz 计算、表情增益计算或 EQ。它们由事件消费者实现。

### 2.1 当前传输 profile

标准裸 MIDI 流允许消息／running status 延续，本机外层帧另外采用**包内自包含** profile：

- MIDI 帧首清局部解析状态；首个非实时消息必须显式给 status。
- running status 允许在同一帧内使用，不跨帧。
- 短消息不得拆跨帧；包尾不完整消息丢弃并报解析错误。
- SysEx 业务暂缓，包内跳过即可；不将长 SysEx 拆帧传输。
- CONFIG 帧不送入 MIDI parser；不能把私有帧头当 MIDI status。

这是本机封装限制，不宣称标准 MIDI 原本就有这样的包边界。未来若要直接接裸 MIDI 串口，需独立定义连续流模式，不能沿用每帧清状态规则后又声称支持跨帧流。

## 3. 首版产生事件的消息

`n` 为 channel 0..15；data1/data2 均 7-bit。

| Status | 数据字节数 | 输出 |
|---|---:|---|
| 8n | 2 | NOTE_OFF，保留 note 和 release velocity；消费者可忽略释放力度 |
| 9n | 2 | NOTE_ON；velocity=0 时归一化 NOTE_OFF |
| Bn | 2 | 仅 CC1、7、11、64、120、123 输出 CONTROL_CHANGE |
| Cn | 1 | PROGRAM_CHANGE，编号原样保留，不直接转换本机 instrument_e |
| En | 2 | PITCH_BEND，原始 lsb/msb；`bend14={msb[6:0],lsb[6:0]}`，中心 8192 |

CC120/123 的 v1 发送端用 value=0；非零保留为语义不支持，不执行静音／松键，计数后忽略。CC64 的 0..63／64..127 开关解释交给消费者。

CC7 与 CC11 为独立事件和状态，不能互相覆盖；CC11 的线性调制由消费者连接，不是重新定义它为 pitch modulation。

### 3.1 32-bit event 格式

| Bits | 字段 | 定义 |
|---|---|---|
| 31:28 | kind | 0=NOTE_OFF，1=NOTE_ON，2=CONTROL_CHANGE，3=PROGRAM_CHANGE，4=PITCH_BEND；其余保留 |
| 27:24 | channel | 0-based，0..15 |
| 23:17 | data1 | note / CC编号 / program / bend LSB |
| 16:10 | data2 | velocity / CC值 / 0 / bend MSB |
| 9:0 | reserved | 全 0 |

该格式为本机内部合同，不是 MIDI 线上消息，也不是旧 class_format Event64。Program Change 的 data2=0；9n velocity=0 归一化后 kind=NOTE_OFF、data2=0。不含 voice、时间戳或本机音色号，避免把后续适配策略锁死在 parser 中。

## 4. 支持识别但暂不执行的消息

| Status | 处理 |
|---|---|
| An | 消费 2 个数据字节，不产生事件，仍可成为 running status |
| Dn | 消费 1 个数据字节，不产生事件，仍可成为 running status |
| Bn 其他 CC | 完整消费，不产生事件，不改变当前播放参数 |
| F1 / F3 | 清 running status，消费 1 个数据字节后忽略 |
| F2 | 清 running status，消费 2 个数据字节后忽略 |
| F6 | 清 running status，零数据字节，忽略 |
| F0..F7 的保留／异常项 | 按 System Common 区处理，清 pending／running；F7 正常结束 SysEx，其他孤立数据不被猜作 Note On |
| F8..FF | 最优先识别为实时区单字节，首版不产生业务事件；不中断 pending／running／SysEx skip，包括保留 F9/FD |

System Reset FF、Active Sensing FE、Clock F8 的业务功能均暂缓；不能因为名称中有 Reset 就把它当成本机清 parser 的私有命令。连接故障走独立 fault/flush 控制，不冒充支持 MIDI Active Sensing。

### 4.1 SysEx 跳过

- F0：清 running status，进入 SKIP_SYSEX；不缓存任意长厂商数据。
- 数据字节：跳过，不输出事件。
- F8..FF：独立忽略，保持 SKIP_SYSEX。
- F7：结束 SysEx；running status 仍无效。
- 其他非实时 status：终止当前 SysEx，将该 status 重新按新消息解析，不能一直等 F7 而吞掉之后的音符。
- v1 外层包尾：结束 skip 状态，未闭合 SysEx 计异常；下包重新建立 status。

## 5. FSM 所需状态与优先级

建议状态／寄存器：WAIT_STATUS、WAIT_DATA1、WAIT_DATA2、SKIP_SYSEX；另记 status、running_status、expected_data_count、data1，以及是否为跳过的 System Common。具体编码在 RTL 阶段决定，不采用 C++ 递归读串口。

每个接受的字节按顺序处理：

1. 链路 flush／reset 优先：清解析局部状态；event FIFO 及本机清音由上层协调。
2. F8..FF：忽略业务动作，不改变普通消息拼装位置。
3. 若为新的非实时 status：终止未完成消息，再用新 status 建立解析状态；该新字节不能丢失。
4. 若在 SysEx：跳过普通数据。
5. 普通数据：仅在 pending 或合法 running status 下消费；否则丢弃并计孤立数据错误。
6. 完整消息：按支持表输出／忽略；仅 channel status 可继续作为 running status，System Common/SysEx 不能。

包尾丢弃不完整消息，不撤销同包之前已经产生的合法事件。输出 FIFO 背压不得使正在拼装的 data1 被后续字节覆盖。

## 6. 最低测试向量

| payload hex | 应有结果 |
|---|---|
| `90 3C 64 80 3C 40` | NOTE_ON 60/100，NOTE_OFF 60/64 |
| `90 3C 00` | NOTE_OFF 60/0 |
| `90 3C 64 3E 50` | 同包 running status，两条 NOTE_ON |
| `C0 05 06` | 同包 running status，两条 PROGRAM_CHANGE；注意外层 C0 需 SLIP 转义 |
| `90 3C F8 64 3E 50` | 实时插入不破坏两条 NOTE_ON |
| `90 3C FF 64` | 首版不执行 System Reset，仍得到 NOTE_ON 60/100 |
| `E0 00 40` | bend=8192 |
| `E0 00 00 E0 7F 7F` | bend=0，16383 |
| `B0 01 20 B0 07 60 B0 0B 40` | CC1／CC7／CC11 三条不同 CONTROL_CHANGE |
| `B0 40 3F B0 40 40` | 两条 CC64，消费者解释 off／on |
| `B0 7B 00 B0 78 00` | CC123 和 CC120 必须保持不同 CC 编号 |
| `D0 10 20 90 3C 64` | 两条 Channel Pressure 跳过，随后 NOTE_ON 正常 |
| `A0 3C 20 3D 30 90 40 64` | 两条 Poly Pressure 跳过，随后 NOTE_ON 正常 |
| `F0 7D 01 F8 02 F7 90 3C 64` | 跳过 SysEx／实时，保留 NOTE_ON |
| `F0 7D 01 90 3C 64` | 新 channel status 终止未闭合 SysEx，得到 NOTE_ON |
| `90 3C F2 00 00 3E 50` | 不完整 Note On 终止，F2 清 running，尾部孤立数据不发音 |
| `90 3C 90 3D 64` | 丢弃前一条不完整消息，得到 NOTE_ON 61/100 |
| 包A=`90 3C 64`，包B=`3D 64` | 包B 不继承 running status，不产生新事件 |
| 包A=`90 3C`，包B=`64` | 不跨包拼装 Note On |

还需覆盖 channel 0/15、所有 CC 值、随机 valid 间隔、事件 FIFO 满时稳定保持、复位／flush、字节级错误恢复。以上为未来验证合同，不是已经运行过的 RTL 测试。
