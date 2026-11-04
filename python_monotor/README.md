# 两种合成引擎的 Python 模拟

本目录统一收纳板端 **ENG0矩阵状态空间引擎**与 **ENG1 ABC二阶递推引擎**的Python模拟、参数提取、系数生成、RTL参考对拍及试听结果。目录名按项目约定使用 `python_monotor`。

## 两种引擎的分工

| 引擎 | 模拟代码 | 计算结构与用途 |
| --- | --- | --- |
| ENG0 矩阵引擎 | `matrix_sim/` | 对每个模态的状态进行2×2矩阵递推；包含钢琴/吉他系数生成、浮点合成与试听实验。生产矩阵资源打包由 `rtl/router/tools/matrix_resources.py` 使用同源数据完成 |
| ENG1 ABC引擎 | `modal_sim/eng1_rtl.py`、`modal_sim/router_eng1.py` | 使用ABC参数的二阶递推，提供当前Q24整数参考模型，以及激励、包络、压力/音高调制、腔体、混响等链路模拟，用于与生产RTL对拍 |

ENG0/ENG1是两种计算引擎。A/B/C则是拨弦/击弦、持续激励、打击等音色类别，不能将其当作三个硬件引擎。`modal_sim/`也保留共用分析与历史浮点/Q30实验，当前ENG1参考入口以 `eng1_rtl.py` 为准。

## 目录

```text
python_monotor/
├── matrix_sim/       ENG0矩阵模拟、系数生成与synthlab实验库
├── modal_sim/        ENG1 ABC/Q24参考及共用、历史音色实验
├── fft_analysis/     频谱分析与参数提取
├── results/
│   ├── params/       提取与拟合的系数参数
│   ├── figures/      参数分析图
│   ├── presets/      冻结的离线参考结果
│   └── sim/          仿真、试听与诊断结果
├── paths.py          录音输入、参数与输出路径的统一定义
├── instruments.py    参数提取用的乐器登记
└── requirements.txt  主模拟工具依赖
```

主要数据流：仓库根目录 `music_resources/` 录音 → `fft_analysis/` 提取 → `results/params/` → ENG0/ENG1模拟、系数生成与RTL对拍 → `results/`图表及试听。ENG0独立试听也会写入 `matrix_sim/out/`。板端生产资源保存在仓库根目录的 `rtl/router/tools/performance/`。

## 运行

以下命令均在仓库根目录执行，使用已安装NumPy、SciPy、SoundFile等依赖的Python环境：

```bash
python3 -m pip install -r python_monotor/requirements.txt
# 录音参数提取
python3 python_monotor/fft_analysis/run.py --instrument guitar
# ENG0矩阵模拟试听
python3 python_monotor/matrix_sim/sim_guitar.py
python3 python_monotor/matrix_sim/sim_piano.py
# ENG1模拟入口（包含历史演示；当前整数参考见上文）
python3 python_monotor/modal_sim/eng1_demo.py
# 当前ENG1整数模型与生产RTL对拍，需要相应仿真器
python3 sim/run_eng1_model.py
# 核对两种引擎的生产资源、源指纹与存储格式
python3 sim/check_performance_resources.py
```

`matrix_sim/requirements.txt`补充独立实验库的依赖，实时播放等可选功能按该清单准备。渲染或提取会写入本地结果，音色实验输出与板端实际演奏分别记录。

## 目录迁移

2026-11-04已统一原三处目录：

| 原目录 | 当前目录 |
| --- | --- |
| `python/` | `python_monotor/` |
| `monitor_synthsound/`（更早为 `sythsound/`） | `python_monotor/matrix_sim/` |
| `monitor_FFT/`（更早为 `FFT_results/`） | `python_monotor/results/` |

当前脚本、资源生成入口、测试导入路径与生产资源清单已同步新位置。已有结果JSON中的历史来源路径/哈希，以及保留构建内的源码快照和输入指纹继续保持原值；查历史来源时按此表定位。移动不改变系数数据、试听文件或板端位流。

迁移校验：两种引擎相关单元测试83项通过；重建16条ENG0/ENG1参考音记录，与生产资源逐字节一致；完整生产资源格式与源指纹检查通过。原参数、结果数据、生产资源二进制及保留位流校验值未变。
