# 音频资源生成

本目录仅保留当前资源生成、打包程序及其数据，不存放旧仿真入口或实验产物。

| 路径 | 用途 |
| --- | --- |
| `performance_resources.py` | 六音色板级资源生成入口 |
| `matrix_resources.py` | ENG0矩阵补音及钢琴矩阵→ABC离线转换 |
| `pack_board_flash.py` | 固定乐器区及公共控制页打包 |
| `sustain_resources.py` | 持续音系数和演奏参数生成 |
| `pitch_tables.py` / `pitch_tables.json` | 公共音高控制页编码和离线表值 |
| `sustain_profiles.json` | Python 试听、资源生成溯源和回归共用的持续音资源目录 |
| `coefficients/` | 当前仍被读取的 ENG0 矩阵系数源 |
| `performance/` | 当前资源输出：BIN、仿真 MEM、清单 |

仿真入口和共享源码清单位于 `sim/`，testbench 位于 `rtl/tb/`。旧 PowerShell 入口、旧矩阵打包工具、演示镜像、biquad 实验工具及向量、重复 MEM、Python 缓存已删除。

资源采用 schema 5：六音色各32音，按乐器独立起始音高，默认低16音。控制表迁移尚未测试、编译或烧录；文件存在不代表验收通过。
