// modulation0 -- 揉弦：按 alpha 改写 a11/a12/a21/a22（纯乘法，无除法/超越函数）
//   read-modify-write：读整条记录，只替换 4 个字段，gq/gv/wo 原样写回
module modulation0 #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 48,
    parameter int FS      = 48000
)(
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             start,
    input  logic [SLOTS-1:0]                 active,
    input  logic signed [31:0]               alpha_q,     // Q1.30
    input  logic [15:0]                      n_modes,
    output logic                             busy,
    output logic                             done,

    // 调制参数表读口（5 字段）
    output logic                             p_re,
    output logic [$clog2(SLOTS*N_MODES)-1:0] p_addr,
    input  logic signed [31:0]               p_c0,
    input  logic signed [31:0]               p_s0,
    input  logic signed [31:0]               p_gam,       // Q16.16
    input  logic signed [31:0]               p_theta0,    // Q1.30
    input  logic signed [31:0]               p_g,         // Q1.30 = dt/theta0

    // 系数块：读原记录 + 写新记录（同一地址）
    output logic                             co_re,
    output logic                             co_we,
    output logic [$clog2(SLOTS*N_MODES)-1:0] co_addr,
    input  modal_step_pkg::coeff_t           co_data,
    output modal_step_pkg::coeff_t           co_wdata
);

    localparam signed [63:0] ONE = 64'sd1 << 30;
    localparam int FS_C = FS;
    localparam signed [31:0] TH_GATE = 32'sd858_993_459;   // 0.8 rad

    typedef enum logic [1:0] { M_IDLE, M_RD, M_WR, M_NEXT } mst_e;
    mst_e  st;

    logic [15:0] slot, mode;
    logic [31:0] idx;
    logic [SLOTS-1:0] act;
    logic        skip;

    assign skip = !act[slot];

    // 读口是组合输出：M_RD 给地址 -> 下一拍（M_WR）数据有效
    assign p_re    = (st == M_RD) && !skip;
    assign co_re   = (st == M_RD) && !skip;
    assign p_addr  = idx[$clog2(SLOTS*N_MODES)-1:0];
    assign co_addr = idx[$clog2(SLOTS*N_MODES)-1:0];

    // ---- 组合计算 ----
    logic signed [63:0] inv_a, alpha2, d_q, D_q, c_q, s_q, a12_q, t_q, ea_q, a21_q, w0, w2;
    always_comb begin
        inv_a  = ONE - (64'(alpha_q) - ONE) + (((64'(alpha_q) - ONE) ** 2) >>> 30);
        alpha2 = (64'(alpha_q) * 64'(alpha_q)) >>> 30;
        d_q    = ONE - ((64'(p_gam) * ONE) / (64'(65536) * FS_C));
        D_q    = (((64'(alpha_q) - ONE) * 64'(p_theta0)) >>> 30);
        c_q    = 64'(p_c0) - ((64'(p_s0) * D_q) >>> 30);
        s_q    = 64'(p_s0) + ((64'(p_c0) * D_q) >>> 30);
        ea_q   = (d_q * c_q) >>> 30;
        a12_q  = (((((d_q * s_q) >>> 30) * 64'(p_g)) >>> 30) * inv_a) >>> 30;
        t_q    = (a12_q * 64'(p_gam)) >>> 16;
        // w0 保留 Q10（直接取整会带来 0.04% 误差，平方后 0.08% ≈ 0.9 音分）
        w0     = (64'(p_theta0) * FS_C) >>> 14;      // omega0 * 2^16（截断误差会平方放大，必须留够）
        w2     = (w0 * w0) >>> 16;                   // omega0^2 * 2^16
        // a21 = -a12*alpha^2*omega0^2：u = 2^10*a12*w0^2，再乘 alpha^2 后 >>10 回 Q30
        a21_q  = -(((((a12_q * w2) >>> 36) * alpha2) >>> 10));
    end

    // 各字段的 Q 不同：a11/a22 是 Q28、a12 是 Q30、a21 是 Q23
    wire signed [31:0] a11_w = 32'((ea_q + t_q) >>> 2);
    wire signed [31:0] a22_w = 32'((ea_q - t_q) >>> 2);
    wire signed [31:0] a12_w = 32'(a12_q);
    wire signed [31:0] a21_w = 32'(a21_q >>> 7);
    wire               gate  = (p_theta0 < TH_GATE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= M_IDLE; slot <= '0; mode <= '0; idx <= '0; act <= '0;
            busy <= 1'b0; done <= 1'b0;
            co_we <= 1'b0; co_wdata <= '0;
        end else begin
            done <= 1'b0; co_we <= 1'b0;

            case (st)
                M_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1; act <= active;
                        slot <= '0; mode <= '0; idx <= '0;
                        st <= M_RD;
                    end
                end

                // 发读地址（参数表 + 系数块同一个索引）
                M_RD: begin
                    st <= skip ? M_NEXT : M_WR;
                end

                // 数据已回：算好并写回（gq/gv/wo 用读到的原值）
                M_WR: begin
                    co_wdata.a11 <= a11_w;
                    co_wdata.a12 <= a12_w;
                    co_wdata.a21 <= a21_w;
                    co_wdata.a22 <= a22_w;
                    co_wdata.gq  <= co_data.gq;
                    co_wdata.gv  <= co_data.gv;
                    co_wdata.wo  <= co_data.wo;
                    co_we <= gate;
                    st <= M_NEXT;
                end

                M_NEXT: begin
                    if (mode + 1 >= n_modes) begin
                        mode <= '0;
                        if (slot + 1 >= 16'(SLOTS)) begin
                            done <= 1'b1; busy <= 1'b0; st <= M_IDLE;
                        end else begin
                            slot <= slot + 1'b1;
                            idx  <= (32'(slot) + 32'd1) * 32'(n_modes);
                            st   <= M_RD;
                        end
                    end else begin
                        mode <= mode + 1'b1;
                        idx  <= idx + 32'd1;
                        st   <= M_RD;
                    end
                end

                default: st <= M_IDLE;
            endcase
        end
    end
endmodule
