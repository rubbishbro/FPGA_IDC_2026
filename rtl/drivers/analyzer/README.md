# MIDI／Config 解析层

本目录负责已验证帧的 TYPE 分发、MIDI 事件解析、Config 字段校验和提交／回复语义。UART、HC-05 和 SLIP／CRC 位于独立驱动与通信层。

| 阅读入口 | 内容 |
|---|---|
| 本文 | 解析模块、MIDI 支持子集、Event32 和配置握手 |
| [PROTOCOL_V1.md](PROTOCOL_V1.md) | 线上帧格式、SLIP、CRC、配置编码与结果码 |
| [通信集成说明](../../comm/README.md) | 双链路、公开顶层接口、缓冲和故障恢复 |
| [验证汇报](../../comm/VERIFICATION.md) | 仿真、压力种子、独立探针时序与验收边界 |

## 模块与通用合同

| RTL | 职责 |
|---|---|
| [parser_dispatch.sv](parser_dispatch.sv) | 按 TYPE 分发，保留帧上下文；解析器 frame_done 前不准入下一帧 |
| [midi_analyzer.sv](midi_analyzer.sv) | MIDI_DATA 字节 → Event32 与来源侧带 |
| [config_analyzer.sv](config_analyzer.sv) | CONFIG 校验、shadow、每源去重、提交屏障及最终回复 |

所有模块使用单系统时钟 `clk` 和低有效 `rst_n`。字节／事件在 `valid && ready` 的时钟上升沿交付；正常背压时 valid、数据及附属元数据保持稳定。reset／显式维护是取消例外。

<a id="midi"></a>

## MIDI 已实现功能

### 输入、背压与帧边界

- 字节输入使用 `s_valid/s_ready/s_data`，并附带 `s_first/s_last/s_source_id/s_payload_len`；边界随字节握手交付。
- payload 长度为 1..32；每帧重新建立 pending、running status、System Common 和 SysEx 状态，短消息不得跨帧拼接。
- running status 仅在同包内有效；首个普通消息需要显式 status。CONFIG 不进入此解析器。
- `event_valid && event_ready` 交付事件；正常背压期间事件数据与来源保持稳定。reset／flush 为维护取消例外。
- `frame_done` 在末字节处理及待输出事件握手完成后产生；此前不接收下一帧。

### 产生事件的消息

`n` 表示 channel 0..15，数据字节为 7 bit。所有通道均保留，不在 parser 中筛选音色或播放通道。

| Status | 数据字节数 | 输出 |
|---|---:|---|
| 8n | 2 | NOTE_OFF，保留 note 与 release velocity |
| 9n | 2 | NOTE_ON；velocity=0 归一化为 NOTE_OFF，data2=0 |
| Bn | 2 | CC1、7、11、64，以及 value=0 的 CC120、123，输出 CONTROL_CHANGE |
| Cn | 1 | PROGRAM_CHANGE，program 原样保留，data2=0 |
| En | 2 | PITCH_BEND，保留 LSB／MSB；`bend14={MSB[6:0],LSB[6:0]}`，中心 8192 |

CC7／CC11、CC120／CC123 保留各自编号，不合并。CC120／123 非零值以及其他 CC 完整消费但不产生事件，不提供每种忽略消息的独立计数。CC64 开关阈值、音量／表情曲线、清音动作和 pitch bend 转换由消费者实现。

### Event32

| Bits | 字段 | 已实现编码 |
|---|---|---|
| 31:28 | kind | 0=NOTE_OFF，1=NOTE_ON，2=CONTROL_CHANGE，3=PROGRAM_CHANGE，4=PITCH_BEND |
| 27:24 | channel | 0-based，0..15 |
| 23:17 | data1 | note／CC 编号／program／bend LSB |
| 16:10 | data2 | velocity／CC 值／0／bend MSB |
| 9:0 | reserved | 全 0 |

`event_source_id=0` 为有线，1 为 HC-05 UART。`comm_top` 使用 33-bit FIFO 一同保存来源和事件；来源不占 reserved，也不作为线上字段。

### 识别与跳过

| 字节／消息 | 已实现处理 |
|---|---|
| An／Dn | 分别消费 2／1 个数据字节，不产生事件；保留 channel running status |
| 其他 Bn CC | 消费完整消息，不产生事件 |
| F1／F3 | 清 running status，消费 1 字节后忽略 |
| F2 | 清 running status，消费 2 字节后忽略 |
| F6 及其他 F0..F7 状态 | 清 pending／running；F0 进入 SysEx skip，F7 结束 skip |
| F8..FF（含 F9／FD） | 优先忽略，不打断 pending、running status 或 SysEx skip |

SysEx 数据不缓存；F8..FF 保持 skip，F7 结束 skip，其他非实时 status 终止 SysEx 并按新状态继续解析。包尾清除全部局部状态，未闭合 SysEx、未完成消息或未消费完的 System Common 数据产生解析错误。

实时消息只被识别／跳过；当前没有 System Reset、Active Sensing 或 MIDI Clock 的业务动作。

### 错误处理与验证

孤立数据、不完整消息、异常帧边界／长度等产生 `parse_error`，由顶层输出为 `midi_parse_error` 单拍诊断。新 status 可重新同步；同包之前已输出的合法事件不回滚。来源故障清理由 `comm_top` 的隔离与消费者握手完成。

`tb_midi_analyzer` 已核对 215 个事件，包含支持消息、全部 CC 编号、16 通道、running status、实时插入、SysEx／Common 跳过、异常帧、背压与复位；双 UART 集成测试另检查事件来源和配置屏障。结果见 [VERIFICATION.md](../../comm/VERIFICATION.md)。

<a id="config"></a>

## Config 接口与完成语义

`config_analyzer #(EQ_BANDS=3)` 接收已经通过外层验证的 CONFIG payload；每帧一条命令、长度不超过 16。EQ／混响的字段编码和结果码见 [协议](PROTOCOL_V1.md)。parser 不实现真实音频效果。

| 接口组 | 字段与合同 |
|---|---|
| payload 输入 | `s_valid/s_ready/s_data[7:0]`，附 `s_first/s_last/s_source_id/s_seq[15:0]/s_payload_len[5:0]` |
| 提交屏障 | `barrier_ready`：此前事件 FIFO 已空，且消费者确认此前 MIDI 操作已完成 |
| 后级请求 | `cfg_valid/cfg_ready`，附 `cfg_source_id/cfg_seq[15:0]/cfg_command[7:0]/cfg_payload_len[4:0]/cfg_shadow[127:0]` |
| 后级完成 | `cfg_done_valid/cfg_done_ready/cfg_result[7:0]`，结果保持到握手；shadow byte0 位于 [7:0] |
| 回复描述符 | `reply_valid/reply_ready`，附 `reply_source_id/reply_seq[15:0]/reply_command[7:0]/reply_result[7:0]` |
| 帧退休 | `busy/frame_done`，最后一个 payload 字节交付不等于后级和回复已完成 |
| 会话维护 | `session_reset[1:0]` 清对应来源重试缓存；`cancel_source[1:0]` 取消尚未接受的提交并抑制旧回复 |

合法配置先收齐并验证，等待屏障后提交；除校验失败／缓存重放外，必须等真实后级结果才能回复。后级已接受的请求在来源隔离后仍须退休，不能假定已撤销或回滚共享效果。

两个来源各自保留最近请求和结果。同源同 SEQ／同 payload 重放结果，不二次提交；同 SEQ／不同 payload 返回 SEQ_CONFLICT，并保留原缓存。会话恢复由通信层协调，不因 UART 空闲自行清缓存。未实现或未就绪的后级应返回 NOT_READY。

## 验证与历史

从仓库根目录运行 `python3 sim/run_comm.py`；定点测试可使用 `--test tb_midi_analyzer` 或 `--test tb_config_analyzer`。结果统一见 [验证汇报](../../comm/VERIFICATION.md)，历史方案见 [归档入口](archive/README.md)。
