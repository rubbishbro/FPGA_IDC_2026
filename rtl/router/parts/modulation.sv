// modulation0 -- 揉弦：一次只处理**一个声部**（模态 0..n_modes-1）
//   * alpha 由 fmap_i 直接映射（内部决定）
//   * 槽号地址由 router 拼，本模块只输出模态偏移
//   * 4 个字段独立写使能，gq/gv/wo 不写
//   * **单乘法器串行**：一拍只做一次 32x32 乘法，用 step 计数复用它
//     （原来 12 个乘法器、43 个 MULT27X36；串行后只需 2 个）
//   * 每模态 47 拍（S_RD + S_W + 15×(S_LD+S_MUL+S_APPLY)）：16 声部 x 48 模态 ≈ 36k 拍，
module modulation0 #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 64,
    parameter int FS      = 48000
)(
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      start,       // 本声部更新（一拍）
    input  logic [15:0]               n_modes,
    input  logic [7:0]                fmap_i,      // 本声部压力 -> alpha
    output logic                      busy,
    output logic                      done,

    output logic                      p_re,
    output logic [$clog2(N_MODES)-1:0] p_mode,
    input  logic signed [31:0]        p_c0,
    input  logic signed [31:0]        p_s0,
    input  logic signed [31:0]        p_gam,
    input  logic signed [31:0]        p_theta0,
    input  logic signed [31:0]        p_g,
    input  logic signed [31:0]        p_k12,        // a12 的归一化系数 sq/sv
    input  logic signed [31:0]        p_k21,        // a21 的归一化系数 sv/sq

    output logic [3:0]                co_we,
    output logic [$clog2(N_MODES)-1:0] co_mode,
    output modal_step_pkg::coeff_t    co_wdata
);

    localparam signed [63:0] ONE     = 64'sd1 << 30;
    localparam signed [31:0] K_ALPHA = 32'sd123_437;      // 50 cent / 255
    localparam signed [31:0] C_GAM   = 32'sd357_913;      // 0.3413 * 2^20 = 2^30/(2^16*fs) * 2^20
    localparam signed [31:0] TH_GATE = 32'sd858_993_459;  // theta0 < 0.8 rad

    // ---- 单乘法器 ----
    logic signed [31:0] mul_a, mul_b;
    logic signed [31:0] mul_a_q, mul_b_q;               // 操作数寄存器（把路径切成两段）
    wire signed [63:0]  prod   = 64'(mul_a_q) * 64'(mul_b_q);
    logic signed [63:0] prod_q;                          // M 级：乘积寄存器

    // ---- 中间量 ----
    logic signed [31:0] alpha_q, alpha1_q, inv_a_q, alpha2_q;
    logic signed [31:0] c0_l, s0_l, gam_l, th_l, g_l, k12_l, k21_l;
    logic signed [31:0] a12_f, a21_f;
    logic signed [31:0] D_q, d_q, c_q, s_q, ea_q, a1_q, a12a_q, a12_q, t_q, pp_q, w0_q, w2_q, a21_q;

    typedef enum logic [3:0] { S_IDLE, S_RD, S_W, S_LD, S_MUL, S_APPLY } mst_e;
    mst_e st;
    logic [3:0]  step;          // 每模态内的步骤
    logic [15:0] mode;
    logic [15:0] nmod_lat;

    wire signed [31:0] alpha_delta = alpha1_q;     // alpha - 1

    assign p_re   = (st == S_RD);
    assign p_mode = mode[$clog2(N_MODES)-1:0];

    // 乘法的操作数选择（按 step）
    always_comb begin
        mul_a = c0_l; mul_b = s0_l;
        case (step)
            4'd1:  begin mul_a = alpha_delta; mul_b = th_l; end   // D
            4'd2:  begin mul_a = gam_l;       mul_b = C_GAM;    end   // d
            4'd3:  begin mul_a = s0_l;        mul_b = D_q;      end   // c
            4'd4:  begin mul_a = c0_l;        mul_b = D_q;      end   // s
            4'd5:  begin mul_a = d_q;         mul_b = c_q;      end   // ea
            4'd6:  begin mul_a = d_q;         mul_b = s_q;      end   // a1
            4'd7:  begin mul_a = a1_q;        mul_b = g_l;      end   // a1*g
            4'd8:  begin mul_a = a12a_q;      mul_b = inv_a_q;  end   // a12
            4'd9:  begin mul_a = a12_q;       mul_b = gam_l;    end   // t
            4'd10: begin mul_a = a12_q;       mul_b = alpha2_q; end   // p
            4'd11: begin mul_a = th_l;        mul_b = 32'(FS);   end   // omega0
            4'd12: begin mul_a = w0_q;        mul_b = w0_q;     end   // omega0^2
            4'd13: begin mul_a = pp_q;        mul_b = w2_q;     end   // a21
            4'd14: begin mul_a = a12_q;       mul_b = k12_l;    end   // a12 归一化
            4'd15: begin mul_a = a21_q;       mul_b = k21_l;    end   // a21 归一化
            default: ;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; step <= '0; mode <= '0; busy <= 1'b0; done <= 1'b0;
            nmod_lat <= '0;
            mul_a_q <= '0; mul_b_q <= '0; prod_q <= '0;
            alpha_q <= '0; alpha1_q <= '0; inv_a_q <= '0; alpha2_q <= '0;
            c0_l <= '0; s0_l <= '0; gam_l <= '0; th_l <= '0; g_l <= '0;
            k12_l <= '0; k21_l <= '0; a12_f <= '0; a21_f <= '0;
            D_q <= '0; d_q <= '0; c_q <= '0; s_q <= '0; ea_q <= '0; a1_q <= '0;
            a12a_q <= '0; a12_q <= '0; t_q <= '0; pp_q <= '0; w0_q <= '0; w2_q <= '0; a21_q <= '0;
            co_we <= 4'b0000; co_mode <= '0; co_wdata <= '0;
        end else begin
            done  <= 1'b0;
            co_we <= 4'b0000;

            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy     <= 1'b1;
                        mode     <= '0;
                        nmod_lat <= n_modes;
                        // alpha 相关量（每轮算一次）
                        alpha1_q <= 32'(64'(K_ALPHA) * 64'(fmap_i));            // alpha-1
                        st       <= S_RD;
                    end
                end

                // 地址给出去；router 侧参数表读出后有两级寄存器，再等一拍才稳定
                S_RD: begin
                    st <= S_W;
                end

                // 这一拍把参数锁进本地寄存器（乘法从 FF 出发，路径里不含 BSRAM 的 CLK->Q）
                S_W: begin
                    c0_l <= p_c0;  s0_l <= p_s0;  gam_l <= p_gam;
                    th_l <= p_theta0; g_l <= p_g;
                    k12_l <= p_k12;   k21_l <= p_k21;
                    alpha2_q <= 32'(ONE + 2*64'(alpha1_q) + ((64'(alpha1_q)*64'(alpha1_q)) >>> 30));
                    inv_a_q  <= 32'(ONE - 64'(alpha1_q) + ((64'(alpha1_q)*64'(alpha1_q)) >>> 30));
                    alpha_q  <= 32'(ONE + 64'(alpha1_q));
                    step     <= 4'd1;
                    st       <= S_LD;
                end

                // 操作数先寄存，乘法从 FF 出发（否则 BSRAM 的 CLK->Q 会和乘法串在一起）
                S_LD: begin
                    mul_a_q <= mul_a;
                    mul_b_q <= mul_b;
                    st      <= S_MUL;
                end

                S_MUL: begin
                    prod_q <= prod;   // 乘法单独占一拍，移位放到下一拍
                    st     <= S_APPLY;
                end

                S_APPLY: begin
                    case (step)
                        4'd1:  D_q      <= 32'(prod_q >>> 30);
                        4'd2:  d_q      <= 32'(ONE - (prod_q >>> 20));
                        4'd3:  c_q      <= 32'(64'(c0_l) - (prod_q >>> 30));
                        4'd4:  s_q      <= 32'(64'(s0_l) + (prod_q >>> 30));
                        4'd5:  ea_q     <= 32'(prod_q >>> 30);
                        4'd6:  a1_q     <= 32'(prod_q >>> 30);
                        4'd7:  a12a_q   <= 32'(prod_q >>> 30);
                        4'd8:  a12_q    <= 32'(prod_q >>> 30);
                        4'd9:  t_q      <= 32'(prod_q >>> 16);
                        4'd10: pp_q     <= 32'(prod_q >>> 30);
                        4'd11: w0_q     <= 32'(prod_q >>> 14);          // omega0 * 2^16
                        4'd12: w2_q     <= 32'((prod_q >>> 32));        // omega0^2
                        4'd13: a21_q    <= 32'(-(prod_q >>> 7));
                        4'd14: a12_f    <= 32'((prod_q >>> 30));
                        4'd15: a21_f    <= 32'((prod_q >>> 30));
                        default: ;
                    endcase

                    if (step >= 4'd15) begin
                        co_mode      <= mode[$clog2(N_MODES)-1:0];
                        co_wdata.a11 <= 32'((ea_q + t_q) >>> 2);      // Q28
                        co_wdata.a12 <= a12_f;                        // Q30（已乘 sq/sv）
                        co_wdata.a21 <= 32'(prod_q >>> 30);           // Q23（本拍刚乘完 sv/sq）
                        co_wdata.a22 <= 32'((ea_q - t_q) >>> 2);      // Q28
                        co_we <= ((th_l < TH_GATE) && (fmap_i != 8'd0)) ? 4'b1111 : 4'b0000;
                        if (mode + 1 >= nmod_lat) begin
                            done <= 1'b1; busy <= 1'b0; st <= S_IDLE;
                        end else begin
                            mode <= mode + 1'b1;
                            st   <= S_RD;
                        end
                    end else begin
                        step <= step + 1'b1;
                        st   <= S_LD;       // 下一步：先寄存操作数
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
