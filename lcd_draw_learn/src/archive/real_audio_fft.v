// real_audio_fft.v - Real audio ROM playback + FFT (Gowin IP) + freq pong output
// 2026-09-29
//  Chain: audio_rom(48k) -> 1024-sample buffer -> FFT_Top(1024) -> freq pong
//  Runs on pix_clk (33.33MHz). 48k playback via samp_en (external ~694:1 div).
//
//  Ports:
//   clk, rst_n
//   samp_en        : 48kHz sample strobe (from pix_clk divider)
//   ff_half        : half-plane flag - we only use first 512 bins (real input)
//   -- frequency-domain pong write (to freq_pingpong) --
//   out_xk_re/out_xk_im[15:0]  : magnitude-relevant raw bin
//   out_bin[9:0]              : bin index 0..511
//   out_valid                 : one per bin
//   fft_busy                  : currently computing
//   fft_done                  : whole frame done
module real_audio_fft (
    input               clk,
    input               rst_n,
    input               samp_en,

    output      [15:0]  xk_re,
    output      [15:0]  xk_im,
    output      [9:0]   bin_idx,
    output              bin_valid,
    output              fft_busy,
    output              fft_done
);

    // ============================================================
    //  audio ROM (reads from .mem file, 8s @48k = 384000 samples)
    // ============================================================
    localparam ROM_DEPTH = 384000;          // 8 seconds
    localparam ROM_AW    = 19;              // 2^19 = 524288 > 384000
    reg [15:0] rom [0:ROM_DEPTH-1];
    initial $readmemh("synth_8s.mem", rom);
    reg [ROM_AW-1:0] rom_addr;
    reg [15:0] rom_out;
    always @(posedge clk) rom_out <= rom[rom_addr];
    // loop when end reached

    // ============================================================
    //  playback + capture: collect 1024 samples into input buffer
    // ============================================================
    reg [9:0]  cap_cnt;
    reg [15:0] inbuf_re [0:1023];
    reg        cap_active;
    reg        frame_done_flag;

    // wrap-around playback address
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rom_addr <= {ROM_AW{1'b0}};
        end
        else if (samp_en) begin
            if (rom_addr == ROM_DEPTH-1) rom_addr <= {ROM_AW{1'b0}};
            else                         rom_addr <= rom_addr + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cap_cnt <= 10'd0;
            cap_active <= 1'b0;
            frame_done_flag <= 1'b0;
        end
        else begin
            frame_done_flag <= 1'b0;
            if (samp_en) begin
                if (!cap_active) begin
                    // start a new frame
                    cap_active <= 1'b1;
                    cap_cnt <= 10'd0;
                    inbuf_re[0] <= rom_out;
                end
                else if (cap_cnt < 10'd1023) begin
                    cap_cnt <= cap_cnt + 1'b1;
                    inbuf_re[cap_cnt + 1'b1] <= rom_out;
                end
                else begin
                    // 1024 captured -> signal FFT
                    cap_active <= 1'b0;
                    frame_done_flag <= 1'b1;
                end
            end
        end
    end

    // ============================================================
    //  FFT_Top instantiation (Gowin IP)
    // ============================================================
    wire [9:0]  fft_idx;
    wire [15:0] fft_xk_re, fft_xk_im;
    wire        fft_sod, fft_ipd, fft_eod;
    wire        fft_busy_w, fft_soud, fft_opd, fft_eoud;

    // feed xn from input buffer while FFT consumes
    reg [9:0]  feed_cnt;
    reg        feeding;
    reg [15:0] xn_re;
    wire [15:0] xn_im = 16'd0;
    reg        start_fft;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_fft <= 1'b0;
            feeding <= 1'b0;
            feed_cnt <= 10'd0;
        end
        else begin
            start_fft <= 1'b0;
            if (frame_done_flag && !fft_busy_w) begin
                start_fft <= 1'b1;
                feeding <= 1'b1;
                feed_cnt <= 10'd0;
            end
            else if (feeding) begin
                if (feed_cnt == 10'd1023) begin
                    feeding <= 1'b0;
                end
                else feed_cnt <= feed_cnt + 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (feeding) xn_re <= inbuf_re[feed_cnt];
        else         xn_re <= 16'd0;
    end

    FFT_Top u_fft (
        .idx    ( fft_idx     ),
        .xk_re  ( fft_xk_re   ),
        .xk_im  ( fft_xk_im   ),
        .sod    ( fft_sod     ),
        .ipd    ( fft_ipd     ),
        .eod    ( fft_eod     ),
        .busy   ( fft_busy_w  ),
        .soud   ( fft_soud    ),
        .opd    ( fft_opd     ),
        .eoud   ( fft_eoud    ),
        .xn_re  ( xn_re       ),
        .xn_im  ( xn_im       ),
        .start  ( start_fft   ),
        .clk    ( clk         ),
        .rst    ( ~rst_n      )
    );

    // ============================================================
    //  Output: capture FFT bins (first 512, real-input symmetry)
    // ============================================================
    reg [15:0] out_xk_re, out_xk_im;
    reg [9:0]  out_bin;
    reg        out_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_xk_re <= 16'd0; out_xk_im <= 16'd0;
            out_bin <= 10'd0; out_valid <= 1'b0;
        end
        else begin
            out_valid <= 1'b0;
            if (fft_soud) begin
                out_xk_re <= fft_xk_re;
                out_xk_im <= fft_xk_im;
                out_bin   <= fft_idx;
                out_valid <= 1'b1;
            end
        end
    end

    assign xk_re    = out_xk_re;
    assign xk_im    = out_xk_im;
    assign bin_idx  = out_bin;
    assign bin_valid= out_valid;
    assign fft_busy = fft_busy_w;
    assign fft_done = fft_eoud;

endmodule