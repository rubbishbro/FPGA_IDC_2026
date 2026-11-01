# 分支整理（2026-11-01）

日常开发统一到 `main`。旧分支使用下列标签保存完整提交历史，标签已保留的分支可删除。

| 原分支 | 归档标签 | 说明 |
| --- | --- | --- |
| board50 | archive/2026-11-01/board50 | 50 MHz 上板、引脚、Flash QE、FFT 与极坐标显示；独有提交尚未逐项移植到主线 |
| boardtest | archive/2026-11-01/boardtest | 键盘压力、FFT、极坐标；已包含在发布快照历史中 |
| codex/board-release-flash8m | archive/2026-11-01/board-release-flash8m | 钢琴/吉他上板发布快照与 Flash 资源 |
| wwiinnd-patch-1 | archive/2026-11-01/wwiinnd-patch-1 | 保留竞赛 FAQ Excel 上传及原始历史 |
| codex/temporary-fmap-display | archive/2026-11-01/temporary-fmap-display | 合并主线之前的 UART 录音、音频修复和临时 fmap 显示开发快照 |

本地 `list`、`lost`、`uart-test` 已被主线包含，删除分支名不丢失提交。两份 stash 保留。

合并保留钢琴/吉他临时试听配置（RESOURCE_MASK=0x03，PCM_HEADROOM_BITS=0，居中双耳单位增益），同时保留远端四音色资源、包络、调制门控和 PAD 灯效。资源检查接受原四音色配置和当前试听配置两个明确组合；资源镜像重新生成以更新合并后的源码哈希。

恢复旧分支示例：`git switch -c board50 archive/2026-11-01/board50`。
