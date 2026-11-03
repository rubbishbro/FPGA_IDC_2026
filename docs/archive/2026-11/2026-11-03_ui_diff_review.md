# UI git diff Review（2026-11-03）

范围：当前未提交 diff，以及 380a26de..HEAD 的 UI/配置相关提交；重点为 d3604c20 的
sidebar_ctrl 预计算优化、7ffbd805 的混响枚举统一、8aa198c4 的自定义键位显示，
以及 instrument_system/midi_voice_top 当前未提交的来源校验。

## [P1] 冷启动菜单缓存未初始化，乐器选择卡在钢琴1

位置：`rtl_FFT/src/ui/sidebar_ctrl.sv:45-59`，引入提交 d3604c20。

复位将 scene.category/selection/edit_index 及 cat_q/sel_q/edit_q 都设为0，changed_q也为0。
进入菜单→声音分类→乐器编辑不会改变这三个值，scene_changed 始终为0；缓存从不填充，
limit_use保持复位值0（正确应为11），count_use也保持0（正确应为2）。因此DOWN不能将
乐器草稿从0改为1，也无法在首次声音分类中向下选择音量。切换分类/选中项等操作可能
偶然触发初始化，掩盖问题。

使用优化前 `git show d3604c20^:rtl_FFT/src/ui/sidebar_ctrl.sv` 与当前模块并行接收完全相同
的复位和按键序列：2（打开）、2（声音）、2（编辑乐器）、1（下）。结果旧版draft=1、
新版draft=0；真实 sidebar_system + dispatch + midi_voice_top 集成夹具也复现 limit=0/draft=0。
所提供 v2 综合网表确有 count_q、limit_q、changed_q，属于待核验固件中的实际逻辑范围。

建议：首次复位释放后强制填充缓存，或引入cache_valid并在有效前使用组合值；不要仅依赖
scene字段变化。应加入冷启动直入声音菜单的定向回归，随机导航容易先触发缓存而漏检。

此缺陷证明UI优化存在功能回归，但其直接表现是草稿不能变化，不能单独解释所有配置
已经选到新值却返回失败，也不能宣称已完整解释混响/音区故障。

## [P1] 来源校验混用两种source编号，会误伤本地菜单

位置：`rtl/platform/tang_mega_138k_pro/instrument_system.sv:241`，当前未提交diff。

sidebar_system 的 control_loop 输入为 {external, UI}，所以 backend_source 的0/1表示
本地UI/外部配置；quarantine和remote_permission的索引0/1则表示有线/蓝牙。
新增 `!quarantine[backend_source] && remote_permission[backend_source]` 因此把本地菜单
当有线，把所有外部配置当蓝牙，没有使用真实 ctx_source。

有线被隔离或禁用远程控制bit0后，本地菜单的乐器、混响、音区配置都可能在实际装载后
被 midi_voice_top 的提交门禁拒绝。蓝牙隔离/权限bit1也会误伤有线外部配置。

集成复现：先绕过第一处缓存问题，使本地菜单确实生成吉他草稿1；在 sound 输入处令
backend_source_valid=0（模拟板级门禁失效，不是通过UART引脚注入隔离），真实UI→dispatch→
音频后端完成后，本地source=0收到result=6，提交快照仍为钢琴。此测试证明门禁会拒绝
本地请求；实际板级索引混用来自上述连线的静态数据流核查。

建议：本地请求不依赖远程串口权限；外部请求使用请求被接受时锁存的物理 ctx_source，
并保持到事务完成。不要直接将 UI/外部仲裁编号作为串口来源编号。

这部分是未提交修改，尚未确认它进入用户提供的v2 FS；必须与第一项已复现UI回归分开。

## 其他检查与验证边界

- 混响枚举依然为2位0/1/2/3，audio_config_t未因该diff改变位宽；NONE/HALL/BATHROOM值保持。
- 自定义键位灰色提示只修改绘制，没有修改低/高音组请求。
- control_loop、config_dispatch、sidebar_system和sidebar_mailbox在上述提交比较范围没有新增diff。
- lcd_fft颜色与spectrum显示修改没有配置请求数据通路。
- 前轮30次Flash专项通过只证明外部请求提交路径，不能覆盖本次发现的冷启动本地菜单缺陷。
- 50,000周期随机旧/新对拍曾通过；定向冷启动序列立即复现差异，说明随机测试覆盖不足。
- 本轮没有修改生产RTL、重新综合或烧录；只写审查证据。

证据：`build/ui_source_review_20261103/differential.log`、`run.log`、`results.json`；
该目录保留优化前模块、对拍TB和集成复现TB。两个专项均复现预期缺陷；不是修复后的PASS。
