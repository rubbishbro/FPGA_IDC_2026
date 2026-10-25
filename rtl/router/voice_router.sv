// -----------------------------------------------------------------------------
// voice_router.sv -- 声部路由器（第一版结构骨架）
//
//   职责：
//     1. 持有全部存储（系数 / 状态 / 激励 / 结果）
//     2. 按乐器号把存储口 mux 到两套互斥的引擎之一（modal_engine7 / eng_alt）
//     3. 调度：采样 x 声部，每个（采样, 声部）一个作业
//     4. 激励来自 exc_router（整张 fmap -> 整张 xmap），**一次作业只跑一个采样**，
//        所以 xmap 直接整张寄存一拍当快照（不再有 x_ram / 采样深度）
//     5. 换乐器 = 停机 -> weight_loader 重灌系数表 -> 再跑
//
//   后级（在本文件末尾，顺序固定）：
//     6. 逐声部过自己的包络 -> 全部声部按采样加和 -> **统一过一遍腔体**
//        （body_router，乐器号选系数）-> 混响（reverb_router）-> y_data 输出
//     7. 混响（reverb_router）：预设由上层输入 reverb_preset 选，NONE 时是逐位直通
//        （只是多 6 拍延迟），HALL/BATHROOM 才真的加湿声
//
//   注意：本文件是新的一版，不改动 modal_voice_top；两者可以并行存在。
//   占位：force_pre / weight_loader / eng_alt 见 router_stubs.sv
//
//   加载是**阻塞**的（S_LOAD 等 ld_done）：这段时间 input_hold=1，fmap 冻结、
//   note 事件不产生，也不出任何 y_valid —— 上层看到的就是"静音 + not ready"。
//   这是有意的设计选择（最省逻辑，代价是换乐器头 1~2 ms 没声音），不是遗漏；
//   要边放边载得改成双缓冲，以后再说。加载出错的处理仍然待定（loader 有 err 输出）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module voice_router #(
    parameter int   SLOTS      = 16,
    parameter int   N_MODES    = 64,          // 唯一的模态数：系数表/状态/激励/参数表都按它开
    parameter int   CLK_HZ     = 100_000_000,
    parameter int   SR_HZ      = 48_000,
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    // ---- 上游 ----
    input  pad_driver_pkg::mat4x4                    fmap,
    input  router_pkg::instrument_e                   inst,
    input  router_pkg::reverb_preset                  reverb_preset,  // 混响预设（NONE/HALL/BATHROOM）
    input  logic                                     reload,      // 强制重灌当前乐器
    input  logic                                     start,
    input  logic [$clog2(SLOTS+1)-1:0]                n_voices,
    input  logic [$clog2(N_MODES+1)-1:0]              n_modes,
    output logic                                      ready,       // 系数表就绪、可以 start
    output logic                                      busy,
    output logic                                      done,

    // ---- 输出（每采样一个）----
    output logic                                      y_valid,
    output logic signed [63:0]                        y_data,

    // ---- QSPI flash ----
    output logic                                      qspi_cs_n,
    output logic                                      qspi_sck,
    output logic [3:0]                                qspi_dq_o,
    output logic                                      qspi_dq_oe,
    input  logic [3:0]                                qspi_dq_i,

    // ---- 调试 ----
    input  logic                                      ns_rd_en,
    input  logic [CO_SLOT-1:0]                        ns_rd_addr,
    input  logic                                      ns_rd_sel,
    output logic signed [31:0]                        ns_rd_data,
    output logic                                      ns_rd_valid
);

    import modal_step_pkg::*;
    import router_pkg::*;

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

    // =========================================================================
    // 存储（与 modal_voice_top 相同的布局；两个引擎互斥，所以只有一套）
    // =========================================================================
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq  [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv  [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo  [0:SLOTS*NMP-1];

    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram  [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram  [0:SLOTS*NMP-1];

    // 调制参数表（引擎不读；加载器写，调制器读）
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_c0 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_s0 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_gam[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_th [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_g  [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_k12[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_k21[0:SLOTS*NMP-1];

    // 激励快照：一次作业只有一个采样，所以就是 16 个寄存器（不再有按采样索引的 RAM）
    logic signed [XW-1:0] x_q [0:SLOTS-1];

    // 早期声明（parts 的选择逻辑要用）
    router_pkg::instrument_e inst_lat;
    logic [VWID:0]           nv_lat;
    logic [IW:0]             nm_lat;
    coeff_t                  co_r;

    // =========================================================================
    // 统一采样节拍：所有 part 共用，避免各自分频漂移
    // =========================================================================
    logic                      smp_tick;
    logic [$clog2(CLK_HZ/SR_HZ+1)-1:0] tick_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= '0;
            smp_tick <= 1'b0;
        end else begin
            smp_tick <= 1'b0;
            if (tick_cnt + 1 >= CLK_HZ/SR_HZ) begin
                tick_cnt <= '0;
                smp_tick <= 1'b1;
            end else tick_cnt <= tick_cnt + 1'b1;
        end
    end

    // =========================================================================
    // 三个部件子路由（各自按乐器号选实例，主 router 只连总线）
    // =========================================================================
    logic signed [15:0][31:0] xmap;      // 打包：xmap[i] 是第 i 个声部的激励
    logic                     xmap_valid;
    logic signed [15:0][31:0] emap;      // 打包：emap[i] 是第 i 个声部的包络
    logic                     emap_valid;
    logic [SLOTS-1:0]         env_dead;  // 包络说

    // ---- 音符事件：由 fmap 双阈值在 router 里统一生成 ----
    //   note_on 就是**滞回判定后的门控电平**：这个键现在按着就是 1。
    //     * 只看当前 fmap + 上一次的门控状态（gate_r 做滞回），不取沿、不粘住；
    //     * 按下要 > NOTE_ON_TH，松开要掉到 < NOTE_OFF_TH 才算松；
    //     * 谁要"起音事件"谁自己取沿：激励/包络内部各有一个 prev 寄存器，
    //       router 自己需要的那份在下面取成 note_ev。
    //   note_gate 与 note_on 是同一个电平（保留旧端口名，部件那边还在用）。
    //   加载系数期间 fmap_q 冻结，这个电平也就跟着冻住——等于忽略外部输入，
    //   装完之后按当前键态重新判：装的过程中按下的键照样能起音。
    localparam logic [7:0] NOTE_ON_TH  = 8'd2;
    localparam logic [7:0] NOTE_OFF_TH = 8'd1;

    logic [SLOTS-1:0] gate_r, note_gate, note_on;
    logic [SLOTS-1:0] note_on_q, note_ev;      // router 内部的起音沿
    logic [SLOTS-1:0] note_pend, note_f;       // 攒到帧头的那份（给引擎/调制器）
    logic             input_hold;              // 1 = 忽略外部输入（驱动见调度器上方）

    // 滞回判定直接决定 note_on。判完打一拍再出去：fmap_q 是 128 位、扇出很大，
    // "16 个比较 -> note_on -> note_ev" 挤在一拍 PnR 实测 11.6 ns；下游（激励/
    // 包络/腔体）本来就只在 smp_tick 看它，晚一拍完全无所谓。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_on <= '0;
        end else begin
            for (int i = 0; i < SLOTS; i++)
                note_on[i] <= gate_r[i] ? (fmap_q.flat_d[i].val >= NOTE_OFF_TH)
                                        : (fmap_q.flat_d[i].val >  NOTE_ON_TH);
        end
    end

    assign note_gate = note_on;                // 同一个电平，只是换了名字

    // 滞回用的上一次门控状态
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        gate_r <= '0;
        else if (smp_tick) gate_r <= note_on;
    end

    exc_router #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_exc (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap_q),
        .note_on(note_on), .inst(inst_lat),
        .xmap(xmap), .xmap_valid(xmap_valid)
    );

    env_router #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_env (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap_q),
        .note_on(note_on), .note_gate(note_gate), .inst(inst_lat),
        .emap(emap), .emap_valid(emap_valid), .dead(env_dead)
    );

    logic                    mod_busy, mod_done, mod_start, mod_p_re;
    logic [VWID-1:0]         mod_slot;
    // 后台调制请求位图：起音的声部在这里置位，调制器空闲时按最低位服务，做完清那一位。
    //   这样谁请求都不会丢（幂等的调制器重复跑也无害），而且**不挡引擎**。
    logic [SLOTS-1:0]        mod_req;

    function automatic logic [VWID-1:0] first_req(input logic [SLOTS-1:0] r);
        first_req = '0;
        for (int i = SLOTS-1; i >= 0; i--) if (r[i]) first_req = VWID'(i);
    endfunction
    logic [IW-1:0]           mod_p_mode, mod_co_mode;
    logic [3:0]              mod_co_we;
    coeff_t                  mod_co_wdata;
    logic signed [31:0]      mod_c0_r, mod_s0_r, mod_gam_r, mod_theta0_r, mod_g_r;
    logic signed [31:0]      mod_k12_r, mod_k21_r;
    logic signed [31:0]      mod_c0, mod_s0, mod_gam, mod_theta0, mod_g;

    assign mod_c0     = mod_c0_r;
    assign mod_s0     = mod_s0_r;
    assign mod_gam    = mod_gam_r;
    assign mod_theta0 = mod_theta0_r;
    assign mod_g      = mod_g_r;

    mod_router #(.SLOTS(SLOTS), .N_MODES(N_MODES)) u_modr (
        .clk(clk), .rst_n(rst_n), .start(mod_start),
        .fmap_i(fmap_q.flat_d[mod_slot].val), .n_modes(16'(nm_lat)),
        .inst(inst_lat), .busy(mod_busy), .done(mod_done),
        .p_re(mod_p_re), .p_mode(mod_p_mode),
        .p_c0(mod_c0), .p_s0(mod_s0), .p_gam(mod_gam),
        .p_theta0(mod_theta0), .p_g(mod_g),
        .p_k12(mod_k12_r), .p_k21(mod_k21_r),
        .co_we(mod_co_we), .co_mode(mod_co_mode), .co_wdata(mod_co_wdata)
    );

    // =========================================================================
    // 系数加载
    // =========================================================================
    logic                           ld_start, ld_busy, ld_done;
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

    weight_loader #(.SLOTS(SLOTS), .N_MODES(N_MODES)) u_ld (
        .clk(clk), .rst_n(rst_n), .inst(4'(inst)),
        .start(ld_start), .busy(ld_busy), .done(ld_done),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_co(ld_co_data), .ld_pm(ld_pm_data),
        .qspi_cs_n(qspi_cs_n), .qspi_sck(qspi_sck),
        .qspi_dq_o(qspi_dq_o), .qspi_dq_oe(qspi_dq_oe), .qspi_dq_i(qspi_dq_i)
    );

    // =========================================================================
    // 两套引擎（互斥）+ 口 mux
    // =========================================================================
    // 引擎 0：modal_engine7
    logic                 e0_start, e0_zero, e0_yv;
    logic [IW-1:0]        e0_co_addr;
    logic                 e0_co_re, e0_st_re, e0_st_we;
    logic [IW-1:0]        e0_st_addr, e0_st_waddr;
    logic [0:0]           e0_x_addr;
    logic                 e0_x_re;
    logic signed [63:0]   e0_y;

    // 引擎 1：eng_alt（占位）
    logic                 e1_start, e1_zero, e1_yv;
    logic [IW-1:0]        e1_co_addr;
    logic                 e1_co_re, e1_st_re, e1_st_we;
    logic [IW-1:0]        e1_st_addr, e1_st_waddr;
    logic [0:0]           e1_x_addr;
    logic                 e1_x_re;
    logic signed [63:0]   e1_y;

    // 存储读出的寄存器（声明必须在引擎实例之前）
    // 选中的引擎（作业开始/装载时锁存，运行中不变）
    logic                 sel_alt;
    logic                 eng_start, eng_zero, eng_yv;
    logic [IW-1:0]        eng_co_addr, eng_st_addr, eng_st_waddr;
    logic                 eng_co_re, eng_st_re, eng_st_we, eng_x_re;
    logic [0:0]           eng_x_addr;
    logic signed [63:0]   eng_y;

    assign e0_start = eng_start && !sel_alt;
    assign e1_start = eng_start &&  sel_alt;
    assign e0_zero  = eng_zero  && !sel_alt;
    assign e1_zero  = eng_zero  &&  sel_alt;

    assign eng_co_re   = sel_alt ? e1_co_re   : e0_co_re;
    assign eng_co_addr = sel_alt ? e1_co_addr : e0_co_addr;
    assign eng_st_re   = sel_alt ? e1_st_re   : e0_st_re;
    assign eng_st_addr = sel_alt ? e1_st_addr : e0_st_addr;
    assign eng_st_we   = sel_alt ? e1_st_we   : e0_st_we;
    assign eng_st_waddr= sel_alt ? e1_st_waddr: e0_st_waddr;
    assign eng_x_re    = sel_alt ? e1_x_re    : e0_x_re;
    assign eng_x_addr  = sel_alt ? e1_x_addr  : e0_x_addr;
    assign eng_yv      = sel_alt ? e1_yv      : e0_yv;
    assign eng_y       = sel_alt ? e1_y       : e0_y;

    logic signed [CW-1:0] co_a11_r, co_a12_r, co_a21_r, co_a22_r, co_gq_r, co_gv_r, co_wo_r;
    logic signed [QW-1:0] st_q_r;
    logic signed [VW-1:0] st_v_r;
    logic signed [QW-1:0] st_q_wd;
    logic signed [VW-1:0] st_v_wd;
    logic signed [XW-1:0] x_r;

    logic signed [31:0] e0_qwd, e0_vwd, e1_qwd, e1_vwd;
    eng0 #(.N_MODES(N_MODES)) u_eng0 (
        .clk(clk), .rst_n(rst_n),
        .start(e0_start), .st_zero(e0_zero), .n_modes(nm_lat),
        .y_valid(e0_yv), .y_data(e0_y),
        .co_re(e0_co_re), .co_addr(e0_co_addr), .co_data(co_r),
        .st_re(e0_st_re), .st_addr(e0_st_addr),
        .st_q(st_q_r), .st_qdot(st_v_r),
        .st_we(e0_st_we), .st_waddr(e0_st_waddr),
        .st_q_wdata(e0_qwd), .st_qdot_wdata(e0_vwd),
        .x_re(e0_x_re), .x_addr(e0_x_addr), .x_data(x_r)
    );

    eng1 #(.N_MODES(N_MODES)) u_eng1 (
        .clk(clk), .rst_n(rst_n),
        .start(e1_start), .st_zero(e1_zero), .n_modes(nm_lat),
        .y_valid(e1_yv), .y_data(e1_y),
        .co_re(e1_co_re), .co_addr(e1_co_addr), .co_data(co_r),
        .st_re(e1_st_re), .st_addr(e1_st_addr),
        .st_q(st_q_r), .st_qdot(st_v_r),
        .st_we(e1_st_we), .st_waddr(e1_st_waddr),
        .st_q_wdata(e1_qwd), .st_qdot_wdata(e1_vwd),
        .x_re(e1_x_re), .x_addr(e1_x_addr), .x_data(x_r)
    );

    // =========================================================================
    // 存储的读写（地址 = {声部槽, 引擎给的偏移}）
    // =========================================================================
    logic [VWID:0]        voi;
    logic [CO_SLOT-1:0]   st_rd_idx, st_wr_idx, co_idx;
    logic [CO_SLOT-1:0]   pm_idx;         // 调制参数读地址 = mod_slot*N_MODES + mode

    // 地址 = slot*N_MODES + mode（显式乘，不靠 {slot,mode} 拼接：N_MODES 不是 2 的
    // 幂时拼接的步长会和 RAM 深度/loader 布局对不上）。N_MODES=2^k 时综合成移位。
    assign pm_idx    = {mod_slot, mod_p_mode};          // 地址 = {slot, mode}（NMP 是 2 的幂）
    assign co_idx    = {voi[VWID-1:0], eng_co_addr};
    assign st_rd_idx = {voi[VWID-1:0], eng_st_addr};
    assign st_wr_idx = {voi[VWID-1:0], eng_st_waddr};

    always_comb begin
        co_r.a11 = co_a11_r;  co_r.a12 = co_a12_r;  co_r.a21 = co_a21_r;
        co_r.a22 = co_a22_r;  co_r.gq  = co_gq_r;   co_r.gv  = co_gv_r;
        co_r.wo  = co_wo_r;
    end

    // x 快照：整张 xmap 一拍抄进 x_q（一次作业一个采样，不需要按采样索引）
    logic                     xw_run;

    logic [31:0]            ns_r;
    logic                   ns_vld;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            co_a11_r <= '0; co_a12_r <= '0; co_a21_r <= '0; co_a22_r <= '0;
            mod_c0_r <= '0; mod_s0_r <= '0; mod_gam_r <= '0; mod_theta0_r <= '0; mod_g_r <= '0;
            mod_k12_r <= '0; mod_k21_r <= '0;
            co_gq_r  <= '0; co_gv_r  <= '0; co_wo_r  <= '0;
            st_q_r   <= '0; st_v_r   <= '0; x_r      <= '0;
            ns_r     <= '0; ns_vld   <= 1'b0;
        end else begin
            // 引擎占用状态口时 debug 读根本没执行，valid 不能报（F11/其它接口表）
            ns_vld <= ns_rd_en & DEBUG_PORT & ~eng_st_re;

            // 系数：加载器 / 调制器 写（loader 优先），引擎读
            if (ld_co_we) begin
                ca_a11[ld_idx] <= ld_co_data.a11;
                ca_a12[ld_idx] <= ld_co_data.a12;
                ca_a21[ld_idx] <= ld_co_data.a21;
                ca_a22[ld_idx] <= ld_co_data.a22;
                ca_gq [ld_idx] <= ld_co_data.gq;
                ca_gv [ld_idx] <= ld_co_data.gv;
                ca_wo [ld_idx] <= ld_co_data.wo;
            end else if (|mod_co_we) begin
                // 每个字段独立写使能；地址 = {当前调制声部, 模态偏移}
                if (mod_co_we[0]) ca_a11[{mod_slot, mod_co_mode}] <= mod_co_wdata.a11;
                if (mod_co_we[1]) ca_a12[{mod_slot, mod_co_mode}] <= mod_co_wdata.a12;
                if (mod_co_we[2]) ca_a21[{mod_slot, mod_co_mode}] <= mod_co_wdata.a21;
                if (mod_co_we[3]) ca_a22[{mod_slot, mod_co_mode}] <= mod_co_wdata.a22;
            end
            // 调制参数表：加载器统一写；调制器读（1 拍延迟）
            if (ld_pm_we) begin
                pm_c0 [ld_idx] <= ld_pm_data.c0;
                pm_s0 [ld_idx] <= ld_pm_data.s0;
                pm_gam[ld_idx] <= ld_pm_data.gam;
                pm_th [ld_idx] <= ld_pm_data.theta0;
                pm_g  [ld_idx] <= ld_pm_data.g;
                pm_k12[ld_idx] <= ld_pm_data.k12;
                pm_k21[ld_idx] <= ld_pm_data.k21;
            end
            // 参数表读出后**再打一拍**：否则 BSRAM 的 CLK->Q 会和调制器第一级乘法
            // 串在同一条路径上（实测 15.2 ns）。这一拍只做寄存，调制器多等一拍。
            if (mod_p_re) begin
                mod_c0_r     <= pm_c0 [pm_idx];
                mod_s0_r     <= pm_s0 [pm_idx];
                mod_gam_r    <= pm_gam[pm_idx];
                mod_theta0_r <= pm_th [pm_idx];
                mod_g_r      <= pm_g  [pm_idx];
                mod_k12_r    <= pm_k12[pm_idx];
                mod_k21_r    <= pm_k21[pm_idx];
            end

            if (eng_co_re) begin
                co_a11_r <= ca_a11[co_idx];
                co_a12_r <= ca_a12[co_idx];
                co_a21_r <= ca_a21[co_idx];
                co_a22_r <= ca_a22[co_idx];
                co_gq_r  <= ca_gq [co_idx];
                co_gv_r  <= ca_gv [co_idx];
                co_wo_r  <= ca_wo [co_idx];
            end

            // 激励：force_pre 分配写入；引擎读
            if (xw_run) for (int i = 0; i < SLOTS; i++) x_q[i] <= xmap[i];
            if (eng_x_re) x_r <= x_q[voi[VWID-1:0]];

            // 状态：引擎独占
            if (eng_st_re) begin
                st_q_r <= q_ram[st_rd_idx];
                st_v_r <= v_ram[st_rd_idx];
            end else if (ns_rd_en && DEBUG_PORT) begin
                ns_r <= ns_rd_sel ? v_ram[ns_rd_addr] : q_ram[ns_rd_addr];
            end
            if (eng_st_we) begin
                q_ram[st_wr_idx] <= st_q_wd;
                v_ram[st_wr_idx] <= st_v_wd;
            end
        end
    end

    assign ns_rd_data  = DEBUG_PORT ? 32'(ns_r) : 32'sd0;
    assign ns_rd_valid = ns_vld;

    // 状态写数据（来自选中的引擎）
    assign st_q_wd = sel_alt ? e1_qwd : e0_qwd;
    assign st_v_wd = sel_alt ? e1_vwd : e0_vwd;

    // =========================================================================
    // 结果：逐声部过自己的包络 -> 全声部混音
    //   y_env = (eng_y * emap[voi]) >>> 31   包络 Q1.31
    //   y_acc = Σ_voi y_env                  帧内跨声部求和
    //   分三拍走（S_RUN_V 取操作数 / S_ENVMUL 乘 / S_ENVACC 累加）：
    //     原来 emap 的 16:1 读 + 96 位乘法 + 64 位累加挤在一拍里，实测 PnR
    //     25.6 ns（Fmax 50 MHz）。分开之后每拍只剩一级：
    //     mux 单独一拍、乘法器两个输入都是寄存器、累加也自己一拍。
    //   y_acc 是 64 位；16 个声部同时满量程理论上会回绕（实际信号远不到）。
    // =========================================================================
    logic signed [AW-1:0] y_acc;       // Σ y_env（帧内跨声部混音）
    logic signed [AW-1:0] y_lat;       // eng_y 打一拍：乘法器的输入必须是寄存器
    logic signed [31:0]   e_lat;       // emap[voi] 打一拍：16:1 读单独占一拍
    logic signed [AW-1:0] y_env;       // 本声部过包络后的输出
    logic signed [95:0]   y_mul;

    assign y_mul = y_lat * e_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_lat <= '0;
            e_lat <= '0;
            y_env <= '0;
            y_acc <= '0;
        end else begin
            if (state == S_RUN_V && eng_yv) begin
                y_lat <= eng_y;
                e_lat <= $signed(emap[voi[VWID-1:0]]);
            end
            // 乘法结果先落一拍，下一拍才做 64 位累加（原来是 mul + add 同一拍）
            if (state == S_ENVMUL) y_env <= y_mul[94:31];   // (eng_y*E) >>> 31
            if (state == S_ENVACC)
                y_acc <= (voi == '0) ? y_env : (y_acc + y_env);
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

    assign body_accept = mix_v && body_in_ready;
    assign y_valid     = rev_out_valid;      // 混响之后才是"data"
    assign y_data      = rev_y;

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
    // 作业调度：IDLE -> (LOAD) -> 每采样 [RUN_X 等 xmap -> XWR 写 16 路 -> RUN_V 跑声部] -> DONE
    // =========================================================================
    // S_ENVMUL / S_ENVACC：包络乘法流水（取操作数 -> 乘 -> 累加），见上面结果段
    typedef enum logic [3:0] { S_IDLE, S_LOAD, S_RUN_X, S_XS, S_RUN_V,
                               S_ENVMUL, S_ENVACC, S_ADV, S_DONE } st_e;
    st_e                 state;

    instrument_e         inst_prev;
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
    assign note_ev = note_on & ~note_on_q;

    // 引擎是逐声部串行跑的，等它跑到某个声部时沿早没了：事件先攒进 note_pend，
    // 到**作业头**（S_RUN_X 那一拍）一次性交给 note_f，note_f 只在这一次作业里有效：
    // 不跨帧粘住，也不会跨加载残留。
    logic             frame_start;

    assign frame_start = (state == S_RUN_X) && wait_xmap && xmap_valid;

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
    //   eng0 的清零 pass 要 n_modes 拍，全静音时 16 个声部每帧都清 = 16x80 拍，
    //   实测一个采样 2754 拍（48 kHz 要 132 MHz）。只在包络掉到 0 的那一帧清，
    //   状态被清成正好 0，之后激励也是 0，状态就一直保持 0 了。

    // 比较结果打一拍：原来 emap -> 比较 -> eng_zero 是一条长组合链
    // （包络每采样才更新一次，晚一拍对 st_zero 没有影响）
    logic [SLOTS-1:0] voice_dead, voice_dead_q;
    logic [SLOTS-1:0] dead_ev;         // 归零的那一拍
    logic [SLOTS-1:0] dead_pend, dead_f;   // 攒到帧头的那份（和 note_f 一个套路）

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

    assign eng_zero = note_f[voi[VWID-1:0]] | dead_f[voi[VWID-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            ready      <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            mix_v      <= 1'b0;
            mix_q      <= '0;
            voi        <= '0;
            nv_lat     <= '0;
            nm_lat     <= '0;
            inst_lat   <= INST_NONE;
            inst_prev  <= INST_NONE;
            sel_alt    <= 1'b0;
            eng_start  <= 1'b0;
            ld_start   <= 1'b0;
            xw_run     <= 1'b0;
            wait_xmap  <= 1'b0;
            mod_req    <= '0;
            mod_start  <= 1'b0;
            mod_slot   <= '0;
        end else begin
            done      <= 1'b0;
            if (body_accept) mix_v <= 1'b0;      // 这一笔混音已经被腔体接走
            eng_start <= 1'b0;
            ld_start  <= 1'b0;
            mod_start <= 1'b0;

            // ---- 后台调制：有请求 + 调制器空闲 + 没在加载 -> 发一拍 start ----
            //   一次只发一个（busy 期间不发，发了也会被它忽略），做完清那一位。
            if (mod_done)
                mod_req[mod_slot] <= 1'b0;
            else if (!mod_start && !mod_busy && !ld_busy && (|mod_req)) begin
                mod_slot  <= first_req(mod_req);
                mod_start <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    ready <= 1'b1;
                    busy  <= 1'b0;
                    if (start) begin
                        nv_lat   <= (n_voices == 0) ? 1 : n_voices;
                        nm_lat   <= n_modes;
                        inst_lat <= inst;
                        sel_alt  <= eng_sel(inst);
                        busy     <= 1'b1;
                        ready    <= 1'b0;
                        voi      <= '0;
                        // 换乐器（或强制 reload）→ 先停机重灌系数表
                        if ((inst != inst_prev) || reload) begin
                            ld_start <= 1'b1;
                            state    <= S_LOAD;
                        end else begin
                            wait_xmap <= 1'b1;
                            state     <= S_RUN_X;
                        end
                    end
                end

                S_LOAD: begin
                    if (ld_done) begin
                        inst_prev <= inst_lat;
                        voi       <= '0;
                        wait_xmap <= 1'b1;
                        state     <= S_RUN_X;
                    end
                end

                // 等 force_pre 出这一采样的 xmap（它自己按 CLK/SR 分频）
                // 一次作业只跑一个采样，所以 xmap 只要整张寄存进 x_q（一拍），
                // 不需要再分 16 拍写 x_ram
                S_RUN_X: begin
                    if (wait_xmap && xmap_valid) begin
                        wait_xmap <= 1'b0;
                        xw_run    <= 1'b1;          // 下一拍照抄 xmap -> x_q
                        state     <= S_XS;
                    end
                end

                // 一拍把 xmap 整张抄进 x_q（快照），然后才起引擎：
                // 引擎第一拍就要读 x，抄和读挤同一拍会读到上一笔
                S_XS: begin
                    xw_run    <= 1'b0;
                    voi       <= '0;
                    eng_start <= 1'b1;              // 第 0 个声部的作业
                    state     <= S_RUN_V;
                end

                // 起音声部只**登记**一个调制请求，不停下来等 —— 调制器在后台跑
                //   （它写系数用的写口和引擎读系数用的读口是同一块 RAM 的两个端口，
                //    天然可以同时工作；新系数从下一帧开始生效）。
                S_RUN_V: begin
                    if (eng_yv) begin
                        if (note_f[voi[VWID-1:0]]) mod_req[voi[VWID-1:0]] <= 1'b1;
                        state <= S_ENVMUL;
                    end
                end

                // 包络乘法：这一拍把乘法结果打进 y_env
                S_ENVMUL: state <= S_ENVACC;

                // 这一拍把 y_env 累加进 y_acc
                S_ENVACC: state <= S_ADV;

                S_ADV: begin
                    if (voi + 1'b1 >= nv_lat) begin
                        // 全部声部算完：把这一采样的混音交给腔体。
                        // 上一笔还没被接走就原地等（绝不覆盖），腔体出来才是 y_data
                        if (!mix_v) begin
                            mix_q <= y_acc;
                            mix_v <= 1'b1;
                            voi   <= '0;
                            state <= S_DONE;
                        end
                    end else begin
                        voi       <= voi + 1'b1;
                        eng_start <= 1'b1;
                        state     <= S_RUN_V;
                    end
                end

                S_DONE: begin
                    // 等腔体 + 混响都把最后几笔吐完再报 done，否则最后一帧的 y_data 会丢
                    if (mix_outstd == '0 && !mix_v && rev_outstd == '0) begin
                        done  <= 1'b1;
                        busy  <= 1'b0;
                        ready <= 1'b1;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 后级实例：混音 -> 腔体 -> 混响 -> y_data
    //   腔体：乐器号选系数（body_router 内部 = 常量表 + body_biquad），用 inst_lat
    //         （一次作业里乐器号不变，系数就不会中途跳）
    //   混响：预设由上层给（reverb_preset），NONE 时是逐位直通的延迟
    // =========================================================================
    body_router #(
        .SLOTS(SLOTS), .NSEC(5), .NTAP(5), .COEFF_FRAC(27), .GUARD_BITS(4)
    ) u_body (
        .clk(clk), .rst_n(rst_n),
        .inst(inst_lat),
        .in_valid(mix_v), .in_ready(body_in_ready), .x(mix_q),
        .out_valid(body_out_valid), .y(body_y)
    );

    reverb_router #(.N(2048)) u_rev (
        .clk(clk), .rst_n(rst_n), .preset(reverb_preset),
        .in_valid(body_out_valid), .x(body_y),
        .out_valid(rev_out_valid), .y(rev_y)
    );

endmodule
