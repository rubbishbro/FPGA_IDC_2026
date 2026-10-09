// -----------------------------------------------------------------------------
// body_filter.sv -- 共享 4-section（8 阶）body-filter 加速器。
//
// 流水线版本。算术运算和所有状态值与先前的
// 单周期实现逐位相同；只有调度改变了。
// 100 MHz 的失败路径是
//     operand mux -> (sec*5 address MULT) -> coefficient mux -> 68x32 multiply
//     -> 100-bit product -> 104-bit accumulate -> round/clamp -> state
// 全在一个周期内。现在被拆分：
//
//   * 移除了 section*5 动态地址乘法器：一个寄存的
//     `tap_idx` 计数器（0..19）选择系数，一个独立的
//     寄存 `tap`（0..4）选择操作数。没有算术地址。
//   * 每个 tap 三个寄存级：S_OP（锁存 op_s/op_c）、S_MUL（寄存
//     精确的 (64+G)+32 位乘积）、S_ACC（将符号扩展后的
//     乘积加/减到 104 位累加器）。乘法和 104 位加法
//     绝不在同一周期。
//   * 逐 section 的舍入也被流水化，因此 clamp/compare 链不
//     在累加器周期内：S_RNDA 寄存 (acc+2**29)>>30，S_RNDB
//     寄存 signed(64+G) clamp，S_UPD 更新 section 历史，并且
//     （仅最后一个 section）S_FIN 完成 Q(30+G)->Q30 折叠和 signed64 clamp。
//     然后是 S_OUT。
//
// 20 taps * 3 cycles + 4 * (3 round/update stages) + final + output = ~74
// cycles（< 128）。各级之间不引入中间舍入、clamp 或
// 回绕：乘积和累加器是精确的宽
// 整数，因此帧结果与 DFI golden 逐位相同。
//
// 数值契约（rtl/body_design.md 第 2 节，guard-bit 变体）：
//   * coefficients    : signed Q2.30，32 位
//   * external x / y  : signed 64 位，Q30（与 modal mix_sum 同标度）
//   * internal state  : signed (64+G) 位，Q(30+G)；G = GUARD_BITS（默认 4）
//   * product         : (64+G)+32 位，符号扩展进 >= 104 位的 acc
//   * Direct Form I，sections 按 SOS 顺序，一次一个 order-2 section：
//         xin = in_sum << G
//         acc = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2
//         y   = clamp_s(64+G)( (acc + 2**29) >>> 30 )          # Q(30+G)
//     只有最后一个 section 折回引脚：
//         raw = (y + 2**(G-1)) >>> G
//         out = clamp_s64(raw);  其饱和值 OR 进 out_sat[3]
//
// 握手 / 优先级（未变）：
//   * reset（rst_n，异步）在任何流水线级取消进行中的帧
//     清除每个历史寄存器并重新运行 ROM preload；
//     没有幽灵 out_valid 能存活。
//   * clear_valid/clear_ready 只清除历史（和饱和
//     记录）并保留系数；仅在空闲时被接受，并优先
//     于同时出现的 in_valid。
//   * in_valid/in_ready 仅在 idle 状态接受一个采样；当帧
//     在途时 in_ready 为低，因此保持的 in_valid 不会成为第二个输入。
//   * out_valid 是单周期，无 backpressure。
//
// 同步 ROM preload 仅在选择乐器的全部 20 个字
// 都被捕获后才拉高 coeff_ready。如果 init 文件缺失或
// 过短，iverilog 会在 ROM 中留下 X；preload 检测到它并停留在
// S_ERR（coeff_error=1，coeff_ready=0），而不是伪造一个有效的全零滤波器。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module body_filter #(
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
