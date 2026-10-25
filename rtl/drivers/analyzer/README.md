# analyzer — MIDI / 私有配置协议分析层

日期：2026-10-26。**目前只有协议设计与参考资料，没有 RTL 实现。** 不修改现有 HC-05、UART、fmap、router 或颤音代码。

## 文档入口

| 文件 | 内容 |
|---|---|
| [PROTOCOL_V1.md](PROTOCOL_V1.md) | 本次明确的 v1 外层帧头、SLIP、CRC16、消息类型、配置布局、回复与错误规则 |
| [MIDI_REFERENCE.md](MIDI_REFERENCE.md) | 标准 MIDI 资料、开源解析器评审、首版解析合同、事件格式、测试清单 |
| [frame_vectors.json](frame_vectors.json) | 六组外层帧的 payload、CRC、转义前后字节，供未来 RTL／主机对拍 |

`PROTOCOL_V1.md` 是本次提交供审阅的字节级设计基线，不代表已实现。EQ 段数、声音映射、通道播放能力等未决项单列，不阻塞先设计分帧和 MIDI 字节解析。

## 架构边界

```text
电脑 UART / HC-05 的完整接收字节
                 │
              RX FIFO
                 │
       frame_analyzer（拟定模块名）
       SLIP 解码、长度、CRC、短帧缓存
       只发布完整验证通过的帧
                 │
            demux / 顺序调度
            ┌────┴─────────────┐
       MIDI_DATA             CONFIG
            │                  │
     midi_analyzer       config_analyzer
            │                  │
       event FIFO       shadow 配置寄存器
            │                  │
    MIDI→fmap / 控制      安全边界 commit
            │                  │
    音符／音高／表情        active EQ／混响寄存器
                               │
                        配置完成／错误回复
```

用户确定的“一个输入 FIFO + demux + 两个解析 FSM，MIDI event 用 FIFO、config 用寄存器”保留。frame_analyzer 的小帧缓存用于 CRC 通过前不产生副作用，不是额外的命令执行 FIFO。demux 可合并在分帧／调度模块中。

### 拟定模块职责

- `frame_analyzer`：只负责外层协议，不解释音符、EQ 算法或音色。
- `midi_analyzer`：按标准 MIDI 字节规则重组短消息，筛选用户确定的子集，输出事件；不分 voice、不直接写 fmap。
- `config_analyzer`：检查私有配置的命令号、长度和取值，写 shadow 寄存器并申请 commit；不能接收一半就改 active 参数。
- MIDI→fmap／控制适配器：独立后续模块。处理 32 音符、16 槽、力度、踏板、音色和调制路由，不属于本目录当前实现范围。
- HC-05／UART 收发：与本分析层解耦。不得在 MIDI FSM 中实现波特率采样、AT 命令或手机蓝牙栈。

## 接口设计原则

先约定字节／事件 `valid && ready` 为单次交付；输出被反压时数据保持稳定。`ready=0` 只能暂停内部读 FIFO，不能让 UART 发送方自动停下来，实际 FIFO 溢出仍需报告与恢复。

帧发布时提供 `type / seq / payload_len`，payload 提供 `data / valid / ready / first / last`。输入解码、整帧验证与下游发布可用不同状态，不能边收 UART 边把尚未验 CRC 的消息交给两个 FSM。

MIDI 输出暂定 32-bit 事件，见 MIDI_REFERENCE；配置是寄存器接口，不强行装成 MIDI 事件。

配置保序：在配置帧之前的 MIDI payload 已解析完、事件 FIFO 已排空且消费者确认没有尚未完成的事件操作后，再提交配置；不等待已发声的所有音符结束。配置实际完成后才 ACK，并继续后续帧。

## 本次已核对

- 在线查阅 MIDI Association 消息表、Arduino MIDI Library、Mido tokenizer，以及 Tang Nano 的 Verilog MIDI decoder。
- 按位 CRC 算法与 Python 标准库 `binascii.crc_hqx(data, 0xFFFF)` 交叉检查。
- `123456789 → 0x29B1`；六个 frame_vectors 的 CRC 一致，SLIP 编解码往返一致。

这些只验证协议样例计算，不是 RTL、UART、HC-05 或板级验收。本次未运行整机回归，也未引入第三方源码依赖。

## 仍待确认，但不影响分帧／MIDI FSM 起步

- 首版实际接收哪些 MIDI 通道，以及单／多音色播放策略；事件接口保留全部 16 个 channel。
- Program Change 到本机 instrument 的映射、每件乐器具体 32 音清单。
- 弯音范围、CC1 深度、音量曲线；CC11 保留为用户指定的线性表情控制。
- EQ 实际段数、系数生成与稳定性校验；本次只给高层配置字段，不上传任意 IIR 系数。
- 断线／UART 错误／FIFO 溢出的清音动作、上游流控与 FIFO 深度；需与驱动／router 联调。
- 混响首版仅选择三个预设，不虚构当前没有的独立 amount 输入口。

当前 HC-05 文件夹若有后续开发，应通过同一字节接口接入；本目录不替代它。
