# 本地菜单混响专项（2026-11-03）

结论：当前源码在来源校验正常时，没有复现本地菜单混响修改失败；冷启动直接进入效果栏也可成功。
本轮为RTL仿真，不是用户板卡的现场复测，没有修改生产RTL或烧录。

新增入口：`python3 sim/run_local_reverb.py --out build/local_reverb_review_20261103 --jobs 2`。
夹具 `sim/unit/midi/tb_local_reverb.sv` 从真实按键输入进入 sidebar_system，经过 sidebar_ctrl、
control_loop、config_dispatch、midi_voice_top、voice_router、weight_loader；Flash使用当前1576960字节
资源MEM，基址0x800000，禁止读取程序区；核心50MHz，内部供样模式（不含实体ADC/UART/I2S）。

实际运行25.44秒完成：7次配置接受、7次完成。检查请求ID=0x0200及值、source=0本地菜单、
真实回复、authoritative audio_state、active_values[2]、reverb_q和菜单busy/result。

- 冷启动→打开菜单→效果→混响：NONE→HALL→BATHROOM→CHAMBER→NONE，四次全部成功。
- 持续PAD力度100时从NONE切HALL成功，松开后切回NONE成功。
- 将backend_source_valid输入置0，菜单切HALL返回6，audio_state和UI提交值保持NONE；
这是显式注入门禁失效，不是通过实体或仿真UART制造隔离。说明来源门禁可以造成同类失败，
不能证明现场触发了这个条件或该未提交改动进入了用户FS。

另执行既有 tb_reverb_presets：PASS，覆盖四个协议ID、标签、非法值、HALL/BATHROOM参数及
CHAMBER/NONE极值逐位直通。代码中CHAMBER仍是占位直通，与NONE相同；提交成功但听感无变化
是该预设当前设计行为，与菜单反馈失败不同。未做模拟输出听测。

证据：`build/local_reverb_review_20261103/run.log`、`results.json`（含本轮关键源码SHA256）；
DSP单元结果在 `build/local_reverb_dsp_20261103/run.log`。

因此，先前冷启动乐器缓存缺陷不能解释本轮混响配置失败。现场混响失败的根因仍未确认，
需要对用户烧录的FS及运行时来源门禁/装载状态继续核对，不能据此宣称实板问题已修复。
