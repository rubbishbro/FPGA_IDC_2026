module data_source (
    input               clk,
    input               rst_n,
    input               frame_pulse,
    input       [1:0]   page_sel,
    input       [9:0]   q_x,        // query column 0..799 (blanking -> up to 1009)
    output reg  [9:0]   q_y,        // y value for that column
    output reg  [9:0]   q_ov        // overshoot target for the light dot (frame-precomputed)
);

    // ============================================================
    //  SCREEN CONSTANTS
    // ============================================================
    parameter SCREEN_W = 10'd800;
    parameter SCREEN_H = 10'd480;
    parameter MID_Y    = 10'd240;

    // ============================================================
    //  TEST SIGNAL: two sine waves summed
    //  This mimics the synthesizer output (a few tones mixed).
    //  sin lookup (triangle-wave approx, synthesizable):
    //    tri(t) 0..255 over one period; y = MID_Y + AMP - tri*AMP/128
    // ============================================================
    parameter AMP1 = 10'd120;   // amplitude of tone 1
    parameter AMP2 = 10'd60;    // amplitude of tone 2

    // tone 1: one full period across the 800px width
    // full triangle: rises -AMP..+AMP over t 0..255, centered at MID_Y
    wire [7:0]  ph1    = q_x[7:0];
    wire [7:0]  triwave1  = (ph1 < 8'd128) ? ph1 : (8'd255 - ph1);   // 0..255 up then down
    wire [17:0] p1    = (AMP1 * 2) * triwave1;                       // up to 240*255
    wire [9:0]  y1    = MID_Y - AMP1 + p1[17:8];                     // MID-AMP .. MID+AMP

    // tone 2: 2x frequency (2 periods across width)
    wire [7:0]  ph2    = {q_x[6:0], 1'b0};           // 2*t mod 256
    wire [7:0]  triwave2  = (ph2 < 8'd128) ? ph2 : (8'd255 - ph2);
    wire [17:0] p2    = (AMP2 * 2) * triwave2;
    wire [9:0]  y2    = MID_Y - AMP2 + p2[17:8];

    // summed: y_sum = (y1 + y2) - MID_Y  -- pure unsigned, then clamp
    // y1,y2 in 0..479; y1+y2 in 0..958; minus 240 -> 0..718 clamp to 0..479
    wire [10:0] y12 = {1'b0, y1} + {1'b0, y2};          // 0..958
    wire [10:0] ysum = y12 - {1'b0, 10'd240};           // -240..718
    wire [9:0]  wave_y = (y12 < 11'd240) ? 10'd0 :      // below 0 -> 0
                         (y12 > 11'd719) ? 10'd479 :    // above 479 -> 479
                         ysum[9:0];

// ============================================================
    //  FFT PAGE: square bars with varying height (spectrum-like).
    //  2026-09-28 重构（修 -50ns 时序违例）：
    //   重计算链（谐波×包络×幅度÷172800 ÷10）从"每像素实时算"
    //   改为"每帧 frame_pulse 后串行重算 128 柱，结果存 RAM"。
    //   像素路径只剩查表：q_y = bar_h_ram[bar]，q_ov = ov_ram[bar]。
    // ============================================================
    parameter FFT_BINS  = 10'd128;    // display 128 bars
    parameter BAR_W     = 10'd6;      // 128*6 = 768 px

    // ---- note schedule（仅在 frame_pulse 更新，路径短）----
    localparam N0_BAR = 8,  N0_AMP = 10'd200;
    localparam N1_BAR = 26, N1_AMP = 10'd160;
    localparam N2_BAR = 42, N2_AMP = 10'd180;
    localparam N3_BAR = 60, N3_AMP = 10'd140;
    localparam N4_BAR = 78, N4_AMP = 10'd170;
    localparam N5_BAR = 96, N5_AMP = 10'd130;
    localparam N6_BAR = 112,N6_AMP = 10'd150;
    localparam N7_BAR = 120,N7_AMP = 10'd110;

    reg  [9:0]  song_cnt;
    wire [7:0]  note_idx = (song_cnt / 10'd32) % 8'd8;   // 0..7
    wire [9:0]  note_pos = (note_idx==0)? N0_BAR : (note_idx==1)? N1_BAR :
                           (note_idx==2)? N2_BAR : (note_idx==3)? N3_BAR :
                           (note_idx==4)? N4_BAR : (note_idx==5)? N5_BAR :
                           (note_idx==6)? N6_BAR : N7_BAR;
    wire [9:0]  note_amp = (note_idx==0)? N0_AMP : (note_idx==1)? N1_AMP :
                           (note_idx==2)? N2_AMP : (note_idx==3)? N3_AMP :
                           (note_idx==4)? N4_AMP : (note_idx==5)? N5_AMP :
                           (note_idx==6)? N6_AMP : N7_AMP;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) song_cnt <= 10'd0;
        else if (frame_pulse) song_cnt <= song_cnt + 10'd1;
    end

    // ---- envelope（每帧才变）----
    wire [9:0]  note_phase = song_cnt % 10'd32;   // 0..31 inside note
    wire [9:0]  env = (note_phase < 10'd5)  ? note_phase * 10'd72 :      // attack
                      (note_phase < 10'd24) ? 10'd360 :                  // sustain
                                              (10'd32 - note_phase) * 10'd45;  // decay

    // ============================================================
    //  帧级重算：128 柱串行 + 3 级流水，结果写 RAM
    // ============================================================
    reg [9:0]   bar_h_ram [0:127];   // 柱高查表（FFT 页 q_y）
    reg [9:0]   ov_ram    [0:127];   // 超调目标查表（光点用）
    reg [7:0]   calc_cnt;            // 0..131 计算游标（8bit：131 需 8 位）
    reg [11:0]  hsum_pipe;           // 级1：谐波和
    reg [23:0]  hp1_pipe;            // 级2a：×env
    reg [35:0]  hp2_pipe;            // 级2b：×note_amp
    reg [9:0]   note_h_pipe;         // 级2c：÷172800
    reg [9:0]   bass_pipe;           // 级2c：bass
    integer     ci;

    wire [9:0]  calc_bar = {2'b0, calc_cnt};   // 0..131；写 index=calc_cnt-4（<=127）天然保护，无需钳位

    // 级1（组合）：calc_bar → 谐波和
    wire [8:0]  c_d0 = (calc_bar >= note_pos) ? (calc_bar - note_pos) : (note_pos - calc_bar);
    wire [9:0]  c_h0 = (c_d0 < 9'd4) ? (10'd4 - c_d0) * 10'd70 : 10'd0;
    wire [8:0]  c_d2 = (calc_bar >= note_pos + 9'd14) ? (calc_bar - (note_pos+9'd14)) : ((note_pos+9'd14) - calc_bar);
    wire [9:0]  c_h2 = (c_d2 < 9'd4) ? (10'd4 - c_d2) * 10'd45 : 10'd0;
    wire [8:0]  c_d3 = (calc_bar >= note_pos + 9'd28) ? (calc_bar - (note_pos+9'd28)) : ((note_pos+9'd28) - calc_bar);
    wire [9:0]  c_h3 = (c_d3 < 9'd4) ? (10'd4 - c_d3) * 10'd25 : 10'd0;
    wire [11:0] c_sum = ({1'b0,c_h0} + {1'b0,c_h2} + {1'b0,c_h3});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hsum_pipe <= 12'd0;
        else        hsum_pipe <= c_sum;
    end

    // 级2a（组合）：harm_sum × env
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hp1_pipe <= 24'd0;
        else        hp1_pipe <= hsum_pipe * {2'b0, env};
    end

    // 级2b（组合）：hp1 × note_amp
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) hp2_pipe <= 36'd0;
        else        hp2_pipe <= {12'b0, hp1_pipe} * {2'b0, note_amp};
    end

    // 级2c（组合）：note_h = hp2 ÷172800 改用乘法近似（去除组合除法器，-0.8ns 违例根因）
    //  1/172800 ≈ 97/2^24 = 5.7803e-6（真值 5.7870e-6，误差 0.12%，最大低估 0.5px）
    wire [33:0] c_approx = hp2_pipe * 34'd97;
    wire [9:0]  c_note_h = c_approx[33:24];
    wire [8:0]  c_dlow   = calc_bar;
    wire [9:0]  c_low_h  = (c_dlow < 9'd24) ? (9'd24 - c_dlow) : 9'd0;
    wire [9:0]  c_bass   = (c_low_h * 10'd5) / 10'd3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_h_pipe <= 10'd0;
            bass_pipe   <= 10'd0;
        end
        else begin
            note_h_pipe <= c_note_h;
            bass_pipe   <= c_bass;
        end
    end

    // 级3（组合）：bar_h 放大（×2.5，柱高 116→290 ≈ 60% 屏高）+ ov_c（1.2x clamp）→ 写 RAM
    wire [9:0]  c_bar_h  = (note_h_pipe > bass_pipe) ? note_h_pipe : bass_pipe;
    wire [12:0] c_bar_h_amp = (c_bar_h * 10'd5) >> 1;                 // ×2.5 = ×5/2
    wire [9:0]  c_bar_h_g = (c_bar_h_amp > 10'd479) ? 10'd479 : c_bar_h_amp[9:0];
    wire [15:0] c_ov     = c_bar_h_g * 10'd12;
    wire [15:0] c_ov_d   = c_ov / 10'd10;
    wire [9:0]  c_ov_c   = (c_ov_d > 10'd479) ? 10'd479 : c_ov_d[9:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (ci = 0; ci < 128; ci = ci + 1) begin
                bar_h_ram[ci] <= 10'd0;
                ov_ram[ci]    <= 10'd0;
            end
        end
        else if ((calc_cnt >= 8'd4) && (calc_cnt <= 8'd131)) begin
            bar_h_ram[calc_cnt - 8'd4] <= c_bar_h_g;   // 柱号 = calc_cnt-4（4级流水对齐）
            ov_ram[calc_cnt - 8'd4]    <= c_ov_c;
        end
    end

    // 计算游标：frame_pulse 启动，连续 131 拍算完 128 柱
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) calc_cnt <= 8'd0;
        else if (frame_pulse) calc_cnt <= 8'd0;
        else if (calc_cnt < 8'd131) calc_cnt <= calc_cnt + 8'd1;
    end

    // ---- 像素路径：查表（无除法器，几个 ns 就稳定）----
    // bar_raw>127（像素 768..799 及消隐期）→ 越界列输出 0（右边 32px 保持黑）。
    // 数组读用 bar_raw 直接索引（不 clamp），越界列由三元短路给 0，避免读到 bar127 数据。
    wire [9:0]  bar_raw = q_x / BAR_W;    // 0..168（含消隐越界）
    wire [6:0]  bar_ok  = (bar_raw <= 7'd127) ? bar_raw[6:0] : 7'd0;   // 仅有效柱号
    wire        bar_val = (bar_raw <= 7'd127);                        // 有效列标记

    // ============================================================
    //  PAGE SELECT (only 2 pages now: FFT, Wave)
    //  2026-09-28: q_y/q_ov are REGISTERED outputs (synchronous RAM read).
    //  This breaks the 128-entry async-read mux off the pixel path.
    //  1-clock lag is invisible: it falls in the LED horizontal gap
    //  (xm==0 pixels are black by design).
    // ============================================================
    wire [9:0]  q_y_c, q_ov_c;
    assign q_y_c  = (page_sel == 2'b00) ? (bar_val ? bar_h_ram[bar_ok] : 10'd0) :
                    (page_sel == 2'b01) ? wave_y : 10'd0;
    assign q_ov_c = (page_sel == 2'b00) ? (bar_val ? ov_ram[bar_ok] : 10'd0) : 10'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_y  <= 10'd0;
            q_ov <= 10'd0;
        end
        else begin
            q_y  <= q_y_c;
            q_ov <= q_ov_c;
        end
    end

endmodule

