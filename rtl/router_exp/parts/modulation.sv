// modulation0 -- 揉弦：一次只处理**一个声部**（模态 0..n_modes-1）
//   * alpha 由 fmap_i 直接映射（内部决定）
//   * 地址（槽号）由 router 拼，本模块只输出模态偏移
//   * 4 个字段独立写使能，gq/gv/wo 不写
module modulation0 #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 48,
    parameter int FS      = 48000
)(
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic                      start,       // 本声部更新（一拍）
    input  logic [15:0]               n_modes,
    input  logic [7:0]                fmap_i,      // 本声部压力 -> alpha
    output logic                      busy,
    output logic                      done,

    // 参数表读口（模态偏移；地址 = {slot, p_mode} 由 router 拼）
    output logic                      p_re,
    output logic [$clog2(N_MODES)-1:0] p_mode,
    input  logic signed [31:0]        p_c0,
    input  logic signed [31:0]        p_s0,
    input  logic signed [31:0]        p_gam,
    input  logic signed [31:0]        p_theta0,
    input  logic signed [31:0]        p_g,

    // 系数写口（模态偏移；地址由 router 拼）
    output logic [3:0]                co_we,
    output logic [$clog2(N_MODES)-1:0] co_mode,
    output modal_step_pkg::coeff_t    co_wdata
);

    localparam signed [63:0] ONE     = 64'sd1 << 30;
    localparam signed [63:0] K_ALPHA = 64'sd123_437;      // 0.0293*2^30/255 ≈ 50 cent 满量程
    localparam int FS_C = FS;
    localparam signed [31:0] TH_GATE = 32'sd858_993_459;  // theta0 < 0.8 rad 才调制

    typedef enum logic [1:0] { M_IDLE, M_RD, M_WR, M_NEXT } mst_e;
    mst_e  st;

    logic [15:0] mode;
    logic signed [63:0] alpha_q;

    // 参数表读口：组合输出（M_RD 给地址，下一拍数据有效）
    assign p_re   = (st == M_RD);
    assign p_mode = mode[$clog2(N_MODES)-1:0];

    // 压力 -> alpha（Q1.30，直接线性映射）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) alpha_q <= ONE;
        else if (start) alpha_q <= ONE + K_ALPHA * 64'(fmap_i);
    end

    // ---- 组合计算 ----
    logic signed [63:0] inv_a, alpha2, d_q, D_q, c_q, s_q, a12_q, t_q, ea_q, a21_q, w0, w2;
    always_comb begin
        inv_a  = ONE - (alpha_q - ONE) + (((alpha_q - ONE) ** 2) >>> 30);
        alpha2 = (alpha_q * alpha_q) >>> 30;
        d_q    = ONE - ((64'(p_gam) * ONE) / (64'(65536) * FS_C));
        D_q    = (((alpha_q - ONE) * 64'(p_theta0)) >>> 30);
        c_q    = 64'(p_c0) - ((64'(p_s0) * D_q) >>> 30);
        s_q    = 64'(p_s0) + ((64'(p_c0) * D_q) >>> 30);
        ea_q   = (d_q * c_q) >>> 30;
        a12_q  = (((((d_q * s_q) >>> 30) * 64'(p_g)) >>> 30) * inv_a) >>> 30;
        t_q    = (a12_q * 64'(p_gam)) >>> 16;
        w0     = (64'(p_theta0) * FS_C) >>> 14;       // omega0 * 2^16
        w2     = (w0 * w0) >>> 16;                    // omega0^2 * 2^16
        a21_q  = -(((((a12_q * w2) >>> 36) * alpha2) >>> 10));
    end

    wire signed [31:0] a11_w = 32'((ea_q + t_q) >>> 2);       // Q28
    wire signed [31:0] a22_w = 32'((ea_q - t_q) >>> 2);       // Q28
    wire signed [31:0] a12_w = 32'(a12_q);                    // Q30
    wire signed [31:0] a21_w = 32'(a21_q >>> 7);              // Q23
    wire               gate  = (p_theta0 < TH_GATE) && (fmap_i != 8'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= M_IDLE; mode <= '0; busy <= 1'b0; done <= 1'b0;
            co_we <= 4'b0000; co_mode <= '0; co_wdata <= '0;
        end else begin
            done <= 1'b0; co_we <= 4'b0000;
            case (st)
                M_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1; mode <= '0; st <= M_RD;
                    end
                end
                M_RD: begin
                    // 读口是组合输出（见上面的 assign）：本拍给地址，下一拍数据有效
                    st <= M_WR;
                end
                M_WR: begin
                    co_mode <= mode[$clog2(N_MODES)-1:0];
                    co_wdata.a11 <= a11_w;
                    co_wdata.a12 <= a12_w;
                    co_wdata.a21 <= a21_w;
                    co_wdata.a22 <= a22_w;
                    co_we <= gate ? 4'b1111 : 4'b0000;
                    st    <= M_NEXT;
                end
                M_NEXT: begin
                    if (mode + 1 >= n_modes) begin
                        done <= 1'b1; busy <= 1'b0; st <= M_IDLE;
                    end else begin
                        mode <= mode + 1'b1;
                        st   <= M_RD;
                    end
                end
                default: st <= M_IDLE;
            endcase
        end
    end
endmodule
