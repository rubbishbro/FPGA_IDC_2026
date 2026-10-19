// -----------------------------------------------------------------------------
// modal_voice_top.sv -- 声部层：多槽存储 + 声部调度 + 状态 ping-pong
//
// 分工（引擎只算，存储和声部在这里）
//   * modal_engine7 只给"本声部内的偏移地址"，读系数/旧状态/激励，写新状态/结果；
//   * 本模块持有全部存储，地址 = {槽号, 偏移}；换声部只是换地址；
//   * 引擎不知道有几份状态、也不知道自己在读哪一份。
//
// 三块存储，每块都是 1R1W（BSRAM 最省的形态）
//   系数块  16 槽 × N 模态 × 7 字段：引擎读、**顶层写**（换音色整块刷 / note-on 写单槽）
//   状态块A/B 各 16 槽 × N 模态 × (q, q̇)：1R1W，读写主人在 A/B 之间**按帧交换**
//   激励/结果 16 槽 × 块长：引擎读 x、写 y；顶层写 x、读 y
//
// 状态的 ping-pong（每帧换一次）
//   第 f 帧：引擎读 old 块、写 new 块；帧末 pp 翻转，第 f+1 帧读刚写好的那块。
//   这样"顶层可写的那一份"永远是**引擎将要在下一帧读的那一块**，所以：
//     - note-on 清零、直接往 q/q̇ 上加激励（吉他拨弦就是 q += K，见 sim_guitar.py:159）
//       都只是往这块写，不需要引擎配合；
//     - 引擎永远不写它正在读的阵列，端口冲突在结构上就不存在。
//   代价：状态 RAM ×2（系数 224 位/模态，状态只有 64 位/模态，多出来的是小头）。
//
// 一次 start = 跑 n_samples 帧 × n_voices 个声部；**每个声部每帧一个作业**（n_samples=1），
// 因为 ping-pong 要在一帧的所有声部都算完之后才能换块。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module modal_voice_top #(
    parameter int   N_MODES    = 48,
    parameter int   X_DEPTH    = 256,
    parameter int   SLOTS      = 16,      // 声部槽数（= 同时发声上界）
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    // ---- 装载口：地址 = {槽号, 偏移} ----
    input  logic                                     co_we,
    input  logic [$clog2(SLOTS*N_MODES)-1:0]         co_addr,
    input  modal_step_pkg::coeff_t                   co_data,

    // 写"旧状态"（= 引擎下一帧要读的那一份）：note-on 清零、或直接注入激励
    input  logic                                     st_we,
    input  logic [$clog2(SLOTS*N_MODES)-1:0]         st_addr,
    input  logic signed [modal_step_pkg::QW-1:0]     st_q,
    input  logic signed [modal_step_pkg::VW-1:0]     st_qdot,

    input  logic                                     x_we,
    input  logic [$clog2(SLOTS*X_DEPTH)-1:0]         x_addr,
    input  logic signed [modal_step_pkg::XW-1:0]     x_data,

    // ---- 作业口 ----
    input  logic                                     start,
    input  logic [$clog2(SLOTS+1)-1:0]               n_voices,
    input  logic [$clog2(X_DEPTH+1)-1:0]             n_samples,
    input  logic [$clog2(N_MODES+1)-1:0]             n_modes,
    output logic                                     done,
    output logic                                     busy,
    output logic                                     pp,           // 0 = 引擎读 A，1 = 读 B

    // ---- 结果读口（**每采样一个**：各声部 Σ wo·q 的和，已由顶层累加）----
    input  logic                                     rd_en,
    input  logic [$clog2(X_DEPTH)-1:0]               rd_addr,
    output logic signed [modal_step_pkg::YW-1:0]     rd_data,
    output logic                                     rd_valid,

    // ---- 新状态读口（引擎刚写完的那一份；给后续处理/校验）----
    input  logic                                     ns_rd_en,
    input  logic [$clog2(SLOTS*N_MODES)-1:0]         ns_rd_addr,
    input  logic                                     ns_rd_sel,
    output logic signed [31:0]                       ns_rd_data,
    output logic                                     ns_rd_valid
);

    import modal_step_pkg::*;

    localparam int IW     = $clog2(N_MODES);
    localparam int JW     = $clog2(X_DEPTH);
    localparam int VWID   = $clog2(SLOTS);            // 槽号位宽（别叫 VW：包里 VW 是 q' 位宽）
    localparam int CO_SLOT = $clog2(SLOTS * N_MODES);
    localparam int X_SLOT  = $clog2(SLOTS * X_DEPTH);

    // ---- 存储 -------------------------------------------------------------
    // 系数：按字段拆成 7 个 32 位阵列（`coeff_t` 结构体阵列 Gowin 不认，会退回 FF）
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22 [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq  [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv  [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo  [0:SLOTS*N_MODES-1];

    // 状态：A / B 两份，每份 1R1W
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] qa_ram [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] va_ram [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] qb_ram [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] vb_ram [0:SLOTS*N_MODES-1];

    (* syn_ramstyle = "block_ram" *) logic signed [XW-1:0] x_ram  [0:SLOTS*X_DEPTH-1];
    // 结果不分声部存：每帧把各声部的 Σ wo·q 加起来，只存"这一个采样"的和
    (* syn_ramstyle = "block_ram" *) logic signed [YW-1:0] y_out  [0:X_DEPTH-1];

    // ---- 引擎实例 ---------------------------------------------------------
    logic                 e_start, e_done, e_busy;
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

    // 每声部每帧一个作业（ping-pong 要在一帧的所有声部算完后才能换块）
    localparam logic [$clog2(X_DEPTH+1)-1:0] ONE_SAMPLE = 1;

    modal_engine7 #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH)) u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(e_start),
        .n_samples(ONE_SAMPLE),
        .n_modes(n_modes),
        .done(e_done), .busy(e_busy),
        .co_re(e_co_re), .co_addr(e_co_addr), .co_data(e_co_data),
        .st_re(e_st_re), .st_addr(e_st_addr),
        .st_q(e_st_q), .st_qdot(e_st_qdot),
        .st_we(e_st_we), .st_waddr(e_st_waddr),
        .st_q_wdata(e_st_q_wdata), .st_qdot_wdata(e_st_qdot_wdata),
        .x_re(e_x_re), .x_addr(e_x_addr), .x_data(e_x_data),
        .y_valid(e_y_valid), .y_data(e_y_data)
    );

    // ---- 调度状态 ---------------------------------------------------------
    logic [VWID:0]   voi;              // 当前槽号（多一位便于与 n_voices 比较）
    logic [JW:0]     fidx;
    logic            bank;             // 与 pp 同义，内部名
    assign pp = bank;

    logic [CO_SLOT-1:0] co_idx, st_rd_idx, st_wr_idx;
    logic [X_SLOT-1:0]  x_idx;
    logic [JW-1:0]      x_off;
    assign co_idx    = {voi[VWID-1:0], e_co_addr};
    assign st_rd_idx = {voi[VWID-1:0], e_st_addr};
    assign st_wr_idx = {voi[VWID-1:0], e_st_waddr};
    // 每声部每帧一个作业（ping-pong 要在帧末换块），所以引擎给的 x/y 偏移只是
    // "作业内第几个采样"；帧号由顶层补上，否则每帧都会读写第 0 个采样。
    assign x_off     = fidx[JW-1:0] + e_x_addr;
    assign x_idx     = {voi[VWID-1:0], x_off};

    // ---- 调度状态 -------------------------------------------------------
    typedef enum logic [1:0] { T_IDLE, T_JOB, T_DONE } tstate_t;
    tstate_t         tstate;
    logic [VWID:0]   nv_lat;
    logic [JW:0]     nsamp_lat;

    // ---- 结果累加：每帧把各声部的 Σ wo·q 加起来（顶层"闲着"的时候干这件事）----
    logic signed [AW-1:0] y_sum_acc;
    logic                 y_frame_we;

    // 一帧的最后一个声部跑完那一拍，把本帧的和写进输出缓冲
    assign y_frame_we = (tstate == T_JOB) && e_done && (voi + 1'b1 >= nv_lat);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) y_sum_acc <= '0;
        else if (e_y_valid) begin
            if (voi == '0) y_sum_acc <= e_y_data;      // 每帧第一个声部：重置
            else           y_sum_acc <= y_sum_acc + e_y_data;
        end
    end

    // ---- 读数据 -----------------------------------------------------------
    logic signed [CW-1:0] ca_a11_r, ca_a12_r, ca_a21_r, ca_a22_r, ca_gq_r, ca_gv_r, ca_wo_r;
    logic signed [QW-1:0] qa_r, qb_r;
    logic signed [VW-1:0] va_r, vb_r;
    logic [31:0]          ns_a_r, ns_b_r;
    logic signed [XW-1:0] e_x_data_r;
    logic signed [YW-1:0] y_rdata;
    logic                 rd_valid_r, ns_rd_valid_r;

    assign rd_valid     = rd_valid_r;
    assign ns_rd_valid  = ns_rd_valid_r;
    assign e_x_data     = e_x_data_r;
    assign rd_data      = y_rdata;

    // 7 个字段拼回 coeff_t（纯连线）
    always_comb begin
        e_co_data.a11 = ca_a11_r;
        e_co_data.a12 = ca_a12_r;
        e_co_data.a21 = ca_a21_r;
        e_co_data.a22 = ca_a22_r;
        e_co_data.gq  = ca_gq_r;
        e_co_data.gv  = ca_gv_r;
        e_co_data.wo  = ca_wo_r;
    end

    // pp = 0：引擎读 A 写 B；pp = 1：引擎读 B 写 A
    assign e_st_q    = bank ? qb_r : qa_r;
    assign e_st_qdot = bank ? vb_r : va_r;

    // ---- RAM 本体 ---------------------------------------------------------
    always_ff @(posedge clk) rd_valid_r <= rd_en;
    always_ff @(posedge clk) ns_rd_valid_r <= ns_rd_en & DEBUG_PORT;

    always_ff @(posedge clk) begin
        // 系数：顶层写、引擎读（两个主人各一个端口）
        if (co_we) begin
            ca_a11[co_addr] <= co_data.a11;
            ca_a12[co_addr] <= co_data.a12;
            ca_a21[co_addr] <= co_data.a21;
            ca_a22[co_addr] <= co_data.a22;
            ca_gq [co_addr] <= co_data.gq;
            ca_gv [co_addr] <= co_data.gv;
            ca_wo [co_addr] <= co_data.wo;
        end
        if (e_co_re) begin
            ca_a11_r <= ca_a11[co_idx];
            ca_a12_r <= ca_a12[co_idx];
            ca_a21_r <= ca_a21[co_idx];
            ca_a22_r <= ca_a22[co_idx];
            ca_gq_r  <= ca_gq [co_idx];
            ca_gv_r  <= ca_gv [co_idx];
            ca_wo_r  <= ca_wo [co_idx];
        end

        // 激励 / 结果
        if (x_we)  x_ram[x_addr] <= x_data;
        if (e_x_re) e_x_data_r <= x_ram[x_idx];   // 见下方 assign
        if (y_frame_we) y_out[fidx[JW-1:0]] <= y_sum_acc;
        if (rd_en)      y_rdata <= y_out[rd_addr];

        // ---- 状态 A：pp=0 引擎读，pp=1 引擎写 ----
        if (!bank) begin
            if (e_st_re) begin
                qa_r <= qa_ram[st_rd_idx];
                va_r <= va_ram[st_rd_idx];
            end
        end else if (ns_rd_en && DEBUG_PORT) begin
            ns_a_r <= ns_rd_sel ? va_ram[ns_rd_addr] : qa_ram[ns_rd_addr];
        end
        if (bank) begin
            if (e_st_we) begin
                qa_ram[st_wr_idx] <= e_st_q_wdata;
                va_ram[st_wr_idx] <= e_st_qdot_wdata;
            end
        end else if (st_we) begin
            qa_ram[st_addr] <= st_q;
            va_ram[st_addr] <= st_qdot;
        end

        // ---- 状态 B：pp=1 引擎读，pp=0 引擎写 ----
        if (bank) begin
            if (e_st_re) begin
                qb_r <= qb_ram[st_rd_idx];
                vb_r <= vb_ram[st_rd_idx];
            end
        end else if (ns_rd_en && DEBUG_PORT) begin
            ns_b_r <= ns_rd_sel ? vb_ram[ns_rd_addr] : qb_ram[ns_rd_addr];
        end
        if (!bank) begin
            if (e_st_we) begin
                qb_ram[st_wr_idx] <= e_st_q_wdata;
                vb_ram[st_wr_idx] <= e_st_qdot_wdata;
            end
        end else if (st_we) begin
            qb_ram[st_addr] <= st_q;
            vb_ram[st_addr] <= st_qdot;
        end
    end


    // 新状态数据：pp=1 时 A 是刚写完的那份，pp=0 时是 B
    assign ns_rd_data = DEBUG_PORT ? (bank ? ns_a_r : ns_b_r) : 32'sd0;

    // ---- 声部/帧调度；每帧结束翻转 ping-pong ----
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate    <= T_IDLE;
            bank      <= 1'b0;
            voi       <= '0;
            fidx      <= '0;
            nv_lat    <= '0;
            nsamp_lat <= '0;
            e_start   <= 1'b0;
            done      <= 1'b0;
            busy      <= 1'b0;
        end else begin
            done    <= 1'b0;
            e_start <= 1'b0;

            case (tstate)
                T_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        nv_lat    <= (n_voices == 0) ? 1 : n_voices;
                        nsamp_lat <= n_samples;
                        voi       <= '0;
                        fidx      <= '0;
                        // bank **不重置**：它决定"顶层能写的是哪一份"，必须和顶层
                        // 刚才装载时用的是同一份；每次 start 重置会让装载落到另一块上。
                        e_start   <= 1'b1;
                        busy      <= 1'b1;
                        tstate    <= T_JOB;
                    end
                end

                T_JOB: begin
                    if (e_done) begin
                        if (voi + 1'b1 >= nv_lat) begin
                            voi <= '0;
                            if (fidx + 1'b1 >= nsamp_lat) begin
                                tstate <= T_DONE;
                            end else begin
                                fidx    <= fidx + 1'b1;
                                bank    <= ~bank;   // 本帧所有声部算完 -> 换块
                                e_start <= 1'b1;
                            end
                        end else begin
                            voi     <= voi + 1'b1;
                            e_start <= 1'b1;
                        end
                    end
                end

                T_DONE: begin
                    done   <= 1'b1;
                    busy   <= 1'b0;
                    tstate <= T_IDLE;
                end

                default: tstate <= T_IDLE;
            endcase
        end
    end

endmodule
