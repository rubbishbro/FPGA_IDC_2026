# Router测试台

本目录位于`rtl/tb/router`，从`rtl/router`迁出，集中存放该子系统的测试台与仿真模型。

| 文件 | 用途 |
|---|---|
| `tb_music.sv` | 音乐合成集成测试台 |
| `tb_loader_ref.sv` | Flash加载参考测试台 |
| `tb_eng1_cosim.sv` | ENG1与Python模型联合仿真测试台 |
| `w25q_dut.sv` | Flash行为模型引脚适配层 |
| `vendor/w25q128/` | 厂商Flash行为模型、初始化文件及许可证 |

旧 PowerShell 仿真入口已删除。当前入口包括 `sim/run_flash_ref.py` 和 `python/modal_sim/eng1_cosim.py`，共享源文件清单为 `sim/router_sources.list`。各入口已更新源文件路径，运行工作目录规则保持不变。其他子系统测试继续保留在`sim/unit`。
