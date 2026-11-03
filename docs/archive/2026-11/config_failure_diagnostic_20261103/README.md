> 后续代码review已在同批067C网表中复现共同提交失败，见[配置提交Review](../../../reports/2026-11-03_代码Review_配置提交.md)。诊断返回码版不再是必经步骤。

# 067C 提交失败诊断包

对应位流SHA256：8c8bfa6ff155797fb5dc0b1611569216e799f588c59fbeec62a597ce79d869bc。
远端资料来自05ccb82c，下载至build/remote_05ccb82c。SHA256SUMS的15项全部核对通过。构建11:57:35–12:13:05；setup +1.049ns、hold +0.181ns、其余所报告检查无违例。SDC未对整个配置控制域作false path豁免。

## 本轮结论边界

同批综合网表的config_dispatch在输入正确请求/快照时未出现固定失败，错误tag负对照产生失败；候选配置网表接受piano/source0/channel2/reverb1，非法channel0负对照被拒绝。这些是强制内部节点的局部门级实验，不是完整事务或整板门级仿真，不能证明实板实际捕获了这些值，也不能据此宣称综合/硬件没有问题。原始实验夹具及日志位于build/gate_config_067c。

结合前轮实板UART全部合法混响返回06、失败后录制仍成功，仍应优先取得实际失败分支；不能把BACKEND_CHECK本身说成已确认根因。

## 诊断补丁

config_failure_codes.patch只改变失败分类及UART桥的错误码透传，不修复功能、不改变Flash寻址或loader协议。此为临时诊断版本，不是正式发布协议；不要将新错误码直接作为正式客户端协议使用。

在另一台PC的干净诊断副本中：

```bash
git apply --check /path/to/config_failure_codes.patch
git apply /path/to/config_failure_codes.patch
```

然后使用正常板级构建流程生成单独位流。使用产生067C的源码/设置副本最有利于控制变量；如果只能使用当前HEAD，请明确记录其commit和未提交差异。保留原067C位流与原构建目录。当前补丁基于05ccb82c；rtl/config_dispatch.sv在本地2dc08ada与该提交之间没有差异。

只需回传新位流及其SHA256、构建来源。下一次UART仍发送原COMMAND02配置请求，回复帧格式不变；错误码现在可区分：

| 返回码 | 含义 |
| --- | --- |
| 00 | 成功 |
| 81 | 后端tag不匹配 |
| 82 | 后端参数ID不匹配 |
| 83 | applied_value超出该参数合法范围 |
| 90..9F | 音频快照校验失败，低四位为错误位图 |
| A0..AF | 后端直接返回失败，低四位为原内部结果码 |
| 06 | 未进入上述诊断分支；仍需查桥接拒绝/身份校验等路径 |

90类位图：bit0=audio_valid_q为0；bit1=audio_config_valid(audio_q)不通过；bit2=audio快照中对应值不等于applied_value；bit3=applied_value不等于请求值。例如91代表音频有效位未到，94代表快照与返回值不一致，98代表返回值与请求不一致。多项可同时置位。A4表示后端明确返回CFG_FAILED。

## 已执行验证

- 9项专项仿真通过：成功、tag错、ID错、applied越界、有效位缺失、快照结构非法、快照值不匹配、返回值与请求不符、后端失败。
- 将两处替换文件放入05ccb82c整板源清单后，Questa整板编译通过。
- 未进行该诊断版本的Gowin综合/PnR，未生成或下载诊断位流，未修改生产RTL。

验证日志：build/config_failure_codes/run.log、full_board_compile.log。
