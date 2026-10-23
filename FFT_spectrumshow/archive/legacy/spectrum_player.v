// spectrum_player.v - Offline-computed spectrum playback (display-chain bring-up)
// 2026-09-29
//  Reads a precomputed 128-bar x NFRAME spectrum from BSRAM ROM (spectrum.mem)
//  and outputs one frame of 128 bar heights per frame_pulse.
//  PURPOSE: verify the "pong buffer -> spectrum_map -> lcd_fft -> display" chain
//           on the board WITHOUT needing the encrypted FFT IP.
//  Data format in spectrum.mem: NFRAME lines, each line = 128 x 10-bit hex values
//  (space or newline separated). Generated offline (tools/).
//
//  Outputs:
//   q_y[9:0]   : bar height for current column (via pix_x/bar index)
//   q_ov[9:0]  : overshoot target = 1.2x height
//  These replace data_source's fake-note FFT page.
module spectrum_player (
    input               clk,
    input               rst_n,
    input               frame_pulse,
    input       [9:0]   pix_x,        // to compute current bar index

    output reg  [9:0]   q_y,
    output reg  [9:0]   q_ov
);

    localparam NFRAME  = 128;            // frames stored (demo)
    localparam NFRAME_AW = 7;            // 128 frames

    // spectrum ROM: [frame][bar] = 10-bit height
    // .mem values are 3-hex-digit (0x000..0x3FF = 10-bit); width matches
    reg [9:0] rom [0:128*128-1];
    initial $readmemh("spectrum.mem", rom);

    // current frame pointer
    reg [NFRAME_AW-1:0] fcnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) fcnt <= {NFRAME_AW{1'b0}};
        else if (frame_pulse) begin
            if (fcnt == NFRAME-1) fcnt <= {NFRAME_AW{1'b0}};
            else                  fcnt <= fcnt + 1'b1;
        end
    end

    // current bar index from pixel column (0..127, clamp >127)
    wire [9:0] bar_raw = pix_x / 10'd6;
    wire [6:0] bar     = (bar_raw > 7'd127) ? 7'd127 : bar_raw[6:0];

    // address = fcnt*128 + bar
    wire [13:0] addr = (fcnt << 7) | {7'b0, bar};

    // async read (small, 16K entries -> fits distributed/LUTRAM or BSRAM)
    reg [9:0] h;
    // map 10-bit ROM value to screen height 0..479: h*479/1024
    wire [19:0] hf = h * 10'd479;
    wire [9:0]  h_scaled = hf[19:10];           // /1024, 0..478
    // overshoot = 1.2x = h_scaled*6/5, clamp 479
    wire [11:0] ov_tmp = h_scaled * 10'd6;
    wire [9:0]  ov_raw = ov_tmp / 10'd5;
    wire [9:0]  ov_scr = (ov_raw > 10'd479) ? 10'd479 : ov_raw;

    always @(posedge clk) begin
        h <= rom[addr];
        q_y  <= (bar_raw <= 7'd127) ? h_scaled : 10'd0;   // out-of-range -> 0
        q_ov <= (bar_raw <= 7'd127) ? ov_scr : 10'd0;
    end

endmodule