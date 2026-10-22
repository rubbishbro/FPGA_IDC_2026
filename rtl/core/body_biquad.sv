// =============================================================================
// 文件 : body_biquad.sv
// 模块 : body_biquad
// 功能 : 4-section body biquad 滤波器
// 说明 : 系数来自 ROM；逐样本 valid/ready；输出饱和统计。
// =============================================================================
`timescale 1ns/1ps

module body_biquad #(
    parameter int BODY_INSTRUMENT = 0,             // 0..3 吉他/钢琴/班卓琴/曼陀林
    parameter BODY_FILE = "rtl/rom/body_coeff.mem",
    parameter int GUARD_BITS = 4                   // 内部额外小数位（>=1）
) (
    input  logic               clk,
    input  logic               rst_n,

    // 同步历史清除（仅在空闲时接受，保留系数）
    input  logic               clear_valid,
    output logic               clear_ready,

    // 采样输入
    input  logic               in_valid,
    output logic               in_ready,
    input  logic signed [63:0] in_sum,

    // 采样输出（单周期，无 backpressure）
    output logic               out_valid,
    output logic signed [63:0] out_sum,
    output logic [3:0]         out_sat,
    output logic [2:0]         sat_count,

    // ROM / 系数诊断
    output logic               coeff_ready,
    output logic               coeff_error
);

    localparam int NSEC   = 4;
    localparam int NTAP   = 5;
    localparam int ROM_WORDS = 80;
    localparam int COEFF_FRAC = 30;

    localparam int SW     = 64 + GUARD_BITS;       // 内部状态 / 级间宽度
    localparam int ACC_W  = SW + 36;               // SW=68 时为 104（要求 >= 100）
    localparam int FSW    = SW + 1;                // 为最终 +2**(G-1) 留出的空间

    // 对（静态）instrument 做掩码，使非法参数无法越界索引 ROM；
    // 错误仍会在下方报告。
    localparam int BASE = (BODY_INSTRUMENT & 3) * (NSEC * NTAP);

    localparam logic [3:0] S_PRE  = 4'd0,
                           S_IDLE = 4'd1,
                           S_OP   = 4'd2,
                           S_MUL  = 4'd3,
                           S_ACC  = 4'd4,
                           S_RNDA = 4'd5,
                           S_RNDB = 4'd6,
                           S_UPD  = 4'd7,
                           S_FIN  = 4'd8,
                           S_OUT  = 4'd9,
                           S_ERR  = 4'd10;

    // ------------------------------------------------------------------
    // 系数 ROM + 捕获的系数
    // ------------------------------------------------------------------
    logic [31:0]        rom [0:ROM_WORDS-1];
    logic signed [31:0] coef [0:NSEC*NTAP-1];

    initial begin
        $readmemh(BODY_FILE, rom);
    end

    logic [4:0] pre_idx;
    logic [3:0] state;

    // X 检测是仿真保护：缺失/过短的 init 文件不能
    // 伪装成有效的全零滤波器。真实综合没有 X，因此
    // 该保护会被编译消除。
`ifdef SYNTHESIS
    wire pre_bad = 1'b0;
`else
    wire pre_bad = $isunknown(rom[BASE + pre_idx]);
`endif

    // ------------------------------------------------------------------
    // 历史状态（逐 section），内部 Q(30+GUARD_BITS)
    // ------------------------------------------------------------------
    logic signed [SW-1:0] x1 [0:NSEC-1];
    logic signed [SW-1:0] x2 [0:NSEC-1];
    logic signed [SW-1:0] y1 [0:NSEC-1];
    logic signed [SW-1:0] y2 [0:NSEC-1];

    // 逐 section 饱和记录，一次移位一个 section（从关键控制路径中
    // 移除 sec==N 时钟使能比较器；经过四个 S_UPD 级后
    // bit s 最终保存 section s 的标志）
    logic [NSEC-1:0] sat_sr;

    // ------------------------------------------------------------------
    // 流水线控制
    // ------------------------------------------------------------------
    logic [1:0]           sec;
    logic [2:0]           tap;
    logic [4:0]           tap_idx;
    logic signed [SW-1:0] sec_x;

    logic signed [SW-1:0] op_s;
    logic signed [31:0]   op_c;
    logic                 op_sub;

    logic signed [SW-1:0]  op_s_r;
    logic signed [31:0]    op_c_r;
    logic                  op_sub_r;
    logic signed [SW+31:0] prod_r;                 // SW=68 时为 100 位
    logic signed [ACC_W-1:0] acc;

    // 操作数选择：仅使用寄存的 tap/sec，无地址算术
    always_comb begin
        op_c   = coef[tap_idx];
        op_s   = sec_x;
        op_sub = 1'b0;
        case (tap)
            3'd1:    op_s = x1[sec];
            3'd2:    op_s = x2[sec];
            3'd3: begin op_s = y1[sec]; op_sub = 1'b1; end
            3'd4: begin op_s = y2[sec]; op_sub = 1'b1; end
            default: op_s = sec_x;
        endcase
    end

    logic signed [ACC_W-1:0] prodx_r;
    logic signed [ACC_W-1:0] acc_nxt;
    assign prodx_r = {{(ACC_W-(SW+32)){prod_r[SW+31]}}, prod_r};
    assign acc_nxt = op_sub_r ? (acc - prodx_r) : (acc + prodx_r);

    // ------------------------------------------------------------------
    // 舍入 / clamp 流水线（精确，算术未变）
    // ------------------------------------------------------------------
    localparam logic signed [ACC_W-1:0] ROUND_C =
        {{(ACC_W-30){1'b0}}, 30'd536870912};                 // 2**29
    localparam logic signed [ACC_W-1:0] TWO_SW1 =
        {{(ACC_W-1){1'b0}}, 1'b1} <<< (SW-1);
    localparam logic signed [ACC_W-1:0] Y_MAX = TWO_SW1 - 1'b1;
    localparam logic signed [ACC_W-1:0] Y_MIN = -TWO_SW1;
    localparam logic signed [SW-1:0] STATE_MAX = {1'b0, {(SW-1){1'b1}}};
    localparam logic signed [SW-1:0] STATE_MIN = {1'b1, {(SW-1){1'b0}}};

    // stage A：舍入加法（由 acc 组合，在 S_RNDA 寄存）
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

    // stage C：最后 section 的 Q(30+G) -> Q30 折叠（由 y_state_r 组合）
    localparam logic signed [FSW-1:0] FINAL_RND =
        {{(FSW-GUARD_BITS){1'b0}}, {1'b1, {(GUARD_BITS-1){1'b0}}}};
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

    // 输出暂存
    logic signed [63:0] yout;

    // ------------------------------------------------------------------
    // 握手
    // ------------------------------------------------------------------
    assign clear_ready = (state == S_IDLE) && coeff_ready;
    assign in_ready    = (state == S_IDLE) && coeff_ready && !clear_valid;

    // ------------------------------------------------------------------
    // 序列器
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_PRE;
            pre_idx     <= 5'd0;
            coeff_ready <= 1'b0;
            coeff_error <= 1'b0;
            out_valid   <= 1'b0;
            out_sum     <= 64'sd0;
            out_sat     <= 4'd0;
            sat_count   <= 3'd0;
            sat_sr      <= {NSEC{1'b0}};
            sec         <= 2'd0;
            tap         <= 3'd0;
            tap_idx     <= 5'd0;
            sec_x       <= {SW{1'b0}};
            op_s_r      <= {SW{1'b0}};
            op_c_r      <= 32'sd0;
            op_sub_r    <= 1'b0;
            prod_r      <= {(SW+32){1'b0}};
            acc         <= {ACC_W{1'b0}};
            rounded_r   <= {ACC_W{1'b0}};
            y_state_r   <= {SW{1'b0}};
            sat68_r     <= 1'b0;
            yout        <= 64'sd0;
            for (int i = 0; i < NSEC; i = i + 1) begin
                x1[i] <= {SW{1'b0}};
                x2[i] <= {SW{1'b0}};
                y1[i] <= {SW{1'b0}};
                y2[i] <= {SW{1'b0}};
            end
        end else begin
            out_valid <= 1'b0;

            case (state)
                // ------------------------------------------------
                S_PRE: begin
                    if ((BODY_INSTRUMENT < 0) || (BODY_INSTRUMENT > 3)) begin
                        coeff_error <= 1'b1;
                        state       <= S_ERR;
                    end else if (pre_bad) begin
                        coeff_error <= 1'b1;
                        state       <= S_ERR;
                    end else begin
                        coef[pre_idx] <= rom[BASE + pre_idx];
                        if (pre_idx == (NSEC * NTAP - 1)) begin
                            coeff_ready <= 1'b1;
                            state       <= S_IDLE;
                        end else begin
                            pre_idx <= pre_idx + 5'd1;
                        end
                    end
                end

                // ------------------------------------------------
                S_ERR: state <= S_ERR;

                // ------------------------------------------------
                S_IDLE: begin
                    if (clear_valid) begin
                        for (int i = 0; i < NSEC; i = i + 1) begin
                            x1[i] <= {SW{1'b0}};
                            x2[i] <= {SW{1'b0}};
                            y1[i] <= {SW{1'b0}};
                            y2[i] <= {SW{1'b0}};
                        end
                        sat_sr <= {NSEC{1'b0}};
                    end else if (in_valid) begin
                        // 在 guard 移位前显式进行 (64+G) 位符号扩展，
                        // 这样完整的 signed64 输入不会被截断
                        sec_x    <= {{GUARD_BITS{in_sum[63]}}, in_sum}
                                    <<< GUARD_BITS;
                        sec      <= 2'd0;
                        tap      <= 3'd0;
                        tap_idx  <= 5'd0;
                        acc      <= {ACC_W{1'b0}};
                        op_sub_r <= 1'b0;
                        sat_sr   <= {NSEC{1'b0}};
                        state    <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_OP: begin
                    op_c_r   <= coef[tap_idx];
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
                    // 将系数索引保持在 0..19：绝不形成 sec*5，
                    // 也绝不越界读取系数数组
                    tap_idx <= (tap_idx == (NSEC * NTAP - 1)) ? 5'd0
                                                              : tap_idx + 5'd1;
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
                    state     <= S_UPD;
                end

                // ------------------------------------------------
                S_UPD: begin
                    x2[sec]    <= x1[sec];
                    x1[sec]    <= sec_x;
                    y2[sec]    <= y1[sec];
                    y1[sec]    <= y_state_r;
                    // 将 section 的饱和标志移位到位；CE 不再依赖
                    // section 计数器
                    sat_sr     <= {sat68_r, sat_sr[NSEC-1:1]};
                    if (sec == (NSEC - 1)) begin
                        state    <= S_FIN;
                    end else begin
                        sec_x      <= y_state_r;
                        sec        <= sec + 2'd1;
                        acc        <= {ACC_W{1'b0}};
                        state      <= S_OP;
                    end
                end

                // ------------------------------------------------
                S_FIN: begin
                    yout     <= y_final_c;
                    sat_sr[3] <= sat_sr[3] | sat_final_c;
                    state    <= S_OUT;
                end

                // ------------------------------------------------
                S_OUT: begin
                    out_valid <= 1'b1;
                    out_sum   <= yout;
                    out_sat   <= sat_sr;
                    sat_count <= sat_sr[0] + sat_sr[1] + sat_sr[2] + sat_sr[3];
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
