# Mystery of Love 第一段副歌：实验长笛音色

旋律来源：https://www.hooktheory.com/theorytab/view/sufjan-stevens/mystery-of-love#chorus 。使用页面 Chorus 的公开 Copy Melody 导出；社区转录，并非官方总谱。
E小调、108BPM，31个音符，保留原旋律节奏和休止。无伴奏。

当前音色：240ms起音、120ms回落至85%、180ms释放；gentle起音激励渐变。
每音高中弱奏谐波权重、生产模态极点、腔体直通、无混响、无新增气息。
E4沿用已经试听的权重；其他音高用各自mezzo-piano采样的谐波比例离线拟合，传递函数RMS向E4对齐。

mystery_of_love_chorus_flute.wav：固定增益PCM24试听版。
mystery_of_love_chorus_flute_native.wav：不调整音量的原生PCM16版。
note_resources.json：逐音高G/a1/a2和参考音源。

使用现有ENG1采样帧定点模型；零变调回放先与正常帧路径对照1600采样。
未模拟MIDI解析/加载/时钟级调度；未修改生产RTL或部署资源。
固定240ms Attack对短音也生效；没有新增连奏包络行为。
检查31次起音、模态轨限、前后静音、有限值和WAV峰值通过；见manifest.json。
