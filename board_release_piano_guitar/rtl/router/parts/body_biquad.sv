`timescale 1ns/1ps
// =============================================================================
// 文件 : body_biquad.sv
// 模块 : body_biquad
// 功能 : 乐器腔体滤波器 —— NSEC 段 biquad 串联（吉他 5 段）
//        段数少的乐器由 body_router 在末尾补直通段（b0 = 1.0，其余 0），
//        所以"全直通"就是默认配置：输出 == 输入。
// 系数 : 由 body_router 按乐器给常量，Q4.27（1.0 = 1 << COEFF_FRAC）。
//        符号约定 y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2（a1/a2 给正值）。
// 定点 : 输入/输出 signed 64；内部状态 = 输入量纲再多 GUARD_BITS 个小数位。
//          每段   acc = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2   (Q(C+G) 精度)
//                 y   = (acc + 2**(C-1)) >>> C                  (舍入回 Q(G))
//          末段   out = (y + 2**(G-1)) >>> G                     (回到输入量纲)
//        所有二进制点只由 COEFF_FRAC / GUARD_BITS 决定，没有散落的 2**N。
// 时序 : 每个 tap 3 拍（S_OP 取操作数 / S_MUL 乘 / S_ACC 累加），乘法与 104 位
//        加法绝不同拍；段间 S_RNDA / S_RNDB / S_UPD，末段后 S_FIN / S_OUT。
//        一个样本 NSEC*NTAP*3 + 3*NSEC + 3 拍 = 93 拍（NSEC=5），期间 in_ready=0。
//
// 历史状态放 RAM（不是寄存器阵列）：
//   原来是 x1/x2/y1/y2 四个 5 项寄存器阵列 = 4*5*68 = 1360 个 FF。面积一大，
//   PnR 就会把它摊开，"sec -> 5:1 读 mux -> 4 组 5:1 写 demux -> FF"成了整条
//   路径上的最坏项（实测 13~17 ns，同一份 RTL 见过 85/58/76 MHz 三个数）。
//   现在改成一块小 RAM（NSEC 项 × 4*SW 位 = 5 x 272）：
//     * 段开始前把这一项读进 h_rd（LR 每段一次，读在 S_RNDB / 接受样本那拍发）
//     * 段末把 {x1',x2',y1',y2'} 一次写回同一项
//     * 一拍读延迟被"tap0 只用 sec_x"天然吸收，所以总拍数还是 93
//   RAM 宽度 272 位，会落成 8 个 BSRAM（深度只要 5，浪费一点但换时序值）。
//
// 清历史（clear）也不再"逐项写 0"：置 clr_run，跑一遍段循环、期间历史读作 0，
// 写完最后一段时 clr_run 落、状态即干净（和 eng0 的 st_zero / comb_reverb 的
// clr_run 一个套路）。这一遍不产生输出，也不接收新样本（in_ready=0）。
// =============================================================================
module body_biquad #(
    parameter int NSEC       = 5,
    parameter int NTAP       = 5,
    parameter int COEFF_FRAC = 27,                     // 系数 Q4.27
    parameter int GUARD_BITS = 4                       // 内部额外小数位（>= 1）
) (
    input  logic                               clk,
    input  logic                               rst_n,

    // 清历史（换乐器）：系数保留。忙时挂起，回到空闲再执行，不丢样本。
    input  logic                               clear,

    // 采样输入（in_valid && in_ready 一拍握手）
    input  logic                               in_valid,
    output logic                               in_ready,
    input  logic signed [63:0]                 in_sum,

    // 系数（Q4.COEFF_FRAC），由 body_router 给：coef_q[s*NTAP + t]
    input  logic signed [NSEC*NTAP-1:0][31:0]   coef_q,

    // 采样输出（单拍脉冲，无 backpressure）
    output logic                               out_valid,
    output logic signed [63:0]                 out_sum,
    output logic [NSEC-1:0]                    out_sat,    // bit s = 第 s 段饱和过
    output logic [2:0]                         sat_count   // 本样本饱和段数
);

    localparam int SW     = 64 + GUARD_BITS;       // 状态 / 级间宽度（68）
    localparam int ACC_W  = SW + 36;               // 累加器（104）
    localparam int FSW    = SW + 1;                // 末段 +2**(G-1) 的进位空间（69）
    localparam int HW     = 4 * SW;                // RAM 一项的宽度（272）

    localparam int TAPW = $clog2(NSEC * NTAP);     // 系数下标宽度（25 -> 5）
    localparam int SECW = $clog2(NSEC);            // 段号宽度（5 -> 3）

    localparam logic [3:0] S_IDLE = 4'd0,
                           S_OP   = 4'd1,
                           S_MUL  = 4'd2,
                           S_ACC  = 4'd3,
                           S_RNDA = 4'd4,
                           S_RNDB = 4'd5,
                           S_UPD  = 4'd6,
                           S_FIN  = 4'd7,
                           S_OUT  = 4'd8;

    // ------------------------------------------------------------------
    // 历史状态 RAM：一项 = {y2, y1, x2, x1}，NSEC 项 x 272 位
    //   读地址也要打拍：综合器只认"地址寄存器 + 输出寄存器"这种形状，
    //   直接写 hist[sec+1] 会被打回寄存器阵列（实测 REG 3000+，一点没省）。
    // ------------------------------------------------------------------
    (* syn_ramstyle = "block_ram" *) logic [HW-1:0] hist [0:NSEC-1];
    logic [HW-1:0]   h_rd;                        // RAM 读出口
    logic [SECW-1:0] nx_sec;                      // 下一个要读的段号
    logic [SECW-1:0] raddr;                       // RAM 读地址（打一拍）

    // 清历史：期间读出的历史当 0，写完最后一段后自动落
    logic clr_run;

    logic signed [SW-1:0] h_x1, h_x2, h_y1, h_y2;
    always_comb begin
        h_x1 = clr_run ? '0 : h_rd[1*SW-1:0];
        h_x2 = clr_run ? '0 : h_rd[2*SW-1:1*SW];
        h_y1 = clr_run ? '0 : h_rd[3*SW-1:2*SW];
        h_y2 = clr_run ? '0 : h_rd[4*SW-1:3*SW];
    end

    // 逐段饱和记录：一次移位一段（UPD 只做移位，不做 sec==N 比较）
    logic [NSEC-1:0] sat_sr;

    // ------------------------------------------------------------------
    // 流水线控制
    // ------------------------------------------------------------------
    logic [3:0]           state;
    logic [SECW-1:0]      sec;
    logic [2:0]           tap;
    logic [TAPW-1:0]      tap_idx;
    logic signed [SW-1:0] sec_x;

    logic signed [SW-1:0] op_s;
    logic signed [31:0]   op_c;
    logic                 op_sub;

    logic signed [SW-1:0]  op_s_r;
    logic signed [31:0]    op_c_r;
    logic                  op_sub_r;
    logic signed [SW+31:0] prod_r;                 // SW=68 时 100 位
    logic signed [ACC_W-1:0] acc;

    // 操作数选择：tap0 只用本级输入，1..4 用 RAM 读出来的历史
    always_comb begin
        op_c   = coef_q[tap_idx];
        op_s   = sec_x;
        op_sub = 1'b0;
        case (tap)
            3'd1:    op_s = h_x1;
            3'd2:    op_s = h_x2;
            3'd3: begin op_s = h_y1; op_sub = 1'b1; end
            3'd4: begin op_s = h_y2; op_sub = 1'b1; end
            default: op_s = sec_x;
        endcase
    end

    logic signed [ACC_W-1:0] prodx_r;
    logic signed [ACC_W-1:0] acc_nxt;
    assign prodx_r = {{(ACC_W-(SW+32)){prod_r[SW+31]}}, prod_r};
    assign acc_nxt = op_sub_r ? (acc - prodx_r) : (acc + prodx_r);

    // ------------------------------------------------------------------
    // 二进制点常数（全部由 COEFF_FRAC / GUARD_BITS 推出）
    // ------------------------------------------------------------------
    localparam logic signed [63:0] ROUND_C64 =
        fxp_pkg::fx_from_int(64'sd1, COEFF_FRAC - 1);
    localparam logic signed [ACC_W-1:0] ROUND_C =
        {{(ACC_W-64){ROUND_C64[63]}}, ROUND_C64};

    localparam logic signed [ACC_W-1:0] TWO_SW1 =
        {{(ACC_W-1){1'b0}}, 1'b1} <<< (SW-1);
    localparam logic signed [ACC_W-1:0] Y_MAX = TWO_SW1 - 1'b1;
    localparam logic signed [ACC_W-1:0] Y_MIN = -TWO_SW1;
    localparam logic signed [SW-1:0] STATE_MAX = {1'b0, {(SW-1){1'b1}}};
    localparam logic signed [SW-1:0] STATE_MIN = {1'b1, {(SW-1){1'b0}}};

    // stage A：舍入 + 定位（由 acc 组合，在 S_RNDA 寄存）
    logic signed [ACC_W-1:0] rounded_c;
    assign rounded_c = (acc + ROUND_C) >>> COEFF_FRAC;
    logic signed [ACC_W-1:0] rounded_r;

    // stage B：signed(64+G) clamp（由 rounded_r 组合）
    logic                 sat68_c;
    logic signed [SW-1:0] y_state_c;
    always_comb begin
        if (rounded_r > Y_MAX) begin
            y_state_c = STATE_MAX;
            sat68_c   = 1'b1;
        end else if (rounded_r < Y_MIN) begin
            y_state_c = STATE_MIN;
            sat68_c   = 1'b1;
        end else begin
            y_state_c = rounded_r[SW-1:0];
            sat68_c   = 1'b0;
        end
    end
    logic                 sat68_r;
    logic signed [SW-1:0] y_state_r;

    // S_RNDB 把本段的 x1/y1 从 h_* 存下来（S_UPD 时 h_rd 已经换成下一段的值了，
    // 所以这两个寄存器是功能上必须的，不会被综合器合并掉）
    logic signed [SW-1:0] cur_x1, cur_y1;

    // stage C：末段的 Q(G) -> 输入量纲折叠（由 y_state_r 组合）
    localparam logic signed [63:0] FINAL_RND64 =
        fxp_pkg::fx_from_int(64'sd1, GUARD_BITS - 1);
    localparam logic signed [FSW-1:0] FINAL_RND =
        {{(FSW-64){FINAL_RND64[63]}}, FINAL_RND64};
    localparam logic signed [FSW-1:0] TWO63_F =
        {{(FSW-1){1'b0}}, 1'b1} <<< 63;
    localparam logic signed [FSW-1:0] OUT_MAX = TWO63_F - 1'b1;
    localparam logic signed [FSW-1:0] OUT_MIN = -TWO63_F;

    logic signed [FSW-1:0] y_plus_c;
    logic signed [FSW-1:0] rawf_c;
    logic                 sat_final_c;
    logic signed [63:0]   y_final_c;
    assign y_plus_c = y_state_r + FINAL_RND;
    assign rawf_c   = y_plus_c >>> GUARD_BITS;
    always_comb begin
        if (rawf_c > OUT_MAX) begin
            y_final_c   = 64'sh7FFFFFFFFFFFFFFF;
            sat_final_c = 1'b1;
        end else if (rawf_c < OUT_MIN) begin
            y_final_c   = 64'sh8000000000000000;
            sat_final_c = 1'b1;
        end else begin
            y_final_c   = rawf_c[63:0];
            sat_final_c = 1'b0;
        end
    end

    // 输出暂存 + 饱和段数
    logic signed [63:0] yout;
    logic        [2:0]  sat_cnt_c;
    always_comb begin
        sat_cnt_c = 3'd0;
        for (int i = 0; i < NSEC; i++)
            sat_cnt_c = sat_cnt_c + {2'b0, sat_sr[i]};
    end

    // ------------------------------------------------------------------
    // 握手：clear 是单拍脉冲，忙时挂起到回空闲那拍执行
    // ------------------------------------------------------------------
    logic clear_pend;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)               clear_pend <= 1'b0;
        else if (state == S_IDLE) clear_pend <= 1'b0;  // 空闲拍当拍就能清，不用挂
        else if (clear)           clear_pend <= 1'b1;
    end

    assign in_ready = (state == S_IDLE) && !(clear || clear_pend) && !clr_run;

    // 下一段读哪一项（最后一段之后回 0，下一次接受样本时会重读）
    assign nx_sec = (sec == SECW'(NSEC-1)) ? '0 : (sec + 1'b1);

    // ------------------------------------------------------------------
    // 序列器
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            out_valid <= 1'b0;
            out_sum   <= 64'sd0;
            out_sat   <= '0;
            sat_count <= 3'd0;
            sat_sr    <= '0;
            sec       <= '0;
            tap       <= 3'd0;
            tap_idx   <= '0;
            sec_x     <= '0;
            op_s_r    <= '0;
            op_c_r    <= 32'sd0;
            op_sub_r  <= 1'b0;
            prod_r    <= '0;
            acc       <= '0;
            rounded_r <= '0;
            y_state_r <= '0;
            sat68_r   <= 1'b0;
            cur_x1    <= '0;
            cur_y1    <= '0;
            yout      <= 64'sd0;
            h_rd      <= '0;
            raddr     <= '0;
            clr_run   <= 1'b1;      // 复位后第一次跑的是"清历史"那一遍
        end else begin
            out_valid <= 1'b0;
            h_rd      <= hist[raddr];       // RAM 读：地址寄存器 -> 输出寄存器

            case (state)
                // ------------------------------------------------
                S_IDLE: begin
                    if (clear || clear_pend || clr_run) begin
                        // 清历史：跑一遍段循环，历史读作 0，写完就干净了
                        clr_run  <= 1'b1;
                        sec      <= '0;
                        tap      <= 3'd0;
                        tap_idx  <= '0;
                        acc      <= '0;
                        op_sub_r <= 1'b0;
                        sat_sr   <= '0;
                        sec_x    <= '0;
                        raddr    <= '0;
                        state    <= S_OP;
                    end else if (in_valid) begin
                        // 先做 (64+G) 位符号扩展再移位，完整 signed64 输入不被截断
                        clr_run  <= 1'b0;
                        sec_x    <= {{GUARD_BITS{in_sum[63]}}, in_sum} <<< GUARD_BITS;
                        sec      <= '0;
                        tap      <= 3'd0;
                        tap_idx  <= '0;
                        acc      <= '0;
                        op_sub_r <= 1'b0;
                        sat_sr   <= '0;
                        raddr    <= '0;
                        state    <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_OP: begin
                    op_c_r   <= coef_q[tap_idx];
                    op_s_r   <= op_s;
                    op_sub_r <= op_sub;
                    state    <= S_MUL;
                end

                // ------------------------------------------------
                S_MUL: begin
                    prod_r <= op_c_r * op_s_r;
                    state  <= S_ACC;
                end

                // ------------------------------------------------
                S_ACC: begin
                    acc     <= acc_nxt;
                    tap_idx <= (tap_idx == (NSEC*NTAP-1)) ? '0 : tap_idx + 1'b1;
                    if (tap == (NTAP - 1)) begin
                        tap   <= 3'd0;
                        state <= S_RNDA;
                    end else begin
                        tap   <= tap + 3'd1;
                        state <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_RNDA: begin
                    rounded_r <= rounded_c;
                    state     <= S_RNDB;
                end

                S_RNDB: begin
                    y_state_r <= y_state_c;
                    sat68_r   <= sat68_c;
                    cur_x1    <= h_x1;          // 本段的旧历史存下来
                    cur_y1    <= h_y1;
                    raddr     <= nx_sec;        // 下一段：地址先打拍，h_rd 下一拍跟上
                    state     <= S_UPD;
                end

                // ------------------------------------------------
                S_UPD: begin
                    // 一次写回 {y2', y1', x2', x1'}
                    hist[sec] <= {cur_y1, y_state_r, cur_x1, sec_x};
                    sat_sr    <= {sat68_r, sat_sr[NSEC-1:1]};
                    if (sec == SECW'(NSEC - 1)) begin
                        if (clr_run) begin
                            clr_run <= 1'b0;    // 全部覆盖过一遍，状态干净
                            state   <= S_IDLE;
                        end else begin
                            state <= S_FIN;
                        end
                    end else begin
                        sec_x <= y_state_r;
                        sec   <= sec + 1'b1;
                        acc   <= '0;
                        state <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_FIN: begin
                    yout                <= y_final_c;
                    sat_sr[NSEC-1]      <= sat_sr[NSEC-1] | sat_final_c;
                    state               <= S_OUT;
                end

                // ------------------------------------------------
                S_OUT: begin
                    out_valid <= 1'b1;
                    out_sum   <= yout;
                    out_sat   <= sat_sr;
                    sat_count <= sat_cnt_c;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
