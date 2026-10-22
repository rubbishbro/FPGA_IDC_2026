// modulation0 -- 揉弦：一次只处理**一个声部**（模态 0..n_modes-1）
//   * alpha 由 fmap_i 直接映射（内部决定）
//   * 地址（槽号）由 router 拼，本模块只输出模态偏移
//   * 4 个字段独立写使能，gq/gv/wo 不写
//   * 计算做成多拍流水：每拍至多一次 32x32 乘法，中间结果存 32 位寄存器
//     （原来一条组合链上有 3~4 个 64x64 乘法，PnR 出来 55 ns）
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
    localparam signed [63:0] K_ALPHA = 64'sd123_437;                 // 0.0293*2^30/255 ≈ 50 cent 满量程
    localparam signed [63:0] C_GAM   = (64'sd1 << 40) / (64'sd65536 * FS);  // 1/(65536*fs)，把除法换成乘法
    localparam signed [31:0] TH_GATE = 32'sd858_993_459;              // theta0 < 0.8 rad 才调制
    localparam int FS_C = FS;

    // 每拍一个状态
    typedef enum logic [3:0] {
        M_IDLE, M_RD,   // 读参数
        M_LAT,          // 参数多等一拍（router 侧参数表读出后又打了一拍）
        M_A,            // D_q, d_q
        M_B,            // c_q, s_q
        M_C,            // ea, a1 = d*s
        M_D,            // a12a = a1*g
        M_E,            // a12, t
        M_F,            // p = a12*alpha2
        M_W             // 写回
    } mst_e;
    mst_e st;

    logic [15:0] mode;
    logic signed [63:0] alpha_q, alpha2_q, inv_a_q;

    // 流水寄存器（32 位）
    logic signed [31:0] D_q, d_q, c_q, s_q, ea_q, a1_q, a12a_q, a12_q, t_q, p_q, w2_q;

    // alpha 相关：每次激活算一次
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            alpha_q  <= ONE;
            alpha2_q <= ONE;
            inv_a_q  <= ONE;
        end else if (start) begin
            alpha_q  <= ONE + K_ALPHA * 64'(fmap_i);
            alpha2_q <= ((ONE + K_ALPHA * 64'(fmap_i)) * (ONE + K_ALPHA * 64'(fmap_i))) >>> 30;
            // 1/alpha ~ 1 - d + d^2   (d = alpha-1)
            inv_a_q  <= ONE - (K_ALPHA * 64'(fmap_i))
                        + (((K_ALPHA * 64'(fmap_i)) * (K_ALPHA * 64'(fmap_i))) >>> 30);
        end
    end

    // 参数表读口：组合输出（M_RD 给地址，下一拍数据有效）
    assign p_re   = (st == M_RD);
    assign p_mode = mode[$clog2(N_MODES)-1:0];

    wire signed [31:0]  a11_w = 32'((ea_q + t_q) >>> 2);   // Q28
    wire signed [31:0]  a12_w = 32'(a12_q);                // Q30
    wire                gate  = (p_theta0 < TH_GATE) && (fmap_i != 8'd0);

    // 每拍一个乘法（32x32 -> 64）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= M_IDLE; mode <= '0; busy <= 1'b0; done <= 1'b0;
            D_q <= '0; d_q <= '0; c_q <= '0; s_q <= '0; ea_q <= '0; a1_q <= '0;
            a12a_q <= '0; a12_q <= '0; t_q <= '0; p_q <= '0; w2_q <= '0;
            co_we <= 4'b0000; co_mode <= '0; co_wdata <= '0;
        end else begin
            done  <= 1'b0;
            co_we <= 4'b0000;

            case (st)
                M_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy <= 1'b1;
                        mode <= '0;
                        st   <= M_RD;
                    end
                end

                M_RD: st <= M_LAT;      // 本拍给地址，router 下一拍寄存

                M_LAT: st <= M_A;       // router 又打了一拍，参数此时才稳定

                M_A: begin
                    // 四个并行乘法（互不依赖），不是链
                    D_q  <= 32'(((alpha_q - ONE) * 64'(p_theta0)) >>> 30);
                    d_q  <= 32'(ONE - ((64'(p_gam) * C_GAM) >>> 40));
                    w2_q <= 32'((((64'(p_theta0) * FS) >>> 14) * ((64'(p_theta0) * FS) >>> 14)) >>> 32);
                    st   <= M_B;
                end

                M_B: begin
                    c_q <= 32'(64'(p_c0) - ((64'(p_s0) * 64'(D_q)) >>> 30));
                    s_q <= 32'(64'(p_s0) + ((64'(p_c0) * 64'(D_q)) >>> 30));
                    st  <= M_C;
                end

                M_C: begin
                    ea_q <= 32'((64'(d_q) * 64'(c_q)) >>> 30);
                    a1_q <= 32'((64'(d_q) * 64'(s_q)) >>> 30);
                    st   <= M_D;
                end

                M_D: begin
                    a12a_q <= 32'((64'(a1_q) * 64'(p_g)) >>> 30);
                    st     <= M_E;
                end

                M_E: begin
                    a12_q <= 32'((64'(a12a_q) * inv_a_q) >>> 30);
                    st    <= M_F;
                end

                M_F: begin
                    t_q  <= 32'((64'(a12_q) * 64'(p_gam)) >>> 16);
                    p_q  <= 32'((64'(a12_q) * alpha2_q) >>> 30);
                    st   <= M_W;
                end

                M_W: begin
                    co_mode <= mode[$clog2(N_MODES)-1:0];
                    co_wdata.a11 <= a11_w;
                    co_wdata.a12 <= a12_w;
                    // a21 = -a12*alpha^2*omega0^2（w2_q 已在 M_A 里算好，Q0 的 omega0^2）
                    co_wdata.a21 <= 32'(-((64'(p_q) * 64'(w2_q)) >>> 7));
                    co_wdata.a22 <= 32'((ea_q - t_q) >>> 2);
                    co_we <= gate ? 4'b1111 : 4'b0000;
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
