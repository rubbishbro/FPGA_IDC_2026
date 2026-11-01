# 串口演奏／配置协议 v1

日期：2026-10-26。状态：**通信 RTL 已实现并完成独立仿真；本文记录当前线上协议。** 设备 RX 接受 MIDI_DATA／CONFIG，TX 生成 REPLY，并支持第10节的有线PERFORMANCE演奏事件；真实音频／EQ后级不在本目录实现。外层消息是私有封装，MIDI_DATA 内的 MIDI 字节保持标准含义。

## 1. 分帧方式

采用 RFC 1055 的 SLIP 定界／转义约定，内部自定义 header 与 CRC：

```text
C0 | SLIP_ESCAPE(HEADER + PAYLOAD + CRC16_LE) | C0
```

SLIP 只负责边界，不自带消息分类或校验；TYPE、LEN、SEQ 和 CRC 是本机协议增加的字段。不传 IP 包，也不是直接发送裸 MIDI。

### 1.1 转义

| 未转义字节 | 串口上发送 |
|---|---|
| C0 | DB DC |
| DB | DB DD |
| 其他 | 原字节 |

- header、payload、CRC 全部参与转义；首尾 C0 不参与。
- 每帧发送首、尾两个 C0。帧间连续 C0／空帧忽略，也接受相邻帧共享一个 C0 的接收形式。
- 开始寻找第一枚 C0 之前的垃圾字节忽略。
- 非法 `DB xx`、帧末悬空 DB、超长均将当前帧标为无效；丢弃到下一枚未转义 C0 后重新同步，不发布部分 payload。

**为何需要转义：** MIDI 的 Program Change 通道 1 状态本身就是 C0；通道压力也可能出现 DB。私有配置和 CRC 更可能包含任意字节，不能靠裸帧头匹配区分。

## 2. 固定帧头

下表 offset 均指 **SLIP 解码后的 frame body**，所有整数为小端，不受 flash 镜像的大端格式影响。

| Offset | 字段 | 字节数 | 定义 |
|---:|---|---:|---|
| 0 | VERSION | 1 | 固定 01 |
| 1 | TYPE | 1 | 01=MIDI_DATA，02=CONFIG，80=REPLY，82=PERFORMANCE（上行） |
| 2 | SEQ | 2 | 序号／配置请求标识，低字节在前 |
| 4 | LEN | 2 | 未转义 payload 的字节数，低字节在前 |
| 6 | PAYLOAD | LEN | 按 TYPE 解释 |
| 6+LEN | CRC16 | 2 | 覆盖 VERSION 到 payload 末尾，低字节在前 |

**body 总长度必须恰好为 `LEN + 8`。** 不含首尾 C0；LEN 不包含 header、CRC 或转义增加的字节。

### 2.1 长度限制

| TYPE | 合法 payload 长度 |
|---|---|
| MIDI_DATA | 1..32 |
| CONFIG | 1..16，且必须再匹配具体命令长度 |
| REPLY | 固定 3 |

`MAX_MIDI_PAYLOAD=32`，`MAX_CONFIG_PAYLOAD=16`；每链路帧存储按 32-byte payload 槽实现，最大解码 body=40 字节，最坏转义后、含两个 C0 的线上帧长=82 字节。CONFIG 帧最多 24 字节 body、50 字节最坏线上长度。

长度按实际内容填写，不补齐到上限：REVERB_SET 为 2 字节、单段 EQ_SET 为 10 字节。多段 EQ 分别发送配置帧；CONFIG payload 大于 16 字节即拒绝。

LEN 越界时直接进入丢弃状态，禁止据 u16 声称的长度无限写缓存。CRC 通过、实际长度匹配、版本／类型／长度合法之后，才允许发布。

FIFO 深度需按 UART 速率、下游停顿与峰值流量另算；上述帧上限不是接收永不溢出的保证。

## 3. CRC16 完整定义

名称：**CRC-16/CCITT-FALSE**，也称 **CRC-16/IBM-3740**。

```text
width   = 16
poly    = 0x1021             // 不把 x^16 的最高项放进这个值
init    = 0xFFFF
refin   = false
refout  = false
xorout  = 0x0000
check("123456789") = 0x29B1
```

每个**原始未转义**字节先 XOR 到 CRC 高 8 位，再按 MSB-first 移位 8 次；CRC 字段本身不参与计算。UART 的字节内串行位序与 CRC 的内部算法位序不要混淆。

参考伪代码：

```text
crc = FFFF
for byte in HEADER + PAYLOAD:
    crc = crc XOR (byte << 8)
    repeat 8:
        if crc bit15 == 1: crc = ((crc << 1) XOR 1021) AND FFFF
        else:             crc = (crc << 1) AND FFFF
append crc[7:0], crc[15:8]
再对 HEADER + PAYLOAD + CRC 做 SLIP 转义
```

不混用 XMODEM（init=0000）、X25（反射／不同 xorout）或 MODBUS（不同多项式）。CRC 是错误检测，不是认证或加密。

## 4. 接收提交、超时与错误

1. RX FIFO → SLIP 解码 → 短帧缓存，边解码边计算 CRC。
2. 未转义 C0 到来后，检查 frame body 长度、LEN、CRC 和 header。
3. 全部通过才发布一帧，demux 根据 TYPE 交给 MIDI／CONFIG FSM。
4. 下游反压时持有已验证帧；不覆盖尚未消费的缓存。

半帧接收具有可参数化的**字节间超时**。`comm_top` 默认 `TIMEOUT_CYCLES=CLK_HZ`，即 1000 ms；计时由 SLIP RX 在非空候选帧等待输入时执行，接受新字节时重置，等待帧槽或完整帧下游消费不计时。空闲链路不视作断线，更不能拿它判断长音是否应该停止。

超时／UART framing error／RX FIFO 溢出使当前半帧失效，并置对应来源的 `link_fault_pending`／`source_quarantine`。CRC 错、非法转义、长度错误记录在 `error_sticky` 和汇总错误周期计数中；这些情况下不信任 SEQ，**不伪造 CONFIG ACK**。不可“发现 CRC 错但前面的 Note On 已执行”。

VERSION／TYPE 不认识：丢弃并计数；comm_top默认还按来源隔离。REPLY 不被当成 MIDI 或配置。错误恢复／清音由独立顶层负责，分帧 FSM 本身不修改 fmap。丢帧可能丢失 Note Off；CRC 不能保证可靠投递。当前comm_top默认ISOLATE_PROTOCOL_ERRORS=1，所有上述协议错误均按源隔离，需消费者实际清音/退休及显式session_restart恢复；没有新增线上恢复命令。

## 5. MIDI_DATA：包内标准 MIDI

- payload 是 MIDI 演奏字节，不是 SMF 文件字节；不含 `.mid` header、delta-time、meta event。
- v1 使用**自包含的短 MIDI 数据包**：每个包独立建立 running status，不能依赖上一个包的状态，也不能把一条短消息拆跨包。
- 允许同包内 running status；上位机优先每条消息都带 status，利于定位错误。
- 每包开始清解析局部状态；每包结束清 pending／running status／SysEx skip 状态。包间 CONFIG 不会成为 MIDI 字节。
- 完整且合法的支持消息按顺序产生事件。语法错误产生 `midi_parse_error` 单拍诊断、丢弃不完整消息并按新 status 重同步；**先前已经产生的合法 MIDI 事件不做回滚**。CRC 帧提交不等于 MIDI payload 的事务回滚。当前集成层默认将MIDI语法错误也送入来源隔离/清理，因此先前发出的声音会在清理中停止。
- SysEx／System Common／Real-Time 等首版不产生业务动作，按 [MIDI 解析说明](README.md#midi) 中的规则识别／跳过，不能吞掉其后的 Note Off。
- 不按通道音色策略过滤 byte parser；事件保留 channel 0..15，实际播放能力另定。

MIDI payload 的已实现行为和事件字段见 [MIDI 解析说明](README.md#midi)。

## 6. CONFIG payload

一帧只包含一条配置命令，首字节为 COMMAND。当前 RTL 实现 EQ／共享混响配置的字段校验、shadow、请求与完成握手；实际效果由外部后级完成。

### 6.1 `01 = EQ_SET`，LEN=10

| Payload offset | 字段 | 类型 | 定义 |
|---:|---|---|---|
| 0 | command | u8 | 01 |
| 1 | band_id | u8 | 0-based 段号，必须小于实现的 EQ_BANDS |
| 2 | enable | u8 | 0=旁路此段，1=启用 |
| 3 | filter_type | u8 | v1 仅 0=peaking/bell；其他值拒绝，不偷偷换成别的滤波器 |
| 4 | frequency_hz | u16 LE | 中心频率，parser 校验 20..20000 Hz；采样率约束由实际后级校验 |
| 6 | gain_q8_8 | i16 LE | dB×256，二补码；校验范围 −12..+12 dB，即 −3072..3072 |
| 8 | q_u8_8 | u16 LE | Q×256；校验范围 26..2560，约 0.1..10 |

当前 `config_analyzer` 按上表校验，`EQ_BANDS` 默认 3，仅决定合法段号。高层参数到 IIR 系数的转换和 DSP 不在本目录实现；未就绪后级通过完成接口返回 NOT_READY。

整帧收齐并验证后，通过 `cfg_shadow` 提交完整请求；byte0 位于 [7:0]。即使 enable=0 也校验其余字段。parser 不计算或写入 IIR 系数。

### 6.2 `02 = REVERB_SET`，LEN=2

```text
command:u8 = 02
preset:u8  = 00 NONE / 01 HALL / 02 BATHROOM
```

其他 preset 拒绝。v1 无 amount、反馈或延迟字段；不虚构当前 router 没有的参数接口。

parser 保留线上 preset 编号并交给后级；当前 `router_pkg` 枚举为 `BATHROOM=0 / HALL=1 / NONE=2`，与线上编号不同。当前没有连接 router 的枚举转换端点，后级不能直接强转编号。

不支持的 command 返回 UNSUPPORTED。

## 7. 配置寄存器、顺序与回复

```text
CONFIG 解码／校验 → shadow → MIDI 操作屏障 → cfg 请求握手 → 后级完成握手 → REPLY
```

“此前 MIDI 操作完成”是事件 FIFO 已排空、消费者已完成对应操作且没有尚未退休的事件，不是所有声部已停止。配置等待期间不让后面的 MIDI 帧越过它；在 UART 入口缓冲，主机也须遵守 stop-and-wait。

### 7.1 序号与重发

- MIDI_DATA 的 SEQ 是独立的 16-bit 帧标记，主机每个新 MIDI 帧递增模 65536；用于诊断，不自动重发、不依此丢弃合法同音重触发。
- CONFIG 使用独立的 16-bit 请求计数器，每个新配置递增模 65536；重试必须使用相同 SEQ 和相同 payload。
- 主机同一会话最多一条配置在途；收到最终回复前不发新的配置，也不发送需要该配置生效后的 MIDI。控制面滑杆在主机合并尚未发送的中间值。
- 设备为两个来源分别保留最近配置的 SEQ、完整 payload 和最终结果。同 SEQ／同 payload 只重放结果，不二次 commit；同 SEQ／不同 payload 返回 SEQ_CONFLICT。
- 当前帧在 `frame_done` 前阻止后续帧进入 parser；在途配置完成后，排队的同源重复帧再查缓存，不二次提交。`comm_top` 在有序会话重建时清对应来源重试缓存；串口空闲不会触发会话重建。
- ACK 是实际生效或明确失败的结果，不是“进入 RX FIFO”或“写了一半 shadow”。

### 7.2 REPLY，TYPE=80，LEN=3

header SEQ 回显配置请求 SEQ；payload：

```text
request_type:u8 = 02
command:u8      = 原 command；CONFIG LEN=0 在外层已拒绝
result:u8       = 下表
```

| result | 定义 |
|---:|---|
| 00 | OK，已经提交 |
| 01 | UNSUPPORTED，命令／filter_type 不支持 |
| 02 | BAD_LENGTH，命令长度不匹配 |
| 03 | OUT_OF_RANGE，字段值越界 |
| 04 | BUSY，不能接收此新配置；原配置不变 |
| 05 | SEQ_CONFLICT，同请求号内容不同 |
| 06 | NOT_READY，对应后级未实现／未就绪，或提交失败且未生效 |

校验错误和后级完成结果均缓存以便重放；SEQ_CONFLICT 保留原缓存。BUSY 可由后级完成接口返回，parser 在忙时通过背压等待。后级负责保证失败时没有部分生效。设备只为合法外层 CONFIG 生成该回复，不对 MIDI 或 REPLY 逐帧应答，不形成 ACK 循环。BUSY 失败若需再次尝试，主机用新的 CONFIG 请求号。

## 8. 可核对的线上例子

十六进制，空格只用于阅读：

```text
Note On，MIDI channel 0，note 60，velocity 100，SEQ=0
C0 01 01 00 00 03 00 90 3C 64 B3 4E C0

Program Change，channel 0，program 1，SEQ=1；payload 的 C0 必须转义
C0 01 01 01 00 02 00 DB DC 01 31 60 C0

设置 HALL，CONFIG SEQ=1
C0 01 02 01 00 02 00 02 01 85 C8 C0

上述 HALL 真正生效后的 OK 回复
C0 01 80 01 00 03 00 02 02 00 61 50 C0
```

完整六组向量见 [frame_vectors.json](frame_vectors.json)，含 EQ 1000 Hz／−6 dB／Q=1，以及 header 同时含 C0、DB 的转义情况。

## 9. 已有验证入口

六组固定向量、CRC 标准检查与随机分片／粘包由 `sim/check_comm_vectors.py` 检查；RTL 仿真覆盖分帧、长度／转义／CRC 错误、背压、MIDI→CONFIG→MIDI 屏障、重复配置及来源故障恢复。具体测试和结果见 [VERIFICATION.md](../../comm/VERIFICATION.md)。

## 10. 有线压力垫演奏录制扩展（2026-10-31）

本节为可编辑MIDI轨道的事件回传，不是PCM/WAV；蓝牙v2不包含此扩展。
旧MIDI/CONFIG/REPLY字节及长度不变。设备RX仍只接收MIDI/CONFIG，新增TYPE82只允许设备→有线PC。

CONFIG `12 RECORD_START` / `13 RECORD_STOP`：payload均为`command:u8 recording_id:u32LE`，LEN=5。
只允许有线来源，且需现有有线远程权限。START需音频资源有效、PAD来源、音色有固定MIDI通道映射；不满足返回NOT_READY；已有take活动/排空返回BUSY；STOP的ID不符返回OUT_OF_RANGE。
START在下一音频帧边界开始；STOP在下一边界停止观察，不清音、不停止PAD发声。设备600秒自主截止；配置桥等待起停最多2秒，超时取消并返回NOT_READY。
START/STOP回复沿用TYPE80、匹配CONFIG SEQ及command，原去重缓存继续有效。STOP成功只能在END已交付编码器之后产生；仲裁锁定整帧，故线上END完整地先于STOP回复。
录制中不重复START；同次连接主机使用新的32bit录制ID，MIDI/配置/录制上行序号相互独立。无物理状态时拔线不能立即由设备识别，主机断线后必须将take标不完整；设备最长600秒截止。维护/有线隔离不伪装完整录制。

### TYPE82 PERFORMANCE，LEN固定24，body固定32字节

所有整数字段小端，每帧只包含一项记录，完整SLIP/CRC与v1一致；仍在40字节body上限内。

|payload offset|字段|含义|
|---:|---|---|
|0|kind:u8|0 STARTED；1 NOTE_ON；2 NOTE_OFF；3 END|
|1|flags:u8|bit0=不完整（END有效）；其它0|
|2|channel:u8|实际音色映射的0-based MIDI通道0..5|
|3|slot:u8|矩阵槽0..15；STARTED/END为0|
|4|recording_id:u32|对应START请求|
|8|ordinal:u32|STARTED=0，每个成功入队记录递增1；header SEQ为低16bit|
|12|frame_index:u32|相对于START的音频帧数；STARTED=0；END为停止边界|
|16|a:u32|STARTED=采样率分子12500000；ON/OFF低byte为note、次byte为velocity；END=0|
|20|b:u32|STARTED=采样率分母256；ON/OFF=0；END=此前成功入队的ON/OFF记录数|

相同生效快照内的音符共享frame_index，按slot顺序发送；UART到达时间不是演奏时间。
NOTE_OFF使用此前起音音高，不能随实时音高清单变化。力度为max(1,floor((strike_level×127+127)/255))，OFF力度不用于重建持续时间。
首版固定槽内一次一个按键实例，通过slot/recording_id匹配；不增加动态多次叠按计数。同槽再次ON在PC收束旧实例并标记不完整，不能跨丢失事件猜测完美轨道。

设备使用128项同步RAM FIFO，不反压合成。队列满/采集扫描重叠会停止take，保留此前记录并发带不完整标志的END；允许等空间发END，不能丢弃结束标志。48.828125kHz采样窗口内扫描16槽，时间戳来自快照而非扫描结束时间。

STARTED可能先于START回复，PC从arming起即接收。收到END后将仍按住的音符在其时间戳封口；无ON不猜音符；序号缺失/错误尾部/断线需标记不完整。无END只可保存已确认部分，不能用PC墙钟伪造设备停止时间。普通长按即使没有新事件也不视作断线。

黄金向量：[performance_vectors.json](performance_vectors.json)。验证入口：

```bash
python3 sim/run_comm.py --test tb_performance_record --test tb_performance_limits
python3 sim/run_board.py --test record
node web/midi-editor/tests/run.mjs
```
