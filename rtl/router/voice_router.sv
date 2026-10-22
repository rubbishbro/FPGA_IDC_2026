// -----------------------------------------------------------------------------
// voice_router.sv -- 声部路由器（第一版结构骨架）
//
//   职责：
//     1. 持有全部存储（系数 / 状态 / 激励 / 结果）
//     2. 按乐器号把存储口 mux 到两套互斥的引擎之一（modal_engine7 / eng_alt）
//     3. 调度：采样 x 声部，每个（采样, 声部）一个作业；结果按采样求和输出
//     4. 激励来自 force_pre（整张 fmap -> 整张 xmap），按槽位分配到 x_ram
//     5. 换乐器 = 停机 -> weight_loader 重灌系数表 -> 再跑
//
//   注意：本文件是新的一版，不改动 modal_voice_top；两者可以并行存在。
//   占位：force_pre / weight_loader / eng_alt 见 router_stubs.sv
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module voice_router #(
    parameter int   SLOTS      = 16,
    parameter int   N_MODES    = 48,
    parameter int   X_DEPTH    = 64,
    parameter int   PM_MODES   = 80,          // 调制参数表按钢琴尺寸开
    parameter int   CLK_HZ     = 100_000_000,
    parameter int   SR_HZ      = 48_000,
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    // ---- 上游 ----
    input  pad_driver_pkg::mat4x4                    fmap,
    input  router_pkg::instrument_e                   inst,
    input  logic                                     reload,      // 强制重灌当前乐器
    input  logic                                     start,
    input  logic [$clog2(SLOTS+1)-1:0]                n_voices,
    input  logic [$clog2(N_MODES+1)-1:0]              n_modes,
    input  logic [$clog2(X_DEPTH+1)-1:0]              n_samples,
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
    input  logic [$clog2(SLOTS*N_MODES)-1:0]          ns_rd_addr,
    input  logic                                      ns_rd_sel,
    output logic signed [31:0]                        ns_rd_data,
    output logic                                      ns_rd_valid
);

    import modal_step_pkg::*;
    import router_pkg::*;

    localparam int IW     = $clog2(N_MODES);
    localparam int JW     = $clog2(X_DEPTH);
    localparam int VWID   = $clog2(SLOTS);
    localparam int CO_SLOT = $clog2(SLOTS * N_MODES);

    // =========================================================================
    // 存储（与 modal_voice_top 相同的布局；两个引擎互斥，所以只有一套）
    // =========================================================================
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq  [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv  [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo  [0:SLOTS*N_MODES-1];

    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram  [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram  [0:SLOTS*N_MODES-1];

    // 调制参数表（引擎不读；加载器写，调制器读）
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_c0 [0:SLOTS*PM_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_s0 [0:SLOTS*PM_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_gam[0:SLOTS*PM_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_th [0:SLOTS*PM_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_g  [0:SLOTS*PM_MODES-1];

    (* syn_ramstyle = "block_ram" *) logic signed [XW-1:0] x_ram  [0:SLOTS*X_DEPTH-1];
    (* syn_ramstyle = "block_ram" *) logic signed [YW-1:0] y_out  [0:X_DEPTH-1];

    // 早期声明（parts 的选择逻辑要用）
    router_pkg::instrument_e inst_lat;
    logic [VWID:0]           nv_lat;
    logic [IW:0]             nm_lat;
    logic [SLOTS-1:0]        zero_lat;   // 仅用于 note_on 的旧路径（保留待删）
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

    // ---- 音符事件：由 fmap 双阈值在 router 里统一生成（带回滞）----
    localparam logic [7:0] NOTE_ON_TH  = 8'd2;
    localparam logic [7:0] NOTE_OFF_TH = 8'd1;

    logic [SLOTS-1:0] gate_r, note_gate, note_on;
    logic             no_clr;
    logic [VWID-1:0]  no_clr_v;

    always_comb for (int i = 0; i < SLOTS; i++)
        note_gate[i] = gate_r[i] ? (fmap.flat_d[i].val >= NOTE_OFF_TH)
                                 : (fmap.flat_d[i].val >  NOTE_ON_TH);

    // note_on：门控上升沿置位，**粘住**到该声部首帧处理完才清
    // （否则换乐器/加载期间按下的音符会被吃掉）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_r  <= '0;
            note_on <= '0;
        end else if (no_clr) begin
            note_on[no_clr_v] <= 1'b0;
            if (smp_tick) gate_r <= note_gate;
        end else if (smp_tick) begin
            note_on <= note_on | (note_gate & ~gate_r);
            gate_r  <= note_gate;
        end
    end

    exc_router #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_exc (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .note_on(note_on), .note_gate(note_gate), .inst(inst_lat),
        .xmap(xmap), .xmap_valid(xmap_valid)
    );

    env_router #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_env (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .note_on(note_on), .note_gate(note_gate), .inst(inst_lat),
        .emap(emap), .emap_valid(emap_valid)
    );

    logic                    mod_busy, mod_done, mod_start, mod_p_re;
    logic [VWID-1:0]         mod_slot;
    logic [IW-1:0]           mod_p_mode, mod_co_mode;
    logic [3:0]              mod_co_we;
    coeff_t                  mod_co_wdata;
    logic signed [31:0]      mod_c0_r, mod_s0_r, mod_gam_r, mod_theta0_r, mod_g_r;
    logic signed [31:0]      mod_c0, mod_s0, mod_gam, mod_theta0, mod_g;

    assign mod_c0     = mod_c0_r;
    assign mod_s0     = mod_s0_r;
    assign mod_gam    = mod_gam_r;
    assign mod_theta0 = mod_theta0_r;
    assign mod_g      = mod_g_r;

    mod_router #(.SLOTS(SLOTS), .N_MODES(N_MODES)) u_modr (
        .clk(clk), .rst_n(rst_n), .start(mod_start),
        .fmap_i(fmap.flat_d[mod_slot].val), .n_modes(16'(nm_lat)),
        .inst(inst_lat), .busy(mod_busy), .done(mod_done),
        .p_re(mod_p_re), .p_mode(mod_p_mode),
        .p_c0(mod_c0), .p_s0(mod_s0), .p_gam(mod_gam),
        .p_theta0(mod_theta0), .p_g(mod_g),
        .co_we(mod_co_we), .co_mode(mod_co_mode), .co_wdata(mod_co_wdata)
    );

    // =========================================================================
    // 系数加载
    // =========================================================================
    logic                           ld_start, ld_busy, ld_done;
    logic                           ld_we;
    logic [CO_SLOT:0]               ld_addr;          // 最高位选表：0=系数 1=调制参数
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
    logic [JW-1:0]        e0_x_addr;
    logic                 e0_x_re;
    logic signed [63:0]   e0_y;

    // 引擎 1：eng_alt（占位）
    logic                 e1_start, e1_zero, e1_yv;
    logic [IW-1:0]        e1_co_addr;
    logic                 e1_co_re, e1_st_re, e1_st_we;
    logic [IW-1:0]        e1_st_addr, e1_st_waddr;
    logic [JW-1:0]        e1_x_addr;
    logic                 e1_x_re;
    logic signed [63:0]   e1_y;

    // 存储读出的寄存器（声明必须在引擎实例之前）
    // 选中的引擎（作业开始/装载时锁存，运行中不变）
    logic                 sel_alt;
    logic                 eng_start, eng_zero, eng_yv;
    logic [IW-1:0]        eng_co_addr, eng_st_addr, eng_st_waddr;
    logic                 eng_co_re, eng_st_re, eng_st_we, eng_x_re;
    logic [JW-1:0]        eng_x_addr;
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
    eng0 #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH)) u_eng0 (
        .clk(clk), .rst_n(rst_n),
        .start(e0_start), .st_zero(e0_zero), .n_modes(n_modes),
        .y_valid(e0_yv), .y_data(e0_y),
        .co_re(e0_co_re), .co_addr(e0_co_addr), .co_data(co_r),
        .st_re(e0_st_re), .st_addr(e0_st_addr),
        .st_q(st_q_r), .st_qdot(st_v_r),
        .st_we(e0_st_we), .st_waddr(e0_st_waddr),
        .st_q_wdata(e0_qwd), .st_qdot_wdata(e0_vwd),
        .x_re(e0_x_re), .x_addr(e0_x_addr), .x_data(x_r)
    );

    eng1 #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH)) u_eng1 (
        .clk(clk), .rst_n(rst_n),
        .start(e1_start), .st_zero(e1_zero), .n_modes(n_modes),
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
    logic [JW:0]          fidx;
    logic [CO_SLOT-1:0]   st_rd_idx, st_wr_idx, co_idx;

    assign co_idx    = {voi[VWID-1:0], eng_co_addr};
    assign st_rd_idx = {voi[VWID-1:0], eng_st_addr};
    assign st_wr_idx = {voi[VWID-1:0], eng_st_waddr};

    always_comb begin
        co_r.a11 = co_a11_r;  co_r.a12 = co_a12_r;  co_r.a21 = co_a21_r;
        co_r.a22 = co_a22_r;  co_r.gq  = co_gq_r;   co_r.gv  = co_gv_r;
        co_r.wo  = co_wo_r;
    end

    // x 写入：把 xmap 的第 i 项写进 {i, fidx}
    logic [$clog2(SLOTS)-1:0] xw_i;
    logic                     xw_run;

    logic [31:0]            ns_r;
    logic                   ns_vld;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            co_a11_r <= '0; co_a12_r <= '0; co_a21_r <= '0; co_a22_r <= '0;
            mod_c0_r <= '0; mod_s0_r <= '0; mod_gam_r <= '0; mod_theta0_r <= '0; mod_g_r <= '0;
            co_gq_r  <= '0; co_gv_r  <= '0; co_wo_r  <= '0;
            st_q_r   <= '0; st_v_r   <= '0; x_r      <= '0;
            ns_r     <= '0; ns_vld   <= 1'b0;
        end else begin
            ns_vld <= ns_rd_en & DEBUG_PORT;

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
                pm_c0 [{ld_idx[VWID-1:0], ld_idx[IW-1:0]}] <= ld_pm_data.c0;
                pm_s0 [{ld_idx[VWID-1:0], ld_idx[IW-1:0]}] <= ld_pm_data.s0;
                pm_gam[{ld_idx[VWID-1:0], ld_idx[IW-1:0]}] <= ld_pm_data.gam;
                pm_th [{ld_idx[VWID-1:0], ld_idx[IW-1:0]}] <= ld_pm_data.theta0;
                pm_g  [{ld_idx[VWID-1:0], ld_idx[IW-1:0]}] <= ld_pm_data.g;
            end
            // 参数表读出后**再打一拍**：否则 BSRAM 的 CLK->Q 会和调制器第一级乘法
            // 串在同一条路径上（实测 15.2 ns）。这一拍只做寄存，调制器多等一拍。
            if (mod_p_re) begin
                mod_c0_r     <= pm_c0 [{mod_slot, mod_p_mode}];
                mod_s0_r     <= pm_s0 [{mod_slot, mod_p_mode}];
                mod_gam_r    <= pm_gam[{mod_slot, mod_p_mode}];
                mod_theta0_r <= pm_th [{mod_slot, mod_p_mode}];
                mod_g_r      <= pm_g  [{mod_slot, mod_p_mode}];
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
            if (xw_run) x_ram[{xw_i, fidx[JW-1:0]}] <= xmap[xw_i];
            if (eng_x_re) x_r <= x_ram[{voi[VWID-1:0], eng_x_addr}];

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
    // 结果：每采样把各声部求和
    // =========================================================================
    logic signed [AW-1:0] y_acc;
    logic signed [AW-1:0] y_last;
    logic signed [AW-1:0] y_now;

    assign y_now = (voi == '0) ? eng_y : (y_acc + eng_y);

    // 包络：y * emap（Q1.31）>>> 31 —— 引擎逐声部串行，所以只要一个乘法器
    logic signed [95:0] y_mul;
    logic signed [63:0] y_env;
    assign y_mul = y_now * $signed(emap[voi[VWID-1:0]]);
    assign y_env = y_mul[94:31];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_acc  <= '0;
            y_last <= '0;
        end else if (eng_yv) begin
            y_acc  <= y_now;      // 帧内跨声部求和
            y_last <= y_env;      // 本声部乘过包络后的结果（给 S_ADV 写输出用）
        end
    end

    // =========================================================================
    // 作业调度：IDLE -> (LOAD) -> 每采样 [RUN_X 等 xmap -> XWR 写 16 路 -> RUN_V 跑声部] -> DONE
    // =========================================================================
    typedef enum logic [2:0] { S_IDLE, S_LOAD, S_RUN_X, S_XWR, S_RUN_V, S_MOD, S_ADV, S_DONE } st_e;
    st_e                 state;
    logic [JW:0]         ns_lat;
    instrument_e         inst_prev;
    logic                wait_xmap;

    // st_zero：note-on 首帧 或 该声部包络已归零（< ENV_ZERO_TH）时清零状态
    localparam logic [31:0] ENV_ZERO_TH = 32'd1;

    logic [SLOTS-1:0] voice_dead;
    always_comb for (int i = 0; i < SLOTS; i++)
        voice_dead[i] = (32'(emap[i]) < ENV_ZERO_TH);

    assign eng_zero = note_on[voi[VWID-1:0]] | voice_dead[voi[VWID-1:0]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            ready      <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            y_valid    <= 1'b0;
            y_data     <= '0;
            voi        <= '0;
            fidx       <= '0;
            nv_lat     <= '0;
            ns_lat     <= '0;
            nm_lat     <= '0;
            zero_lat   <= '0;
            inst_lat   <= INST_NONE;
            inst_prev  <= INST_NONE;
            sel_alt    <= 1'b0;
            eng_start  <= 1'b0;
            ld_start   <= 1'b0;
            xw_run     <= 1'b0;
            xw_i       <= '0;
            wait_xmap  <= 1'b0;
            no_clr     <= 1'b0;
            no_clr_v   <= '0;
        end else begin
            done      <= 1'b0;
            no_clr    <= 1'b0;
            y_valid   <= 1'b0;
            eng_start <= 1'b0;
            ld_start  <= 1'b0;

            case (state)
                S_IDLE: begin
                    ready <= 1'b1;
                    busy  <= 1'b0;
                    if (start) begin
                        nv_lat   <= (n_voices == 0) ? 1 : n_voices;
                        ns_lat   <= n_samples;
                        nm_lat   <= n_modes;
                        inst_lat <= inst;
                        sel_alt  <= eng_sel(inst);
                        busy     <= 1'b1;
                        ready    <= 1'b0;
                        voi      <= '0;
                        fidx     <= '0;
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
                        fidx      <= '0;
                        wait_xmap <= 1'b1;
                        state     <= S_RUN_X;
                    end
                end

                // 等 force_pre 出这一采样的 xmap（它自己按 CLK/SR 分频）
                S_RUN_X: begin
                    if (wait_xmap && xmap_valid) begin
                        wait_xmap <= 1'b0;
                        xw_i      <= '0;
                        xw_run    <= 1'b1;
                        state     <= S_XWR;
                    end
                end

                // 把 xmap 的 16 路依次写进 x_ram 的当前采样位
                S_XWR: begin
                    if (xw_i + 1'b1 >= SLOTS[$clog2(SLOTS)-1:0]) begin
                        xw_run    <= 1'b0;
                        voi       <= '0;
                        eng_start <= 1'b1;          // 第 0 个声部的作业
                        state     <= S_RUN_V;
                    end else begin
                        xw_i <= xw_i + 1'b1;
                    end
                end

                S_RUN_V: begin
                    if (eng_yv) begin
                        // y_last 由累加器那个 always_ff 一并寄存（单一驱动者）
                        if (note_on[voi[VWID-1:0]]) begin
                            mod_slot  <= voi[VWID-1:0];   // 只调这一个声部
                            mod_start <= 1'b1;
                            state     <= S_MOD;
                        end else state <= S_ADV;
                    end
                end

                S_MOD: begin
                    if (mod_done) begin
                        mod_start <= 1'b0;
                        state     <= S_ADV;
                    end
                end

                S_ADV: begin
                    if (fidx == '0) begin
                        no_clr   <= 1'b1;
                        no_clr_v <= voi[VWID-1:0];
                    end
                    if (voi + 1'b1 >= nv_lat) begin
                        y_out[fidx[JW-1:0]] <= y_last;
                        y_data  <= 64'(y_last);
                        y_valid <= 1'b1;
                        voi     <= '0;
                        if (fidx + 1'b1 >= ns_lat) begin
                            state <= S_DONE;
                        end else begin
                            fidx      <= fidx + 1'b1;
                            wait_xmap <= 1'b1;
                            state     <= S_RUN_X;
                        end
                    end else begin
                        voi       <= voi + 1'b1;
                        eng_start <= 1'b1;
                        state     <= S_RUN_V;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    ready <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
