// -----------------------------------------------------------------------------
// modal_voice_top.sv -- 声部层：多槽存储 + 声部调度（单份状态，无 ping-pong）
//
// 分工（引擎只算，存储和声部在这里）
//   * modal_engine7 只给"本声部内的偏移地址"，读系数/状态/激励，写回状态、输出结果流；
//   * 本模块持有全部存储，地址 = {槽号, 偏移}；换声部只是换地址；
//   * 引擎不知道有几份状态、也不知道自己在读哪一块。
//
// 四块存储，全部 1R1W
//   系数块   SLOTS 槽 × N 模态 × 7 字段：引擎读、**顶层写**（换音色整块刷 / note-on 写单槽）
//   状态块   SLOTS 槽 × N 模态 × (q, q̇)：**引擎独占读+写**（原地更新：读 ri、写 ri-4，不撞）
//   激励块   SLOTS 槽 × 块长：引擎读、顶层写
//   结果缓冲 1 块 × 块长：引擎只给流，顶层每帧把各声部求和后写入
//
// 为什么不再需要 ping-pong：顶层**不写状态**了。note-on 的清零改成引擎内的
// `st_zero` 清零 pass（N 拍，一次性），于是状态块只有一个主人（引擎），
// 1R1W 就够，交换/搬运/bank 选择器全部消失。
//
// 一次 start = 跑 n_samples 帧 × n_voices 个声部；每声部每帧一个作业（n_samples=1）。
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

    input  logic                                     x_we,
    input  logic [$clog2(SLOTS*X_DEPTH)-1:0]         x_addr,
    input  logic signed [modal_step_pkg::XW-1:0]     x_data,

    // ---- 作业口 ----
    input  logic                                     start,
    input  logic [$clog2(SLOTS+1)-1:0]               n_voices,
    input  logic [$clog2(X_DEPTH+1)-1:0]             n_samples,
    input  logic [$clog2(N_MODES+1)-1:0]             n_modes,
    input  logic [SLOTS-1:0]                         st_zero_mask,  // 哪些槽是"新音符"（首作业清状态）
    output logic                                     done,
    output logic                                     busy,

    // ---- 结果读口（**每采样一个**：各声部 Σ wo·q 的和）----
    input  logic                                     rd_en,
    input  logic [$clog2(X_DEPTH)-1:0]               rd_addr,
    output logic signed [modal_step_pkg::YW-1:0]     rd_data,
    output logic                                     rd_valid,

    // ---- 状态读口（空闲时读；给后续处理/校验）----
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

    // 状态：单份，引擎独占读 + 写
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram [0:SLOTS*N_MODES-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram [0:SLOTS*N_MODES-1];

    (* syn_ramstyle = "block_ram" *) logic signed [XW-1:0] x_ram [0:SLOTS*X_DEPTH-1];
    // 结果不分声部存：每帧把各声部的 Σ wo·q 加起来，只存"这一个采样"的和
    (* syn_ramstyle = "block_ram" *) logic signed [YW-1:0] y_out [0:X_DEPTH-1];

    // ---- 引擎实例 ---------------------------------------------------------
    logic                 e_start, e_st_zero;
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

    modal_engine7 #(.N_MODES(N_MODES), .X_DEPTH(X_DEPTH)) u_eng (
        .clk(clk), .rst_n(rst_n),
        .start(e_start),
        .st_zero(e_st_zero),
        .n_modes(n_modes),
        .co_re(e_co_re), .co_addr(e_co_addr), .co_data(e_co_data),
        .st_re(e_st_re), .st_addr(e_st_addr),
        .st_q(e_st_q), .st_qdot(e_st_qdot),
        .st_we(e_st_we), .st_waddr(e_st_waddr),
        .st_q_wdata(e_st_q_wdata), .st_qdot_wdata(e_st_qdot_wdata),
        .x_re(e_x_re), .x_addr(e_x_addr), .x_data(e_x_data),
        .y_valid(e_y_valid), .y_data(e_y_data)
    );

    // ---- 调度状态 ---------------------------------------------------------
    typedef enum logic [1:0] { T_IDLE, T_JOB, T_DONE } tstate_t;
    tstate_t          tstate;
    logic [VWID:0]    voi;             // 当前槽号（多一位便于与 n_voices 比较）
    logic [JW:0]      fidx;
    logic [VWID:0]    nv_lat;
    logic [JW:0]      nsamp_lat;
    logic [SLOTS-1:0] zero_lat;

    logic [CO_SLOT-1:0] co_idx, st_rd_idx, st_wr_idx;
    logic [X_SLOT-1:0]  x_idx;
    logic [JW-1:0]      x_off;

    assign co_idx    = {voi[VWID-1:0], e_co_addr};
    assign st_rd_idx = {voi[VWID-1:0], e_st_addr};
    assign st_wr_idx = {voi[VWID-1:0], e_st_waddr};
    // 每声部每帧一个作业，引擎给的 x 偏移只是"作业内第几个采样"；帧号由顶层补
    assign x_off     = fidx[JW-1:0] + e_x_addr;
    assign x_idx     = {voi[VWID-1:0], x_off};

    // 只在"该声部的第一帧"清状态：每帧是一个独立作业，否则每帧都会把状态清掉
    assign e_st_zero = zero_lat[voi[VWID-1:0]] && (fidx == '0);

    // ---- 读数据 -----------------------------------------------------------
    logic signed [CW-1:0] ca_a11_r, ca_a12_r, ca_a21_r, ca_a22_r, ca_gq_r, ca_gv_r, ca_wo_r;
    logic signed [QW-1:0] q_r;
    logic signed [VW-1:0] v_r;
    logic signed [XW-1:0] e_x_data_r;
    logic signed [YW-1:0] y_rdata;
    logic [31:0]          ns_r;
    logic                 rd_valid_r, ns_rd_valid_r;

    assign rd_valid    = rd_valid_r;
    assign ns_rd_valid = ns_rd_valid_r;
    assign e_x_data    = e_x_data_r;
    assign rd_data     = y_rdata;

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

    assign e_st_q    = q_r;
    assign e_st_qdot = v_r;

    // ---- 结果累加：每帧把各声部的 Σ wo·q 加起来 ----
    logic signed [AW-1:0] y_sum_acc;
    logic                 y_frame_we;

    assign y_frame_we = (tstate == T_JOB) && e_y_valid && (voi + 1'b1 >= nv_lat);
    // y_valid 那一拍既是"本声部结果有效"也是"作业结束"，所以写出去的和要把本拍这一路也算进去
    wire signed [AW-1:0] y_now = (voi == '0) ? e_y_data : (y_sum_acc + e_y_data);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) y_sum_acc <= '0;
        else if (e_y_valid) begin
            if (voi == '0) y_sum_acc <= e_y_data;      // 每帧第一个声部：重置
            else           y_sum_acc <= y_sum_acc + e_y_data;
        end
    end

    // ---- RAM 本体 ---------------------------------------------------------
    always_ff @(posedge clk) rd_valid_r <= rd_en;
    always_ff @(posedge clk) ns_rd_valid_r <= ns_rd_en & DEBUG_PORT;

    always_ff @(posedge clk) begin
        // 系数：顶层写、引擎读
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

        // 激励：顶层写、引擎读
        if (x_we)   x_ram[x_addr] <= x_data;
        if (e_x_re) e_x_data_r <= x_ram[x_idx];

        // 结果：引擎给流，顶层每帧写一次和
        if (y_frame_we) y_out[fidx[JW-1:0]] <= y_now;
        if (rd_en)      y_rdata <= y_out[rd_addr];

        // 状态：唯一的写口在引擎侧；读口在"引擎读"和"顶层读回"之间分时
        if (e_st_we) begin
            q_ram[st_wr_idx] <= e_st_q_wdata;
            v_ram[st_wr_idx] <= e_st_qdot_wdata;
        end
        if (e_st_re) begin
            q_r <= q_ram[st_rd_idx];
            v_r <= v_ram[st_rd_idx];
        end else if (ns_rd_en && DEBUG_PORT) begin
            ns_r <= ns_rd_sel ? v_ram[ns_rd_addr] : q_ram[ns_rd_addr];
        end
    end

    assign ns_rd_data = DEBUG_PORT ? ns_r : 32'sd0;

    // ---- 声部/帧调度 -------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate    <= T_IDLE;
            voi       <= '0;
            fidx      <= '0;
            nv_lat    <= '0;
            nsamp_lat <= '0;
            zero_lat  <= '0;
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
                        zero_lat  <= st_zero_mask;   // 锁存：本作业里哪些槽要清状态
                        voi       <= '0;
                        fidx      <= '0;
                        e_start   <= 1'b1;
                        busy      <= 1'b1;
                        tstate    <= T_JOB;
                    end
                end

                T_JOB: begin
                    if (e_y_valid) begin
                        if (voi + 1'b1 >= nv_lat) begin
                            voi <= '0;
                            if (fidx + 1'b1 >= nsamp_lat) begin
                                tstate <= T_DONE;
                            end else begin
                                fidx    <= fidx + 1'b1;
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
