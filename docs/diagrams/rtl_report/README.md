# 系统 RTL 汇报图

更新：2026-11-01。这组图配合 [系统RTL框图说明](../../系统RTL框图说明.md) 使用，是**内部汇报版**：
按当前源码的实际实例树和端口宽度画，不是旧文档的合同复述。

| 文件 | 内容 |
|---|---|
| `01_system_overview` | 整机总览：板级入口、主要功能块、三条独立通道 |
| `02_clock_domains` | 单 PLL 三域、复位链、5 类跨域协议 |
| `03_comm` | 双物理通道 → SLIP/v2 → arbiter/parser → 事件与配置 |
| `04_config_control` | 摇杆/按键/远程请求 → loop → dispatch → 三类提交 |
| `05_performance_frontend` | MIDI 事件路径与压力路径在 router 内选源 |
| `06_router_frontend` | 每采样帧头：激励/包络并行与整表快照 |
| `07_router_compute` | 双 bank 计算 → 包络乘 → 混音 → 腔体 → 混响 |
| `08_engine_storage` | 模态 RAM、写口仲裁、eng0/eng1 与定点格式 |
| `09_flash_loader` | 64B 记录格式、QSPI 状态机、失败写零与静音 |
| `10_audio_output` | Q24→PCM16→双声道→FIFO→I2S/PT8211 与采样时基 |
| `11_display` | PCM 副本 → FFT/波形/极坐标 → 三层叠加 → LCD |
| `hierarchy_top` | 板级实例树（脚本从 RTL 自动提取） |
| `hierarchy_router` | voice_router 实例树 |

## 重新生成

```bash
./render.sh                     # 全部 DOT → SVG/PNG
python3 tools/gen_hierarchy.py  # 只重算实例树（HIER_DEPTH / HIER_ROOT / HIER_OUT 环境变量）
python3 tools/build_report.py   # Markdown → build/report_diagrams/report.html
```

`build_report.py` 依赖 `markdown` 包，可用 `pip install --target build/report_diagrams/.pylib markdown`，
再以 `PYTHONPATH=build/report_diagrams/.pylib python3 ...` 运行；随后用 Chrome 无头模式打印 PDF：

```bash
google-chrome --headless=new --no-pdf-header-footer \
  --print-to-pdf=docs/系统RTL框图说明.pdf build/report_diagrams/report.html
```

`tools/hierarchy.py` 是极简 SystemVerilog 实例扫描器（正则级，不解析参数/端口），只用于画实例树；
端口与位宽以源码和 [系统RTL框图说明](../../系统RTL框图说明.md) 表格为准。
