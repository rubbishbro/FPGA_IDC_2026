// real_audio_chain.v - Audio ROM -> time_pingpong -> fft_ctrl -> FFT IP -> spectrum -> pong
// 2026-09-29 架构重构 v3（正确架构：时域乒乓 + 寄存器化喂 FFT）
//
//  调试期数据源：内部 ROM（gc_6s.mem）当音频源，audio_if 转发写时域乒乓。
//  未来：ROM 换成合成器/外部音频，audio_if 接口不变。
//  时域乒乓(wr/rd)与 fft_ctrl 读喂合一，xn_re 寄存器化（无组合 mux 长路径）。
module real_audio_chain (
    input               clk,          // pix_clk
    input               rst_n,        // 低有效
    input               samp_en,      // 48k 节拍脉冲（pix_clk 分频）

    // display read side (from lcd_fft via lcd_draw)
    input       [6:0]   rd_bar_idx,
    input               rd_valid,     // 1 only for bar 0..127 (right edge -> 0)
    output      [9:0]   rd_q_y,
    output      [9:0]   rd_q_ov
);

    // ============================================================
    //  audio ROM（调试期音频源）
    // ============================================================
    localparam ROM_DEPTH = 288000;    // 6s @48k
    localparam ROM_AW    = 19;
    reg [15:0] rom [0:ROM_DEPTH-1];
    initial $readmemh("gc_6s.mem", rom);
    reg [ROM_AW-1:0] rom_addr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rom_addr <= {ROM_AW{1'b0}};
        else if (samp_en) rom_addr <= (rom_addr == ROM_DEPTH-1) ? {ROM_AW{1'b0}} : rom_addr + 1'b1;
    end
    reg [15:0] rom_out;
    always @(posedge clk) rom_out <= rom[rom_addr];

    // ============================================================
    //  audio_if：ROM 采样 → 写时域乒乓
    // ============================================================
    wire [15:0] tp_wr_data;
    wire        tp_wr_valid;
    wire        tp_wr_ready;

    audio_if #(.WIDTH(16)) u_audio_if(
        .clk_i(clk), .rst_ni(rst_n),
        .audio_in_i(rom_out), .samp_en_i(samp_en),
        .wr_data_o(tp_wr_data), .wr_valid_o(tp_wr_valid), .wr_ready_i(tp_wr_ready)
    );

    // ============================================================
    //  time_pingpong：时域双缓冲
    // ============================================================
    wire        tp_rd_valid, tp_rd_req, tp_rd_done;
    wire [9:0]  tp_rd_addr;
    wire [15:0] tp_rd_data;

    time_pingpong #(.N_SAMPLES(1024), .WIDTH(16)) u_tp(
        .rst_ni(rst_n),
        .wr_clk_i(clk), .wr_data_i(tp_wr_data), .wr_valid_i(tp_wr_valid), .wr_ready_o(tp_wr_ready),
        .rd_clk_i(clk), .rd_req_i(tp_rd_req), .rd_addr_i(tp_rd_addr),
        .rd_data_o(tp_rd_data), .rd_valid_o(tp_rd_valid), .rd_done_i(tp_rd_done),
        .wf_clk_i(clk), .wf_addr_i(10'd0), .wf_data_o()
    );

    // ============================================================
    //  fft_ctrl：读乒乓 → 喂 FFT（寄存器化）→ 收输出
    // ============================================================
    wire [15:0] xk_re, xk_im;
    wire [9:0]  bin_idx;
    wire        opd, eoud;

    fft_ctrl #(.N_SAMPLES(1024)) u_fft_ctrl(
        .clk_i(clk), .rst_ni(rst_n),
        .tp_rd_valid_i(tp_rd_valid),
        .tp_rd_req_o(tp_rd_req), .tp_rd_addr_o(tp_rd_addr),
        .tp_rd_data_i(tp_rd_data), .tp_rd_done_o(tp_rd_done),
        .xk_re_o(xk_re), .xk_im_o(xk_im), .bin_idx_o(bin_idx),
        .opd_o(opd), .eoud_o(eoud)
    );

    // ============================================================
    //  spectrum_map：bin → 柱高（用 opd/eoud 握手）
    // ============================================================
    wire [6:0]  sm_bar_addr;
    wire [9:0]  sm_bar_w, sm_ov_w;
    wire        sm_bar_we, sm_frame_done;

    spectrum_map #(.N_BARS(128), .BIN_W(10)) u_sm(
        .clk_i(clk), .rst_ni(rst_n),
        .xk_re_i(xk_re), .xk_im_i(xk_im),
        .bin_idx_i(bin_idx), .bin_valid_i(opd), .eoud_i(eoud),
        .bar_addr_o(sm_bar_addr),
        .bar_w_o(sm_bar_w), .ov_w_o(sm_ov_w),
        .bar_we_o(sm_bar_we), .frame_done_o(sm_frame_done)
    );

// ============================================================
    //  freq_pingpong（自包含：内部翻块，无需外部 wr_sel/frame_done）
    // ============================================================
    wire [9:0] pp_bar, pp_ov;
    freq_pingpong #(.N_BARS(128), .WIDTH(10)) u_pp(
        .clk_i(clk), .rst_ni(rst_n),
        .wr_addr_i(sm_bar_addr), .wr_bar_i(sm_bar_w), .wr_ov_i(sm_ov_w),
        .wr_we_i(sm_bar_we),
        .rd_addr_i(rd_bar_idx), .rd_bar_o(pp_bar), .rd_ov_o(pp_ov)
    );

    // out-of-range columns (right edge) -> force 0
    assign rd_q_y  = !rd_valid ? 10'd0 : pp_bar;
    assign rd_q_ov = !rd_valid ? 10'd0 : pp_ov;

endmodule