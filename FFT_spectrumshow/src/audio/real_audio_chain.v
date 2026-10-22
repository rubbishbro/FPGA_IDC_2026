// real_audio_chain.v - 可视化核心：“PCM 输入 → FFT → 频谱/瀑布”
//
// 当前不再内置 demo 音频 ROM。主引擎接入时，由外部提供：
//   pcm_valid + pcm_data[23:0]
// （主引擎 64-bit mix_sum 先经过 pcm_tap 缩放，再过 100M→33.3M 异步 FIFO）
//
// 内部仍用 33.333 MHz：
//   时域窗口 → Hann → 1024 点 FFT → 频谱柱 → 帧缓冲/瀑布历史
module real_audio_chain (
    // 33.333 MHz 可视化/显示时钟与复位
    input               clk_core,
    input               rst_core_n,

    // 33.333 MHz 像素时钟与复位（LCD 扫描/绘制）
    input               clk_pix,
    input               rst_pix_n,

    // ---------------- 主引擎 PCM 输入（33.3 MHz 侧） ----------------
    // pcm_valid：当前 PCM 样本有效（每 1/48k 秒一拍）
    // pcm_data ：24-bit 有符号 PCM 样本
    input               pcm_valid,
    input       [23:0]   pcm_data,

    // 像素帧边界：每帧一个脉冲，用于切换显示帧缓冲的 bank
    input               frame_pulse,

    // ---------------- 柱状图读接口（显示侧） ----------------
    // rd_bar_idx：当前像素属于第几根柱子（0..127）
    // rd_valid  ：当前像素是否在有效柱状图区域（右侧 32px 为 0）
    // rd_q_y    ：该柱子的高度（0..479）
    // rd_q_ov   ：该柱子的光点超调目标（0..479）
    input       [6:0]   rd_bar_idx,
    input               rd_valid,
    output      [9:0]   rd_q_y,
    output      [9:0]   rd_q_ov,

    // ---------------- 瀑布图读接口（显示侧） ----------------
    // wf_base_row：最新一帧在历史 RAM 中的行号
    // wf_rd_row  ：显示当前像素要读的历史行
    // wf_rd_col  ：显示当前像素要读的柱子编号（0..127）
    // wf_rd_data ：该历史单元保存的柱高（0..1023，显示时缩放到 0..479）
    output      [5:0]   wf_base_row,
    input       [5:0]   wf_rd_row,
    input       [6:0]   wf_rd_col,
    output      [9:0]   wf_rd_data
);

    // ============================================================
    //  time_pingpong：时域双缓冲
    //  写侧：主引擎 PCM（pcm_valid/pcm_data）
    //  读侧：Hann + FFT
    // ============================================================
    wire        tp_rd_valid, tp_rd_req, tp_rd_done;
    wire [9:0]  tp_rd_addr;
    wire [23:0] tp_rd_data;

    time_pingpong #(.N_SAMPLES(1024), .WIDTH(24)) u_tp(
        .rst_ni(rst_core_n),
        .wr_clk_i(clk_pix), .wr_data_i(pcm_data), .wr_valid_i(pcm_valid), .wr_ready_o(),
        .rd_clk_i(clk_core), .rd_req_i(tp_rd_req), .rd_addr_i(tp_rd_addr),
        .rd_data_o(tp_rd_data), .rd_valid_o(tp_rd_valid), .rd_done_i(tp_rd_done),
        .wf_clk_i(clk_core), .wf_addr_i(10'd0), .wf_data_o()
    );

    // ============================================================
    //  fft_ctrl：读乒乓 → 喂 FFT（寄存器化）→ 收输出
    // ============================================================
    wire [15:0] xk_re, xk_im;
    wire [9:0]  bin_idx;
    wire        opd, eoud;

    fft_ctrl #(.N_SAMPLES(1024)) u_fft_ctrl(
        .clk_i(clk_core), .rst_ni(rst_core_n),
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
        .clk_i(clk_core), .rst_ni(rst_core_n),
        .xk_re_i(xk_re), .xk_im_i(xk_im),
        .bin_idx_i(bin_idx), .bin_valid_i(opd), .eoud_i(eoud),
        .bar_addr_o(sm_bar_addr),
        .bar_w_o(sm_bar_w), .ov_w_o(sm_ov_w),
        .bar_we_o(sm_bar_we), .frame_done_o(sm_frame_done)
    );

// ============================================================
    //  centralized display frame buffer (100 MHz write / 33.3 MHz read)
    // ============================================================
    wire [23:0] fb_rd_data;

    waterfall_store u_wf (
        .clk             (clk_pix),
        .rst_n           (rst_pix_n),
        .wr_en           (sm_bar_we),
        .wr_col          (sm_bar_addr),
        .wr_data         (sm_bar_w),
        .wr_frame_done   (sm_frame_done),
        .rd_row          (wf_rd_row),
        .rd_col          (wf_rd_col),
        .rd_data         (wf_rd_data),
        .base_row        (wf_base_row)
    );

    display_frame_buffer u_fb (
        .wr_clk        (clk_core),
        .wr_rst_n      (rst_core_n),
        .wr_en         (sm_bar_we),
        .wr_addr       (sm_bar_addr),
        .wr_data       ({4'b0, sm_ov_w, sm_bar_w}),
        .wr_frame_done (sm_frame_done),

        .rd_clk        (clk_pix),
        .rd_rst_n      (rst_pix_n),
        .rd_addr       (rd_bar_idx),
        .rd_data       (fb_rd_data),
        .rd_frame_pulse(frame_pulse)
    );

    // out-of-range columns (right edge) -> force 0
    assign rd_q_y  = !rd_valid ? 10'd0 : fb_rd_data[9:0];
    assign rd_q_ov = !rd_valid ? 10'd0 : fb_rd_data[19:10];

endmodule

