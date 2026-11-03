# Flash 布局与配置切换 Review（2026-11-03）

现场：钢琴1可选，其他乐器、混响、低音组/高音组修改失败。用户确认测试固件为
`build/pnr_20261103_24min_v2/instrument_board/impl/pnr/instrument_board.fs`。

结论：没有在当前源码中发现 Flash 放置/读取地址不一致；本轮没有复现现场失败，不能宣布修复。
低/高音指音区（CFG 0x0300），不是 EQ；音区与混响都已接入真实后端。
本轮只增加测试和审查记录，没有修改生产 RTL，也没有烧录或新读回实体 Flash。

## 地址合同

用户指定 FS 对应的 v2 flow.log/综合日志确认 FLASH_BASE=0x800000、FLASH_BYTES=16777216、
FLASH_NOTES=32、NOTE_BANKS=1、RESOURCE_MASK=110000101011。构建资源合同为
1576960 字节、SHA256 `e9de9737735eda50f03853c959d162868949b2a80ec202dce992d3924c3ca900`。

实际读取地址为 `0x800000 + instrument*0x20000 + note_offset + mode*64`。
低组 note_offset=slot*0x1000，高组=(16+slot)*0x1000。公共控制页固定在 0x980000。
打包 BIN 无 8MiB 前导空洞，必须从 0x800000 写入；固件从 0 写入。

| 乐器 | ID | 低组起点 | 高组起点 |
|---|---:|---|---|
| 钢琴1 | 0 | 0x800000 | 0x810000 |
| 吉他1 | 1 | 0x820000 | 0x830000 |
| 小号 | 3 | 0x860000 | 0x870000 |
| 小提琴 | 5 | 0x8A0000 | 0x8B0000 |
| 钢琴2 | 10 | 0x940000 | 0x950000 |
| 吉他2 | 11 | 0x960000 | 0x970000 |

镜像覆盖 [0x800000,0x981000)，公共控制页 4096 字节，未越 16MiB 容量。
其他 ID 不在已部署掩码内，返回不支持不能作为 Flash 读失败证据。

## 确认的缺口与证据边界

1. 缺少本次 FS 烧录后的资源回读证明。11月2日六音色烧录的历史窗口逐区域比较：
钢琴1、吉他1、小号、小提琴、钢琴2、公共控制页与当前 BIN 完全一致；吉他2相差7011字节，
属于后来资源更新。不能拿早期768KiB错配当作本次已证实根因，也不能用历史回读证明当前板内内容。
2. `voice_router.sv` 的 weight_loader 实例 `.error_code()` 未接出；板级 sound 的
`config_failed/load_err/error_sticky` 也未暴露到外部诊断。最终 CFG_FAILED 会折叠多种原因。
这是可确认的诊断缺口，不是已经定位到的功能根因。
3. 混响修改也会触发 C_CLEAN→C_APPLY→C_WAIT→C_DRAIN 的真实重新加载，
所以三类修改共同失败时，需要同时检查维护握手、loader 完成/错误、配置200ms超时，
不能只怀疑非钢琴区域。loader 读操作为 6Bh，24位地址、8个dummy时钟、四线数据；
每次装载先设置 QE 并等待20ms。
4. 当前源码的仿真不等同于所提供 FS 的门级验证。父构建目录 input_hashes.json 对多份
当前源文件不匹配，不能用它证明 v2 FS 与当前工作区逐字节同源；v2 综合日志只能证明上述参数。

## 本轮执行验证

- `python3 sim/check_performance_resources.py`：PASS，12288条记录、32音、1576960字节。
- `python3 sim/test_flash_resources.py`：3项PASS（该历史测试中16音双表用例不替代当前32音验证）。
- `python3 rtl/router/tools/pack_board_flash.py --out /tmp/flash_review_20261103/resources.bin`：PASS，地址与上表一致。
- `python3 sim/run_integration_keymap_config.py --out build/flash_config_review_20261103 --jobs 2`：
生产板级UART/bridge/后端/loader回归45项PASS，含混响配置交接。
- 新增 `python3 sim/run_flash_config_review.py --out build/flash_config_six_20261103 --jobs 2`：
六音色，每种执行乐器选择、上组、HALL、下组、NONE；30次接受、30次完成、60个断言全部PASS。
真实 dispatch、midi_voice_top、voice_router、weight_loader；Flash 使用当前资源MEM及非零基址模型，
禁止读程序区。该专项为100MHz内部供样配置；上项板级测试为50MHz真实UART路径。
保留编译既有warning，不声称零warning。

机器证据：`build/flash_config_six_20261103/{results.json,run.log,layout_review.json}`，
以及 `build/flash_config_review_20261103/results.json`。

下一步应对当前板执行只读身份/资源核验：确认UserCode与该FS，读取0x800000起1576960字节
与上述镜像逐区比较，随后捕获失败时 cfg_state、u_ld.error_code、load_complete 和 cfg_timer。
本轮没有相连实板的最新读取结果，因此保持根因未确认。
