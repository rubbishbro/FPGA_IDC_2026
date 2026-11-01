# 当前板级资源

六音色混合格式镜像，固定16音、64KiB/乐器区域，headroom=3；完整配置与验证见[双引擎接入与增益](../../../../docs/音频设计.md)。

- `resources.bin`：768KiB，物理烧录地址0x800000，不含前缀。
- `resources.mem`：同一字节图像，仿真用。
- `resources.json`：布局、音符来源、源文件和镜像哈希。
- `gain.json`：共同headroom下的逐音Q12增益与声部数LUT；RTL常数在`rtl/router/pkg/performance_gain_pkg.sv`，需重编配套固件。
- `piano_eng0`、`guitar_eng0`：ID0/1的原矩阵表。
- `trumpet_eng1`、`violin_eng1`：ID3/5的ABC/P1T1表。
- `piano_abc_eng1`、`guitar_abc_eng1`：ID10/11的ABC/P1T1表，分别为钢琴2、吉他2（F）。

矩阵与ABC的同一字节位置含义不同，禁止互换编号。未装的区域保持FF。固件地址0，资源地址0x800000，分别擦写与校验；本次未烧录。
