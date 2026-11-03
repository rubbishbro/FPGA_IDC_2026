`timescale 1ns/1ps
// =============================================================================
// reverb_router -- 混响子路由：预设 -> 参数表 -> comb_reverb -> 干湿混合
//
// 和 body_router 一个套路：case (preset) 选参数，里面封装 parts/comb_reverb，
// 对外只收/发样本。
//
//   湿声：4 条梳状线（延迟 n_k、反馈 g_k、加权 w_k 都由预设给）
//   输出：y = (x_dry * gd + wet * gw) >>> G_FRAC   （Q4.27）
//
// 延迟对齐：comb_reverb 的湿声比输入晚 4 拍，干声也拖 4 拍；混合再占 2 拍
//           （乘一拍、加一拍），所以 out_valid 比 in_valid 晚 6 拍。
//
// REVERB_NONE = 直通：gc=0、wc=0、gd=1.0、gw=0 => y 就是延迟 6 拍的 x，逐位不变。
//
// 48 kHz presets: CHAMBER RT60=0.60s, BATHROOM RT60=1.10s.
// Per-line g = 10^(-3*len/(48000*RT60)), rounded to Q4.27.
// HALL keeps its original parameters (individual RT60 about 1.66..2.02s).
// Four bare combs: no diffusion or frequency-dependent damping; audition needed.
// =============================================================================
module reverb_router #(
    parameter int N      = 2048,          // 最大延迟（和 comb_reverb 一致）
    parameter int G_FRAC = 27
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        clear_req,
    input  router_pkg::reverb_preset    preset,

    input  logic                        in_valid,
    input  logic signed [63:0]          x,

    output logic                        out_valid,
    output logic signed [63:0]          y
);

    localparam int AW = $clog2(N);
    localparam int FW = 96 - G_FRAC;
    function automatic logic signed [FW-1:0] scaled_product(
        input logic signed [63:0] a, input logic signed [31:0] b);
        logic signed [95:0] product;
        product = a * b;
        return product >>> G_FRAC;
    endfunction
    // Q4.27 常数（1.0 = 1<<27）
    localparam logic signed [31:0] Q_ONE   = 32'sd134217728;   // 1.00
    localparam logic signed [31:0] Q_0_93  = 32'sd124822487;   // 0.93
    localparam logic signed [31:0] Q_0_91  = 32'sd122138132;   // 0.91
    localparam logic signed [31:0] Q_0_90  = 32'sd120795955;   // 0.90
    localparam logic signed [31:0] Q_0_89  = 32'sd119453778;   // 0.89
    localparam logic signed [31:0] Q_0_82  = 32'sd110058537;   // 0.82
    localparam logic signed [31:0] Q_0_70  = 32'sd93952410;    // 0.70
    localparam logic signed [31:0] Q_0_50  = 32'sd67108864;    // 0.50
    localparam logic signed [31:0] Q_0_80  = 32'sd107374182;   // 0.80
    localparam logic signed [31:0] Q_0_40  = 32'sd53687091;    // 0.40
    localparam logic signed [31:0] Q_0_25  = 32'sd33554432;    // 0.25

    logic [3:0][AW:0]         len;   // 比指针宽一位：要能装下 N（clog2(N) 位装不下 N 本身）
    logic signed [3:0][31:0]  gc, wc;
    logic signed [31:0]       gd, gw;

    always_comb begin
        // 默认 = 直通（延迟给 1，别让指针比较落在 0 上）
        for (int k = 0; k < 4; k++) begin
            len[k] = (AW+1)'(1);
            gc[k]  = 32'sd0;
            wc[k]  = 32'sd0;
        end
        gd = Q_ONE;
        gw = 32'sd0;

        case (preset)
            router_pkg::REVERB_NONE: begin
                // The defaults above are the bit-exact dry passthrough preset.
            end
            router_pkg::REVERB_CHAMBER: begin
                // Target RT60=0.60s @48kHz; TODO: confirm by listening.
                len[0] = (AW+1)'(431);
                gc[0] = 32'sd121035857;
                wc[0] = Q_0_25;
                len[1] = (AW+1)'(557);
                gc[1] = 32'sd117432701;
                wc[1] = Q_0_25;
                len[2] = (AW+1)'(683);
                gc[2] = 32'sd113936808;
                wc[2] = Q_0_25;
                len[3] = (AW+1)'(809);
                gc[3] = 32'sd110544986;
                wc[3] = Q_0_25;
                gd = 32'sd120795955;
                gw = 32'sd24159191;
            end
            router_pkg::REVERB_HALL: begin
                len[0] = (AW+1)'(1214); len[1] = (AW+1)'(1293);
                len[2] = (AW+1)'(1390); len[3] = (AW+1)'(1476);
                gc[0]  = Q_0_90;  gc[1]  = Q_0_90;
                gc[2]  = Q_0_90;  gc[3]  = Q_0_90;
                wc[0]  = Q_0_25;  wc[1]  = Q_0_25;
                wc[2]  = Q_0_25;  wc[3]  = Q_0_25;
                gd = Q_0_70;
                gw = Q_0_50;
            end
            router_pkg::REVERB_BATHROOM: begin
                // Target RT60=1.10s @48kHz; TODO: confirm by listening.
                len[0] = (AW+1)'(293);
                gc[0] = 32'sd129170148;
                wc[0] = Q_0_25;
                len[1] = (AW+1)'(379);
                gc[1] = 32'sd127724965;
                wc[1] = Q_0_25;
                len[2] = (AW+1)'(463);
                gc[2] = 32'sd126329002;
                wc[2] = Q_0_25;
                len[3] = (AW+1)'(557);
                gc[3] = 32'sd124784935;
                wc[3] = Q_0_25;
                gd = 32'sd114085069;
                gw = 32'sd33554432;
            end
            default: ;                    // 非法值：直通
        endcase
    end

    // ------------------------------------------------------------------
    logic                    wet_valid;
    logic signed [63:0]      wet;

    // ------------------------------------------------------------------
    // 清空延迟线：复位 + 换预设时给 comb_reverb 一拍 clr（旧尾音不串到新预设）
    // ------------------------------------------------------------------
    router_pkg::reverb_preset preset_q;
    logic                      comb_clr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) preset_q <= router_pkg::REVERB_NONE;
        else        preset_q <= preset;
    end
    assign comb_clr = clear_req || (preset != preset_q);
    comb_reverb #(.N(N), .G_FRAC(G_FRAC)) u_comb (
        .clk(clk), .rst_n(rst_n),
        .n1(len[0]), .n2(len[1]), .n3(len[2]), .n4(len[3]),
        .g1(gc[0]),  .g2(gc[1]),  .g3(gc[2]),  .g4(gc[3]),
        .w1c(wc[0]), .w2c(wc[1]), .w3c(wc[2]), .w4c(wc[3]),
        .clr(comb_clr),
        .in_valid(in_valid), .in_data(x),
        .out_valid(wet_valid), .wet(wet)
    );

    // ------------------------------------------------------------------
    // 干声拖 4 拍跟湿声对齐；混合再流水两拍（乘一拍、加一拍）
    //   vq[k] = in_valid 延迟 k+1 拍
    //   湿声在第 4 拍有效 -> vq[3] 那拍做两个乘法 -> vq[4] 那拍相加
    //   out_valid = vq[5]，比 in_valid 晚 6 拍
    // ------------------------------------------------------------------
    logic signed [63:0] xd [0:3];
    logic signed [FW-1:0] dry_w, wet_w;      // 干/湿乘积移位后保留 69 位（先不饱和）
    logic [5:0]         vq;

    assign out_valid = vq[5];


    // ------------------------------------------------------------------
    // 干 + 湿：70 位加法 + 一次饱和（原来是 64 位直接加，超了回绕 -> 爆音）
    //   饱和判决放在**相加这一级**，乘法那一级只存 69 位不比较：在乘法后面
    //   塞 32 位比较器会把这条路拖到 57 MHz（教训）。
    // ------------------------------------------------------------------
    logic signed [FW:0] y_sum;
    logic               ys_ok;
    assign y_sum = {{1{dry_w[FW-1]}}, dry_w} + {{1{wet_w[FW-1]}}, wet_w};
    assign ys_ok = (y_sum[FW:63] == {(FW-62){y_sum[63]}});

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 4; k++) xd[k] <= '0;
            dry_w <= '0;
            wet_w <= '0;
            y     <= '0;
            vq    <= '0;
        end else if (comb_clr) begin
            for (int k = 0; k < 4; k++) xd[k] <= '0;
            dry_w <= '0; wet_w <= '0; y <= '0; vq <= '0;
        end else begin
            vq <= {vq[4:0], in_valid};

            xd[0] <= x;
            for (int k = 1; k < 4; k++) xd[k] <= xd[k-1];

            if (vq[3]) begin                // 湿声 + 干声同一拍，只寄存不饱和
                dry_w <= scaled_product(xd[3], gd);
                wet_w <= scaled_product(wet, gw);
            end
            // 相加这一级才饱和
            if (vq[4]) begin
                if (ys_ok) y <= y_sum[63:0];
                else y <= y_sum[FW] ? 64'sh8000_0000_0000_0000 : 64'sh7FFF_FFFF_FFFF_FFFF;
            end
        end
    end

endmodule
