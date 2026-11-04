# 固定方案：flute_soft_legato_v1

用户于2026-11-03选定的长笛音色与演奏基线。后续对照以本版为准，修改另建版本，不覆盖v1。

- 逐音高中弱奏模态权重，原生产极点；冻结8个已试听音高：D4/E4/G4/A4/B4/C5/D5/E5。
- Attack240ms，Decay120ms，Sustain85%，Release从保持电平180ms。
- gentle起音激励：两级右移5位低通，保持1536采样，再经4096采样的移位加法渐变回原脉冲。
- 腔体五段直通，不加混响或额外气息。
- 相邻音提前40ms起、延后60ms松；保留乐句休止。
- 上行尾音+12音分，下行起音+18音分、100ms内回本音；使用既有PAD压力弯音映射，松键保持音高。

`preset.json`冻结完整参数、验证音域、资源哈希和实现边界。
`note_resources.json`包含所有8个音高的64条G/a1/a2及周期，不依赖重新拟合或重新提取。
参考音频和输入夹具在`python_monotor/results/presets/flute_soft_legato_v1/`。

复现（在仓库根目录、numpy/scipy/soundfile环境）：

```bash
python3 python_monotor/modal_sim/presets/flute_soft_legato_v1/render.py
```

脚本校验模型及资产哈希，再完整重渲染并与参考raw/PCM逐位对照。
后续模型升级若导致哈希变化，不要绕过v1检查；新建版本并重新验证。

边界：此版为采样帧定点仿真基线，未写入生产RTL、Flash或全音域资源。
起音激励仍是已有模块边界内的实验算术；96采样弯音快照回放未覆盖控制FSM时钟延迟。
音符连接和弯音属于演奏设置，不是乐器固有声学系数。
