# 共享 RAM CORE 归档（2026-11-01）

本快照包含原 `rtl/core/`、`sim/unit/core/`、`sim/run_core.sh` 及共享 RAM 综合探针（gowin_build.tcl、router_probe.sv/.cst/.sdc）。原文件内容保持不变，原路径及 SHA-256 见 manifest.json。

这些代码未接入当前板级 sources.f，与当前 voice_router/eng0/eng1 不是同一实例树。测试仍有旧算法、定点格式、共享 RAM、握手与装载行为的历史参考价值，但不能作为当前实现的回归或时序证据，因此一并移出活动目录。

归档前完整回归已中断：run_core.sh 引用已不存在的 rtl/simsynth/modal_step_pkg.sv、modal_engine7.sv，e2_engine 接口也未迁移。2026-10-22 的 21 项 PASS 只代表当时版本。

脚本和测试中的原路径有意保留，归档不是可直接运行的独立工程；需要复现时应恢复匹配版本的依赖和原目录布局。当前构建入口为 rtl/platform/tang_mega_138k_pro/build.tcl，当前验证入口见 sim/README.md。rtl/rom 与 Python 模型未随本快照移动。
