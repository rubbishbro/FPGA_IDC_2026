# 测试分类与运行说明

功能仿真用 **cocotb + Icarus Verilog**；Gowin 只负责综合 / 布局布线 / 烧录。
原有 46 个扁平 `sim/*.py` 已 **1:1 迁移**进分类目录，路径变了、用例/断言/参数/超时门槛不变。
机器可读清单见 [`catalog.json`](catalog.json)，统一入口是 [`run.py`](run.py)。

## 1. 快速开始

```bash
micromamba activate torch312          # 或 export PATH=$HOME/micromamba/envs/torch312/bin:$PATH

python sim/run.py --list              # 看全部脚本（只读 catalog，不跑任何东西）
python sim/run.py --list --category core
python sim/run.py --list --filter 饱和 # 按 purpose/id 子串过滤
python sim/run.py --help

python sim/run.py core/resonator      # 运行某个稳定 id
python sim/run.py core/bank --testcase t01_reset_preconfig --build-dir /tmp/opencode/my-bank-check
```

`--list` / `--help`只读取清单，不构建、不运行测试，也不导入cocotb、Matplotlib等依赖。
没有自动 `--all` 全量、没有自动烧录。

## 2. 分类目录

| 目录 | 内容 |
|---|---|
| `unit/core/` | resonator / modal_bank / coeff_loader / modal_poly_bank / modal_engine 及其独立 review |
| `unit/audio/` | audio bring-up 单元、song_player 及其独立 review |
| `unit/body/` | body 四 biquad 单元、纯模型、数值/拒绝 review |
| `integration/` | 真实 engine 的整链 / 板级集成与 body 端到端 |
| `netlist/` | 真实 Gowin 综合网表级检查（bank / body / song） |
| `regression/` | 元数据位图、lane 地址、RAM 等价、write-mode 修复与持续性引擎控制率/收尾残留回归 |
| `checks/` | preflight 门禁、Gowin 报告门禁、合成夹具检查 |
| `diagnostics/` | 隔离诊断音调引脚级复核 |
| `tools/` | 报告检查、绘图与真实Gowin构建工具；不是测试，build类会执行综合/P&R |
| `support/` | 共享运行/快照/路径辅助，**不可直接运行** |
| `archive/bringup_mock/` | 早期 mock 链路归档，见 §4 |

`catalog.json` 中每个脚本都有 `id`、`path`、中文 `purpose`、`role`
（baseline / independent / regression / tool / archive / support）、`kind`
（rtl / python / netlist / reports / build / plot）和简单 `deps`。

## 3. 精选入口（完整 48 条请 `--list --filter`）

| id | 用途 |
|---|---|
| `core/resonator` | 单谐振器定点递推逐比特对拍（起点的最小闭环） |
| `core/bank` | 2A 四 lane 单声部 modal_bank 回归 |
| `core/engine` | 2B/2C loader + 32 声部集成引擎回归 |
| `audio/transport` | 音频 bring-up 单元协议与跨时钟回归 |
| `body/filter` | body 四 biquad 单元（含坏 ROM / 坏 instrument） |
| `integration/body_demo` | 真实歌曲→engine→body→输出适配→FIFO→I2S 端到端 |
| `netlist/bank` | 真实 Gowin 综合网表级隔离 bank 检查 |
| `checks/gowin_report_gate` | 综合/布局报告门禁单元测试（合成夹具） |
| `regression/coeff_metadata` | coeff_loaded / low_unloaded 元数据位图回归 |
| `regression/sustain_control` | 持续性引擎 LFO 逐采样推进 / verify 静态校准 / 收尾噪声残留 / 静音回收相位独立模态 quadrature 包络 / 软抢占槽位绑定与 pending Note Off / 键回退 / release 提取 / 默认噪声（纯 Python，合成 Patch + 真实入口） |
| `archive/mock_board` | 早期 mock 板级链路（归档，仍有隔离覆盖） |

## 4. 归档：`archive/bringup_mock/`

`test_audio_board.py` 与 `test_audio_demo.py` 是早期板级/音频启动用例，完整保留、可运行。
它们包含mock engine、行为PLL与备选MIC等隔离覆盖；demo还保留一个真实engine分支，因此不能简单说“都是假数据、已无用”。
现行整链优先使用`integration/`；归档不是删除或宣称被完全替代，基础协议与独立黄金测试也不合并删除。

## 5. 直接执行 vs 统一入口

推荐始终用 `python sim/run.py <id>`：它会自动定位仓库根，把各分类目录、`sim/support/`
和 `python/modal_sim` 加入 `sys.path` 并镜像到 `PYTHONPATH`，再以
`runpy.run_path(..., run_name="__main__")` 执行原脚本、原样传参。

每个脚本内部也保留了一段祖先目录探测：`__file__` 向上找到同时含 `rtl/` 与 `sim/` 的仓库根，
并把 `sim/` 下带 `.py` 的目录加入导入路径。因此**直接执行** `python sim/<category>/<script>.py`
同样可用。迁移改了脚本SHA，旧验收证据中的原路径/SHA保留当轮版本，不覆盖旧冻结副本。

## 6. 输出与结果

- 保留原输出约定：基础回归通常写`sim/build/<name>/`，专项复核多用`/tmp/opencode/`；支持`--build-dir`的入口建议显式指定新目录，避免覆盖旧证据。不会误生成到分类目录下。
- 当前整理与验收不覆盖`sim/results.xml`及已有构建结果。
- `tools/`中的review/plot读取证据；build类和`netlist/bank`会运行真实Gowin综合（build类还会P&R），必须主动选择，并非“只读测试”。本次整理未运行这些构建，不调用Programmer。

## 7. 环境与 iverilog 约束（原说明压缩）

| 组件 | 版本 |
|---|---|
| Icarus Verilog | 13.0（`~/micromamba/envs/torch312/bin/iverilog`） |
| cocotb | 2.1.0（`torch312`，`cocotb_tools.runner`） |
| Python | 3.12（含 numpy/scipy） |

- 每个 RTL 文件都要有 `` `timescale 1ns/1ps ``，否则 cocotb 报 `Bad period`。
- `iverilog` 必须在 PATH 上（cocotb 用 `which iverilog` 找仿真器）。
- iverilog 13.0 支持：`logic`/`always_ff`/`always_comb`/packed struct/立即断言/generate/function；
  **不支持**：interface 出现在端口列表、SVA、unpacked array 参数——分别用离散端口、cocotb 时序检查、function+case 替代。
- 用 iverilog 4 态仿真是为了能显式查 X（`value.is_resolvable`），故现阶段不用 Verilator。
- 资源与 Fmax 只有 Gowin 综合/布局报告能给，功能正确性由 cocotb 负责。
