// spectrum_map.v - 1024 点 FFT 的 512 个正频率 bin → 128 根对数柱
//
// 频率关系：
//   采样率 48 kHz，FFT 1024 点，bin 间隔 = 48k/1024 = 46.875 Hz
//   只处理正频率 bin 0..511；负频率 bin 512..1023 忽略
//   bin2bar.mem 有 512 项，每项表示该 bin 归属哪根柱子
//
// 状态机：
//   ACCUM：逐 bin 找每根柱子的最大幅度
//   FLUSH：把 bar_max 转成显示高度，做 attack/decay 平滑，写帧缓冲
//   CLEAR：清空 bar_max，准备下一帧
//
// 注意：ACCUM 目前存在 bin/bar 延迟不一致的问题，
// 会表现为频谱左移、空洞和斜边；后续需要按注释里的延迟对齐修复。
module spectrum_map #(
    parameter N_BARS = 128,   // 柱子数量
    parameter BIN_W  = 10     // 柱子高度位宽
) (
    // 33.333 MHz 可视化时钟与低有效复位
    input               clk_i,
    input               rst_ni,

    // ---------------- FFT bin 输入 ----------------
    // xk_re_i / xk_im_i：当前 bin 的实部/虚部（16-bit）
    // bin_idx_i        ：bin 编号 0..1023
    // bin_valid_i      ：当前 bin 有效（FFT opd）
    // eoud_i           ：所有 bin 输出结束（FFT eoud），触发 FLUSH
    input       [15:0]  xk_re_i,
    input       [15:0]  xk_im_i,
    input       [9:0]   bin_idx_i,
    input               bin_valid_i,
    input               eoud_i,

    // ---------------- 柱状图输出（写帧缓冲/瀑布） ----------------
    // bar_addr_o  ：柱子编号 0..127
    // bar_w_o     ：平滑后的柱高 0..479
    // ov_w_o      ：光点超调目标 0..479
    // bar_we_o    ：本拍写柱高有效
    // frame_done_o：一帧柱高全部输出完成（单拍）
    output reg  [6:0]   bar_addr_o,
    output reg  [BIN_W-1:0] bar_w_o,
    output reg  [BIN_W-1:0] ov_w_o,
    output reg          bar_we_o,
    output reg          frame_done_o
);

    // 单级输入寄存器
    reg [9:0]  bin_idx_r;
    reg        bin_valid_r, eoud_r;
    always @(posedge clk_i) begin
        xk_re_r    <= xk_re_i;
        xk_im_r    <= xk_im_i;
        bin_idx_r  <= bin_idx_i;
        bin_valid_r <= bin_valid_i;
        eoud_r     <= eoud_i;
    end
    // bin->bar ROM (log axis), 256 entries for the 512-point FFT.
    // bin_idx_i[8] = 1 是反频率，忽略
    // REGISTERED read: break the combinational index->array glitch path.
    reg [6:0] bin2bar [0:511];
    initial $readmemh("bin2bar.mem", bin2bar);
    reg [6:0] cur_bar_r;
    always @(posedge clk_i) cur_bar_r <= bin2bar[bin_idx_r[8:0]];   // sync read

    // magnitude approx: |re| + |im|/4
    wire [15:0] re_abs = xk_re_r[15] ? (~xk_re_r + 16'd1) : xk_re_r;
    wire [15:0] im_abs = xk_im_r[15] ? (~xk_im_r + 16'd1) : xk_im_r;
    wire [15:0] mag_big   = (re_abs > im_abs) ? re_abs : im_abs;
    wire [15:0] mag_sml   = (re_abs > im_abs) ? im_abs : re_abs;
    wire [17:0] mag   = {2'b0, mag_big} + {2'b0, mag_sml[15:2]};

    // bar_max: single write port + single registered read port (shared).
    // rd_sel picks accumulate-addr vs flush-addr. Avoids dual-read inference.
    // initial 0 (RAM can't reliably for-loop reset in Gowin inference).
    reg [17:0] bar_max [0:N_BARS-1];
    integer bm;
    initial begin
        for (bm = 0; bm < N_BARS; bm = bm + 1) bar_max[bm] = 18'd0;
    end

    // smooth_ram: per-bar smoothed height (attack+decay), single write+read port.
    // 10-bit smoothed height per bar. Initialized 0.
    reg [9:0] smooth_ram [0:N_BARS-1];
    initial begin
        for (bm = 0; bm < N_BARS; bm = bm + 1) smooth_ram[bm] = 10'd0;
    end
    reg [9:0] smooth_rd;     // registered read during FLUSH

    // smoothing params
    localparam SMOOTH_DECAY = 10'd6;   // per-frame release step (px)

    // state
    reg [8:0]  flush_cnt;    // 0 .. N_BARS+3
    reg [1:0]  phase;        // 0=accum 1=flush 2=clear
    reg [7:0]  clr_cnt;

    // One registered read port shared by ACCUM and FLUSH.
    reg [6:0]  rd_addr_d;
    reg [17:0] bar_max_rd;
    always @(posedge clk_i) begin
        if (phase == 2'd1) rd_addr_d <= flush_cnt[6:0];
        else               rd_addr_d <= cur_bar_r;

        bar_max_rd <= bar_max[rd_addr_d];
        smooth_rd  <= smooth_ram[rd_addr_d];
    end

    // Flush pipeline: S1 = msb + smooth, S2 = smoothed height, S3 = output.
    reg [4:0] msb_s1;
    reg [9:0] smooth_s1;
    reg [6:0] addr_s1;
    reg       v1;

    reg [9:0] sm_s2;
    reg [6:0] addr_s2;
    reg       v2;

    wire [9:0] sm_rel_s2 = (smooth_s1 > SMOOTH_DECAY) ? (smooth_s1 - SMOOTH_DECAY) : 10'd0;
    wire [9:0] sm_raw_s2 = (msb_s1 * 10'd28 > 10'd479) ? 10'd479 : msb_s1 * 10'd28;
    wire [9:0] sm_new_s2 = (sm_raw_s2 > smooth_s1) ? sm_raw_s2 : sm_rel_s2;
    wire [9:0] ov_s3     = ov_target(sm_s2);

    // linear sequence machine: ACCUM -> FLUSH -> CLEAR -> ACCUM
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            phase <= 2'd0;
            flush_cnt <= 0;
            clr_cnt <= 0;
            bar_we_o <= 1'b0;
            frame_done_o <= 1'b0;
            bar_addr_o <= 7'd0;
            bar_w_o <= 10'd0;
            ov_w_o <= 10'd0;
            msb_s1 <= 0; smooth_s1 <= 0; addr_s1 <= 0; v1 <= 1'b0;
            sm_s2 <= 0; addr_s2 <= 0; v2 <= 1'b0;
        end
        else begin
            frame_done_o <= 1'b0;
            bar_we_o <= 1'b0;

            // Stage 3: write one bar.
            if (v2) begin
                bar_addr_o <= addr_s2;
                bar_w_o    <= sm_s2;
                ov_w_o     <= ov_s3;
                bar_we_o   <= 1'b1;
                smooth_ram[addr_s2] <= sm_s2;
            end

            // Stage 2: smooth/limit.
            v2 <= v1;
            if (v1) begin
                addr_s2 <= addr_s1;
                sm_s2   <= sm_new_s2;
            end

            // Stage 1 capture.
            v1 <= 1'b0;

            case (phase)
                2'd0: begin  // ACCUM
                    if (bin_valid_r && !bin_idx_r[9]) begin
                        if (mag > bar_max_rd) bar_max[cur_bar_r] <= mag;
                    end
                    if (eoud_r) begin
                        phase <= 2'd1;
                        flush_cnt <= 0;
                    end
                end

                2'd1: begin  // FLUSH
                    if ((flush_cnt >= 1) && (flush_cnt <= N_BARS)) begin
                        msb_s1    <= msb_of(bar_max_rd);
                        smooth_s1 <= smooth_rd;
                        addr_s1   <= rd_addr_d;
                        v1        <= 1'b1;
                    end
                    if (flush_cnt == N_BARS + 3) begin
                        phase <= 2'd2;
                        clr_cnt <= 0;
                        frame_done_o <= 1'b1;
                    end
                    else flush_cnt <= flush_cnt + 1'b1;
                end

                2'd2: begin  // CLEAR
                    bar_max[clr_cnt[6:0]] <= 18'd0;
                    if (clr_cnt == N_BARS-1)
                        phase <= 2'd0;
                    else
                        clr_cnt <= clr_cnt + 1'b1;
                end
            endcase
        end
    end

    // Highest set bit (approx log2) -- separated into its own pipeline stage.
    function [4:0] msb_of(input [17:0] x);
        begin
            if (x[17:16])      msb_of = 5'd17;
            else if (x[15])    msb_of = 5'd15;
            else if (x[14])    msb_of = 5'd14;
            else if (x[13])    msb_of = 5'd13;
            else if (x[12])    msb_of = 5'd12;
            else if (x[11])    msb_of = 5'd11;
            else if (x[10])    msb_of = 5'd10;
            else if (x[9])     msb_of = 5'd9;
            else if (x[8])     msb_of = 5'd8;
            else if (x[7])     msb_of = 5'd7;
            else if (x[6])     msb_of = 5'd6;
            else if (x[5])     msb_of = 5'd5;
            else if (x[4])     msb_of = 5'd4;
            else if (x[3])     msb_of = 5'd3;
            else if (x[2])     msb_of = 5'd2;
            else if (x[1])     msb_of = 5'd1;
            else               msb_of = 5'd0;
        end
    endfunction

    // overshoot target = +20% of bar height (effect B bounce)
    // 1.2x �?h + h/4 - h/32 (shift approx), clamp 479
    function [9:0] ov_target(input [9:0] h);
        reg [11:0] t;
        begin
            t = h + (h >> 2) - (h >> 5);   // ~1.21875x �?1.2x
            ov_target = (t > 10'd479) ? 10'd479 : t[9:0];
        end
    endfunction

endmodule