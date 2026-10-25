# 串口演奏／配置协议 v1

日期：2026-10-26。状态：**字节级设计方案，供审阅与后续实现；无 RTL。** 外层消息不是 MIDI 标准的一部分；MIDI_DATA 内的 MIDI 字节保持标准含义。

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
| 1 | TYPE | 1 | 01=MIDI_DATA，02=CONFIG，80=REPLY |
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

`MAX_MIDI_PAYLOAD=32`，`MAX_CONFIG_PAYLOAD=16`；共享帧缓存按全局 `MAX_PAYLOAD=32` 设计，最大解码 body=40 字节，最坏转义后、含两个 C0 的线上帧长=82 字节。CONFIG 帧最多 24 字节 body、50 字节最坏线上长度。

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

半帧接收设可参数化的**字节间超时**，初始建议 1000 ms，只在已经进入非空帧且等待后续线上字节时计时。每收到线上字节重置；完整帧等待下游消费不计该超时。空闲链路不视作断线，更不能拿它判断长音是否应该停止。

超时／UART framing error／RX FIFO 溢出使当前半帧失效，并通知上层 `link_fault`。CRC 错、非法转义、长度错误也应有计数／错误标志；这些情况下不信任 SEQ，**不伪造 CONFIG ACK**。不可“发现 CRC 错但前面的 Note On 已执行”。

VERSION／TYPE 不认识：丢弃并计数；REPLY 不被当成 MIDI 或配置。错误恢复／清音由独立顶层负责，分帧 FSM 本身不修改 fmap。丢帧可能丢失 Note Off；CRC 不能保证可靠投递或消除挂音。

## 5. MIDI_DATA：包内标准 MIDI

- payload 是 MIDI 演奏字节，不是 SMF 文件字节；不含 `.mid` header、delta-time、meta event。
- v1 使用**自包含的短 MIDI 数据包**：每个包独立建立 running status，不能依赖上一个包的状态，也不能把一条短消息拆跨包。
- 允许同包内 running status；上位机优先每条消息都带 status，利于定位错误。
- 每包开始清解析局部状态；每包结束清 pending／running status／SysEx skip 状态。包间 CONFIG 不会成为 MIDI 字节。
- 完整且合法的支持消息按顺序产生事件。语法错误计数、丢弃不完整消息并按新 status 重同步；**先前已经产生的合法 MIDI 事件不做回滚**。CRC 帧提交不等于 MIDI payload 的事务回滚。
- SysEx／System Common／Real-Time 等首版不产生业务动作，但必须按 MIDI_REFERENCE 中的规则识别／跳过，不能吞掉其后的 Note Off。
- 不按通道音色策略过滤 byte parser；事件保留 channel 0..15，实际播放能力另定。

MIDI payload 的具体状态机和事件字段见 [MIDI_REFERENCE.md](MIDI_REFERENCE.md)。

## 6. CONFIG payload

一帧只包含一条配置命令，首字节为 COMMAND。配置仅作用于本机 EQ／共享混响，不假装是标准 MIDI 控制器。

### 6.1 `01 = EQ_SET`，LEN=10

| Payload offset | 字段 | 类型 | 定义 |
|---:|---|---|---|
| 0 | command | u8 | 01 |
| 1 | band_id | u8 | 0-based 段号，必须小于实现的 EQ_BANDS |
| 2 | enable | u8 | 0=旁路此段，1=启用 |
| 3 | filter_type | u8 | v1 仅 0=peaking/bell；其他值拒绝，不偷偷换成别的滤波器 |
| 4 | frequency_hz | u16 LE | 中心频率，20..20000 Hz，并满足设备采样率约束 |
| 6 | gain_q8_8 | i16 LE | dB×256，二补码；设计范围 −12..+12 dB，即 −3072..3072 |
| 8 | q_u8_8 | u16 LE | Q×256；设计范围 26..2560，约 0.1..10 |

以上是供实现评审的首版参数编码，实际 EQ_BANDS 和 DSP 能力仍待确认。未实现 EQ 时应报 NOT_READY，而不是接收成功却无效果。

所有字段验证后写 shadow，并将该段作为完整更新提交。即使 enable=0 也校验其余字段。高层参数到 IIR 系数的计算、量化及稳定性检查另行设计，不在 UART/MIDI parser 中做；不能直接把未经检查的 32-bit 系数写进滤波器。

### 6.2 `02 = REVERB_SET`，LEN=2

```text
command:u8 = 02
preset:u8  = 00 NONE / 01 HALL / 02 BATHROOM
```

其他 preset 拒绝。v1 无 amount、反馈或延迟字段；不虚构当前 router 没有的参数接口。

通信编号必须显式映射：当前 `router_pkg` 原生枚举为 `BATHROOM=0 / HALL=1 / NONE=2`，与线上编号不同，禁止直接强转。NONE 表示直通，不需要另发 enable。

不支持的 command 返回 UNSUPPORTED。未来扩展应分配新 command 或升版本，不改变现有 LEN=2 的含义。

## 7. 配置寄存器、顺序与回复

```text
CONFIG 解码／校验 → shadow → 等待此前 MIDI 操作完成 → commit → active → ACK
```

“此前 MIDI 操作完成”是事件 FIFO 已排空、消费者已完成对应操作且没有尚未退休的事件，不是所有声部已停止。配置等待期间不让后面的 MIDI 帧越过它；在 UART 入口缓冲，主机也须遵守 stop-and-wait。

### 7.1 序号与重发

- MIDI_DATA 的 SEQ 是独立的 16-bit 帧标记，主机每个新 MIDI 帧递增模 65536；用于诊断，不自动重发、不依此丢弃合法同音重触发。
- CONFIG 使用独立的 16-bit 请求计数器，每个新配置递增模 65536；重试必须使用相同 SEQ 和相同 payload。
- 主机同一会话最多一条配置在途；收到最终回复前不发新的配置，也不发送需要该配置生效后的 MIDI。控制面滑杆在主机合并尚未发送的中间值。
- 设备保留最近配置的 SEQ、完整 payload 和最终结果。同 SEQ／同 payload 只重放结果，不二次 commit；同 SEQ／不同 payload 返回 SEQ_CONFLICT。
- 待处理配置的重复请求不排第二次；它们等原请求完成。缓存及影子状态在会话重建时由上层清除，不能把任意串口空闲误认为新会话。
- 初始建议主机配置超时 1500 ms 后重试，最多 3 次；最终失败明确报错，不继续假定配置已生效。超时值应大于设备操作上限和允许的半帧间隔。
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

OK 与错误结果都需缓存以便重复请求重放；错误不得部分修改 active。设备只为合法外层 CONFIG 生成该回复，不对 MIDI 或 REPLY 逐帧应答，不形成 ACK 循环。BUSY 失败若需再次尝试，主机用新的 CONFIG 请求号。

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

## 9. 后续实现的最低验证项

- 正常帧、连续帧、重复 C0、垃圾前缀；逐字节随机空隙与背压。
- 在 header／payload／CRC 各处放 C0、DB，核对转义与 LEN。
- 单字节损坏、错误 CRC、LEN 过长／过短／不匹配、截断帧、非法转义、字节间超时。
- 未知 VERSION／TYPE／命令、CONFIG 长度错、EQ 越界、混响非法值均无部分副作用。
- 验证 MIDI→CONFIG→MIDI 的保序、commit ACK 时点、重复配置不二次生效。
- 下游停顿、event FIFO 满、RX 溢出报告与清音联动；不能靠丢掉 Note Off 让系统继续“看似可用”。

参考：[RFC 1055](https://www.rfc-editor.org/rfc/rfc1055)、[CRC catalogue：CRC-16/IBM-3740](https://reveng.sourceforge.io/crc-catalogue/16.htm#crc.cat.crc-16-ibm-3740)。
