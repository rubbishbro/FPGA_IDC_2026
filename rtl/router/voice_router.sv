// -----------------------------------------------------------------------------
// voice_router.sv -- 声部路由器（第一版结构骨架）
//
//   职责：
//     1. 持有全部存储（系数 / 状态 / 激励 / 结果）
//     2. 按乐器号把存储口 mux 到两套互斥的引擎之一（modal_engine7 / eng_alt）
//     3. 调度：采样 x 声部，每个（采样, 声部）一个作业
//     4. 激励来自 exc_router（选源后的力度 -> 整张 xmap），**一次作业只跑一个采样**，
//        所以 xmap 直接整张寄存一拍当快照（不再有 x_ram / 采样深度）
//     5. 换乐器 = 停机 -> weight_loader 重灌系数表 -> 再跑
//
//   后级（在本文件末尾，顺序固定）：
//     6. 逐声部过自己的包络 -> 全部声部按采样加和 -> **统一过一遍腔体**
//        （body_router，乐器号选系数）-> 混响（reverb_router）-> y_data 输出
//     7. 混响（reverb_router）：预设由上层输入 reverb_preset 选，NONE 时是逐位直通
//        （只是多 6 拍延迟），HALL/BATHROOM 才真的加湿声
//
//   加载是**阻塞**的（S_LOAD 等 ld_done）：这段时间 input_hold=1，fmap 冻结、
//   note 事件不产生，也不出任何 y_valid —— 上层看到的就是"静音 + not ready"。
//   这是有意的设计选择（最省逻辑，代价是换乐器头 1~2 ms 没声音），不是遗漏；
//   要边放边载得改成双缓冲，以后再说。加载出错的处理仍然待定（loader 有 err 输出）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module voice_router #(
    // 声部数。硬件只有 16 个按键（fmap 是 mat4x4），所以 SLOTS 只能 <= 16，
    // 且只用 fmap 的前 SLOTS 个键；地址是 {slot, mode} 纯拼接，所以必须 2 的幂；
    // 还要拆两个 bank（HS = SLOTS/2 >= 2），所以实际可用 4 / 8 / 16。
    parameter int   SLOTS      = 16,
    parameter int   N_MODES    = 64,          // 唯一的模态数：系数表/状态/激励/参数表都按它开
    parameter int   CLK_HZ     = 100_000_000,
    parameter int   SR_HZ      = 48_000,
    parameter logic [7:0] PAD_NOTE_ON_TH=8'd102, PAD_NOTE_OFF_TH=8'd13,
    parameter logic DEBUG_PORT = 1'b1,
    parameter bit EXTERNAL_SAMPLE_TICK = 1'b0,
    parameter bit MIDI_ENABLE = 1'b0,
    parameter bit LOAD_OFFSETS = 1'b0,
    parameter int FLASH_NOTES = SLOTS,
    parameter logic [31:0] FLASH_BASE=32'h0000_0000,
    parameter int FLASH_BYTES=8_388_608
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    // ---- 上游 ----
    input  pad_driver_pkg::mat4x4                    fmap,
    input  router_pkg::instrument_e                   inst,
    input  router_pkg::reverb_preset                  reverb_preset,  // 混响预设（NONE/HALL/BATHROOM）
    input  logic                                     reload,      // 强制重灌当前乐器（内部取上升沿）
    input  logic                                     start,
    output wire [SLOTS-1:0] pad_keys_down, // actual pressure hysteresis used by the PAD path
    input logic [SLOTS*7-1:0] slot_note_map = router_pkg::default_note_map(), // resource identity; latched with each load
    input  logic                                     sample_tick, // clk domain; I2S frame master when enabled
    // 每个乐器用多少模态在内部按 inst 查 router_pkg::n_modes_of()，不再是端口
    // ---- 作业流控 ----
    output logic                                      done,        // **电平**：1 = 空闲、可以 start；0 = 正在工作
    // ---- 配置流控 ----
    output logic                                      ready,       // 1 = 现在会执行挂起的 inst/reload 变更
                                                                    //   （没有挂起变更时恒 1；有变更且还有键按着时为 0）
    // ---- 状态给上层（UI 用；router 自己不处理）----
    output logic                                      load_err,    // 1 = 本乐器的表是坏的（RAM 已被填 0）

    // ---- 输出（每采样一个）----
    output logic                                      y_valid,
    output logic signed [63:0]                        y_data,

    // ---- QSPI flash ----
    output logic                                      qspi_cs_n,
    output logic                                      qspi_sck,
    output logic [3:0]                                qspi_dq_o,
    output logic                                      qspi_dq_oe,
    input  logic [3:0]                                qspi_dq_i,

    // MIDI 状态快照；MIDI_ENABLE=0 时忽略，旧压力垫实例无需接这些口。
    input  logic midi_select, midi_valid,
    output logic midi_ready, // 该操作帧真正退休
    input  logic [SLOTS-1:0] midi_gate, midi_retrigger, midi_hard_clear,
    input  logic [SLOTS*7-1:0] midi_velocity,
    input logic pitch_control_valid=1'b0,pitch_control_cancel=1'b0,pitch_control_source=1'b0,
    input logic [31:0] pitch_control_data='0,
    input logic [SLOTS-1:0] pitch_slot_source='0,
    input logic [1:0] pitch_cleanup='0,
    output logic pitch_control_ready,pitch_control_rejected,

    // 维护和资源事务都留在router内；默认参数下旧PAD实例忽略这些输入。
    input logic maintenance_clear, map_reload,
    input logic [SLOTS*32-1:0] load_offsets,
    output logic maintenance_done, midi_inflight, load_complete,
    output logic table_valid,
    output logic [SLOTS-1:0] voice_idle,

    // ---- 调试 ----
    input  logic                                      ns_rd_en,
    input  logic [$clog2(SLOTS)+$clog2(N_MODES)-1:0] ns_rd_addr,
    input  logic                                      ns_rd_sel,
    output logic signed [31:0]                        ns_rd_data,
    output logic                                      ns_rd_valid
);

    import modal_step_pkg::*;
    import router_pkg::*;
    // Local reset leaves: async assertion, two-clock release. Preserve each
    // leaf so synthesis cannot merge the DSP banks back onto one huge reset net.
    (* ASYNC_REG="TRUE", syn_preserve=1 *) logic [6:0][1:0] child_reset;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) child_reset<='0;
        else for(integer i=0;i<7;i++) child_reset[i]<={child_reset[i][0],1'b1};
    end
    logic input_hold,load_now;
    logic [SLOTS-1:0] note_on,perf_clear,dead_ev;
    instrument_e inst_prev;
    logic [SLOTS-1:0] dead_pend, dead_f;
    typedef enum logic [3:0] { S_DONE, S_LOAD, S_RUN_X, S_XS, S_RUN_V,
                               S_ENVMUL, S_ENVACC, S_ADV, S_WAIT, S_CFG } st_e;
    st_e                 state;

    // fmap 先寄存一拍再分发给三个部件：它扇出很大（激励/包络/note_on 比较），
    // 直接从端口进组合逻辑会把路径拉长；加载系数期间冻结（忽略外部输入）
    pad_driver_pkg::mat4x4 fmap_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)           fmap_q <= '0;
        else if (!input_hold) fmap_q <= fmap;
    end

    localparam int IW     = $clog2(N_MODES);
    localparam int VWID   = $clog2(SLOTS);
    // 每声部的模态槽数**补齐到 2 的幂**：地址就退化成 {slot, mode} 的纯拼接（移位），
    // 地址路径上不放乘法器。N_MODES=64 时 NMP 就是 64，和原来完全一样；
    // N_MODES=48 时补齐成 64（RAM 多 33%，但地址不再错位）。
    localparam int NMP    = 1 << IW;
    localparam int CO_SLOT = VWID + IW;
    // 引擎读的阵列拆成两个 bank（每个引擎一个）：两个引擎同拍读不同地址时，
    // 一块 BSRAM 只有两个端口（1R1W），2R1W 是三个口 —— 不拆就只能退化成寄存器阵列。
    // 每 bank HS 个声部 x NMP 个模态 = 512 字，正好一块 512x36 的 BSRAM（块数不变）。
    localparam int HS      = SLOTS / 2;            // 每个 bank 的声部数
    localparam int HVW     = $clog2(HS);           // bank 内声部号位宽
    localparam int BA      = HVW + IW;             // bank 内地址 = {bank内声部, 模态}

    // =========================================================================
    // 存储（与 modal_voice_top 相同的布局；两个引擎互斥，所以只有一套）
    // =========================================================================
    // 引擎读的 9 个阵列按声部拆成 A（声部 0..HS-1）/ B（HS..SLOTS-1）两个 bank
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] pitch_a12_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram_a  [0:HS*NMP-1];

    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] pitch_a12_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram_b  [0:HS*NMP-1];

    // 调制参数表（引擎不读；加载器写，调制器读）：8 个字 = 4 基值 + 4 斜率
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_a11[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_a12[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_a22[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_wo [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_s11[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_s12[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_s22[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_swo[0:SLOTS*NMP-1];

    // 激励快照：一次作业只有一个采样，所以就是 SLOTS 个寄存器（不再有按采样索引的 RAM）
    logic signed [XW-1:0] x_q [0:SLOTS-1];

    // 早期声明（parts 的选择逻辑要用）
    router_pkg::instrument_e inst_lat;

    logic [IW:0]             nm_lat;

    // =========================================================================
    // 统一采样节拍：所有 part 共用，避免各自分频漂移
    // =========================================================================
    logic smp_tick;
    generate if (EXTERNAL_SAMPLE_TICK) begin : g_frame_master
        assign smp_tick = sample_tick;
    end else begin : g_legacy_tick
        logic [$clog2(CLK_HZ/SR_HZ+1)-1:0] tick_cnt;
        always_ff @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin tick_cnt<='0; smp_tick<=0; end
            else begin
                smp_tick<=0;
                if (tick_cnt+1 >= CLK_HZ/SR_HZ) begin tick_cnt<='0; smp_tick<=1; end
                else tick_cnt<=tick_cnt+1'b1;
            end
        end
    end endgenerate

    sustain_cfg_t pending_play[0:SLOTS-1],active_play[0:SLOTS-1];
    logic [SLOTS*7-1:0] pending_notes;
    logic [SLOTS*32-1:0] pending_offsets;
    logic [VWID-1:0] cfg_slot;
    logic [1:0] cfg_phase;
    logic [6:0] cfg_note;
    sustain_cfg_t cfg_lookup;
    logic cfg_error,cfg_fail_pulse;
    logic [SLOTS*16-1:0] play_period;
    logic [SLOTS*32-1:0] play_attack,play_release;
    for(genvar pc=0;pc<SLOTS;pc++)begin:g_play_bus
        assign play_period[pc*16 +:16]=active_play[pc].period;
        assign play_attack[pc*32 +:32]=active_play[pc].a_step;
        assign play_release[pc*32 +:32]=active_play[pc].r_step;
    end
    logic play_clear;
    assign play_clear=!table_valid || state==S_CFG || state==S_LOAD || load_now;
    logic [SLOTS-1:0] part_clear,part_gate,part_trigger;
    logic [SLOTS*8-1:0] part_strike,part_envelope;
    logic part_tick,part_midi,part_commit;
    logic [SLOTS*24-1:0] pitch_delta,part_pitch_delta;
    logic pitch_sources_ready;
    logic [SLOTS-1:0] committed_gate;
    logic signed [SLOTS-1:0][31:0] emap_frame;
    logic [SLOTS-1:0] idle_confirmed,zero_mask_f,gate_f,dead_frame;

    // =========================================================================
    // 三个部件子路由（各自按乐器号选实例，主 router 只连总线）
    // =========================================================================
    logic signed [SLOTS-1:0][31:0] xmap;   // 打包：xmap[i] 是第 i 个声部的激励
    logic                     xmap_valid;
    logic signed [SLOTS-1:0][31:0] emap;   // 打包：emap[i] 是第 i 个声部的包络
    logic                     emap_valid;
    logic [SLOTS-1:0]         env_dead;  // 包络说

    // ---- 压力垫门控：fmap 双阈值；MIDI 绕过此判定，由 u_input 选源 ----
    //   note_on 就是**滞回判定后的门控电平**：这个键现在按着就是 1。
    //     * 只看当前 fmap + 上一次的门控状态（gate_r 做滞回），不取沿、不粘住；
    //     * 按下要 > NOTE_ON_TH，松开要掉到 < NOTE_OFF_TH 才算松；
    //     * 谁要"起音事件"谁自己取沿：激励/包络内部各有一个 prev 寄存器，
    //       router 自己需要的那份在下面取成 note_ev。
    //   note_gate 与 note_on 是同一个电平（保留旧端口名，部件那边还在用）。
    //   加载系数期间 fmap_q 冻结，这个电平也就跟着冻住——等于忽略外部输入，
    //   装完之后按当前键态重新判：装的过程中按下的键照样能起音。
    localparam logic [7:0] NOTE_ON_TH  = PAD_NOTE_ON_TH;
    localparam logic [7:0] NOTE_OFF_TH = PAD_NOTE_OFF_TH;

    logic [SLOTS-1:0] gate_r, pad_note_on, note_gate;
    logic active_midi, performance_commit, frame_start, frame_retire;
    wire maintain_req = MIDI_ENABLE && maintenance_clear;
    logic maintenance_completed;
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) maintenance_completed<=1'b0;
        else if(!maintain_req) maintenance_completed<=1'b0;
        else if(maintenance_done) maintenance_completed<=1'b1;
    end
    logic [SLOTS-1:0] perf_trigger, clear_f;
    logic [SLOTS*8-1:0] strike_level, envelope_level;
    logic [SLOTS-1:0] note_on_q, note_ev;      // router 内部的起音沿
    logic [SLOTS-1:0] note_pend, note_f;       // 攒到帧头的那份（给引擎/调制器）

    // 滞回判定直接决定 note_on。判完打一拍再出去：fmap_q 是 128 位、扇出很大，
    // "16 个比较 -> note_on -> note_ev" 挤在一拍 PnR 实测 11.6 ns；下游（激励/
    // 包络/腔体）本来就只在 smp_tick 看它，晚一拍完全无所谓。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pad_note_on <= '0;
        end else begin
            for (int i = 0; i < SLOTS; i++)
                pad_note_on[i] <= gate_r[i] ? (fmap_q.flat_d[i].val >= NOTE_OFF_TH)
                                        : (fmap_q.flat_d[i].val >  NOTE_ON_TH);
        end
    end

    assign note_gate = note_on;
    assign pad_keys_down = pad_note_on;
    performance_input_mux #(.SLOTS(SLOTS), .MIDI_ENABLE(MIDI_ENABLE)) u_input (
        .clk(clk), .rst_n(rst_n), .sample_commit(performance_commit), .frame_retire(frame_retire),
        .maintenance_clear(maintain_req), .maintenance_done(maintenance_done), .midi_inflight(midi_inflight),
        .pad_gate(pad_note_on), .pad_level(fmap_q.raw[SLOTS*8-1:0]),
        .midi_select(midi_select), .midi_valid(midi_valid && (pitch_sources_ready || !(|midi_retrigger))), .midi_ready(midi_ready),
        .midi_gate(midi_gate), .midi_velocity(midi_velocity),
        .midi_retrigger(midi_retrigger), .midi_hard_clear(midi_hard_clear),
        .active_midi(active_midi), .gate(note_on), .trigger(perf_trigger),
        .hard_clear(perf_clear), .strike_level(strike_level), .envelope_level(envelope_level)
    );
    // 强制清除走现有 st_zero，全部模态写回后才确认完成。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) clear_f <= '0;
        else if (performance_commit) clear_f <= perf_clear;
    end

    // 滞回用的上一次门控状态
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        gate_r <= '0;
        else if (smp_tick) gate_r <= pad_note_on;
    end

    // One coherent performance snapshot before the high-fanout DSP controls.
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            part_clear<='0;part_gate<='0;part_trigger<='0;
            part_strike<='0;part_envelope<='0;part_tick<=0;part_midi<=0;part_commit<=0;committed_gate<='0;part_pitch_delta<='0;
        end else begin
            part_tick<=smp_tick;part_commit<=performance_commit;
            if(performance_commit)committed_gate<=note_on;
            if(smp_tick) begin
                part_clear<=perf_clear | {SLOTS{play_clear}};
                part_gate<=play_clear ? '0 : note_on;
                part_trigger<=perf_trigger;part_strike<=strike_level;
                part_envelope<=envelope_level;part_midi<=active_midi;
                part_pitch_delta<=pitch_delta;
            end
        end
    end

    exc_router #(.SLOTS(SLOTS), .CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_exc (
        .clk(clk), .rst_n(child_reset[0][1]), .smp_tick(part_tick),
        .slot_period(play_period),.slot_pitch_delta(part_pitch_delta),
        .strike_level(part_strike), .retrigger(part_trigger), .slot_clear(part_clear),
        .note_on(part_gate), .inst(inst_lat),
        .xmap(xmap), .xmap_valid(xmap_valid)
    );

    env_router #(.SLOTS(SLOTS), .CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_env (
        .clk(clk), .rst_n(child_reset[1][1]), .smp_tick(part_tick),
        .slot_a_step(play_attack),.slot_r_step(play_release),
        .envelope_level(part_envelope), .retrigger(part_trigger),
        .slot_clear(part_clear), .midi_mode(part_midi),
        .note_on(part_gate), .note_gate(part_gate), .inst(inst_lat),
        .emap(emap), .emap_valid(emap_valid), .dead(env_dead)
    );

    logic                    mod_busy, mod_done, mod_start, mod_p_re;
    logic [VWID-1:0]         mod_slot;
    // 后台调制请求位图：起音的声部在这里置位，调制器空闲时按最低位服务，做完清那一位。
    //   这样谁请求都不会丢（幂等的调制器重复跑也无害），而且**不挡引擎**。
    logic [SLOTS-1:0]        mod_req;
    logic [7:0]              fmap_prev [0:SLOTS-1];   // 上次调制用的力度（变了才重新调制）

    function automatic logic [VWID-1:0] first_req(input logic [SLOTS-1:0] r);
        first_req = '0;
        for (int i = SLOTS-1; i >= 0; i--) if (r[i]) first_req = VWID'(i);
    endfunction
    logic [IW-1:0]           mod_p_mode, mod_co_mode;
    logic [4:0]              mod_co_we;
    coeff_t                  mod_co_wdata;
    // 参数表读出（两级寄存器：BSRAM 的 CLK->Q 不进乘法）
    logic signed [31:0]      mod_a11_r, mod_a12_r, mod_a22_r, mod_wo_r;
    logic signed [31:0]      mod_s11_r, mod_s12_r, mod_s22_r, mod_swo_r;

    mod_router #(.SLOTS(SLOTS), .N_MODES(N_MODES), .FS(SR_HZ),
                 .PAD_NOTE_ON_TH(PAD_NOTE_ON_TH)) u_modr (
        .clk(clk), .rst_n(child_reset[2][1]), .start(mod_start),
        .fmap_i(fmap_q.flat_d[mod_slot].val), .n_modes(16'(nm_lat)),
        .inst(inst_lat), .busy(mod_busy), .done(mod_done),
        .p_re(mod_p_re), .p_mode(mod_p_mode),
        .p_a11(mod_a11_r), .p_a12(mod_a12_r), .p_a22(mod_a22_r), .p_wo(mod_wo_r),
        .p_s11(mod_s11_r), .p_s12(mod_s12_r), .p_s22(mod_s22_r), .p_swo(mod_swo_r),
        .co_we(mod_co_we), .co_mode(mod_co_mode), .co_wdata(mod_co_wdata)
    );

    logic pitch_bank,pitch_busy,pitch_commit,pitch_p_re,pitch_co_we;
    logic [CO_SLOT-1:0] pitch_p_addr,pitch_co_addr;
    logic signed [31:0] pitch_a1;
    wire [CO_SLOT-1:0] pm_read_addr;
    wire pitch_commit_ok;
    eng1_pitch #(.SLOTS(SLOTS),.N_MODES(N_MODES)) u_pitch(
        .clk(clk),.rst_n(child_reset[2][1]),.clear(play_clear || !router_pkg::is_sustain(inst_lat)),
        .sample_tick(smp_tick),.commit_ok(pitch_commit_ok),.cleanup(pitch_cleanup),.n_modes(nm_lat),
        .slot_source(pitch_slot_source),.control_valid(pitch_control_valid),.control_cancel(pitch_control_cancel),
        .control_source(pitch_control_source),.control_data(pitch_control_data),
        .control_ready(pitch_control_ready),.control_rejected(pitch_control_rejected),
        .active_bank(pitch_bank),.busy(pitch_busy),.commit_pulse(pitch_commit),.active_delta(pitch_delta),
        .sources_ready(pitch_sources_ready),
        .p_re(pitch_p_re),.p_addr(pitch_p_addr),.p_lower(mod_a11_r),.p_base(mod_a12_r),
        .p_upper(mod_a22_r),.p_slope(mod_s12_r),.p_tag(mod_swo_r),
        .co_we(pitch_co_we),.co_addr(pitch_co_addr),.co_a1(pitch_a1));

    // =========================================================================
    // 系数加载
    // =========================================================================
    logic                           ld_start, ld_busy, ld_done, ld_err;
    logic                           ld_we;
    logic [CO_SLOT:0]               ld_addr;          // 最高位选表：0=系数 1=调制参数（低位 {slot, mode}）
    coeff_t                         ld_co_data;
    router_pkg::mod_par_t           ld_pm_data;
    logic                           ld_co_we, ld_pm_we;
    logic [CO_SLOT-1:0]             ld_idx;

    // 一个写使能 + 地址高位选表
    logic                           ld_sel_pm;
    assign ld_sel_pm = ld_addr[CO_SLOT];
    assign ld_idx    = ld_addr[CO_SLOT-1:0];
    assign ld_co_we  = ld_we & ~ld_sel_pm;
    assign ld_pm_we  = ld_we &  ld_sel_pm;

    weight_loader #(.SLOTS(SLOTS), .N_MODES(N_MODES), .CLK_HZ(CLK_HZ),
                    .FLASH_NOTES(FLASH_NOTES), .FLASH_BASE(FLASH_BASE), .FLASH_BYTES(FLASH_BYTES), .USE_OFFSETS(LOAD_OFFSETS), .SUPPORT_ABORT(1)) u_ld (
        .clk(clk), .rst_n(rst_n), .inst(4'(inst_lat)),
        .slot_offsets(pending_offsets), .update_mask({SLOTS{1'b1}}),
        .abort(maintain_req && !maintenance_completed), .error_code(),
        .start(ld_start), .busy(ld_busy), .done(ld_done), .err(ld_err),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_co(ld_co_data), .ld_pm(ld_pm_data),
        .qspi_cs_n(qspi_cs_n), .qspi_sck(qspi_sck),
        .qspi_dq_o(qspi_dq_o), .qspi_dq_oe(qspi_dq_oe), .qspi_dq_i(qspi_dq_i)
    );

    // =========================================================================
    // 两个引擎（各管 HS 个声部，并行跑）+ 各自的存储 bank
    //   * 两个实例的 inst 接同一个乐器号 -> 同一种引擎，时序完全一致
    //   * 每个实例只碰自己 bank 的读口；写口由 loader/调制器按声部号 demux
    // =========================================================================
    logic                    eng_start;                 // 两个引擎同时起
    logic [VWID-1:0]         g;                         // 本组第几个（bank 内声部号）
    logic                    pick_b;                    // 0 = 正在处理 A 声部, 1 = B 声部

    // ---- bank A ----
    logic                 era_co_re, era_st_re, era_st_we, era_x_re, era_yv;
    logic [IW-1:0]        era_co_addr, era_st_addr, era_st_waddr;
    logic signed [63:0]   era_y;
    logic signed [QW-1:0] era_qwd;
    logic signed [VW-1:0] era_vwd;

    // ---- bank B ----
    logic                 erb_co_re, erb_st_re, erb_st_we, erb_x_re, erb_yv;
    logic [IW-1:0]        erb_co_addr, erb_st_addr, erb_st_waddr;
    logic signed [63:0]   erb_y;
    logic signed [QW-1:0] erb_qwd;
    logic signed [VW-1:0] erb_vwd;

    logic signed [CW-1:0] co_a11_ra, co_a12_ra, co_a21_ra, co_a22_ra, co_gq_ra, co_gv_ra, co_wo_ra;
    logic signed [CW-1:0] co_a11_rb, co_a12_rb, co_a21_rb, co_a22_rb, co_gq_rb, co_gv_rb, co_wo_rb;
    coeff_t               co_ra, co_rb;
    logic signed [QW-1:0] st_q_ra, st_q_rb;
    logic signed [VW-1:0] st_v_ra, st_v_rb;
    logic signed [XW-1:0] x_ra, x_rb;

    // 清零：只看本组这两个声部有没有"刚起音/刚空了"
    logic [CO_SLOT-1:0]   pm_idx;      // 调制参数读地址 = {slot, mode}（不拆 bank）
    logic                 era_zero, erb_zero;
    // BSRAM没有复位值；整帧会遍历全部HS组。每次成功换表后的第一帧必须清
    // 全部工作状态，不能让新音色的常数包络暴露旧音色的release状态。
    logic [IW:0]          zero_frames;      // 还剩几帧要强制清零
    logic                 init_zero;
    assign init_zero = (zero_frames != '0);
    // clear_f 是 MIDI/维护的逐槽强制清零，和上面两条同属"这一帧必须写 0"。
    assign era_zero = note_f[g[VWID-1:0]]         | dead_f[g[VWID-1:0]]         | init_zero | clear_f[g[VWID-1:0]];
    assign erb_zero = note_f[VWID'(g + VWID'(HS))] | dead_f[VWID'(g + VWID'(HS))] | init_zero | clear_f[VWID'(g + VWID'(HS))];

    always_comb begin
        co_ra.a11 = co_a11_ra; co_ra.a12 = co_a12_ra; co_ra.a21 = co_a21_ra;
        co_ra.a22 = co_a22_ra; co_ra.gq  = co_gq_ra;  co_ra.gv  = co_gv_ra;
        co_ra.wo  = co_wo_ra;
        co_rb.a11 = co_a11_rb; co_rb.a12 = co_a12_rb; co_rb.a21 = co_a21_rb;
        co_rb.a22 = co_a22_rb; co_rb.gq  = co_gq_rb;  co_rb.gv  = co_gv_rb;
        co_rb.wo  = co_wo_rb;
    end

    eng_router #(.N_MODES(N_MODES)) u_era (
        .clk(clk), .rst_n(child_reset[5][1]), .inst(inst_lat),
        .start(eng_start), .st_zero(era_zero), .n_modes(nm_lat),
        .co_re(era_co_re), .co_addr(era_co_addr), .co_data(co_ra),
        .st_re(era_st_re), .st_addr(era_st_addr),
        .st_q(st_q_ra), .st_qdot(st_v_ra),
        .st_we(era_st_we), .st_waddr(era_st_waddr),
        .st_q_wdata(era_qwd), .st_qdot_wdata(era_vwd),
        .x_re(era_x_re), .x_data(x_ra),
        .y_valid(era_yv), .y_data(era_y)
    );

    eng_router #(.N_MODES(N_MODES)) u_erb (
        .clk(clk), .rst_n(child_reset[6][1]), .inst(inst_lat),
        .start(eng_start), .st_zero(erb_zero), .n_modes(nm_lat),
        .co_re(erb_co_re), .co_addr(erb_co_addr), .co_data(co_rb),
        .st_re(erb_st_re), .st_addr(erb_st_addr),
        .st_q(st_q_rb), .st_qdot(st_v_rb),
        .st_we(erb_st_we), .st_waddr(erb_st_waddr),
        .st_q_wdata(erb_qwd), .st_qdot_wdata(erb_vwd),
        .x_re(erb_x_re), .x_data(x_rb),
        .y_valid(erb_yv), .y_data(erb_y)
    );
    // =========================================================================
    // 存储的读写：两个 bank 各一套读寄存器；写口按声部号 demux
    //   bank 内地址 = {bank 内声部号, 模态偏移}
    //   声部号最高位选 bank：0 -> A（声部 0..HS-1），1 -> B（HS..SLOTS-1）
    //   一次作业固定跑 HS 组，每组 A 的 g + B 的 g+HS（全部 SLOTS 个声部）
    // =========================================================================
    logic                 ld_bank_b, mod_bank_b;
    logic [BA-1:0]        ld_bank_addr, mod_bank_addr;
    logic [VWID:0]        ns_bank;

    assign ld_bank_b    = ld_idx[CO_SLOT-1];
    assign ld_bank_addr = ld_idx[BA-1:0];
    assign mod_bank_b   = mod_slot[VWID-1];
    assign mod_bank_addr= {mod_slot[HVW-1:0], mod_co_mode};
    assign pm_idx       = {mod_slot, mod_p_mode};      // 参数表不拆 bank：{slot, mode}

    // 激励快照：整张 xmap 一拍抄进 x_q（一次作业一个采样，不需要按采样索引）
    logic                     xw_run;

    logic [31:0]            ns_r;
    logic                   ns_vld;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            co_a11_ra <= '0; co_a12_ra <= '0; co_a21_ra <= '0; co_a22_ra <= '0;
            co_a11_rb <= '0; co_a12_rb <= '0; co_a21_rb <= '0; co_a22_rb <= '0;
            co_gq_ra  <= '0; co_gv_ra  <= '0; co_wo_ra  <= '0;
            co_gq_rb  <= '0; co_gv_rb  <= '0; co_wo_rb  <= '0;
            mod_a11_r <= '0; mod_a12_r <= '0; mod_a22_r <= '0; mod_wo_r  <= '0;
            mod_s11_r <= '0; mod_s12_r <= '0; mod_s22_r <= '0; mod_swo_r <= '0;
            st_q_ra  <= '0; st_v_ra  <= '0; st_q_rb <= '0; st_v_rb <= '0;
            x_ra     <= '0; x_rb     <= '0;
            ns_r     <= '0; ns_vld   <= 1'b0;
        end else begin
            // 引擎占用状态口时 debug 读根本没执行，valid 不能报
            ns_vld <= ns_rd_en & DEBUG_PORT & ~(era_st_re | erb_st_re);

            // ---- 系数写（loader 优先，其次后台调制）----
            if (ld_co_we) begin
                if (ld_bank_b) begin
                    ca_a11_b[ld_bank_addr] <= ld_co_data.a11;
                    ca_a12_b[ld_bank_addr] <= ld_co_data.a12;
                    pitch_a12_b[ld_bank_addr] <= ld_co_data.a12;
                    ca_a21_b[ld_bank_addr] <= ld_co_data.a21;
                    ca_a22_b[ld_bank_addr] <= ld_co_data.a22;
                    ca_gq_b [ld_bank_addr] <= ld_co_data.gq;
                    ca_gv_b [ld_bank_addr] <= ld_co_data.gv;
                    ca_wo_b [ld_bank_addr] <= ld_co_data.wo;
                end else begin
                    ca_a11_a[ld_bank_addr] <= ld_co_data.a11;
                    ca_a12_a[ld_bank_addr] <= ld_co_data.a12;
                    pitch_a12_a[ld_bank_addr] <= ld_co_data.a12;
                    ca_a21_a[ld_bank_addr] <= ld_co_data.a21;
                    ca_a22_a[ld_bank_addr] <= ld_co_data.a22;
                    ca_gq_a [ld_bank_addr] <= ld_co_data.gq;
                    ca_gv_a [ld_bank_addr] <= ld_co_data.gv;
                    ca_wo_a [ld_bank_addr] <= ld_co_data.wo;
                end
            // 加载期间调制器的写一律丢弃：loader 的优先级只保证“同一拍”；
            // 已经起跑的调制如果在 loader 写完之后才写同一个地址，会把新表改坏。
            // 新表本来就会覆盖全部系数，丢掉这几笔没有副作用。
            end else if(pitch_co_we && !play_clear && router_pkg::is_sustain(inst_lat))begin
                if(pitch_co_addr[CO_SLOT-1])begin
                    if(pitch_bank)ca_a12_b[pitch_co_addr[BA-1:0]]<=pitch_a1;
                    else pitch_a12_b[pitch_co_addr[BA-1:0]]<=pitch_a1;
                end else begin
                    if(pitch_bank)ca_a12_a[pitch_co_addr[BA-1:0]]<=pitch_a1;
                    else pitch_a12_a[pitch_co_addr[BA-1:0]]<=pitch_a1;
                end
            end else if ((|mod_co_we) && !ld_busy && !ld_start) begin
                if (mod_bank_b) begin
                    if (mod_co_we[0]) ca_a11_b[mod_bank_addr] <= mod_co_wdata.a11;
                    if (mod_co_we[1]) ca_a12_b[mod_bank_addr] <= mod_co_wdata.a12;
                    if (mod_co_we[2]) ca_a21_b[mod_bank_addr] <= mod_co_wdata.a21;
                    if (mod_co_we[3]) ca_a22_b[mod_bank_addr] <= mod_co_wdata.a22;
                    if (mod_co_we[4]) ca_wo_b [mod_bank_addr] <= mod_co_wdata.wo;   // 现在 wo 也调制
                end else begin
                    if (mod_co_we[0]) ca_a11_a[mod_bank_addr] <= mod_co_wdata.a11;
                    if (mod_co_we[1]) ca_a12_a[mod_bank_addr] <= mod_co_wdata.a12;
                    if (mod_co_we[2]) ca_a21_a[mod_bank_addr] <= mod_co_wdata.a21;
                    if (mod_co_we[3]) ca_a22_a[mod_bank_addr] <= mod_co_wdata.a22;
                    if (mod_co_we[4]) ca_wo_a [mod_bank_addr] <= mod_co_wdata.wo;
                end
            end

            // ---- 调制参数表：loader 写，调制器读（不拆 bank）----
            if (ld_pm_we) begin
                pm_a11[ld_idx] <= ld_pm_data.a11;
                pm_a12[ld_idx] <= ld_pm_data.a12;
                pm_a22[ld_idx] <= ld_pm_data.a22;
                pm_wo [ld_idx] <= ld_pm_data.wo;
                pm_s11[ld_idx] <= ld_pm_data.s11;
                pm_s12[ld_idx] <= ld_pm_data.s12;
                pm_s22[ld_idx] <= ld_pm_data.s22;
                pm_swo[ld_idx] <= ld_pm_data.swo;
            end
            if (mod_p_re || pitch_p_re) begin
                mod_a11_r <= pm_a11[pm_read_addr];
                mod_a12_r <= pm_a12[pm_read_addr];
                mod_a22_r <= pm_a22[pm_read_addr];
                mod_wo_r  <= pm_wo [pm_read_addr];
                mod_s11_r <= pm_s11[pm_read_addr];
                mod_s12_r <= pm_s12[pm_read_addr];
                mod_s22_r <= pm_s22[pm_read_addr];
                mod_swo_r <= pm_swo[pm_read_addr];
            end

            // ---- 系数读：A/B 两个 bank 各一个同步读口 ----
            if (era_co_re) begin
                co_a11_ra <= ca_a11_a[{g[HVW-1:0], era_co_addr}];
                co_a12_ra <= pitch_bank ? pitch_a12_a[{g[HVW-1:0], era_co_addr}] : ca_a12_a[{g[HVW-1:0], era_co_addr}];
                co_a21_ra <= ca_a21_a[{g[HVW-1:0], era_co_addr}];
                co_a22_ra <= ca_a22_a[{g[HVW-1:0], era_co_addr}];
                co_gq_ra  <= ca_gq_a [{g[HVW-1:0], era_co_addr}];
                co_gv_ra  <= ca_gv_a [{g[HVW-1:0], era_co_addr}];
                co_wo_ra  <= ca_wo_a [{g[HVW-1:0], era_co_addr}];
            end
            if (erb_co_re) begin
                co_a11_rb <= ca_a11_b[{g[HVW-1:0], erb_co_addr}];
                co_a12_rb <= pitch_bank ? pitch_a12_b[{g[HVW-1:0], erb_co_addr}] : ca_a12_b[{g[HVW-1:0], erb_co_addr}];
                co_a21_rb <= ca_a21_b[{g[HVW-1:0], erb_co_addr}];
                co_a22_rb <= ca_a22_b[{g[HVW-1:0], erb_co_addr}];
                co_gq_rb  <= ca_gq_b [{g[HVW-1:0], erb_co_addr}];
                co_gv_rb  <= ca_gv_b [{g[HVW-1:0], erb_co_addr}];
                co_wo_rb  <= ca_wo_b [{g[HVW-1:0], erb_co_addr}];
            end

            // ---- 激励（是寄存器，不是 RAM）----
            if (xw_run) begin
                for (int i = 0; i < SLOTS; i++) x_q[i] <= xmap[i];
            end
            if (era_x_re) x_ra <= x_q[g[VWID-1:0]];
            if (erb_x_re) x_rb <= x_q[VWID'(g[VWID-1:0] + VWID'(HS))];

            // ---- 状态读（引擎独占；debug 读串行插在空拍里）----
            if (era_st_re) begin
                st_q_ra <= q_ram_a[{g[HVW-1:0], era_st_addr}];
                st_v_ra <= v_ram_a[{g[HVW-1:0], era_st_addr}];
            end
            if (erb_st_re) begin
                st_q_rb <= q_ram_b[{g[HVW-1:0], erb_st_addr}];
                st_v_rb <= v_ram_b[{g[HVW-1:0], erb_st_addr}];
            end
            // debug 口：不再单独读 RAM —— 多一个读口会让 q/v 推断不出 BSRAM
            //   （实测 REG 5.5k -> 72k，PnR 卡在 placement 半小时以上）。
            //   改成吐出"最近一次引擎读到的状态字"，调试够用。
            if (ns_rd_en && DEBUG_PORT) ns_r <= ns_rd_sel ? 32'(st_v_ra) : 32'(st_q_ra);

            // ---- 状态写回 ----
            if (era_st_we) begin
                q_ram_a[{g[HVW-1:0], era_st_waddr}] <= era_qwd;
                v_ram_a[{g[HVW-1:0], era_st_waddr}] <= era_vwd;
            end
            if (erb_st_we) begin
                q_ram_b[{g[HVW-1:0], erb_st_waddr}] <= erb_qwd;
                v_ram_b[{g[HVW-1:0], erb_st_waddr}] <= erb_vwd;
            end
        end
    end

    assign ns_rd_data  = DEBUG_PORT ? 32'(ns_r) : 32'sd0;
    assign ns_rd_valid = ns_vld;
    // =========================================================================
    // 结果：逐声部过自己的包络 -> 全声部混音
    //   y_env = (eng_y * emap[voi]) >>> 31   包络 Q1.31
    //   y_acc = Σ_voi y_env                  帧内跨声部求和
    //   分三拍走（S_RUN_V 取操作数 / S_ENVMUL 乘 / S_ENVACC 累加）：
    //     原来 emap 的 16:1 读 + 96 位乘法 + 64 位累加挤在一拍里，实测 PnR
    //     25.6 ns（Fmax 50 MHz）。分开之后每拍只剩一级：
    //     mux 单独一拍、乘法器两个输入都是寄存器、累加也自己一拍。
    //   y_acc 是 64 位；SLOTS 个声部同时满量程理论上会回绕（实际信号远不到）。
    // =========================================================================
    logic signed [AW-1:0] y_acc;       // Σ y_env（帧内跨声部混音）
    logic signed [AW-1:0] y_lat;       // eng_y 打一拍：乘法器的输入必须是寄存器
    logic signed [AW-1:0] y_b_lat;     // B 结果只在 y_valid 保证有效，必须同步锁存
    logic signed [31:0] e_b_lat;
    logic signed [31:0]   e_lat;       // emap[voi] 打一拍：16:1 读单独占一拍
    logic signed [AW-1:0] y_env;       // 本声部过包络后的输出
    logic signed [95:0]   y_mul;

    // Local, one-cycle delayed group copy isolates the envelope mux from the
    // coefficient/state-address fanout of g. It settles long before y_valid.
    (* syn_preserve=1 *) logic [HVW-1:0] envelope_group;
    always_ff @(posedge clk or negedge rst_n)
        if(!rst_n)envelope_group<='0;else envelope_group<=g[HVW-1:0];
    assign y_mul = y_lat * e_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_lat <= '0;
            y_b_lat <= '0;
            e_b_lat <= '0;
            e_lat <= '0;
            y_env <= '0;
            y_acc <= '0;
        end else begin
            if (state == S_RUN_V && era_yv && erb_yv) begin
                // 有效拍同时锁存 A/B；eng1 的结果在 y_valid 后不保证保持。
                // A 先算，S_ADV 再把已锁存的 B 送入同一条乘法流水。
                y_lat <= era_y;
                y_b_lat <= erb_y;
                e_b_lat <= $signed(emap_frame[VWID'($unsigned(envelope_group))+VWID'(HS)]);
                e_lat <= $signed(emap_frame[VWID'($unsigned(envelope_group))]);
            end
            // 乘法结果先落一拍，下一拍才做 64 位累加（原来是 mul + add 同一拍）
            if (state == S_ENVMUL) y_env <= y_mul[94:31];   // (eng_y*E) >>> 31
            if (state == S_ENVACC)
                y_acc <= (g == '0 && !pick_b) ? y_env : (y_acc + y_env);
            if (state == S_ADV && !pick_b) begin
                y_lat <= y_b_lat;
                e_lat <= e_b_lat;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin emap_frame<='0;dead_frame<='1;end
        else if(xw_run)begin emap_frame<=emap;dead_frame<=env_dead;end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin idle_confirmed<='0;zero_mask_f<='0;gate_f<='0;end
        else begin
            if(play_clear) idle_confirmed<='0;
            else begin
                if(frame_retire)
                    idle_confirmed<=(idle_confirmed | (zero_mask_f & dead_frame & ~gate_f)) & ~committed_gate;
                else idle_confirmed<=idle_confirmed & ~committed_gate & ~part_trigger;
            end
            if(frame_start)begin
                zero_mask_f<=dead_pend | dead_ev | clear_f | {SLOTS{init_zero}};
                gate_f<=committed_gate;
            end
        end
    end

    // =========================================================================
    // 后级：全声部混音 -> 腔体 -> 混响 -> y_data
    //   mix_v / mix_q : 一笔待接走的混音；腔体 93 拍/样本，忙时 in_ready=0
    //   mix_outstd    : 已经交出去、还没从腔体出来的样本数
    //   rev_outstd    : 已经进混响、还没出来的样本数（混响是固定 6 拍流水）
    //   两者都排空才能报 done，否则最后一帧的 y_data 会丢
    // =========================================================================
    logic                 mix_v;
    logic signed [AW-1:0] mix_q;
    logic                 body_in_ready, body_accept, body_out_valid;
    logic signed [63:0]   body_y;
    logic                 rev_out_valid;
    logic signed [63:0]   rev_y;
    logic [3:0]           mix_outstd, rev_outstd;
    logic frame_drained;
    assign frame_drained = (state == S_WAIT) && (mix_outstd == '0) &&
                          !mix_v && (rev_outstd == '0);

    assign body_accept = mix_v && body_in_ready;
    assign y_valid     = rev_out_valid && table_valid;
    assign y_data      = table_valid ? rev_y : 64'sd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_outstd <= '0;
            rev_outstd <= '0;
        end else begin
            case ({body_accept, body_out_valid})
                2'b10:   mix_outstd <= mix_outstd + 1'b1;
                2'b01:   mix_outstd <= mix_outstd - 1'b1;
                default: ;
            endcase
            case ({body_out_valid, rev_out_valid})
                2'b10:   rev_outstd <= rev_outstd + 1'b1;
                2'b01:   rev_outstd <= rev_outstd - 1'b1;
                default: ;
            endcase
        end
    end

    // =========================================================================
    // 作业调度：IDLE -> (LOAD) -> 每采样 [RUN_X 等 xmap -> XWR 写 SLOTS 路 -> RUN_V 跑声部] -> DONE
    // =========================================================================
    // S_ENVMUL / S_ENVACC：包络乘法流水（取操作数 -> 乘 -> 累加），见上面结果段

    // ---- 对外语义 ----
    //   done  : 电平，1 = 空闲可以 start（= 在 S_DONE 等着）
    //   ready : 电平，1 = 现在会执行挂起的 inst/reload 变更（没有挂起变更时恒 1）
    //   load_err: loader 的 err 电平，转发给上层（UI 展示），router 自己不处理
    logic                reload_q, reload_pend;
    logic                change_pend;
    assign change_pend = (inst != inst_prev) || reload_pend;
    assign done        = (state == S_DONE);
    // Only stable, committed gates decide reload eligibility. The instant MIDI
    // apply mux must not feed a combinational path back into the frame FSM.
    assign ready       = !change_pend || !table_valid ||
                         ((active_midi ? committed_gate : pad_note_on) == '0);
    assign load_err    = ld_err || cfg_error;
    assign load_complete = ((state == S_LOAD) && ld_done) || cfg_fail_pulse;
    // Published only from retirement-qualified state. Do not feed combinational
    // maintenance/gate/envelope paths back into the MIDI allocator.
    assign voice_idle = idle_confirmed;
    instrument_e run_inst;
    assign run_inst = (change_pend && !ready) ? inst_lat : inst;

    // 这一拍会不会在 S_DONE 里真正启动加载（和 case 里的判定同一条件）。
    //   必须用组合判据：always_ff 里调制器的门在 case 之前执行，非阻塞赋值下
    //   它看不到同一拍稍后才置起的 ld_start / S_LOAD，只加 !ld_start 挡不住。

    assign load_now = (state == S_DONE) && start && change_pend && ready;

    // synthesis translate_off
    // 硬件只有 16 个按键（fmap 是 mat4x4）：SLOTS 不能超过 16；同时它必须是
    // 2 的幂（地址是 {slot, mode} 拼接），且 >= 4（要拆两个 bank，HS = SLOTS/2）。
    initial if (SLOTS > 16 || SLOTS < 4 || (SLOTS & (SLOTS - 1)) != 0)
        $error("voice_router: SLOTS must be 4/8/16 (2^n, <= 16 keys)");
    // synthesis translate_on

    logic                wait_xmap;

    // ------------------------------------------------------------------
    // 外部输入采样：加载系数期间一律忽略（fmap_q 冻结，见文件开头）
    //   第一次装载（inst_prev 还是 NONE）也算加载中——否则上电时按下的键
    //   会被 gate_r 记成"已经按下"，装完之后就不再算新起音
    // ------------------------------------------------------------------
    assign input_hold = (state == S_LOAD) || (inst_prev == INST_NONE);

    // router 自己要的那份"起音事件"：note_on 是电平，这里取一拍沿
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) note_on_q <= '0;
        else        note_on_q <= note_on;
    end
    assign note_ev = (note_on & ~note_on_q) | perf_trigger;

    // 引擎是逐声部串行跑的，等它跑到某个声部时沿早没了：事件先攒进 note_pend，
    // 到**作业头**（S_RUN_X 那一拍）一次性交给 note_f，note_f 只在这一次作业里有效：
    // 不跨帧粘住，也不会跨加载残留。

    assign pm_read_addr=pitch_p_re ? pitch_p_addr : pm_idx;
    assign pitch_commit_ok=(state==S_DONE || (state==S_RUN_X && wait_xmap)) &&
                           !smp_tick && !part_tick && table_valid && !load_now;
    assign performance_commit = (state == S_RUN_X) && wait_xmap && smp_tick;
    assign frame_start = (state == S_RUN_X) && wait_xmap && xmap_valid && part_commit;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_f    <= '0;
            note_pend <= '0;
        end else if (frame_start) begin
            note_f    <= note_pend | note_ev;
            note_pend <= '0;
        end else if (|note_ev) begin
            note_pend <= note_pend | note_ev;
        end
    end

    // st_zero：note-on 首帧 或 该声部**刚刚**变成
    //
    //   注意这里是"归零的那一帧"清一次，不是"归零期间每帧都清"：
    //   eng0 的清零 pass 要 n_modes 拍，全静音时 SLOTS 个声部每帧都清 = SLOTS×80 拍，
    //   实测一个采样 2754 拍（48 kHz 要 132 MHz）。只在包络掉到 0 的那一帧清，
    //   状态被清成正好 0，之后激励也是 0，状态就一直保持 0 了。

    // 比较结果打一拍：原来 emap -> 比较 -> eng_zero 是一条长组合链
    // （包络每采样才更新一次，晚一拍对 st_zero 没有影响）
    logic [SLOTS-1:0] voice_dead, voice_dead_q;

    // "这个声部空了"由包络自己给（ADSR：release 走完才给；dyn0：没按住就给），
    // 顶层不再拿 emap==0 去猜——起音头几个采样 emap 也是 0，猜错就会把刚打进去的
    // 激励清掉（retrigger 的听感是"没声音"）。这里只打一拍当同步。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_dead   <= '0;
            voice_dead_q <= '0;
        end else begin
            voice_dead   <= env_dead;
            voice_dead_q <= voice_dead;
        end
    end

    assign dead_ev = voice_dead & ~voice_dead_q;

    // 帧头把 note 事件和"刚归零"事件一起交给本帧
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dead_f    <= '0;
            dead_pend <= '0;
        end else if (frame_start) begin
            dead_f    <= dead_pend | dead_ev;
            dead_pend <= '0;
        end else if (|dead_ev) begin
            dead_pend <= dead_pend | dead_ev;
        end
    end

    // Local index control: configuration/error comparisons must not drive g.CE.
    // g is already zero on entry to DONE/LOAD (reset or final S_ADV retirement).
    // Keep it zero there, and initialize again before starting each engine job.
    // Only the second-bank S_ADV completion advances to the next voice pair.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) g <= '0;
        else if (state == S_DONE || state == S_LOAD || state == S_XS) g <= '0;
        else if (state == S_ADV && pick_b) begin
            if (g + 1'b1 < VWID'(HS)) g <= g + 1'b1;
            else if (!mix_v) g <= '0;
        end
    end

    // 清零信号在引擎实例那边按 bank 各自给（era_zero / erb_zero），这里不用了

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_slot<='0;cfg_phase<=0;cfg_note<=0;cfg_lookup<='0;
            pending_notes<='0;pending_offsets<='0;cfg_error<=0;cfg_fail_pulse<=0;
            for(int p=0;p<SLOTS;p++)begin pending_play[p]<='0;active_play[p]<='0;end
            state      <= S_DONE;        // 上电就是"空闲、可以 start"
            mix_v      <= 1'b0;
            mix_q      <= '0;

            pick_b     <= 1'b0;
            nm_lat     <= '0;
            table_valid<= 1'b0;
            zero_frames<= (IW+1)'(HS + 2);   // 启动保护，成功加载后改为一帧全槽清理
            inst_lat   <= INST_NONE;
            inst_prev  <= INST_NONE;
            eng_start  <= 1'b0;
            ld_start   <= 1'b0;
            xw_run     <= 1'b0;
            wait_xmap  <= 1'b0;
            mod_req    <= '0;
            for (int i = 0; i < SLOTS; i++) fmap_prev[i] <= '0;
            mod_start  <= 1'b0;
            mod_slot   <= '0;
            reload_q   <= 1'b0;
            reload_pend<= 1'b0;
        end else begin
            if (body_accept) mix_v <= 1'b0;      // 这一笔混音已经被腔体接走
            cfg_fail_pulse<=0;
            eng_start <= 1'b0;
            ld_start  <= 1'b0;
            mod_start <= 1'b0;

            // reload 在内部取上升沿（外部一直拉高也只认一次）
            reload_q    <= reload;
            if ((reload && !reload_q) || (MIDI_ENABLE && map_reload)) reload_pend <= 1'b1;

            // ---- 后台调制：有请求 + 调制器空闲 + 没在加载 -> 发一拍 start ----
            //   一次只发一个（busy 期间不发，发了也会被它忽略），做完清那一位。
            //   load_now 挡“这一拍就要开始加载”：非阻塞下 ld_start/S_LOAD 下一拍才可见，
            //   只靠 !ld_start / state!=S_LOAD 会漏掉 S_DONE 同拍首次加载。
            if (mod_done)
                mod_req[mod_slot] <= 1'b0;
            else if (!mod_start && !mod_busy && !ld_busy && !ld_start &&
                     !load_now && !active_midi && (state != S_LOAD) && (|mod_req)) begin
                mod_slot  <= first_req(mod_req);
                mod_start <= 1'b1;
            end

            if (active_midi) mod_req <= '0; // velocity 不进入压力调音

            case (state)
                // 空闲：done=1（上面组合输出），等 start。
                //   ready=1 才真正执行 inst/reload 的变更（没有挂起变更时恒 1）；
                //   ready=0 时这一帧照常跑（用旧表），变更挂起等下一次。
                S_DONE: begin
                    if (start) begin
                      // 失败不是成功的换表：持续run不自动反复重试，也不再出声。
                      // 仍允许真实维护帧清状态；显式reload或另一个inst才重新加载。
                      if((ld_err || cfg_error) && !reload_pend && inst==inst_lat)begin
                        if((maintain_req && !maintenance_completed) || (MIDI_ENABLE && midi_valid))begin
                            pick_b<=0;wait_xmap<=1;state<=S_RUN_X;
                        end
                      end else begin
                        // 每帧扣一次保护计数；加载后的首帧已遍历并清理全部工作槽
                        if (zero_frames != '0) zero_frames <= zero_frames - 1'b1;
                        // 每个乐器用多少模态由 router_pkg 定；超过表的物理深度就限幅
                        //   （n_modes_of 不知道 N_MODES，所以夹在这里）
                        nm_lat   <= (n_modes_of(run_inst) > N_MODES) ? (IW+1)'(N_MODES)
                                                                 : (IW+1)'(n_modes_of(run_inst));

                        pick_b   <= 1'b0;
                        if (change_pend) begin
                            if (ready) begin
                                inst_lat    <= inst;
                                reload_pend <= 1'b0;
                                cfg_error<=0;cfg_slot<='0;cfg_phase<=0;
                                pending_notes<=slot_note_map;pending_offsets<=load_offsets;
                                table_valid <= 1'b0;
                                state       <= S_CFG;
                            end else begin
                                // 键还按着：先出这一帧（旧系数、旧乐器号），别停摆
                                wait_xmap <= 1'b1;
                                state     <= S_RUN_X;
                            end
                        end else begin
                            inst_lat  <= inst;
                            wait_xmap <= 1'b1;
                            state     <= S_RUN_X;
                        end
                      end
                    end
                end

                S_CFG: begin
                    // Break slot mux -> profile ROM -> validation/control into
                    // separate cycles. This only runs before Flash loading.
                    case(cfg_phase)
                        0:begin cfg_note<=pending_notes[cfg_slot*7 +:7];cfg_phase<=1;end
                        1:begin cfg_lookup<=sustain_profiles_pkg::lookup(inst_lat,cfg_note);cfg_phase<=2;end
                        default:begin
                            cfg_phase<=0;
                            if(is_sustain(inst_lat) && (!cfg_lookup.valid || cfg_lookup.period<2 ||
                               cfg_lookup.a_step==0 || cfg_lookup.r_step==0))begin
                                cfg_error<=1;cfg_fail_pulse<=1;state<=S_DONE;
                            end else begin
                                pending_play[cfg_slot]<=is_sustain(inst_lat) ? cfg_lookup : sustain_cfg_t'('0);
                                if(cfg_slot==VWID'(SLOTS-1))begin ld_start<=1;state<=S_LOAD;end
                                else cfg_slot<=cfg_slot+1'b1;
                            end
                        end
                    endcase
                end
                S_LOAD: begin
                    if (ld_done) begin
                        table_valid <= !ld_err;
                        if(ld_err)begin
                            state<=S_DONE;
                        end else begin
                            for(int p=0;p<SLOTS;p++) active_play[p]<=pending_play[p];
                            zero_frames <= (IW+1)'(1);
                            inst_prev <= inst_lat;

                            wait_xmap <= 1'b1;
                            state     <= S_RUN_X;
                        end
                    end
                end

                // 等统一 smp_tick 产生的 xmap（外部 I2S 模式不再运行内部采样分频）
                // 一次作业只跑一个采样，所以 xmap 只要整张寄存进 x_q（一拍），
                // 不需要再分 SLOTS 拍写 x_ram
                S_RUN_X: begin
                    if (frame_start) begin
                        wait_xmap <= 1'b0;
                        xw_run    <= 1'b1;          // 下一拍照抄 xmap -> x_q
                        state     <= S_XS;
                    end
                end

                // 一拍把 xmap 整张抄进 x_q（快照），然后才起引擎：
                // 引擎第一拍就要读 x，抄和读挤同一拍会读到上一笔
                S_XS: begin
                    xw_run    <= 1'b0;

                    pick_b    <= 1'b0;
                    eng_start <= 1'b1;              // 第 0 组的两个声部**同时**起
                    state     <= S_RUN_V;
                end

                // 起音声部只**登记**一个调制请求，不停下来等 —— 调制器在后台跑
                //   （它写系数用的写口和引擎读系数用的读口是同一块 RAM 的两个端口，
                //    天然可以同时工作；新系数从下一帧开始生效）。
                // 两个引擎都出 y_valid 才算这一组完成（同种引擎、同拍启动，时序一致）
                S_RUN_V: begin
                    if (era_yv && erb_yv) begin
                        if (!active_midi && note_f[g[VWID-1:0]]) mod_req[g[VWID-1:0]] <= 1'b1;
                        if (!active_midi && note_f[VWID'(g + VWID'(HS))])
                                                            mod_req[VWID'(g + VWID'(HS))] <= 1'b1;
                        // 按住期间**力度变化**也要重新调制（揉弦就靠这个）：
                        //   以前只有 note_f（起音沿）会登记，按住之后 fmap 怎么变
                        //   都没人管 -> 揉弦只生效一下。这里补一个"fmap 变了"的触发，
                        //   每帧每组两个声部各比一次，改了才登记（幂等，重复跑无害）。
                        if (!active_midi && !maintain_req && part_gate[g[VWID-1:0]] &&
                            (fmap_q.flat_d[g[VWID-1:0]].val != fmap_prev[g[VWID-1:0]])) begin
                            mod_req[g[VWID-1:0]]          <= 1'b1;
                            fmap_prev[g[VWID-1:0]]        <= fmap_q.flat_d[g[VWID-1:0]].val;
                        end
                        if (!active_midi && !maintain_req && part_gate[VWID'(g + VWID'(HS))] &&
                            (fmap_q.flat_d[VWID'(g + VWID'(HS))].val !=
                             fmap_prev[VWID'(g + VWID'(HS))])) begin
                            mod_req[VWID'(g + VWID'(HS))] <= 1'b1;
                            fmap_prev[VWID'(g + VWID'(HS))] <=
                                fmap_q.flat_d[VWID'(g + VWID'(HS))].val;
                        end
                        pick_b <= 1'b0;
                        state  <= S_ENVMUL;
                    end
                end

                // 包络乘法：这一拍把乘法结果打进 y_env
                S_ENVMUL: state <= S_ENVACC;

                // 这一拍把 y_env 累加进 y_acc
                S_ENVACC: state <= S_ADV;

                S_ADV: begin
                    if (!pick_b) begin
                        // 同一组里的 B 声部：复用同一套 乘法/累加 流水
                        pick_b <= 1'b1;
                        state  <= S_ENVMUL;
                    end else if (g + 1'b1 >= VWID'(HS)) begin
                        // 全部声部算完：把这一采样的混音交给腔体。
                        // 上一笔还没被接走就原地等（绝不覆盖），腔体出来才是 y_data
                        if (!mix_v) begin
                            mix_q <= y_acc;
                            mix_v <= 1'b1;

                            pick_b<= 1'b0;
                            state <= S_WAIT;      // 先排空，排空完才回 S_DONE（done 才变 1）
                        end
                    end else begin

                        pick_b    <= 1'b0;
                        eng_start <= 1'b1;
                        state     <= S_RUN_V;
                    end
                end

                // 排空：等腔体 + 混响把最后几笔都吐完，才回 S_DONE（这时 done 才变 1）
                //   这段时间 done=0，上层不会发新的 start。
                S_WAIT: begin
                    if (frame_retire) begin
                        state <= S_DONE;
                    end
                end

                default: state <= S_DONE;
            endcase
        end
    end

    // =========================================================================
    // 后级实例：混音 -> 腔体 -> 混响 -> y_data
    //   腔体：乐器号选系数（body_router 内部 = 常量表 + body_biquad），用 inst_lat
    //         （一次作业里乐器号不变，系数就不会中途跳）
    //   混响：预设由上层给（reverb_preset），NONE 时是逐位直通的延迟
    // =========================================================================
    logic effects_clear, effects_pending, effects_cleared, body_clear_busy;
    wire effects_need = (maintain_req || active_midi) && (|clear_f) && committed_gate=='0;
    // Retirement is a registered fence, not a combinational feedback through
    // the same frame's performance-input mux. It can only delay completion.
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n)frame_retire<=0;
        else frame_retire<=frame_drained && (!effects_need || effects_cleared);
    end
    // Business clear is synchronous. Hold frame retirement until the body RAM
    // clear has finished; comb RAM is invalidated logically, without changing layout.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            effects_clear<=0; effects_pending<=0; effects_cleared<=0;
        end else begin
            effects_clear<=0;
            if(frame_start) effects_cleared<=0;
            if(frame_drained && effects_need && !effects_pending && !effects_cleared) begin
                effects_clear<=1; effects_pending<=1;
            end
            if(effects_pending && !effects_clear && !body_clear_busy) begin
                effects_pending<=0; effects_cleared<=1;
            end
        end
    end
    body_router #(
        .SLOTS(SLOTS), .NSEC(5), .NTAP(5), .COEFF_FRAC(27), .GUARD_BITS(4)
    ) u_body (
        .clk(clk), .rst_n(child_reset[3][1]),
        .clear_req(effects_clear), .clear_busy(body_clear_busy),
        .inst(inst_lat),
        .in_valid(mix_v), .in_ready(body_in_ready), .x(mix_q),
        .out_valid(body_out_valid), .y(body_y)
    );

    reverb_router #(.N(2048)) u_rev (
        .clk(clk), .rst_n(child_reset[4][1]), .clear_req(effects_clear), .preset(reverb_preset),
        .in_valid(body_out_valid), .x(body_y),
        .out_valid(rev_out_valid), .y(rev_y)
    );

endmodule
