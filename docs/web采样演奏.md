# Web 上位机采样演奏

电脑输出已改为 SampleSynth，以 AudioBufferSourceNode 演奏本地真实乐器录音。
它与 FPGA 资源清单、串口通道检查分别处理；WebGL 仍负责卷帘画面。

## 使用

打开本地上位机，左侧文件区点击“加载巴赫合奏示例”，然后点击播放。
页面会先加载该工程所需的 87 段录音，再开始走带。播放时支持轨道 M/S、
踏板、停止、清音，以及 MIDI CC7 音量和 CC10 声像。

资源涵盖钢琴、吉他、小号、小提琴、中提琴、大提琴、低音提琴、长笛和双簧管，
总计 393 个录音音高，约 64 MB。资源按需解码并缓存，不一次性加载全部音色。
目标音高没有独立录音时选最近的采样，以 playbackRate 调整到目标 MIDI 音高。
持续型乐器使用做过交叉淡化的循环段；停止/踏板释放走短释放包络。

MIDI 的 Program Change 按音符所在拍解析，并携带到该音符事件，避免相同
MIDI 通道的不同轨道被误配成同一采样。没有 Program Change 的旧工程继续
使用已有的八通道乐器映射。通道菜单的显式音色选择通过 previewInstrument
保存在 JSON，并写入导出 MIDI 的 Program Change。

## 本地资源重建

在仓库根目录执行：

```bash
npm --prefix web/midi-editor run build:samples
npm --prefix web/midi-editor run dev
```

构建脚本用 libsndfile 读取 music_resources 内的录音，裁掉前导静音，
归一化峰值并生成单声道 WAV 与 manifest。WAV 是可再生本地产物，已加入
Git 忽略规则。原始录音不变；程序没有公开主目录或 music_resources 的文件服务。
本地服务器仍只绑定 127.0.0.1。

钢琴来源为 music_resources/UprightPian（目录内附 CC0 声明）；其余乐器使用
项目对应目录内 normal / arco-normal 单音录音。生成清单逐条记录原始相对路径。
这些私有本地播放资源不应作为独立采样包公开分发。

巴赫示例 MIDI 来自 Mutopia Project，作品 BWV 1047 第一乐章，录入 Andy Vaught，
来源标注 Public Domain：
https://www.mutopiaproject.org/ftp/BachJS/BWV1047/brandenburg_2/

示例保留开头 64 个四分音符拍，速度设为 112 BPM。原 2/2 改为等长的 4/4
显示以兼容编辑器；音符音高与相对节奏保留。低音乐器按谱面改为正确 GM 音色。

## 验证

- Node 回归：87 项通过；包含跨轨音色、Program Change、MIDI 往返、
  资源请求合并、失败重试、静音和定位前音量/声像恢复。
- 浏览器主页面：加载九轨、1239 音符，显示“采样演奏中”，停止后回到起点；控制台无错误。
- 浏览器实录回归：tests/browser/sample-playback.html，使用真正的浏览器音频引擎和实际 WAV。
  禁止 createOscillator；1239 次发声全部通过 AudioBufferSourceNode；实际解码 87 个采样。
  音频 RMS 0.10554、峰值 0.52193；无挂音、无满幅削波，七类乐器全部进入混音。

验证页面可在本地打开并点击“运行采样演奏回归”。它只用于开发验证，主页面没有测试声音按钮。

## 自定义压力垫键位

右侧“属性 / 串口” → “自定义键位配置”可打开独立配置页。选择乐器，填写 16 个 MIDI 音高，也可填入默认低 / 高音组；鼓组按六个合法 GM 鼓件循环填写。所有键使用同一乐器，允许重复音高。

使用有线 USB-UART、v1、115200 baud（8N1），连接后保持全部压力垫松开，点击“通过串口应用键位”。沿用现有 CONFIG 命令 `0x20`，其后为 16 对 `[instrument_id, midi_note]`，总载荷 33 字节。蓝牙 v1 同样可以复用此页面；v2 不提供此功能。

页面等待匹配的设备 `CONFIG_REPLY`（命令、序号匹配且结果为 0）后才显示成功，并更新主机的已加载音高核对清单。超时、断线或设备返回 BUSY / OUT_OF_RANGE / NOT_READY 均不视为成功；超时结果未知，可保持松键后重新应用。页面暂不读取设备已有键位，不保证断电保存。

本次只增加前端编码、配置界面及测试，不增加 RTL 实例或信号扇出。`tests/keymap.test.mjs` 检查全部 12 种音色范围与生产资源一致，并通过 SerialLink 实际编码、独立帧解码和模拟回包验证发送/确认路径。当前环境没有可用物理串口，未执行实板配置；既有 `build/keyscan_pipeline_20261103/keymap/results.json` 记录此前 UART / 板级键位集成回归 45 项通过，本次未重新运行该 RTL 回归（环境缺少 Verilator）。
