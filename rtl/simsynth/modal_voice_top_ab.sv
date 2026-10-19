// -----------------------------------------------------------------------------
// modal_voice_top_ab.sv -- 固定角色 A/B 版（对比用）：激励（gq/gv）搬到顶层
//
// 与 modal_voice_top（单份状态、激励在引擎里）功能相同，差别只在结构：
//
//   引擎：**固定读 A、写 B**（不做原地更新，读口没有 bank 选择器）
//   顶层：**读 B、加激励、写 A** —— 每个阵列各有一个口归顶层，全程不抢
//         引擎的口，所以 gq/gv 可以从引擎里拿掉，由顶层每拍算 Δ = gq·x。
//
// 帧流水：
//   帧 f：引擎读 A（帧 f 的初态）→ 写 B（帧 f 的末态）；
//         引擎每跑完一个声部，顶层就把该声部 B → A（顺便加下一帧的激励）。
//   于是帧 f+1 的引擎读到的就是刚准备好的 A。搬运（N 拍）比引擎一个作业
//   （N+10 拍）短，错开一个声部就能完全藏在后面。
//
// 激励的定点语义与引擎内一致：Δq = (gq·x + 2^(SH-1)) >>> SH（term()），
// 因为黄金向量里没有饱和，所以"先写回再相加"与"在累加器里相加"逐位相同。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module modal_voice_top_ab #(
    parameter int   N_MODES    = 48,
    parameter int   X_DEPTH    = 256,
    parameter int   SLOTS      = 16,
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    input  logic                                     co_we,
    input  logic [$clog2(SLOTS*N_MODES)-1:0]         co_addr,
    input  modal_step_pkg::coeff_t                   co_data,

    input  logic                                     x_we,
    input  logic [$clog2(SLOTS*X_DEPTH)-1:0]         x_addr,
    input  logic signed [modal_step_pkg::XW-1:0]     x_data,

    input  logic                                     start,
    input  logic [$clog2(SLOTS+1)-1:0]               n_voices,
    input  logic [$clog2(X_DEPTH+1)-1:0]             n_samples,
    input  logic [$clog2(N_MODES+1)-1:0]             n_modes,
    input  logic [SLOTS-1:0]                         st_zero_mask,
    output logic                                     done,
    output logic                                     busy,

    input  logic                                     rd_en,
    input  logic [$clog2(X_DEPTH)-1:0]               rd_addr,
    output logic signed [modal_step_pkg::YW-1:0]     rd_data,
    output logic                                     rd_valid,

    input  logic                                     ns_rd_en,
    input  logic [$clog2(SLOTS*N_MODES)-1:0]         ns_rd_addr,
    input  logic                                     ns_rd_sel,
    output logic signed [31:0]                       ns_rd_data,
    output logic                                     ns_rd_valid
);

    import modal_step_pkg::*;

    localparam int IW     = $clog2(N_MODES);
    localparam int JW     = $clog2(X_DEPTH);
    localparam int VWID   = $clog2(SLOTS);
    localparam int CO_SLOT = $clog2(SLOTS * N_MODES);
    localparam int X_SLOT  = $clog2(SLOTS * X_DEPTH);

    // ---- 存储 -------------------------------------------------------------
    // 系数：引擎 5 个字段 + 顶层 2 个字段（gq/gv），总数与单份版相同
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo  [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq  [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv  [0:SLOTS*N_MODES-1];

    // 状态 A：引擎读、顶层写
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] qa_ram [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] va_ram [0:SLOTS*N_MODES-1];
    // 状态 B：引擎写、顶层读
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] qb_ram [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] vb_ram [0:SLOTS*N_MODES-1];

    (* syn_ramstyle = "block_ram" *) logic signed [XW-1:0] x_ram [0:SLOTS*X_DEPTH-1];
    (* syn_ramstyle = "block_ram" *) logic signed [YW-1:0] y_out [0:X_DEPTH-1];

    // ---- 引擎（5 个乘法器）------------------------------------------------
    localparam logic [$clog2(X_DEPTH+1)-1:0] ONE_SAMPLE = 1;

    logic                 e_start, e_done;
    logic                 e_co_re;
    logic [IW-1:0]        e_co_addr;
    coeff_t               e_co_data;
    logic                 e_st_re;
    logic [IW-1:0]        e_st_addr;
    logic signed [QW-1:0] e_st_q;
    logic signed [VW-1:0] e_st_qdot;
    logic                 e_st_we;
    logic [IW-1:0]        e_st_waddr;
    logic signed [QW-1:0] e_st_q_wdata;
    logic signed [VW-1:0] e_st_qdot_wdata;
    logic                 e_x_re;
    logic [JW-1:0]        e_x_addr;
    logic signed [XW-1:0] e_x_data;
    logic                 e_y_valid;
    logic signed [YW-1:0] e_y_data;

    modal_engine7 #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH), .USE_X(1'b0)) u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(e_start),
        .st_zero(1'b0),                          // 清零由顶层的初始化搬运负责
        .n_samples(ONE_SAMPLE),
        .n_modes(n_modes),
        .done(e_done),
        .co_re(e_co_re), .co_addr(e_co_addr), .co_data(e_co_data),
        .st_re(e_st_re), .st_addr(e_st_addr),
        .st_q(e_st_q), .st_qdot(e_st_qdot),
        .st_we(e_st_we), .st_waddr(e_st_waddr),
        .st_q_wdata(e_st_q_wdata), .st_qdot_wdata(e_st_qdot_wdata),
        .x_re(e_x_re), .x_addr(e_x_addr), .x_data('0),
        .y_valid(e_y_valid), .y_data(e_y_data)
    );

    // ---- 调度 -------------------------------------------------------------
    typedef enum logic [1:0] { T_IDLE, T_INIT, T_JOB, T_DONE } tstate_t;
    tstate_t          tstate;
    logic [VWID:0]    voi;
    logic [JW:0]      fidx;
    logic [VWID:0]    nv_lat;
    logic [JW:0]      nsamp_lat;
    logic [IW:0]      nmod_lat;
    logic [SLOTS-1:0] zero_lat;
    logic [SLOTS-1:0] pend;              // 哪些声部还等着"B -> A"搬运
    logic [JW-1:0]    pend_f [0:SLOTS-1]; // 每个待搬声部对应的**帧号**（激励下标）
    logic [JW-1:0]    cpy_f;              // 本次搬运锁存的帧号
    logic             want_start;
    logic [VWID:0]    job_v;             // 下一个作业的目标声部
    logic [JW:0]      job_f;

    logic [CO_SLOT-1:0] co_idx, st_rd_idx, st_wr_idx;

    assign co_idx    = {voi[VWID-1:0], e_co_addr};
    assign st_rd_idx = {voi[VWID-1:0], e_st_addr};     // 读 A
    assign st_wr_idx = {voi[VWID-1:0], e_st_waddr};    // 写 B
    assign e_st_q    = qa_r;
    assign e_st_qdot = va_r;

    // 引擎的系数口只接 5 个字段（gq/gv 由顶层用）
    always_comb begin
        e_co_data.a11 = ca_a11_r;
        e_co_data.a12 = ca_a12_r;
        e_co_data.a21 = ca_a21_r;
        e_co_data.a22 = ca_a22_r;
        e_co_data.wo  = ca_wo_r;
        e_co_data.gq  = '0;
        e_co_data.gv  = '0;
    end

    // ---- 搬运（B -> A，加激励）--------------------------------------------
    logic [VWID-1:0]  cpy_v;
    logic [IW-1:0]    cpy_m;             // 当前读的模态号
    logic [IW-1:0]    cpy_m_d;           // 上一拍读的模态号（写回用）
    logic             cpy_busy, cpy_vld_d, cpy_zero, cpy_zero_d, cpy_init_d;
    logic [VWID-1:0]  cpy_v_d;
    logic [VWID-1:0]  nxt_v;
    logic             any_pend;

    always_comb begin
        nxt_v    = '0;
        any_pend = 1'b0;
        for (int i = 0; i < SLOTS; i++) begin
            if (!any_pend && pend[i]) begin
                nxt_v    = i[VWID-1:0];
                any_pend = 1'b1;
            end
        end
    end

    wire [CO_SLOT-1:0] cpy_addr = {cpy_v, cpy_m};
    // 激励下标必须在"设 pend"的那一拍锁存：最后一帧的 pend 与 fidx 自增同拍发生
    wire [JW-1:0]      cpy_xidx = {cpy_v, cpy_f};

    // 读阶段：B、gq、gv、x 都是同步读（BSRAM 出不了异步读）
    logic signed [QW-1:0] bq_r;
    logic signed [VW-1:0] bv_r;
    logic signed [CW-1:0] gq_r, gv_r;
    logic signed [XW-1:0] xc_r;

    // 加阶段：Δ = term(x, g, SH)
    logic signed [AW-1:0] dq_c, dv_c;
    assign dq_c = term(xc_r, gq_r, SH_GQ);
    assign dv_c = term(xc_r, gv_r, SH_GV);

    // ---- 结果累加 ---------------------------------------------------------
    logic signed [AW-1:0] y_sum_acc;
    logic                 y_frame_we;
    assign y_frame_we = (tstate == T_JOB) && e_done && (voi + 1'b1 >= nv_lat);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) y_sum_acc <= '0;
        else if (e_y_valid) begin
            if (voi == '0) y_sum_acc <= e_y_data;
            else           y_sum_acc <= y_sum_acc + e_y_data;
        end
    end

    // ---- 读数据 -----------------------------------------------------------
    logic signed [CW-1:0] ca_a11_r, ca_a12_r, ca_a21_r, ca_a22_r, ca_wo_r;
    logic signed [QW-1:0] qa_r;
    logic signed [VW-1:0] va_r;
    logic signed [YW-1:0] y_rdata;
    logic [31:0]          ns_r;
    logic                 rd_valid_r, ns_rd_valid_r;

    assign rd_valid    = rd_valid_r;
    assign ns_rd_valid = ns_rd_valid_r;
    assign rd_data     = y_rdata;

    // ---- RAM 本体 ---------------------------------------------------------
    always_ff @(posedge clk) rd_valid_r <= rd_en;
    always_ff @(posedge clk) ns_rd_valid_r <= ns_rd_en & DEBUG_PORT;

    always_ff @(posedge clk) begin
        // 系数：顶层写、引擎读（5 个字段）
        if (co_we) begin
            ca_a11[co_addr] <= co_data.a11;
            ca_a12[co_addr] <= co_data.a12;
            ca_a21[co_addr] <= co_data.a21;
            ca_a22[co_addr] <= co_data.a22;
            ca_wo [co_addr] <= co_data.wo;
            ca_gq [co_addr] <= co_data.gq;
            ca_gv [co_addr] <= co_data.gv;
        end
        if (e_co_re) begin
            ca_a11_r <= ca_a11[co_idx];
            ca_a12_r <= ca_a12[co_idx];
            ca_a21_r <= ca_a21[co_idx];
            ca_a22_r <= ca_a22[co_idx];
            ca_wo_r  <= ca_wo [co_idx];
        end

        // 激励：顶层写；顶层搬运时读
        if (x_we) x_ram[x_addr] <= x_data;
        if (cpy_busy) begin
            bq_r <= qb_ram[cpy_addr];
            bv_r <= vb_ram[cpy_addr];
            gq_r <= ca_gq[cpy_addr];
            gv_r <= ca_gv[cpy_addr];
            xc_r <= x_ram[cpy_xidx];
        end

        // 状态 A：引擎读、搬运写
        if (e_st_re) begin
            qa_r <= qa_ram[st_rd_idx];
            va_r <= va_ram[st_rd_idx];
        end else if (ns_rd_en && DEBUG_PORT) begin
            ns_r <= ns_rd_sel ? va_ram[ns_rd_addr] : qa_ram[ns_rd_addr];
        end
        if (cpy_vld_d) begin
            // 初始化：清零的声部写 0，续跑的声部直接搬 B（不重复加激励）
            // 帧间：A = B + Δ（Δ 是**当前帧**的激励）
            qa_ram[{cpy_v_d, cpy_m_d}] <= cpy_init_d ? (cpy_zero_d ? '0 : bq_r)
                                                     : (bq_r + dq_c[QW-1:0]);
            va_ram[{cpy_v_d, cpy_m_d}] <= cpy_init_d ? (cpy_zero_d ? '0 : bv_r)
                                                     : (bv_r + dv_c[VW-1:0]);
        end

        // 状态 B：引擎写
        if (e_st_we) begin
            qb_ram[st_wr_idx] <= e_st_q_wdata;
            vb_ram[st_wr_idx] <= e_st_qdot_wdata;
        end

        // 结果
        if (y_frame_we) y_out[fidx[JW-1:0]] <= y_sum_acc;
        if (rd_en)      y_rdata <= y_out[rd_addr];
    end

    assign ns_rd_data = DEBUG_PORT ? ns_r : 32'sd0;

    // ---- 搬运 FSM ---------------------------------------------------------
    wire [SLOTS-1:0] set_now = e_done ? (SLOTS'(1) << voi[VWID-1:0]) : '0;
    wire [SLOTS-1:0] clr_now = (cpy_busy && ({1'b0, cpy_m} + 1'b1 >= nmod_lat))
                               ? (SLOTS'(1) << cpy_v) : '0;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpy_busy   <= 1'b0;
            cpy_zero_d <= 1'b0;
            cpy_init_d <= 1'b0;
            cpy_v     <= '0;
            cpy_m     <= '0;
            cpy_m_d   <= '0;
            cpy_v_d   <= '0;
            cpy_vld_d <= 1'b0;
            cpy_zero  <= 1'b0;
            pend      <= '0;
        end else if (start && (tstate == T_IDLE)) begin
            // 新作业开始：pend 只由本 FSM 拥有（同时作废遗留的搬运）
            pend      <= (SLOTS'(1) << n_voices) - SLOTS'(1);
            cpy_busy  <= 1'b0;
            cpy_vld_d <= 1'b0;
        end else begin
            cpy_vld_d <= 1'b0;

            // pend：新设 = 引擎刚完成一个声部；清除 = 本次搬运做完
            pend <= (pend | set_now) & ~clr_now;

            if (!cpy_busy) begin
                if (any_pend) begin
                    cpy_busy  <= 1'b1;
                    cpy_v     <= nxt_v;
                    cpy_m     <= '0;
                    cpy_f     <= (tstate == T_INIT) ? {JW{1'b0}} : pend_f[nxt_v];
                    cpy_zero  <= (tstate == T_INIT) && zero_lat[nxt_v];
                end
            end else begin
                cpy_vld_d  <= 1'b1;
                cpy_v_d    <= cpy_v;
                cpy_m_d    <= cpy_m;
                cpy_zero_d <= cpy_zero;
                cpy_init_d <= (tstate == T_INIT);
                if ({1'b0, cpy_m} + 1'b1 >= nmod_lat) begin
                    cpy_busy <= 1'b0;
                    cpy_m    <= '0;
                end else begin
                    cpy_m <= cpy_m + 1'b1;
                end
            end
        end
    end

    // ---- 作业/帧调度 -------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate    <= T_IDLE;
            voi       <= '0;
            fidx      <= '0;
            nv_lat    <= '0;
            nsamp_lat <= '0;
            nmod_lat  <= '0;
            zero_lat  <= '0;
            e_start    <= 1'b0;
            want_start <= 1'b0;
            job_v      <= '0;
            job_f      <= '0;
            done       <= 1'b0;
            busy       <= 1'b0;
        end else begin
            done    <= 1'b0;
            e_start <= 1'b0;

            case (tstate)
                T_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        nv_lat    <= (n_voices == 0) ? 1 : n_voices;
                        nsamp_lat <= n_samples;
                        nmod_lat  <= n_modes;
                        zero_lat  <= st_zero_mask;
                        voi       <= '0;
                        fidx      <= '0;
                        busy      <= 1'b1;
                        tstate    <= T_INIT;
                    end
                end

                T_INIT: begin
                    // 等初始化搬运做完（pend 清空）再开引擎
                    if (pend == '0) begin
                        e_start <= 1'b1;
                        tstate  <= T_JOB;
                    end
                end

                T_JOB: begin
                    if (e_done) begin
                        pend_f[voi[VWID-1:0]] <= fidx[JW-1:0]; // 激励下标 = 刚算完的这一帧
                        if (voi + 1'b1 >= nv_lat) begin
                            job_v <= '0;
                            if (fidx + 1'b1 >= nsamp_lat) begin
                                tstate <= T_DONE;
                            end else begin
                                job_f      <= fidx + 1'b1;
                                want_start <= 1'b1;
                            end
                        end else begin
                            job_v      <= voi + 1'b1;
                            job_f      <= fidx;
                            want_start <= 1'b1;
                        end
                    end

                    // 目标声部的 A 必须先搬完（否则引擎会读到上一帧的旧值）。
                    // want_start 比 pend 晚一拍置起，所以这里看到的一定是更新后的 pend。
                    if (want_start && !pend[job_v[VWID-1:0]]) begin
                        want_start <= 1'b0;
                        e_start    <= 1'b1;
                        voi        <= job_v;
                        fidx       <= job_f;
                    end
                end

                T_DONE: begin
                    // 等最后一帧的搬运做完，A 里才是真正的末态
                    if (pend == '0) begin
                        done   <= 1'b1;
                        busy   <= 1'b0;
                        tstate <= T_IDLE;
                    end
                end

                default: tstate <= T_IDLE;
            endcase
        end
    end

endmodule
