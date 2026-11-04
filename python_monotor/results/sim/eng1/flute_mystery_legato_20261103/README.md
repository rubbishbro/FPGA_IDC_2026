# Mystery of Love副歌：音头音尾重叠与小幅弯音

沿用上一版31音旋律、逐音轻奏权重、240ms Attack、85% Sustain、180ms Release与gentle激励。
相邻音提前40ms起音、延后60ms松键；乐句休止不连接。上行衔接尾音升至12音分；下行新音从+18音分在100ms内回本音。
使用当前PAD aftertouch的非负映射：102为0，100压力计数对应60音分。压力也影响原激励幅度。
松键后保持最后音高；同一P1T1/Q24比例同时改变激励相位增量与模态a1。

mystery_of_love_chorus_flute_legato_bend.wav：新版试听。
original_then_legato_bend.wav：先上一版，后新版。

按96采样控制周期回放committed_delta，未模拟控制FSM提交延迟或ADC/MIDI时钟。
未使用不受支持的负弯音/MIDI弯音接口；未修改生产RTL。
pressure_fixture.npz、traces.npz和manifest.json包含压力、门控、重触发和音高轨迹。
检查31次起音、释放音高保持、压力映射、模态轨限与输出峰值通过。
