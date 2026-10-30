# 已上板验证的钢琴＋吉他版本

这是从本地 `build/main_src` 抽出的独立工程快照，基线为用户最后确认烧录通过的 Flash 地址搬移版。不是按“昨天”的字面日期另选旧版本。所有88份生产源文件与交付时的 `release/source_hashes.json` 逐字节一致；本次抽取不修改RTL。

## 直接烧录

解压 `release/phase1_piano_guitar_release.zip`，使用其中的文件：

1. Gowin Programmer：固件 `phase1_piano_guitar.fs` 写入板载MSPI Flash的 **0x000000**。
2. 音色 `piano_guitar_16.bin` 写入同一颗Flash的 **0x800000**；第二步不能再次全片擦除。
3. 重新上电，验证默认钢琴及菜单切换吉他。完整步骤见 [烧录与验证](release/烧录与验证.md)。

ZIP中的FS与已完成布局布线的 `instrument_board.fs` 内容一致，只统一了交付文件名。原构建位于 `build/main_src/build/instrument_board/instrument_board/impl/pnr`；ZIP和报告中的该绝对路径仅记录来源，直接烧录不依赖它。

固件SHA256：`b571c57211050ba481c02777c87c91b207109cb3bdc3b5bae55d3944668b46c6`。
音色BIN SHA256：`2305d756eb0e84d3f84e7b5b24fd9c658c0971ebc5e021bdd4ed1ba04808b15a`。

## 从本目录复现

在PowerShell中进入本目录，运行：

```powershell
& ./rtl/router/tools/pack_phase1.ps1
& ./rtl/router/tools/check_phase1_stability.ps1
& ./rtl/router/tools/run_phase1.ps1
& ./rtl/router/tools/phase1_pcm.ps1
& D:/gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe build_phase1.tcl
& ./rtl/router/tools/finish_phase1.ps1 -PnrDir ./build/phase1_piano_guitar/phase1_piano_guitar/impl/pnr -ProjectName phase1_piano_guitar
```

工具位置按本机安装；ModelSim路径可用 `run_phase1.ps1 -ModelSim <目录>` 指定。生成物位于本目录的 `build/`，由本目录 `.gitignore` 排除。无需原来的 `build/main_src`、另一个worktree或Python环境。

## 验证边界

- 原搬移版已实际完成Gowin综合和布局布线，setup/hold违例均为0，其余时序检查也通过；报告见 `release/verification.json`，完整时序报告在发布ZIP内。
- 用户反馈烧录验证通过；完全断电自启动是否已测，以用户实际操作为准。
- 现有ModelSim测试使用 `FLASH_BASE=0`，验证音色数据、配置切换、故障恢复及I2S；不把它当成0x800000搬移地址已通过仿真的证明。
- 音色为原16音布局，采样率约48828.125Hz，PCM余量4位；原钢琴极轻微的极点越界问题保留，详见 `release/stability.json`。

这个目录只携带该已验证版本所需的生产源、初始化数据、回归及打包脚本、发布文件；其它音色的开发工具和历史实验不在这个快照里。
