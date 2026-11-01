#!/usr/bin/env python3
"""Render docs/系统RTL框图说明.md -> HTML -> PDF (A3 landscape, one figure per page)."""
import re, sys, pathlib, html
import markdown

ROOT = pathlib.Path(__file__).resolve().parents[4]
SRC = ROOT / 'docs' / '系统RTL框图说明.md'
OUT_HTML = ROOT / 'build' / 'report_diagrams' / 'report.html'
OUT_PDF = ROOT / 'docs' / '系统RTL框图说明.pdf'

text = SRC.read_text(encoding='utf-8')
body_md = text.split('\n', 1)[1]  # drop the H1, cover carries the title

# PDF 里不保留页内锚点（Chrome 不生成书签），把 [#...] 链接降级为纯文本
body_md = re.sub(r'\[([^\]]+)\]\(#[^)]*\)', r'\1', body_md)
# 图片路径由 <base href=".../docs/"> 解析，无需改写

# PDF 用矢量 SVG，避免位图放大失真
body_md = re.sub(r'!\[([^\]]*)\]\((diagrams/[^)]+)\.png\)', r'![\1](\2.svg)', body_md)
md = markdown.Markdown(extensions=['tables', 'fenced_code', 'sane_lists', 'attr_list'])
body = md.convert(body_md)

CSS = """
@page { size: A3 landscape; margin: 10mm 10mm 12mm 10mm; }
* { box-sizing: border-box; }
body { font-family: "Noto Sans CJK SC","Microsoft YaHei",sans-serif; font-size: 10.5pt;
       color:#0f172a; line-height: 1.55; margin:0; }
h1,h2,h3,h4 { color:#0b2545; line-height:1.25; }
h2 { font-size: 17pt; margin: 0 0 6mm 0; padding-bottom: 2mm;
     border-bottom: 1.2pt solid #93c5fd; page-break-before: always; }
h3 { font-size: 13pt; margin: 6mm 0 2mm; color:#1e3a8a; }
h4 { font-size: 11.5pt; margin: 4mm 0 1.5mm; }
p, li { orphans: 3; widows: 3; }
table { border-collapse: collapse; width: 100%; margin: 3mm 0 5mm; font-size: 9pt; }
th, td { border: 0.5pt solid #cbd5e1; padding: 1.4mm 2mm; text-align: left; vertical-align: top; }
th { background: #eff6ff; font-weight: 600; }
tr:nth-child(even) td { background: #f8fafc; }
code { font-family: "Noto Sans Mono CJK SC", monospace; font-size: 8.6pt;
       background:#f1f5f9; padding: 0.4mm 1mm; border-radius: 1mm; }
pre { background:#0f172a; color:#e2e8f0; padding: 3mm 4mm; border-radius: 2mm;
      font-size: 8.6pt; line-height: 1.45; overflow: hidden; page-break-inside: avoid; }
pre code { background: none; color: inherit; padding: 0; }
img { display:block; margin: 3mm auto; max-width: 100%; max-height: 235mm; }
p:has(> img) { page-break-inside: avoid; page-break-after: always; text-align:center; }
p:has(> img) a { font-size: 8.5pt; color:#64748b; }
blockquote { margin: 3mm 0; padding: 2mm 4mm; border-left: 3pt solid #f59e0b;
             background:#fffbeb; font-size: 9.8pt; }
hr { border: none; border-top: 0.6pt solid #cbd5e1; margin: 6mm 0; }
a { color:#1d4ed8; text-decoration:none; }
.cover { page-break-after: always; padding-top: 55mm; text-align:center; }
.cover h1 { font-size: 30pt; margin-bottom: 4mm; }
.cover .sub { font-size: 14pt; color:#334155; }
.cover .meta { margin-top: 22mm; font-size: 11pt; color:#475569; line-height: 2; }
.cover .kpi { margin: 18mm auto 0; width: 70%; }
.cover .kpi td { border: 0.5pt solid #dbeafe; text-align:center; font-size: 10pt; }
"""

cover = f"""
<div class="cover">
  <h1>FPGA 模态合成电子乐器<br/>系统 RTL 框图与模块说明</h1>
  <div class="sub">内部汇报版 · 以当前工作区源码为准</div>
  <div class="meta">
    平台：Tang Mega 138K Pro（GW5AST-LV138FPG676AES）<br/>
    日期：2026-11-01<br/>
    生产 RTL：96 个源文件 / 19,560 行 / 82 个实例树模块
  </div>
  <table class="kpi">
    <tr><td>合成规模<br/><b>16 声部 × 64 模态</b></td>
        <td>采样率<br/><b>48.828125 kHz</b></td>
        <td>时钟域<br/><b>50 / 12.5 / 33.333 MHz</b></td>
        <td>50MHz 时序<br/><b>Fmax 53.839 MHz</b></td></tr>
  </table>
</div>
"""

html_doc = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<base href="file://{ROOT}/docs/">
<title>系统 RTL 框图与模块说明</title>
<style>{CSS}</style></head>
<body>{cover}{body}</body></html>"""

OUT_HTML.write_text(html_doc, encoding='utf-8')
print(f'html -> {OUT_HTML.relative_to(ROOT)}')
