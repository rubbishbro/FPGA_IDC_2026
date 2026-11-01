# 咏春：小提琴副歌节选

七朵组合《咏春》，取副歌重复记号处开始的8小节主旋律。按公开简谱人工录入，不是原唱录音转录或伴奏复刻。

[谱源：桃李醉春风制谱](https://www.xinyuepu.com/jianpu/20194/9857.html)

[试听](yongchun_chorus_violin_experimental.wav) / [原生PCM16](yongchun_violin_native.wav) / [完整配置与结果](results.json) / [音符事件](events.json)

- C调，75BPM，44个按键事件，最低A3、最高A4；总长26.8秒，包括0.2秒起始静音及结尾休止/尾音。
- 同音延音线按谱保持；其他重复音保留松键再按。最后括号内的器乐过门省略，以休止结束。
- 合成ADC压力经过板级force_map与64/48门控；压力8ms上升/12ms下降，下降在名义note-off结束，音符间留15ms。
- 沿用刚才的小提琴实验包络：20ms attack、full sustain、无decay、80ms release。周期冲激和原模态系数不变，48个计算模态，无混响、无额外噪声/颤音/滑音。
- 固定16槽MIDI56..71，缺失音高由生产打包器重定音生成；细节见results.json的resources。
- 试听只加恒定增益；原生PCM和Q24另存。此包络是Python实验候选，输入由合成按键动作驱动。

复跑：`python3 python/modal_sim/violin_yongchun_audition.py`。
