// -----------------------------------------------------------------------------
// modal_voice_top.sv -- 声部/ping-pong 层（ARCH_PARALLEL7.md 第 8 节 B）
//
// 分工（就是文档里那句"引擎只读、声部由顶层负责"）：
//   * 引擎（modal_engine7）**只有计算**：它给出本声部内的偏移地址，读系数/状态/激励，
//     写回状态和结果；它不知道有几个声部、也不知道 A/B 哪一份在跑。
//   * 本模块持有**全部存储**：两份物理阵列 A/B，每份 VOICES 个常驻声部槽位；
//     地址 = {bank, 声部号, 偏移}，其中 bank/声部号由这里拼上去。
//     ⇒ 切声部只是换地址高位，不需要重新装载，引擎也不用停。
//
// ping-pong
// ---------
//   * 装载口（co_we/st_we/x_we）的地址自带 bank 位，顶层应当装**非活动**的那一份；
//     两份阵列各有自己的写口，所以"引擎写回状态"和"装载另一份"可以同拍发生
//     （单份阵列只有一个写口，那样装载会被写回吃掉 —— 这是拆成两份物理阵列的原因）。
//   * `start` 时若 `swap_en=1`，整个作业换到另一份上跑；运行期间 `run_bank` 指向
//     正在跑的那一份，顶层照它读结果、往 `~run_bank` 装下一批声部。
//
// 作业粒度
// --------
//   一次 start = 顺序跑 `n_voices` 个声部，每个声部 `n_samples` 帧。
//   8 声部 × 48 模态 × 1 帧 = 8 × 56 = 448 拍（预算 2083 的 21.5%）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module modal_voice_top #(
    parameter int   N_MODES    = 48,
    parameter int   X_DEPTH    = 256,
    parameter int   VOICES     = 8,
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    // ---- 装载口：地址 = {bank, 声部号, 偏移} ----
    input  logic                                     co_we,
    input  logic [$clog2(2*VOICES*N_MODES)-1:0]      co_addr,
    input  modal_step_pkg::coeff_t                   co_data,

    input  logic                                     st_we,
    input  logic [$clog2(2*VOICES*N_MODES)-1:0]      st_addr,
    input  logic signed [modal_step_pkg::QW-1:0]     st_q,
    input  logic signed [modal_step_pkg::VW-1:0]     st_v,

    input  logic                                     x_we,
    input  logic [$clog2(2*VOICES*X_DEPTH)-1:0]      x_addr,
    input  logic signed [modal_step_pkg::XW-1:0]     x_data,

    // ---- 作业口 ----
    input  logic                                     start,
    input  logic [$clog2(VOICES+1)-1:0]              n_voices,
    input  logic [$clog2(X_DEPTH+1)-1:0]             n_samples,
    input  logic [$clog2(N_MODES+1)-1:0]             n_modes,
    input  logic                                     swap_en,      // 1 = 本次作业换一份 bank
    output logic                                     run_bank,     // 当前/刚跑完的 bank
    output logic                                     done,
    output logic                                     busy,

    // ---- 结果读口：地址 = {bank, 声部号, 采样号} ----
    input  logic                                     rd_en,
    input  logic [$clog2(2*VOICES*X_DEPTH)-1:0]      rd_addr,
    output logic signed [modal_step_pkg::YW-1:0]     rd_data,
    output logic                                     rd_valid,

    // ---- 验证/调试：空闲时读状态（地址 = {bank, 声部号, 模态号}）----
    input  logic                                     st_rd_en,
    input  logic [$clog2(2*VOICES*N_MODES)-1:0]      st_rd_addr,
    input  logic                                     st_rd_sel,    // 0 = q, 1 = q'
    output logic signed [31:0]                       st_rd_data,
    output logic                                     st_rd_valid
);

    import modal_step_pkg::*;

    localparam int IW     = $clog2(N_MODES);
    localparam int JW     = $clog2(X_DEPTH);
    localparam int VWID   = $clog2(VOICES);          // 声部号位宽（别叫 VW：包里 VW 是 q' 位宽）
    localparam int CO_SLOT = $clog2(VOICES * N_MODES);
    localparam int X_SLOT  = $clog2(VOICES * X_DEPTH);
    localparam int CO_BNK  = CO_SLOT;                // 地址最高位是 bank
    localparam int X_BNK   = X_SLOT;

    // ---- 两份物理阵列 -----------------------------------------------------
    // 系数**按字段拆成 7 个 32 位阵列**，不用 `coeff_t` 结构体阵列：
    // 结构体阵列（一个"字"224 位）Gowin 不认，综合日志里只有 q/v/x/y 有
    // "Extracting RAM"，co_* 没有 ⇒ 直接退回 FF（实测 +25k 寄存器、布线 6530 条布不通）。
    // 拆成 7 个 32 位阵列后每个都是标准的 1W1R，能进 BSRAM。
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] cb_a11 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] cb_a12 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] cb_a21 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] cb_a22 [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] cb_gq  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] cb_gv  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] cb_wo  [0:VOICES*N_MODES-1];

    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram_a  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram_b  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram_a  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram_b  [0:VOICES*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [XW-1:0] x_ram_a  [0:VOICES*X_DEPTH-1];
    (* syn_ramstyle = "block_ram" *) logic signed [XW-1:0] x_ram_b  [0:VOICES*X_DEPTH-1];
    (* syn_ramstyle = "block_ram" *) logic signed [YW-1:0] y_ram_a  [0:VOICES*X_DEPTH-1];
    (* syn_ramstyle = "block_ram" *) logic signed [YW-1:0] y_ram_b  [0:VOICES*X_DEPTH-1];

    // ---- 引擎实例 ---------------------------------------------------------
    logic                 bank_r;                    // 0 = A, 1 = B
    logic [VWID:0]        voi;                       // 当前声部（多一位，便于与 nv_lat 比较）
    assign run_bank = bank_r;

    logic                 e_start;
    logic                 e_done;
    logic                 e_busy;
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
    logic                 e_y_we;
    logic [JW-1:0]        e_y_addr;
    logic signed [YW-1:0] e_y_data;

    logic [IW:0]          n_mod_lat;
    logic [JW:0]          n_samp_lat;
    logic [VWID:0]        nv_lat;

    modal_engine7 #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH)) u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(e_start),
        .n_samples(n_samp_lat), .n_modes(n_mod_lat[$clog2(N_MODES+1)-1:0]),
        .done(e_done), .busy(e_busy),
        .co_re(e_co_re), .co_addr(e_co_addr), .co_data(e_co_data),
        .st_re(e_st_re), .st_addr(e_st_addr),
        .st_q(e_st_q), .st_qdot(e_st_qdot),
        .st_we(e_st_we), .st_waddr(e_st_waddr),
        .st_q_wdata(e_st_q_wdata), .st_qdot_wdata(e_st_qdot_wdata),
        .x_re(e_x_re), .x_addr(e_x_addr), .x_data(e_x_data),
        .y_we(e_y_we), .y_addr(e_y_addr), .y_data(e_y_data)
    );

    // ---- 地址拼接：{声部号, 引擎偏移} -------------------------------------
    logic [CO_SLOT-1:0]   co_idx, st_rd_idx, st_wr_idx;
    logic [X_SLOT-1:0]    x_idx, y_wr_idx, y_rd_idx;

    assign co_idx     = {voi[VWID-1:0], e_co_addr};
    assign st_rd_idx  = {voi[VWID-1:0], e_st_addr};
    assign st_wr_idx  = {voi[VWID-1:0], e_st_waddr};
    assign x_idx      = {voi[VWID-1:0], e_x_addr};
    assign y_wr_idx   = {voi[VWID-1:0], e_y_addr};
    assign y_rd_idx   = rd_addr[X_SLOT-1:0];

    // ---- 读：两份各自同步读出，再按 bank 选 ---------------------------------
    logic signed [CW-1:0] ca_a11_r, ca_a12_r, ca_a21_r, ca_a22_r, ca_gq_r, ca_gv_r, ca_wo_r;
    logic signed [CW-1:0] cb_a11_r, cb_a12_r, cb_a21_r, cb_a22_r, cb_gq_r, cb_gv_r, cb_wo_r;
    logic signed [QW-1:0] q_ra, q_rb;
    logic signed [VW-1:0] v_ra, v_rb;
    logic signed [XW-1:0] x_ra, x_rb;
    logic signed [YW-1:0] y_ra, y_rb;
    logic                 y_rd_bank;
    logic                 rd_valid_r;

    assign y_rd_bank = rd_addr[X_BNK];
    assign rd_valid  = rd_valid_r;

    // 7 个字段读回来后再拼成 coeff_t（这一步是纯连线，不产生存储）
    always_comb begin
        e_co_data.a11 = bank_r ? cb_a11_r : ca_a11_r;
        e_co_data.a12 = bank_r ? cb_a12_r : ca_a12_r;
        e_co_data.a21 = bank_r ? cb_a21_r : ca_a21_r;
        e_co_data.a22 = bank_r ? cb_a22_r : ca_a22_r;
        e_co_data.gq  = bank_r ? cb_gq_r  : ca_gq_r;
        e_co_data.gv  = bank_r ? cb_gv_r  : ca_gv_r;
        e_co_data.wo  = bank_r ? cb_wo_r  : ca_wo_r;
    end
    assign e_st_q    = bank_r ? q_rb  : q_ra;
    assign e_st_qdot = bank_r ? v_rb  : v_ra;
    assign e_x_data  = bank_r ? x_rb  : x_ra;
    assign rd_data   = y_rd_bank ? y_rb : y_ra;

    // ---- RAM 本体 ---------------------------------------------------------
    always_ff @(posedge clk) rd_valid_r <= rd_en;

    always_ff @(posedge clk) begin
        // 系数：只有装载口写（A/B 各一个写口）
        if (co_we && !co_addr[CO_BNK]) begin
            ca_a11[co_addr[CO_SLOT-1:0]] <= co_data.a11;
            ca_a12[co_addr[CO_SLOT-1:0]] <= co_data.a12;
            ca_a21[co_addr[CO_SLOT-1:0]] <= co_data.a21;
            ca_a22[co_addr[CO_SLOT-1:0]] <= co_data.a22;
            ca_gq [co_addr[CO_SLOT-1:0]] <= co_data.gq;
            ca_gv [co_addr[CO_SLOT-1:0]] <= co_data.gv;
            ca_wo [co_addr[CO_SLOT-1:0]] <= co_data.wo;
        end
        if (co_we && co_addr[CO_BNK]) begin
            cb_a11[co_addr[CO_SLOT-1:0]] <= co_data.a11;
            cb_a12[co_addr[CO_SLOT-1:0]] <= co_data.a12;
            cb_a21[co_addr[CO_SLOT-1:0]] <= co_data.a21;
            cb_a22[co_addr[CO_SLOT-1:0]] <= co_data.a22;
            cb_gq [co_addr[CO_SLOT-1:0]] <= co_data.gq;
            cb_gv [co_addr[CO_SLOT-1:0]] <= co_data.gv;
            cb_wo [co_addr[CO_SLOT-1:0]] <= co_data.wo;
        end

        // 状态：A、B 各自的写口独立判断（引擎写活动的一份 = 计算侧写回）
        if (e_st_we && !bank_r) begin
            q_ram_a[st_wr_idx] <= e_st_q_wdata;
        end else if (st_we && !st_addr[CO_BNK]) begin
            q_ram_a[st_addr[CO_SLOT-1:0]] <= st_q;
        end
        if (e_st_we && bank_r) begin
            q_ram_b[st_wr_idx] <= e_st_q_wdata;
        end else if (st_we && st_addr[CO_BNK]) begin
            q_ram_b[st_addr[CO_SLOT-1:0]] <= st_q;
        end
        if (e_st_we && !bank_r) begin
            v_ram_a[st_wr_idx] <= e_st_qdot_wdata;
        end else if (st_we && !st_addr[CO_BNK]) begin
            v_ram_a[st_addr[CO_SLOT-1:0]] <= st_v;
        end
        if (e_st_we && bank_r) begin
            v_ram_b[st_wr_idx] <= e_st_qdot_wdata;
        end else if (st_we && st_addr[CO_BNK]) begin
            v_ram_b[st_addr[CO_SLOT-1:0]] <= st_v;
        end

        // 激励
        if (x_we) begin
            if (x_addr[X_BNK]) x_ram_b[x_addr[X_SLOT-1:0]] <= x_data;
            else               x_ram_a[x_addr[X_SLOT-1:0]] <= x_data;
        end

        // 结果（只有引擎写）
        if (e_y_we) begin
            if (bank_r) y_ram_b[y_wr_idx] <= e_y_data;
            else        y_ram_a[y_wr_idx] <= e_y_data;
        end

        // 读口
        if (e_co_re) begin
            ca_a11_r <= ca_a11[co_idx];
            ca_a12_r <= ca_a12[co_idx];
            ca_a21_r <= ca_a21[co_idx];
            ca_a22_r <= ca_a22[co_idx];
            ca_gq_r  <= ca_gq [co_idx];
            ca_gv_r  <= ca_gv [co_idx];
            ca_wo_r  <= ca_wo [co_idx];
            cb_a11_r <= cb_a11[co_idx];
            cb_a12_r <= cb_a12[co_idx];
            cb_a21_r <= cb_a21[co_idx];
            cb_a22_r <= cb_a22[co_idx];
            cb_gq_r  <= cb_gq [co_idx];
            cb_gv_r  <= cb_gv [co_idx];
            cb_wo_r  <= cb_wo [co_idx];
        end
        if (e_st_re) begin
            q_ra <= q_ram_a[st_rd_idx];
            q_rb <= q_ram_b[st_rd_idx];
            v_ra <= v_ram_a[st_rd_idx];
            v_rb <= v_ram_b[st_rd_idx];
        end
        if (e_x_re) begin
            x_ra <= x_ram_a[x_idx];
            x_rb <= x_ram_b[x_idx];
        end
        if (rd_en) begin
            y_ra <= y_ram_a[y_rd_idx];
            y_rb <= y_ram_b[y_rd_idx];
        end
    end

    // ---- 验证读回（独立第二读口）------------------------------------------
    generate
        if (DEBUG_PORT) begin : g_dbg
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    st_rd_valid <= 1'b0;
                    st_rd_data  <= '0;
                end else if (st_rd_en) begin
                    if (st_rd_addr[CO_BNK])
                        st_rd_data <= st_rd_sel ? v_ram_b[st_rd_addr[CO_SLOT-1:0]]
                                                : q_ram_b[st_rd_addr[CO_SLOT-1:0]];
                    else
                        st_rd_data <= st_rd_sel ? v_ram_a[st_rd_addr[CO_SLOT-1:0]]
                                                : q_ram_a[st_rd_addr[CO_SLOT-1:0]];
                    st_rd_valid <= 1'b1;
                end else begin
                    st_rd_valid <= 1'b0;
                end
            end
        end else begin : g_nodbg
            assign st_rd_valid = 1'b0;
            assign st_rd_data  = '0;
        end
    endgenerate

    // ---- 声部调度：一次 start = n_voices 个作业（每个声部 n_samples 帧）-----
    typedef enum logic [1:0] { T_IDLE, T_RUN, T_DONE } tstate_t;
    tstate_t      tstate;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate     <= T_IDLE;
            bank_r     <= 1'b0;
            voi        <= '0;
            e_start    <= 1'b0;
            nv_lat     <= '0;
            n_mod_lat  <= '0;
            n_samp_lat <= '0;
            done       <= 1'b0;
            busy       <= 1'b0;
        end else begin
            done    <= 1'b0;
            e_start <= 1'b0;

            case (tstate)
                T_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        n_samp_lat <= n_samples;
                        n_mod_lat  <= n_modes;
                        nv_lat     <= (n_voices == 0) ? 1 : n_voices;
                        voi        <= '0;
                        // 起跑瞬间换 bank：这次整个作业跑另一份
                        if (swap_en) bank_r <= ~bank_r;
                        e_start    <= 1'b1;
                        busy       <= 1'b1;
                        tstate     <= T_RUN;
                    end
                end

                T_RUN: begin
                    if (e_done) begin
                        if (voi + 1'b1 >= nv_lat) begin
                            tstate <= T_DONE;
                        end else begin
                            voi     <= voi + 1'b1;
                            e_start <= 1'b1;   // 下一拍引擎已回到 IDLE
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
