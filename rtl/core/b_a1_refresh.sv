// -----------------------------------------------------------------------------
// b_a1_refresh.sv -- B 的 a1 刷新（颤音/小弯音）
//
// a1_nom = -2r cosθ，a2 = r²；对 ratio 的小偏移：
//   s     = 2r sinθ = sqrt(4a2 - a1²)
//   δθ    = (ratio-1)·θ
//   a1'   = a1_nom + s·δθ - a1_nom·δθ²/2
// 先覆盖颤音/±50c 小弯音；大滑音以后换直接 cos。
//
// Q：a1_nom Q2.20(22)、a2 UQ0.24(24)、theta UQ2.14(16)、ratio UQ1.15(16)。
//    输出 a1_new Q2.20(22)，饱和到 ±2。
// 纯组合（含 13 步 restoring sqrt）；控制率下每拍一个模态，够用。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module b_a1_refresh (
    input  logic signed [21:0] a1_nom,
    input  logic [23:0]        a2,
    input  logic [15:0]        theta,     // UQ2.14 rad
    input  logic [15:0]        ratio,     // UQ1.15，1.0=0x8000
    output logic signed [21:0] a1_new
);

    function automatic logic [13:0] isqrt26(input logic [25:0] x);
        logic [25:0] rem;
        logic [13:0] root;
        logic [51:0] trial;
        begin
            rem  = x;
            root = 14'd0;
            for (int i = 12; i >= 0; i--) begin
                trial = ((52'({12'b0, root, 2'b0}) + 52'd1) << (2 * i));
                if ({26'b0, rem} >= trial) begin
                    rem  = rem - trial[25:0];
                    root = (root << 1) | 14'd1;
                end else begin
                    root = root << 1;
                end
            end
            isqrt26 = root;
        end
    endfunction

    logic signed [16:0] delta;      // ratio - 1.0, Q1.15
    logic signed [33:0] dt_prod;
    logic signed [17:0] dtheta;     // Q3.14
    logic signed [43:0] a1_sq;      // Q4.40
    logic signed [27:0] rad;        // Q2.24
    logic [13:0]        s;          // Q1.12
    logic signed [35:0] d2;         // Q6.28
    logic signed [63:0] term1_p, term2_p;
    logic signed [31:0] term1, term2;
    logic signed [31:0] calc;

    assign delta  = $signed({1'b0, ratio}) - 17'sd32768;
    assign dt_prod = 34'(delta) * 34'(theta);
    assign dtheta  = dt_prod >>> 15;
    assign a1_sq  = $signed(a1_nom) * $signed(a1_nom);
    assign rad    = $signed({2'b0, a2, 2'b0}) - (a1_sq >>> 16);
    assign s      = isqrt26(rad[25:0]);
    assign d2      = dtheta * dtheta;
    assign term1_p = (64'(s) * 64'(dtheta)) >>> 6;
    assign term2_p = (64'(a1_nom) * 64'(d2)) >>> 28;
    assign term1   = term1_p[31:0];
    assign term2   = term2_p[31:0];
    assign calc    = $signed(a1_nom) + term1 - term2;

    always_comb begin
        if (calc > 32'sd2097151)       a1_new = 22'sd2097151;
        else if (calc < -32'sd2097152) a1_new = -22'sd2097152;
        else                           a1_new = calc[21:0];
    end

endmodule
