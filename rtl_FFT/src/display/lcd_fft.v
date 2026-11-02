module lcd_fft #(parameter REVERSE_SCAN=1'b0) (
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
        else if (REVERSE_SCAN) begin
            if (pix_x >= 10'd767) begin
                xmod_c <= 3'd5;
                bar_idx_c <= 7'd127;
            end else if (xmod_c == 3'd0) begin
                xmod_c <= 3'd5;
                if (bar_idx_c != 0) bar_idx_c <= bar_idx_c - 1'b1;
            end else xmod_c <= xmod_c - 1'b1;
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
    wire in_bar = (pxx < 10'd768) && (q_y_lim > 10'd0) && (pxy >= bar_top) && (pxy <= BASE_Y);

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

    // ===== color lookup: exact 3-segment rainbow =====
    // The 192-entry case was the sampled form of:
    //   v(x) = (48*x + 31) / 63, x = color_idx % 64
    //   seg 0: (52-v, 4, 4+v)   seg 1: (4+v, 4+v, 52-v)
    //   seg 2: (52, 52-v, 4)
    // Keeping the 64-entry generator removes the 192-way 18-bit mux while
    // producing the identical RGB values (checked against all 192 entries).
    function automatic [5:0] tri_v(input [5:0] x);
        case (x)
            6'd0: tri_v = 6'd0;
            6'd1: tri_v = 6'd1;
            6'd2: tri_v = 6'd2;
            6'd3: tri_v = 6'd2;
            6'd4: tri_v = 6'd3;
            6'd5: tri_v = 6'd4;
            6'd6: tri_v = 6'd5;
            6'd7: tri_v = 6'd5;
            6'd8: tri_v = 6'd6;
            6'd9: tri_v = 6'd7;
            6'd10: tri_v = 6'd8;
            6'd11: tri_v = 6'd8;
            6'd12: tri_v = 6'd9;
            6'd13: tri_v = 6'd10;
            6'd14: tri_v = 6'd11;
            6'd15: tri_v = 6'd11;
            6'd16: tri_v = 6'd12;
            6'd17: tri_v = 6'd13;
            6'd18: tri_v = 6'd14;
            6'd19: tri_v = 6'd14;
            6'd20: tri_v = 6'd15;
            6'd21: tri_v = 6'd16;
            6'd22: tri_v = 6'd17;
            6'd23: tri_v = 6'd18;
            6'd24: tri_v = 6'd18;
            6'd25: tri_v = 6'd19;
            6'd26: tri_v = 6'd20;
            6'd27: tri_v = 6'd21;
            6'd28: tri_v = 6'd21;
            6'd29: tri_v = 6'd22;
            6'd30: tri_v = 6'd23;
            6'd31: tri_v = 6'd24;
            6'd32: tri_v = 6'd24;
            6'd33: tri_v = 6'd25;
            6'd34: tri_v = 6'd26;
            6'd35: tri_v = 6'd27;
            6'd36: tri_v = 6'd27;
            6'd37: tri_v = 6'd28;
            6'd38: tri_v = 6'd29;
            6'd39: tri_v = 6'd30;
            6'd40: tri_v = 6'd30;
            6'd41: tri_v = 6'd31;
            6'd42: tri_v = 6'd32;
            6'd43: tri_v = 6'd33;
            6'd44: tri_v = 6'd34;
            6'd45: tri_v = 6'd34;
            6'd46: tri_v = 6'd35;
            6'd47: tri_v = 6'd36;
            6'd48: tri_v = 6'd37;
            6'd49: tri_v = 6'd37;
            6'd50: tri_v = 6'd38;
            6'd51: tri_v = 6'd39;
            6'd52: tri_v = 6'd40;
            6'd53: tri_v = 6'd40;
            6'd54: tri_v = 6'd41;
            6'd55: tri_v = 6'd42;
            6'd56: tri_v = 6'd43;
            6'd57: tri_v = 6'd43;
            6'd58: tri_v = 6'd44;
            6'd59: tri_v = 6'd45;
            6'd60: tri_v = 6'd46;
            6'd61: tri_v = 6'd46;
            6'd62: tri_v = 6'd47;
            6'd63: tri_v = 6'd48;
            default: tri_v = 6'd48;
        endcase
    endfunction

    wire [5:0] c_v   = tri_v(color_idx[5:0]);
    wire [1:0] c_seg = color_idx[7:6];
    reg  [5:0] c_r, c_g, c_b;
    always @(*) begin
        case (c_seg)
            2'd0: begin c_r = 6'd52 - c_v; c_g = 6'd4;       c_b = 6'd4 + c_v; end
            2'd1: begin c_r = 6'd4 + c_v;  c_g = 6'd4 + c_v; c_b = 6'd52 - c_v; end
            default: begin c_r = 6'd52;    c_g = 6'd52 - c_v;c_b = 6'd4; end
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
    reg [6:0] peak_init_addr;
    reg peak_init_done;
    // Reset only this small controller. Both tables are cleared through their
    // normal write ports in 128 clocks, independently of page/peak selection.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            peak_init_addr <= 7'd0;
            peak_init_done <= 1'b0;
        end
        else if (!peak_init_done) begin
            if (peak_init_addr == 7'd127) peak_init_done <= 1'b1;
            else peak_init_addr <= peak_init_addr + 1'b1;
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (!peak_init_done) begin
                dot_ram[peak_init_addr] <= 10'd0;
                fall_ram[peak_init_addr] <= 10'd0;
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
    end

    // light dot at the ball position of the current bar
    // The dot is INDEPENDENT of the bar body: drawn whenever we are in the bar's
    // column (6px wide) at the dot's height. So an overshooting dot above the
    // bar top is still visible (it is NOT gated by in_bar).
    wire [9:0] peak_h = (dot_ram[bar_idx] > MAX_H) ? MAX_H : dot_ram[bar_idx];
    wire [9:0] peak_top = BASE_Y - peak_h;
    wire in_bar_col  = (pxx >= {3'b0, bar_idx} * 10'd6) && (pxx < {3'b0, bar_idx} * 10'd6 + 10'd6);
    wire is_peak_dot = rst_n && peak_init_done && peak_en && (peak_h > 10'd0) && in_bar_col &&
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

