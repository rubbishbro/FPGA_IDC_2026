# UI / Flash / Loader 差异复核（2026-11-03）

> 阶段报告：结论与验证范围以报告日期为界，当前状态见[状态页](../status.md)。旧构建产物已按交稿要求清理，文中旧路径保留作历史定位。

未改生产RTL、未烧录。采用两层比较：包含较早UI预计算优化的56045d15（Nov 2 20:31）到HEAD，以及d3604c20（Nov 3 04:57，侧栏count/limit/change缓存优化）前后与当前。用户实测通过的准确提交尚未指定，因此不把56045d15等同于已确认的实测基线。

## UI

56045d15中的sidebar_ctrl仍直接使用组合count/limit/change；d3604c20新增缓存和scene_changed门控。此后直到HEAD，sidebar_ctrl逐字节未变。两种优化不能混淆：较早lcd_sidebar的标签/数字帧间预计算和sidebar_system的dirty分组比较，与d3604c20选择范围缓存属于不同改动。

A/B仿真仅替换d3604c20父提交的sidebar_ctrl，其余使用当前package：首次编辑音色后向下，旧版draft=1、limit=11、count=2；当前版draft=0、limit_use=0、count_use=0。旧版与当前版在切换分类后的混响、音组编辑均能变为1。这直接确认d3604c20引入了首次音色/分类选择回退，但仍不足以解释全部实板现象。

从56045d15到HEAD，UI其余主要变化：声像参数从旧索引改为21并加入初值同步；自定义音组显示值2进入编辑时转为普通组0；混响标签与校验支持CHAMBER；旧LEGACY_UI渲染路径移除。sidebar_mailbox与joystick_adapter没有差异。d3604c20以后lcd_sidebar仅混响标签case调整，sidebar_system/config_dispatch没有差异。

## Flash与资源

56045d15、d3604c20和HEAD均为基址0x800000、容量16MiB、32音、每乐器0x20000字节、资源总长1576960字节、mask0xC2B。instrument_board_top及Flash引脚相同；CST仅蓝牙引脚改变。

逐字节比较56045d15与当前resources.bin：ID0..10各区完全相同，ID11（guitar2，0x960000分区）改变7011字节；尾部0x980000控制页完全相同。因此该段历史的资源内容改动无法解释piano1、混响、高低音组一起不可选。此结论针对仓库文件，未替代板上Flash回读。

## Loader与周边

rtl/router/loader.sv从56045d15到HEAD完全相同；此前127175b6仅新增LOAD_CONTROL时N_MODES至少为3的仿真参数断言，位于synthesis translate_off内。QSPI命令、QE初始化、读时序、地址计算及完成/错误握手没有新增改动。

midi_voice_top有实质改动：341b8cc1增加自定义键位、custom_q偏移选择、committed_map、回滚和keymap事务；7ffbd805统一混响枚举。默认非自定义音组仍使用(bank?16+i:i)*64*64，未改变；custom_q复位0，切音色/普通音组会清除custom状态。

voice_router还改了子模块复位分发、part_tick复制、part_commit保持到frame_start、逐声部调制共享通道等。虽然不是loader.sv本体改动，但所有配置仍共享cleanup→maintenance→load→drain提交链，因此若实板是“能修改草稿、提交后全不生效”，应优先抓这一共同链路的状态，不能只检查Flash地址公式。

## 证据与结论

build/ui_flash_diff_20261103保存ui.patch、midi_backend.patch、voice_router.patch、空loader.patch、resources_diff.json及before_cache.log。当前完整联合场景见build/review_selection_20261103/full_board/system.log。

已证实的回退是d3604c20首次缓存初始化遗漏。没有发现这两个比较区间内新的Flash布局或loader本体回退。后续定位应区分编辑值不变与提交等待：前者检查UI/摇杆，后者检查维护、装载、放键等待及响应。尚未证实另一个能解释全部实板问题的根因。
