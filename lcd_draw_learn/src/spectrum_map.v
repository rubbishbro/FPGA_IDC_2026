// spectrum_map.v - FFT bins -> 128 log-axis bars -> bar heights + overshoot
// 2026-09-29
//  Log frequency axis: bar n covers 20Hz..20kHz.
//  bin k freq = k*46.875 Hz (48k/1024). bin2bar ROM maps bin->bar.
//  Accumulates |X| per bar, then at end-of-frame log-scales + outputs.
module spectrum_map #(
    parameter N_BARS = 128,   // 柱数
    parameter BIN_W  = 10     // 柱高位宽
) (
    input               clk_i,
    input               rst_ni,

    // FFT bins in
    input       [15:0]  xk_re_i,
    input       [15:0]  xk_im_i,
    input       [9:0]   bin_idx_i,    // 0..511
    input               bin_valid_i,  // one per bin (opd)
    input               eoud_i,       // FFT output done -> start FLUSH

    // bar write out (to freq_pingpong)
    output reg  [6:0]   bar_addr_o,
    output reg  [BIN_W-1:0] bar_w_o,
    output reg  [BIN_W-1:0] ov_w_o,
    output reg          bar_we_o,
    output reg          frame_done_o
);

    // bin->bar ROM (log axis), 512 entries, 7-bit bar (0..127)
    // >f_high bins are folded into bar126 (see gen_bin2bar) so bar127 stays narrow.
    // REGISTERED read: break the combinational index->array glitch path.
    reg [6:0] bin2bar [0:511];
    initial $readmemh("bin2bar.mem", bin2bar);
    reg [6:0] cur_bar_r;
    always @(posedge clk_i) cur_bar_r <= bin2bar[bin_idx_i[8:0]];   // sync read

    // magnitude approx: |re| + |im|/4
    wire [15:0] re_abs = xk_re_i[15] ? (~xk_re_i + 16'd1) : xk_re_i;
    wire [15:0] im_abs = xk_im_i[15] ? (~xk_im_i + 16'd1) : xk_im_i;
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
    // (always below, after flush_cnt declared)

    // smoothing params
    localparam SMOOTH_DECAY = 10'd6;   // per-frame release step (px)

    // attack+decay: rise instantly on new peak, decay slowly otherwise
    wire [9:0] sm_raw  = log_scale(bar_max_rd);
    wire [9:0] sm_rel  = (smooth_rd > SMOOTH_DECAY) ? (smooth_rd - SMOOTH_DECAY) : 10'd0;
    wire [9:0] sm_new  = (sm_raw > smooth_rd) ? sm_raw : sm_rel;

    // state
    reg [$clog2(N_BARS):0] flush_cnt;    // 0..N_BARS during flush
    reg [$clog2(N_BARS):0] flush_cnt_r;  // delayed flush_cnt (aligns addr with data)
    reg [1:0]  phase;        // 0=accum 1=flush 2=clear
    reg [$clog2(N_BARS)-1:0] clr_cnt;    // clear counter

    // ONE registered read port: reads bar_max[rd_addr]
    reg [6:0]  rd_addr;
    reg [17:0] bar_max_rd;
    always @(posedge clk_i) begin
        rd_addr    <= (phase == 2'd1) ? flush_cnt[$clog2(N_BARS)-1:0] : cur_bar_r;
        bar_max_rd <= bar_max[(phase == 2'd1) ? flush_cnt[$clog2(N_BARS)-1:0] : cur_bar_r];
    end

    // registered read of smooth_ram during FLUSH
    always @(posedge clk_i) smooth_rd <= smooth_ram[flush_cnt];

    // linear sequence machine: ACCUM -> FLUSH -> CLEAR -> ACCUM
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            phase <= 2'd0;
            flush_cnt <= 0;
            flush_cnt_r <= 0;
            clr_cnt <= 0;
            bar_we_o <= 1'b0;
            frame_done_o <= 1'b0;
            bar_addr_o <= 7'd0;
            bar_w_o <= 10'd0;
            ov_w_o <= 10'd0;
        end
        else begin
            frame_done_o <= 1'b0;
            bar_we_o <= 1'b0;
            case (phase)
                2'd0: begin  // ACCUM
                    if (bin_valid_i) begin
                        if (mag > bar_max_rd) bar_max[cur_bar_r] <= mag;
                    end
                    if (eoud_i) begin
                        phase <= 2'd1;       // -> FLUSH（握手，不数拍）
                        flush_cnt <= 0;
                    end
                end

                2'd1: begin  // FLUSH: writes bar0..barN_BARS-1 with attack+decay smoothing
                    bar_addr_o <= flush_cnt_r[$clog2(N_BARS)-1:0];
                    bar_w_o    <= sm_new;
                    ov_w_o     <= ov_target(sm_new);
                    bar_we_o   <= 1'b1;
                    smooth_ram[flush_cnt_r] <= sm_new;
                    flush_cnt_r <= flush_cnt;
                    if (flush_cnt == N_BARS) begin
                        phase <= 2'd2;           // -> CLEAR
                        clr_cnt <= 0;
                        frame_done_o <= 1'b1;
                    end
                    else flush_cnt <= flush_cnt + 1'b1;
                end

                2'd2: begin  // CLEAR (write-port clears, RAM-friendly)
                    bar_max[clr_cnt] <= 18'd0;
                    if (clr_cnt == N_BARS-1) begin
                        phase <= 2'd0;
                    end
                    else clr_cnt <= clr_cnt + 1'b1;
                end
            endcase
        end
    end

    // log-scale magnitude to 0..479 height.
    // 20*log10(x): use bit position (approx log2) then linear map.
    function [9:0] log_scale(input [17:0] x);
        reg [4:0] msb;
        reg [9:0] h;
        begin
            // find highest set bit (log2 approx)
            msb = 5'd0;
            if (x[17:16]) msb = 5'd17;
            else if (x[15]) msb = 5'd15;
            else if (x[14]) msb = 5'd14;
            else if (x[13]) msb = 5'd13;
            else if (x[12]) msb = 5'd12;
            else if (x[11]) msb = 5'd11;
            else if (x[10]) msb = 5'd10;
            else if (x[9])  msb = 5'd9;
            else if (x[8])  msb = 5'd8;
            else if (x[7])  msb = 5'd7;
            else if (x[6])  msb = 5'd6;
            else if (x[5])  msb = 5'd5;
            else if (x[4])  msb = 5'd4;
            else if (x[3])  msb = 5'd3;
            else if (x[2])  msb = 5'd2;
            else if (x[1])  msb = 5'd1;
            else msb = 5'd0;
            // map msb 0..17 -> height 0..479 (log-ish)
            h = (msb * 10'd28);   // 17*28 = 476
            if (h > 10'd479) h = 10'd479;
            log_scale = h;
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