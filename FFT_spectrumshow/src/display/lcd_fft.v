module lcd_fft (
    input               clk,
    input               rst_n,
    input               frame_pulse,   // one pulse per frame -> hue cycles
    input               dot_en,        // gate dot physics to active FFT pixels (lcd_en & fft page)
    input               peak_en,
    input               theme,
    input               smooth_en,
    input       [9:0]   q_y,        // bar height 0..479 (from data_source, table lookup)
    input       [9:0]   q_ov,       // overshoot target 0..479 (frame-precomputed)
    input       [9:0]   pix_x,
    input       [9:0]   pix_y,

    output              fft_hit,    // pixel is part of a bar
    output      [5:0]   fft_r,
    output      [5:0]   fft_g,
    output      [5:0]   fft_b
);

    // peak-hold light dot color (bright cyan) and decay rate
    localparam TOP_R = 6'h00, TOP_G = 6'h34, TOP_B = 6'h34;
    parameter PEAK_HYST = 10'd12;     // bar must rise this much above peak to snap up
    parameter PEAK_FALL = 10'd1;      // peak drifts down by this on each decay event
    parameter FALL_PERIOD = 10'd96;   // line updates between decay steps

// ===== bar geometry: 128 bars, each 6 px wide (768 px used) =====
    // q_y/q_ov now arrive 1 clock after pix_x (registered RAM read in data_source).
    // Align pix_x/pix_y by 1 clock so ALL drawing reads the same column the
    // height belongs to. (The 1-pixel horizontal shift this introduces lands in
    // the LED gap pixels, which are black by design.)
    reg [9:0] pxx, pxy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pxx <= 10'd0; pxy <= 10'd0; end
        else begin pxx <= pix_x; pxy <= pix_y; end
    end

    // bar index counter: bar = floor(pix_x/6), advanced every 6 pixels.
    // This replaces the /6 or *10923 divider on the dot_ram path.
    reg [2:0] xmod_c;
    reg [6:0] bar_idx_c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xmod_c    <= 3'd0;
            bar_idx_c <= 7'd0;
        end
        else if (pix_x == 10'd0) begin
            xmod_c    <= 3'd0;
            bar_idx_c <= 7'd0;
        end
        else if (xmod_c == 3'd5) begin
            xmod_c <= 3'd0;
            if (bar_idx_c < 7'd127)
                bar_idx_c <= bar_idx_c + 1'b1;
        end
        else begin
            xmod_c <= xmod_c + 1'b1;
        end
    end

    wire [6:0] bar_idx = bar_idx_c;

    localparam logic [9:0] BASE_Y = 10'd479;
    localparam logic [9:0] MAX_H  = 10'd439;
    wire [9:0] q_y_lim  = (q_y  > MAX_H) ? MAX_H : q_y;
    wire [9:0] q_ov_lim = (q_ov > MAX_H) ? MAX_H : q_ov;
    wire [9:0] bar_top  = BASE_Y - q_y_lim;

    // bar body: from bottom up to bar_top
    wire in_bar = (q_y_lim > 10'd0) && (pxy >= bar_top) && (pxy <= BASE_Y);

// ===== hue shift: color band ROTATES (circular), not ping-pong =====
    // band is 192 long, wraps 191->0. The whole window slides around the ring.
    // HUE_STEP: color steps per update. HUE_DIV: frames between updates (slow it down).
    // total circle time = (192/HUE_STEP) * HUE_DIV frames. e.g. HUE_STEP=1,HUE_DIV=8
    // -> 192*8=1536 frames @52Hz ≈ 29.5s/circle.
    parameter HUE_STEP = 9'd1;
    parameter HUE_DIV  = 9'd8;
    reg  [8:0]  hue_shift;
    reg  [8:0]  hue_div_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hue_shift   <= 9'd0;
            hue_div_cnt <= 9'd0;
        end
        else if (frame_pulse) begin
            if (hue_div_cnt >= HUE_DIV - 9'd1) begin
                hue_div_cnt <= 9'd0;
                hue_shift   <= (hue_shift >= 9'd192 - HUE_STEP) ? 9'd0 : hue_shift + HUE_STEP;
            end
            else
                hue_div_cnt <= hue_div_cnt + 9'd1;
        end
    end

    // color index = (bar + shift) mod 192 : circular rotation
    wire [8:0]  hue_use = theme ? 9'd0 : hue_shift;
    wire [9:0]  idx_sum  = {1'b0, bar_idx} + {1'b0, hue_use};   // 0..191+127
    wire [8:0]  color_idx = (idx_sum >= 9'd192) ? (idx_sum - 9'd192) : idx_sum[8:0];

    // ===== color lookup: 128-bar rainbow (red->blue-cyan) =====
        reg  [5:0] c_r, c_g, c_b;
    always @(*) begin
        case (color_idx)
9'd0: begin c_r = 6'h34; c_g = 6'h04; c_b = 6'h04; end
9'd1: begin c_r = 6'h33; c_g = 6'h04; c_b = 6'h05; end
9'd2: begin c_r = 6'h32; c_g = 6'h04; c_b = 6'h06; end
9'd3: begin c_r = 6'h32; c_g = 6'h04; c_b = 6'h06; end
9'd4: begin c_r = 6'h31; c_g = 6'h04; c_b = 6'h07; end
9'd5: begin c_r = 6'h30; c_g = 6'h04; c_b = 6'h08; end
9'd6: begin c_r = 6'h2F; c_g = 6'h04; c_b = 6'h09; end
9'd7: begin c_r = 6'h2F; c_g = 6'h04; c_b = 6'h09; end
9'd8: begin c_r = 6'h2E; c_g = 6'h04; c_b = 6'h0A; end
9'd9: begin c_r = 6'h2D; c_g = 6'h04; c_b = 6'h0B; end
9'd10: begin c_r = 6'h2C; c_g = 6'h04; c_b = 6'h0C; end
9'd11: begin c_r = 6'h2C; c_g = 6'h04; c_b = 6'h0C; end
9'd12: begin c_r = 6'h2B; c_g = 6'h04; c_b = 6'h0D; end
9'd13: begin c_r = 6'h2A; c_g = 6'h04; c_b = 6'h0E; end
9'd14: begin c_r = 6'h29; c_g = 6'h04; c_b = 6'h0F; end
9'd15: begin c_r = 6'h29; c_g = 6'h04; c_b = 6'h0F; end
9'd16: begin c_r = 6'h28; c_g = 6'h04; c_b = 6'h10; end
9'd17: begin c_r = 6'h27; c_g = 6'h04; c_b = 6'h11; end
9'd18: begin c_r = 6'h26; c_g = 6'h04; c_b = 6'h12; end
9'd19: begin c_r = 6'h26; c_g = 6'h04; c_b = 6'h12; end
9'd20: begin c_r = 6'h25; c_g = 6'h04; c_b = 6'h13; end
9'd21: begin c_r = 6'h24; c_g = 6'h04; c_b = 6'h14; end
9'd22: begin c_r = 6'h23; c_g = 6'h04; c_b = 6'h15; end
9'd23: begin c_r = 6'h22; c_g = 6'h04; c_b = 6'h16; end
9'd24: begin c_r = 6'h22; c_g = 6'h04; c_b = 6'h16; end
9'd25: begin c_r = 6'h21; c_g = 6'h04; c_b = 6'h17; end
9'd26: begin c_r = 6'h20; c_g = 6'h04; c_b = 6'h18; end
9'd27: begin c_r = 6'h1F; c_g = 6'h04; c_b = 6'h19; end
9'd28: begin c_r = 6'h1F; c_g = 6'h04; c_b = 6'h19; end
9'd29: begin c_r = 6'h1E; c_g = 6'h04; c_b = 6'h1A; end
9'd30: begin c_r = 6'h1D; c_g = 6'h04; c_b = 6'h1B; end
9'd31: begin c_r = 6'h1C; c_g = 6'h04; c_b = 6'h1C; end
9'd32: begin c_r = 6'h1C; c_g = 6'h04; c_b = 6'h1C; end
9'd33: begin c_r = 6'h1B; c_g = 6'h04; c_b = 6'h1D; end
9'd34: begin c_r = 6'h1A; c_g = 6'h04; c_b = 6'h1E; end
9'd35: begin c_r = 6'h19; c_g = 6'h04; c_b = 6'h1F; end
9'd36: begin c_r = 6'h19; c_g = 6'h04; c_b = 6'h1F; end
9'd37: begin c_r = 6'h18; c_g = 6'h04; c_b = 6'h20; end
9'd38: begin c_r = 6'h17; c_g = 6'h04; c_b = 6'h21; end
9'd39: begin c_r = 6'h16; c_g = 6'h04; c_b = 6'h22; end
9'd40: begin c_r = 6'h16; c_g = 6'h04; c_b = 6'h22; end
9'd41: begin c_r = 6'h15; c_g = 6'h04; c_b = 6'h23; end
9'd42: begin c_r = 6'h14; c_g = 6'h04; c_b = 6'h24; end
9'd43: begin c_r = 6'h13; c_g = 6'h04; c_b = 6'h25; end
9'd44: begin c_r = 6'h12; c_g = 6'h04; c_b = 6'h26; end
9'd45: begin c_r = 6'h12; c_g = 6'h04; c_b = 6'h26; end
9'd46: begin c_r = 6'h11; c_g = 6'h04; c_b = 6'h27; end
9'd47: begin c_r = 6'h10; c_g = 6'h04; c_b = 6'h28; end
9'd48: begin c_r = 6'h0F; c_g = 6'h04; c_b = 6'h29; end
9'd49: begin c_r = 6'h0F; c_g = 6'h04; c_b = 6'h29; end
9'd50: begin c_r = 6'h0E; c_g = 6'h04; c_b = 6'h2A; end
9'd51: begin c_r = 6'h0D; c_g = 6'h04; c_b = 6'h2B; end
9'd52: begin c_r = 6'h0C; c_g = 6'h04; c_b = 6'h2C; end
9'd53: begin c_r = 6'h0C; c_g = 6'h04; c_b = 6'h2C; end
9'd54: begin c_r = 6'h0B; c_g = 6'h04; c_b = 6'h2D; end
9'd55: begin c_r = 6'h0A; c_g = 6'h04; c_b = 6'h2E; end
9'd56: begin c_r = 6'h09; c_g = 6'h04; c_b = 6'h2F; end
9'd57: begin c_r = 6'h09; c_g = 6'h04; c_b = 6'h2F; end
9'd58: begin c_r = 6'h08; c_g = 6'h04; c_b = 6'h30; end
9'd59: begin c_r = 6'h07; c_g = 6'h04; c_b = 6'h31; end
9'd60: begin c_r = 6'h06; c_g = 6'h04; c_b = 6'h32; end
9'd61: begin c_r = 6'h06; c_g = 6'h04; c_b = 6'h32; end
9'd62: begin c_r = 6'h05; c_g = 6'h04; c_b = 6'h33; end
9'd63: begin c_r = 6'h04; c_g = 6'h04; c_b = 6'h34; end
9'd64: begin c_r = 6'h04; c_g = 6'h04; c_b = 6'h34; end
9'd65: begin c_r = 6'h05; c_g = 6'h05; c_b = 6'h33; end
9'd66: begin c_r = 6'h06; c_g = 6'h06; c_b = 6'h32; end
9'd67: begin c_r = 6'h06; c_g = 6'h06; c_b = 6'h32; end
9'd68: begin c_r = 6'h07; c_g = 6'h07; c_b = 6'h31; end
9'd69: begin c_r = 6'h08; c_g = 6'h08; c_b = 6'h30; end
9'd70: begin c_r = 6'h09; c_g = 6'h09; c_b = 6'h2F; end
9'd71: begin c_r = 6'h09; c_g = 6'h09; c_b = 6'h2F; end
9'd72: begin c_r = 6'h0A; c_g = 6'h0A; c_b = 6'h2E; end
9'd73: begin c_r = 6'h0B; c_g = 6'h0B; c_b = 6'h2D; end
9'd74: begin c_r = 6'h0C; c_g = 6'h0C; c_b = 6'h2C; end
9'd75: begin c_r = 6'h0C; c_g = 6'h0C; c_b = 6'h2C; end
9'd76: begin c_r = 6'h0D; c_g = 6'h0D; c_b = 6'h2B; end
9'd77: begin c_r = 6'h0E; c_g = 6'h0E; c_b = 6'h2A; end
9'd78: begin c_r = 6'h0F; c_g = 6'h0F; c_b = 6'h29; end
9'd79: begin c_r = 6'h0F; c_g = 6'h0F; c_b = 6'h29; end
9'd80: begin c_r = 6'h10; c_g = 6'h10; c_b = 6'h28; end
9'd81: begin c_r = 6'h11; c_g = 6'h11; c_b = 6'h27; end
9'd82: begin c_r = 6'h12; c_g = 6'h12; c_b = 6'h26; end
9'd83: begin c_r = 6'h12; c_g = 6'h12; c_b = 6'h26; end
9'd84: begin c_r = 6'h13; c_g = 6'h13; c_b = 6'h25; end
9'd85: begin c_r = 6'h14; c_g = 6'h14; c_b = 6'h24; end
9'd86: begin c_r = 6'h15; c_g = 6'h15; c_b = 6'h23; end
9'd87: begin c_r = 6'h16; c_g = 6'h16; c_b = 6'h22; end
9'd88: begin c_r = 6'h16; c_g = 6'h16; c_b = 6'h22; end
9'd89: begin c_r = 6'h17; c_g = 6'h17; c_b = 6'h21; end
9'd90: begin c_r = 6'h18; c_g = 6'h18; c_b = 6'h20; end
9'd91: begin c_r = 6'h19; c_g = 6'h19; c_b = 6'h1F; end
9'd92: begin c_r = 6'h19; c_g = 6'h19; c_b = 6'h1F; end
9'd93: begin c_r = 6'h1A; c_g = 6'h1A; c_b = 6'h1E; end
9'd94: begin c_r = 6'h1B; c_g = 6'h1B; c_b = 6'h1D; end
9'd95: begin c_r = 6'h1C; c_g = 6'h1C; c_b = 6'h1C; end
9'd96: begin c_r = 6'h1C; c_g = 6'h1C; c_b = 6'h1C; end
9'd97: begin c_r = 6'h1D; c_g = 6'h1D; c_b = 6'h1B; end
9'd98: begin c_r = 6'h1E; c_g = 6'h1E; c_b = 6'h1A; end
9'd99: begin c_r = 6'h1F; c_g = 6'h1F; c_b = 6'h19; end
9'd100: begin c_r = 6'h1F; c_g = 6'h1F; c_b = 6'h19; end
9'd101: begin c_r = 6'h20; c_g = 6'h20; c_b = 6'h18; end
9'd102: begin c_r = 6'h21; c_g = 6'h21; c_b = 6'h17; end
9'd103: begin c_r = 6'h22; c_g = 6'h22; c_b = 6'h16; end
9'd104: begin c_r = 6'h22; c_g = 6'h22; c_b = 6'h16; end
9'd105: begin c_r = 6'h23; c_g = 6'h23; c_b = 6'h15; end
9'd106: begin c_r = 6'h24; c_g = 6'h24; c_b = 6'h14; end
9'd107: begin c_r = 6'h25; c_g = 6'h25; c_b = 6'h13; end
9'd108: begin c_r = 6'h26; c_g = 6'h26; c_b = 6'h12; end
9'd109: begin c_r = 6'h26; c_g = 6'h26; c_b = 6'h12; end
9'd110: begin c_r = 6'h27; c_g = 6'h27; c_b = 6'h11; end
9'd111: begin c_r = 6'h28; c_g = 6'h28; c_b = 6'h10; end
9'd112: begin c_r = 6'h29; c_g = 6'h29; c_b = 6'h0F; end
9'd113: begin c_r = 6'h29; c_g = 6'h29; c_b = 6'h0F; end
9'd114: begin c_r = 6'h2A; c_g = 6'h2A; c_b = 6'h0E; end
9'd115: begin c_r = 6'h2B; c_g = 6'h2B; c_b = 6'h0D; end
9'd116: begin c_r = 6'h2C; c_g = 6'h2C; c_b = 6'h0C; end
9'd117: begin c_r = 6'h2C; c_g = 6'h2C; c_b = 6'h0C; end
9'd118: begin c_r = 6'h2D; c_g = 6'h2D; c_b = 6'h0B; end
9'd119: begin c_r = 6'h2E; c_g = 6'h2E; c_b = 6'h0A; end
9'd120: begin c_r = 6'h2F; c_g = 6'h2F; c_b = 6'h09; end
9'd121: begin c_r = 6'h2F; c_g = 6'h2F; c_b = 6'h09; end
9'd122: begin c_r = 6'h30; c_g = 6'h30; c_b = 6'h08; end
9'd123: begin c_r = 6'h31; c_g = 6'h31; c_b = 6'h07; end
9'd124: begin c_r = 6'h32; c_g = 6'h32; c_b = 6'h06; end
9'd125: begin c_r = 6'h32; c_g = 6'h32; c_b = 6'h06; end
9'd126: begin c_r = 6'h33; c_g = 6'h33; c_b = 6'h05; end
9'd127: begin c_r = 6'h34; c_g = 6'h34; c_b = 6'h04; end
9'd128: begin c_r = 6'h34; c_g = 6'h34; c_b = 6'h04; end
9'd129: begin c_r = 6'h34; c_g = 6'h33; c_b = 6'h04; end
9'd130: begin c_r = 6'h34; c_g = 6'h32; c_b = 6'h04; end
9'd131: begin c_r = 6'h34; c_g = 6'h32; c_b = 6'h04; end
9'd132: begin c_r = 6'h34; c_g = 6'h31; c_b = 6'h04; end
9'd133: begin c_r = 6'h34; c_g = 6'h30; c_b = 6'h04; end
9'd134: begin c_r = 6'h34; c_g = 6'h2F; c_b = 6'h04; end
9'd135: begin c_r = 6'h34; c_g = 6'h2F; c_b = 6'h04; end
9'd136: begin c_r = 6'h34; c_g = 6'h2E; c_b = 6'h04; end
9'd137: begin c_r = 6'h34; c_g = 6'h2D; c_b = 6'h04; end
9'd138: begin c_r = 6'h34; c_g = 6'h2C; c_b = 6'h04; end
9'd139: begin c_r = 6'h34; c_g = 6'h2C; c_b = 6'h04; end
9'd140: begin c_r = 6'h34; c_g = 6'h2B; c_b = 6'h04; end
9'd141: begin c_r = 6'h34; c_g = 6'h2A; c_b = 6'h04; end
9'd142: begin c_r = 6'h34; c_g = 6'h29; c_b = 6'h04; end
9'd143: begin c_r = 6'h34; c_g = 6'h29; c_b = 6'h04; end
9'd144: begin c_r = 6'h34; c_g = 6'h28; c_b = 6'h04; end
9'd145: begin c_r = 6'h34; c_g = 6'h27; c_b = 6'h04; end
9'd146: begin c_r = 6'h34; c_g = 6'h26; c_b = 6'h04; end
9'd147: begin c_r = 6'h34; c_g = 6'h26; c_b = 6'h04; end
9'd148: begin c_r = 6'h34; c_g = 6'h25; c_b = 6'h04; end
9'd149: begin c_r = 6'h34; c_g = 6'h24; c_b = 6'h04; end
9'd150: begin c_r = 6'h34; c_g = 6'h23; c_b = 6'h04; end
9'd151: begin c_r = 6'h34; c_g = 6'h22; c_b = 6'h04; end
9'd152: begin c_r = 6'h34; c_g = 6'h22; c_b = 6'h04; end
9'd153: begin c_r = 6'h34; c_g = 6'h21; c_b = 6'h04; end
9'd154: begin c_r = 6'h34; c_g = 6'h20; c_b = 6'h04; end
9'd155: begin c_r = 6'h34; c_g = 6'h1F; c_b = 6'h04; end
9'd156: begin c_r = 6'h34; c_g = 6'h1F; c_b = 6'h04; end
9'd157: begin c_r = 6'h34; c_g = 6'h1E; c_b = 6'h04; end
9'd158: begin c_r = 6'h34; c_g = 6'h1D; c_b = 6'h04; end
9'd159: begin c_r = 6'h34; c_g = 6'h1C; c_b = 6'h04; end
9'd160: begin c_r = 6'h34; c_g = 6'h1C; c_b = 6'h04; end
9'd161: begin c_r = 6'h34; c_g = 6'h1B; c_b = 6'h04; end
9'd162: begin c_r = 6'h34; c_g = 6'h1A; c_b = 6'h04; end
9'd163: begin c_r = 6'h34; c_g = 6'h19; c_b = 6'h04; end
9'd164: begin c_r = 6'h34; c_g = 6'h19; c_b = 6'h04; end
9'd165: begin c_r = 6'h34; c_g = 6'h18; c_b = 6'h04; end
9'd166: begin c_r = 6'h34; c_g = 6'h17; c_b = 6'h04; end
9'd167: begin c_r = 6'h34; c_g = 6'h16; c_b = 6'h04; end
9'd168: begin c_r = 6'h34; c_g = 6'h16; c_b = 6'h04; end
9'd169: begin c_r = 6'h34; c_g = 6'h15; c_b = 6'h04; end
9'd170: begin c_r = 6'h34; c_g = 6'h14; c_b = 6'h04; end
9'd171: begin c_r = 6'h34; c_g = 6'h13; c_b = 6'h04; end
9'd172: begin c_r = 6'h34; c_g = 6'h12; c_b = 6'h04; end
9'd173: begin c_r = 6'h34; c_g = 6'h12; c_b = 6'h04; end
9'd174: begin c_r = 6'h34; c_g = 6'h11; c_b = 6'h04; end
9'd175: begin c_r = 6'h34; c_g = 6'h10; c_b = 6'h04; end
9'd176: begin c_r = 6'h34; c_g = 6'h0F; c_b = 6'h04; end
9'd177: begin c_r = 6'h34; c_g = 6'h0F; c_b = 6'h04; end
9'd178: begin c_r = 6'h34; c_g = 6'h0E; c_b = 6'h04; end
9'd179: begin c_r = 6'h34; c_g = 6'h0D; c_b = 6'h04; end
9'd180: begin c_r = 6'h34; c_g = 6'h0C; c_b = 6'h04; end
9'd181: begin c_r = 6'h34; c_g = 6'h0C; c_b = 6'h04; end
9'd182: begin c_r = 6'h34; c_g = 6'h0B; c_b = 6'h04; end
9'd183: begin c_r = 6'h34; c_g = 6'h0A; c_b = 6'h04; end
9'd184: begin c_r = 6'h34; c_g = 6'h09; c_b = 6'h04; end
9'd185: begin c_r = 6'h34; c_g = 6'h09; c_b = 6'h04; end
9'd186: begin c_r = 6'h34; c_g = 6'h08; c_b = 6'h04; end
9'd187: begin c_r = 6'h34; c_g = 6'h07; c_b = 6'h04; end
9'd188: begin c_r = 6'h34; c_g = 6'h06; c_b = 6'h04; end
9'd189: begin c_r = 6'h34; c_g = 6'h06; c_b = 6'h04; end
9'd190: begin c_r = 6'h34; c_g = 6'h05; c_b = 6'h04; end
9'd191: begin c_r = 6'h34; c_g = 6'h04; c_b = 6'h04; end

default: begin c_r = 6'h34; c_g = 6'h04; c_b = 6'h04; end
        endcase

        if (theme) begin
            c_r = {color_idx[7:3], 1'b0};
            c_g = {color_idx[7:3], 1'b0};
            c_b = {color_idx[7:3], 1'b0};
        end
    end

// ===== output: LED array style =====
    // Each bar is made of small square "LEDs" with black gaps between them.
    // Horizontal: bar is 6px wide; LED occupies middle 4px, 1px gap each side.
    // Vertical:   LEDs stack downward from the bar TOP, 4px tall with 1px gap.
    //             (bar top always aligns to a full LED => clean top edge + light dot)
    // Top "light dot": the topmost LED, shown white.

    // distance below the bar top: 0 at topmost pixel
    wire [9:0] dist_top = pxy - bar_top;
    // LED body in vertical: within a 5-row group (4 body + 1 gap), aligned from top
    wire [2:0] yg = dist_top % 10'd5;                // 0..4
    wire led_v = (yg <= 3'd3);                       // 4 rows on, 1 row gap

    // horizontal position within the 6px bar
    wire [2:0] xm = xmod_c;                         // 0..5
    wire led_h = (xm >= 3'd1) && (xm <= 3'd4);       // LED body 4px, 1px gap each side

    wire in_led = in_bar && led_h && led_v;          // a lit LED

    // ===== "ball" light dot: overshoots the bar, then settles down =====
    // dot_ram[bar] is the light-dot position. Physical-ball feel:
    //  - when the bar rises above the dot, the dot is BASHED UP to q_ov
    //    (frame-precomputed 1.2x target, no divider on the pixel path),
    //  - otherwise the dot slowly falls (gravity), but never below the bar
    //    height (it rests on the bar).
    // 2026-09-28 fixes:
    //  - q_ov comes precomputed from data_source (kills the -50ns divider path)
    //  - added dead-zone branch: if the dot ends up BELOW the bar top (bar rose
    //    by <PEAK_HYST), lift it to the bar top so it never gets buried
    //  - dot physics only run when dot_en (active FFT area) -> uniform per-bar
    //    update slots, blanking can't hammer bar0/bar127.

    reg  [9:0]  dot_ram[0:127];
    reg  [9:0]  fall_ram[0:127];   // per-bar fall timer (so bars don't interfere)
    integer pi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pi = 0; pi < 128; pi = pi + 1) begin
                dot_ram[pi]  <= 10'd0;
                fall_ram[pi] <= 10'd0;
            end
        end
        else if (dot_en && peak_en && (xm == 3'd1)) begin
            // physical bounce: bash up when bar rises past the dot -> overshoot,
            // then gravity pulls it down to rest on the bar top.
            if (q_y_lim > dot_ram[bar_idx]) begin
                dot_ram[bar_idx] <= q_ov_lim;
                fall_ram[bar_idx] <= 10'd0;
            end
            else if (dot_ram[bar_idx] > q_y_lim) begin
                if (fall_ram[bar_idx] >= FALL_PERIOD - 10'd1) begin
                    fall_ram[bar_idx] <= 10'd0;
                    if (dot_ram[bar_idx] - PEAK_FALL > q_y_lim)
                        dot_ram[bar_idx] <= dot_ram[bar_idx] - PEAK_FALL;
                    else
                        dot_ram[bar_idx] <= q_y_lim;
                end
                else
                    fall_ram[bar_idx] <= fall_ram[bar_idx] + 10'd1;
            end
        end
    end

    // light dot at the ball position of the current bar
    // The dot is INDEPENDENT of the bar body: drawn whenever we are in the bar's
    // column (6px wide) at the dot's height. So an overshooting dot above the
    // bar top is still visible (it is NOT gated by in_bar).
    wire [9:0] peak_h = (dot_ram[bar_idx] > MAX_H) ? MAX_H : dot_ram[bar_idx];
    wire [9:0] peak_top = BASE_Y - peak_h;
    wire in_bar_col  = (pxx >= {3'b0, bar_idx} * 10'd6) && (pxx < {3'b0, bar_idx} * 10'd6 + 10'd6);
    wire is_peak_dot = peak_en && (peak_h > 10'd0) && in_bar_col &&
                       (xm >= 3'd1) && (xm <= 3'd4) &&
                       (pxy >= peak_top) && (pxy <= peak_top + 10'd2);

    // LED gaps are black (in_bar but not in_led -> 0). Outside bar -> 0.
    // Priority: peak dot > LED body > gap.
    assign fft_hit = in_bar || is_peak_dot;

    wire edge_dim = smooth_en && ((xm == 3'd1) || (xm == 3'd4));
    wire [5:0] body_r = in_led ? (edge_dim ? {c_r[5:1], 1'b0} : c_r) : 6'h00;
    wire [5:0] body_g = in_led ? (edge_dim ? {c_g[5:1], 1'b0} : c_g) : 6'h00;
    wire [5:0] body_b = in_led ? (edge_dim ? {c_b[5:1], 1'b0} : c_b) : 6'h00;

    assign fft_r = is_peak_dot ? TOP_R : in_bar ? body_r : 6'h00;
    assign fft_g = is_peak_dot ? TOP_G : in_bar ? body_g : 6'h00;
    assign fft_b = is_peak_dot ? TOP_B : in_bar ? body_b : 6'h00;

endmodule

