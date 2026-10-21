// -----------------------------------------------------------------------------
// modal_bank_ram.sv -- RAM 中心化的模态 bank：系数/状态/激励/结果都在模块内，
//                      顶层只做"装载 -> start -> done -> 读结果"
//
// 与 modal_bank_seq.sv 的区别（那条路把系数放外部 ROM、状态走旁路口）：这里模块自己
// 持有全部数据，按作业(job)自主跑完：
//
//   1. 装载（busy=0 时随时可做）：
//        co_we/co_addr/co_data    一个模态的 7 个常量（尾数 + 移位）
//        st_we/st_addr/st_q/st_v  该模态初值（击弦/拨弦前的 q、q'）
//        x_we /x_addr /x_data     本次作业的激励序列（每采样一个 32 位值）
//   2. 给 n_samples / n_modes，拉高 start（一拍）
//   3. 自主跑 n_samples 帧；每帧 = 一个采样步（N 个模态 × 7 个乘积），
//      并把 y_ram[j] = Σ_i wo_i·q_i 写进结果 RAM
//   4. done 拉高一拍；顶层读 y_ram 做最后一次移位/舍入 → 最终音频
//
// 帧内算术与 modal_bank_seq / string_mode_step 共用 modal_step_pkg，三者逐位一致。
//
// 周期：每帧 1（取 x）+ N×11（每模态：取数 1 + 三级流水乘加 9 + 写回 1）+ 1（写结果）
//       = 11N + 2 拍。100 MHz / 48 kHz 每个采样有 2083 拍，以 N=48 为例需要 530 拍，
//       余量约 3.9 倍（块处理还可以进一步降低 start/done 的频率）。
//
// 三级流水（见 op_*_q / term_q）：
//   S1 = 操作数选择（打一拍）      S2 = 乘法 + 四舍五入 + 移位（打一拍）
//   S3 = 累加到 qn/vn/y
// 因为每个乘积都是"先独立舍入再相加"，加法顺序无关，所以晚两拍累加**逐位等价**
// （黄金向量不用改）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module modal_bank_ram #(
    parameter int   N_MODES  = 32,
    parameter int   X_DEPTH  = 256,
    parameter logic SATURATE = 1'b1,
    // 验证用状态读回口。生产配置必须关掉：它多占一个读口，会让 st_ram 无法推断成
    // BSRAM（1W1R 才能进），退回成 2048 个 FF。
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                 clk,
    input  logic                                 rst_n,

    input  logic                                 co_we,
    input  logic [$clog2(N_MODES)-1:0]           co_addr,
    input  modal_step_pkg::coeff_t               co_data,

    input  logic                                 st_we,
    input  logic [$clog2(N_MODES)-1:0]           st_addr,
    input  logic signed [modal_step_pkg::QW-1:0] st_q,
    input  logic signed [modal_step_pkg::VW-1:0] st_v,

    input  logic                                 x_we,
    input  logic [$clog2(X_DEPTH)-1:0]           x_addr,
    input  logic signed [modal_step_pkg::XW-1:0] x_data,

    input  logic                                 start,
    input  logic [$clog2(X_DEPTH+1)-1:0]         n_samples,
    input  logic [$clog2(N_MODES+1)-1:0]         n_modes,
    output logic                                 done,
    output logic                                 busy,

    input  logic                                 rd_en,
    input  logic [$clog2(X_DEPTH)-1:0]           rd_addr,
    output logic signed [modal_step_pkg::YW-1:0] rd_data,
    output logic                                 rd_valid,

    // 验证/调试：空闲时读状态（帧运行期间无效）
    input  logic                                 st_rd_en,
    input  logic [$clog2(N_MODES)-1:0]           st_rd_addr,
    input  logic                                 st_rd_sel,     // 0 = q, 1 = q'
    output logic signed [31:0]                   st_rd_data,
    output logic                                 st_rd_valid
);

    import modal_step_pkg::*;

    localparam int IW = $clog2(N_MODES);
    localparam int JW = $clog2(X_DEPTH);

    // ---- 内部 RAM ---------------------------------------------------------
    // 系数按字段拆成 7 个 32 位阵列：`coeff_t` 结构体阵列（224 位一个字）Gowin 不认，
    // 会退回 FF（实测 48 模态 = 10752 个寄存器，比整条数据通路还贵）。
    (* syn_ramstyle = "block_ram" *)
    logic signed [CW-1:0] co_a11 [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [CW-1:0] co_a12 [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [CW-1:0] co_a21 [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [CW-1:0] co_a22 [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [CW-1:0] co_gq  [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [CW-1:0] co_gv  [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [CW-1:0] co_wo  [0:N_MODES-1];
    // 状态拆成两个纯向量阵列（结构体阵列 Gowin 不认，会退回 FF）
    (* syn_ramstyle = "block_ram" *)
    logic signed [QW-1:0] q_ram  [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [VW-1:0] v_ram  [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [XW-1:0] x_ram  [0:X_DEPTH-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [YW-1:0] y_ram  [0:X_DEPTH-1];

    // ---- 端口与寄存器 -----------------------------------------------------
    logic                 co_re;
    logic [IW-1:0]        co_raddr;
    coeff_t               co_rdata;
    logic signed [CW-1:0] co_a11_r, co_a12_r, co_a21_r, co_a22_r, co_gq_r, co_gv_r, co_wo_r;

    // 7 个字段拼回 coeff_t（纯连线；数据通路的算术不用改）
    always_comb begin
        co_rdata.a11 = co_a11_r;
        co_rdata.a12 = co_a12_r;
        co_rdata.a21 = co_a21_r;
        co_rdata.a22 = co_a22_r;
        co_rdata.gq  = co_gq_r;
        co_rdata.gv  = co_gv_r;
        co_rdata.wo  = co_wo_r;
    end

    logic                 st_re;
    logic [IW-1:0]        st_raddr;
    logic signed [QW-1:0] q_rdata;
    logic signed [VW-1:0] v_rdata;
    logic                 st_wen;
    logic [IW-1:0]        st_waddr;
    logic signed [QW-1:0] q_wdata;
    logic signed [VW-1:0] v_wdata;

    logic                 x_re;
    logic [JW-1:0]        x_raddr;
    logic signed [XW-1:0] x_rdata;

    logic                 y_wen;
    logic [JW-1:0]        y_waddr;
    logic signed [YW-1:0] y_wdata;
    logic                 y_re;
    logic [JW-1:0]        y_raddr;
    logic signed [YW-1:0] y_rdata;

    logic                 rd_valid_r;

    assign rd_valid = rd_valid_r;

    // ---- 作业状态 ---------------------------------------------------------
    typedef enum logic [2:0] { S_IDLE, S_X, S_REQ, S_MAC, S_WB, S_FRAME, S_DONE } state_t;
    state_t               state;
    logic [IW-1:0]        midx;
    logic [JW-1:0]        fidx;
    logic [JW:0]          n_samp_lat;
    logic [IW:0]          n_mod_lat;
    logic [3:0]           k;
    logic signed [AW-1:0] qn_acc, vn_acc, y_acc, y_sum;

    typedef enum logic [1:0] { DST_QN, DST_VN, DST_Y } dst_t;
    logic signed [XW-1:0] op_a;
    logic signed [CW-1:0] op_m;
    logic        [5:0]    op_s;   // 6 位：移位量是编译期常量，窄一点综合出的移位器更小
    dst_t                 op_dst;

    // ---- 三级流水 ---------------------------------------------------------
    //   S1（时序）：操作数选择  -> 打一拍到 op_*_q
    //   S2（时序）：乘法 + 四舍五入 + 移位 -> 打一拍到 term_q
    //   S3（时序）：把上一拍的项加到累加器（qn/vn/y）
    //
    // 为什么逐位等价：每个乘积都是**先独立舍入成整数**再相加，加法顺序无关；
    // 所以把"选择/乘/累加"拆成三级、晚两拍累加，结果完全不变（黄金向量不用改）。
    logic signed [XW-1:0] op_a_q;
    logic signed [CW-1:0] op_m_q;
    logic        [5:0]    op_s_q;
    dst_t                 op_dst_q;
    logic signed [AW-1:0] term_q;
    dst_t                 dst_q;
    logic                 sel_en;
    logic                 mult_en;

    // ---- 操作数选择（S1 的输入侧）-----------------------------------------
    always_comb begin
        // 系数/状态在 S_REQ 取地址（同步 RAM 使它们在 S_MAC 期间有效）；激励在 S_X 取。
        // 三者都不再额外锁存 —— 多锁一拍就会晚一个模态（modal_bank_seq 里踩过）。
        // k = 0..6 各选一个项；k = 7/8 只是让流水线排空。
        sel_en  = (state == S_MAC) && (k <= 4'd6);
        mult_en = (state == S_MAC) && (k >= 4'd1) && (k <= 4'd7);
        case (k)
            3'd0: begin op_a = q_rdata; op_m = co_rdata.a11; op_s = SH_A11; op_dst = DST_QN; end
            3'd1: begin op_a = v_rdata; op_m = co_rdata.a12; op_s = SH_A12; op_dst = DST_QN; end
            3'd2: begin op_a = x_rdata; op_m = co_rdata.gq;  op_s = SH_GQ; op_dst = DST_QN; end
            3'd3: begin op_a = q_rdata; op_m = co_rdata.a21; op_s = SH_A21; op_dst = DST_VN; end
            3'd4: begin op_a = v_rdata; op_m = co_rdata.a22; op_s = SH_A22; op_dst = DST_VN; end
            3'd5: begin op_a = x_rdata; op_m = co_rdata.gv;  op_s = SH_GV; op_dst = DST_VN; end
            default: begin op_a = q_rdata; op_m = co_rdata.wo; op_s = SH_WO; op_dst = DST_Y; end
        endcase
    end

    // S1 打拍
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_a_q   <= '0;
            op_m_q   <= '0;
            op_s_q   <= '0;
            op_dst_q <= DST_QN;
        end else if (sel_en) begin
            op_a_q   <= op_a;
            op_m_q   <= op_m;
            op_s_q   <= op_s;
            op_dst_q <= op_dst;
        end
    end

    // S2：乘法 + 舍入（唯一乘法器）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            term_q <= '0;
            dst_q  <= DST_QN;
        end else if (mult_en) begin
            term_q <= term(op_a_q, op_m_q, op_s_q);
            dst_q  <= op_dst_q;
        end
    end

    // ---- RAM 端口接续 -----------------------------------------------------
    always_comb begin
        co_re    = (state == S_REQ);
        co_raddr = midx;

        // 状态读口：只在 S_REQ 读当前模态（验证读回走独立端口，不共用）
        st_re    = (state == S_REQ);
        st_raddr = midx;
        st_wen   = (state == S_WB);
        st_waddr = midx;
        q_wdata  = SATURATE ? sat_q(qn_acc) : qn_acc[QW-1:0];
        v_wdata  = SATURATE ? sat_v(vn_acc) : vn_acc[VW-1:0];

        x_re    = (state == S_X);
        x_raddr = fidx;

        y_wen   = (state == S_FRAME);
        y_waddr = fidx;
        y_wdata = y_sum[YW-1:0];
        y_re    = rd_en;
        y_raddr = rd_addr;
    end

    // ---- RAM 本体 ---------------------------------------------------------
    always_ff @(posedge clk) rd_valid_r <= y_re;

    always_ff @(posedge clk) begin
        if (co_we) begin
            co_a11[co_addr] <= co_data.a11;
            co_a12[co_addr] <= co_data.a12;
            co_a21[co_addr] <= co_data.a21;
            co_a22[co_addr] <= co_data.a22;
            co_gq [co_addr] <= co_data.gq;
            co_gv [co_addr] <= co_data.gv;
            co_wo [co_addr] <= co_data.wo;
        end
        // 状态有两个写源：帧内的写回（st_wen）优先，其次是顶层装载初值
        if (st_wen) begin
            q_ram[st_waddr] <= q_wdata;
            v_ram[st_waddr] <= v_wdata;
        end else if (st_we) begin
            q_ram[st_addr]  <= st_q;
            v_ram[st_addr]  <= st_v;
        end
        if (x_we)  x_ram[x_addr]   <= x_data;
        if (y_wen) y_ram[y_waddr]  <= y_wdata;

        if (co_re) begin
            co_a11_r <= co_a11[co_raddr];
            co_a12_r <= co_a12[co_raddr];
            co_a21_r <= co_a21[co_raddr];
            co_a22_r <= co_a22[co_raddr];
            co_gq_r  <= co_gq [co_raddr];
            co_gv_r  <= co_gv [co_raddr];
            co_wo_r  <= co_wo [co_raddr];
        end
        if (st_re) begin
            q_rdata <= q_ram[st_raddr];
            v_rdata <= v_ram[st_raddr];
        end
        if (x_re)  x_rdata  <= x_ram[x_raddr];
        if (y_re)  y_rdata  <= y_ram[y_raddr];
    end

    assign rd_data = y_rdata;

    // ---- 验证读回：独立的第二个读口（DEBUG_PORT=1 时才存在；生产配置必须关掉，
    //      否则 st_ram 有 2 个读口 + 1 个写口，BSRAM 推断不出来）--------------
    generate
        if (DEBUG_PORT) begin : g_dbg
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    st_rd_valid <= 1'b0;
                    st_rd_data  <= '0;
                end else if (st_rd_en) begin
                    // 同步读：地址在沿上采，数据下一拍有效
                    st_rd_data  <= st_rd_sel ? v_ram[st_rd_addr]
                                             : q_ram[st_rd_addr];
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

    // ---- 作业状态机 -------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            midx       <= '0;
            fidx       <= '0;
            n_samp_lat <= '0;
            n_mod_lat  <= '0;
            k          <= '0;
            qn_acc     <= '0;
            vn_acc     <= '0;
            y_acc      <= '0;
            y_sum      <= '0;
            done       <= 1'b0;
            busy       <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        n_samp_lat <= n_samples;
                        n_mod_lat  <= n_modes;
                        fidx       <= '0;
                        midx       <= '0;
                        state      <= S_X;
                        busy       <= 1'b1;
                    end
                end

                S_X: begin
                    midx  <= '0;
                    state <= S_REQ;
                end

                S_REQ: begin
                    qn_acc <= '0;
                    vn_acc <= '0;
                    y_acc  <= '0;
                    k      <= '0;
                    state  <= S_MAC;
                end

                S_MAC: begin
                    // S3：把上一拍算好的项加进累加器（k=0/1 时流水线还没吐出有效项）
                    if (k >= 4'd2) begin
                        case (dst_q)
                            DST_QN:  qn_acc <= qn_acc + term_q;
                            DST_VN:  vn_acc <= vn_acc + term_q;
                            default: y_acc  <= y_acc + term_q;
                        endcase
                    end
                    if (k == 4'd8) state <= S_WB;
                    else           k     <= k + 1'b1;
                end

                S_WB: begin
                    y_sum <= (midx == '0) ? y_acc : (y_sum + y_acc);
                    if (midx + 1'b1 >= n_mod_lat[IW-1:0]) state <= S_FRAME;
                    else begin
                        midx  <= midx + 1'b1;
                        state <= S_REQ;
                    end
                end

                S_FRAME: begin
                    if (fidx + 1'b1 >= n_samp_lat[JW-1:0]) state <= S_DONE;
                    else begin
                        fidx  <= fidx + 1'b1;
                        state <= S_X;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
