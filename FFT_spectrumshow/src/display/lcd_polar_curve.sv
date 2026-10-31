// =============================================================================
// lcd_polar_curve.sv - polar FALL page renderer (inverse mapping, no frame RAM)
//
// Function
//   Draws the four FALL age curves on a polar (radar) dashboard.  Every pixel
//   is evaluated independently: the pixel position is converted to (radius,
//   angle) by a pipelined CORDIC, the angle selects one of the 768 curve
//   columns, and four radius comparisons produce the curve colour with a
//   three-level glow.  A decorative dashboard (gradient, rings, spokes,
//   ticks, bloom, rim) and a two-layer starfield with a meteor come from the
//   same radius/angle, so none of it needs storage.
//
// Data flow
//   pix_x/pix_y -> x_disp (advanced by LAT) -> dx/dy
//     -> cordic_polar (14 stages) -> radius, angle
//     -> angle*3/256 -> curve_rd_addr -> curve_rd_data (1 clock)
//     -> radius_of_height x4 -> glow level -> palette
//     -> compose dashboard / sky -> registered RGB -> lcd_draw
//
// Clock domain / timing
//   clk = clk_pix = 33.333 MHz, async active-low reset rst_n.
//   Pipeline latency LAT = 17 clocks (CORDIC 15 + curve read 1 + glow 1).
//   pix_x is advanced by LAT so the result belongs to the pixel being
//   scanned; the first LAT pixels of each line carry no valid data.
//   frame_pulse only advances the sky animation (twinkle, meteor).
//
// Geometry
//   R_BASE = 190 px.  A curve height h (0..479) maps to
//   R = 190 - h*150/512 px, so the inner radius is ~49.7 px.
//   The angle is produced with CORDIC inputs (dy, dx): theta = 0 at
//   12 o'clock and increases clockwise.  theta = 0 selects curve column 0.
//
// Notes
//   No atan2/sqrt table, no line rasteriser, no double bank.  Ports follow
//   the existing display-module style (no _i/_o suffix, see lcd_draw).
// =============================================================================
`timescale 1ns/1ps

module lcd_polar_curve #(
    parameter int CX  = 400,   // circle centre x (pixels)
    parameter int CY  = 240,   // circle centre y (pixels)
    parameter int LAT = 17,    // pipeline latency, must match the RTL
    parameter bit REVERSE_SCAN = 1'b0
) (
    input  logic        clk,            // 33.333 MHz pixel clock
    input  logic        rst_n,          // async active-low reset
    input  logic        frame_pulse,    // one-clock pulse per displayed frame
    input  logic        lcd_valid,      // current pixel inside the active area
    input  logic [9:0]  pix_x,          // pixel x, 0..799 in the active area
    input  logic [9:0]  pix_y,          // pixel y, 0..479 in the active area
    output logic [9:0]  curve_rd_addr,  // curve_store read address (0..767)
    input  logic [39:0] curve_rd_data,  // {cur, old, mid, recent}, 10 bit each
    input  logic        theme,          // 1 = monochrome palette
    output logic        hit,            // page pixel is opaque (always 1 here)
    output logic [5:0]  r,              // 6-bit red
    output logic [5:0]  g,              // 6-bit green
    output logic [5:0]  b               // 6-bit blue
);

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    localparam int W    = 20;   // CORDIC datapath width
    localparam int FRAC = 7;    // fractional bits added at the CORDIC input
    localparam int NST  = 14;   // CORDIC stages

    // CORDIC gain K = 1.6467603; one pixel of radius is K*2^FRAC = 210.785
    // raw units.  190 px -> 40049 raw; 1 px -> 211 raw.
    localparam logic [15:0] RAW_RING = 16'd40049;   // R_BASE = 190 px
    localparam logic [19:0] RAW_EDGE = 20'd40300;   // 191.2 px: page seam
    localparam logic [11:0] K_SCALE  = 12'd3952;    // 61.755 * 64

    // Curve glow thresholds in raw units (211 raw = 1 px)
    localparam logic [19:0] GLOW_CORE  = 20'd200;   // < 0.95 px: full colour
    localparam logic [19:0] GLOW_INNER = 20'd460;   // < 2.2 px: 50 %
    localparam logic [19:0] GLOW_HALO  = 20'd950;   // < 4.5 px: 25 %

    // Dashboard geometry (raw units, 1 px = 211)
    localparam logic [19:0] RING1_LO = 20'd9896;    // 47.5 px - 0.55 px
    localparam logic [19:0] RING1_HI = 20'd10128;
    localparam logic [19:0] RING2_LO = 20'd19909;   // 95 px
    localparam logic [19:0] RING2_HI = 20'd20141;
    localparam logic [19:0] RING3_LO = 20'd29921;   // 142.5 px
    localparam logic [19:0] RING3_HI = 20'd30153;

    localparam logic [11:0] SPOKE_WIDTH = 12'd45;   // 0.25 deg each side
    localparam logic [9:0]  TICK_WIDTH  = 10'd64;   // 0.35 deg
    localparam logic [19:0] TICK_R_LO   = 20'd38363; // 182 px
    localparam logic [19:0] TICK_R_HI   = 20'd40120; // 190.3 px

    localparam logic [19:0] BLOOM_R     = 20'd1054;  // 5 px
    localparam logic [19:0] BLOOM2_R    = 20'd2530;  // 12 px
    localparam logic [19:0] RIM_LO      = 20'd39850; // 189 px
    localparam logic [19:0] RIM_HI      = 20'd40250; // 191 px
    localparam logic [19:0] RIMHALO_LO  = 20'd39200; // 186 px
    localparam logic [19:0] RIMHALO_HI  = 20'd40900; // 194 px

    localparam logic [19:0] HALO_SPAN   = 20'd14000; // 66 px outward
    localparam logic [19:0] HALO_STEP   = 20'd1024;  // 4.9 px per level
    localparam logic [3:0]  HALO_MAX    = 4'd15;     // level at the rim

    localparam logic [19:0] ARC1_LO = 20'd44115;     // 210 px
    localparam logic [19:0] ARC1_HI = 20'd44415;
    localparam logic [19:0] ARC2_LO = 20'd48752;     // 232 px
    localparam logic [19:0] ARC2_HI = 20'd49052;
    localparam logic [13:0] ARC_WIN = 14'd6000;      // 33 deg per quadrant

    // Starfield hash: seed -> xor-shift -> multiply -> xor-shift.  The
    // multiply is the avalanche step; without it the linear seed shows
    // visible diagonal stripes.
    localparam logic [15:0] FAR_SEED_X  = 16'd73;
    localparam logic [15:0] FAR_SEED_Y  = 16'd151;
    localparam logic [15:0] NEAR_SEED_X = 16'd197;
    localparam logic [15:0] NEAR_SEED_Y = 16'd131;
    localparam logic [15:0] HASH_MIX    = 16'd11421; // 0x2C9D
    localparam logic [7:0]  FAR_DENSITY = 8'd16;     // 16/256 of 4x4 cells
    localparam logic [7:0]  NEAR_DENSITY= 8'd8;      // 8/256 of 8x8 cells
    localparam logic [5:0]  FAR_LEVEL    = 6'd8;     // 8..15
    localparam logic [5:0]  NEAR_LEVEL   = 6'd14;    // 14..29
    localparam logic [6:0]  TWINKLE_HALF = 7'd127;   // 128-frame triangle

    // Meteor: one every 170 frames (~3.24 s at 52.5 fps), 45 degree line,
    // 64 px fading trail, drawn over the whole page.
    localparam logic [7:0]  METEOR_PERIOD = 8'd170;  // frames between meteors
    localparam logic [7:0]  METEOR_FRAMES = 8'd56;   // visible frames
    localparam logic [9:0]  METEOR_STEP   = 10'd16;  // x advance per frame
    localparam logic [9:0]  METEOR_X0     = 10'd40;  // start offset
    localparam logic [9:0]  METEOR_Y0     = 10'd40;  // lowest start y
    localparam logic [9:0]  METEOR_TRAIL  = 10'd64;  // trail length
    localparam logic [5:0]  METEOR_LEVEL  = 6'd24;   // head brightness
    localparam logic signed [11:0] METEOR_TOL = 12'sd3;

    // ------------------------------------------------------------------
    // Pixel coordinate and CORDIC
    // ------------------------------------------------------------------
    // The CORDIC output belongs to the pixel LAT clocks ago.  Advancing x by
    // LAT makes the result belong to the pixel being scanned now.
    wire [10:0] x_disp = REVERSE_SCAN ? ({1'b0, pix_x} - LAT[10:0]) : ({1'b0, pix_x} + LAT[10:0]);
    wire signed [10:0] dx = $signed(x_disp) - CX[10:0];
    wire signed [10:0] dy = CY[10:0] - $signed({1'b0, pix_y});

    wire [W-1:0] cord_r;    // raw radius = K * r * 2^FRAC
    wire [15:0]  cord_a;    // angle, BAM (2*pi = 65536)
    wire         cord_v;    // CORDIC output valid

    // (x, y) = (dy, dx): theta = 0 at 12 o'clock, clockwise
    cordic_polar #(
        .N    (NST),
        .IN_W (11),
        .FRAC (FRAC),
        .W    (W)
    ) u_cord (
        .clk       (clk),
        .rst_n     (rst_n),
        .x_in      (dy),
        .y_in      (dx),
        .in_valid  (lcd_valid),
        .r_out     (cord_r),
        .ang_out   (cord_a),
        .out_valid (cord_v)
    );

    // angle -> curve column: theta * 768 / 65536 = theta * 3 / 256
    wire [17:0] col_times3 = {2'b0, cord_a} * 18'd3;
    assign curve_rd_addr = col_times3[17:8];

    // ------------------------------------------------------------------
    // Curve height -> radius in CORDIC raw units
    //   R = 190 - h*150/512 px  ->  R_raw = 40049 - h*61.755
    // ------------------------------------------------------------------
    function automatic [15:0] radius_of_height(input [9:0] h);
        logic [21:0] product;
        product = h * K_SCALE;
        radius_of_height = RAW_RING - product[21:6];
    endfunction

    wire [15:0] r_cur_raw = radius_of_height(curve_rd_data[39:30]);
    wire [15:0] r_old_raw = radius_of_height(curve_rd_data[29:20]);
    wire [15:0] r_mid_raw = radius_of_height(curve_rd_data[19:10]);
    wire [15:0] r_rec_raw = radius_of_height(curve_rd_data[9:0]);

    // ------------------------------------------------------------------
    // Post-CORDIC pipeline
    //   p1 : curve_rd_data is valid, radius/angle registered
    //   p2 : radii and valid registered, glow/background computed
    // ------------------------------------------------------------------
    logic [W-1:0] radius_p1, radius_p2;
    logic [15:0]  angle_p1, angle_p2;
    logic [15:0]  r_cur_q, r_old_q, r_mid_q, r_rec_q;
    logic         valid_p1, valid_p2;

    wire [19:0] radius_q = radius_p2;

    wire [19:0] dist_cur = (radius_q > {4'b0, r_cur_q}) ? (radius_q - {4'b0, r_cur_q})
                                                        : ({4'b0, r_cur_q} - radius_q);
    wire [19:0] dist_old = (radius_q > {4'b0, r_old_q}) ? (radius_q - {4'b0, r_old_q})
                                                        : ({4'b0, r_old_q} - radius_q);
    wire [19:0] dist_mid = (radius_q > {4'b0, r_mid_q}) ? (radius_q - {4'b0, r_mid_q})
                                                        : ({4'b0, r_mid_q} - radius_q);
    wire [19:0] dist_rec = (radius_q > {4'b0, r_rec_q}) ? (radius_q - {4'b0, r_rec_q})
                                                        : ({4'b0, r_rec_q} - radius_q);

    // ------------------------------------------------------------------
    // Curve glow: 2-bit level per age, brightest wins, ties to the newest
    // ------------------------------------------------------------------
    wire [1:0] glow_cur = (dist_cur <= GLOW_CORE)  ? 2'd3 :
                          (dist_cur <= GLOW_INNER) ? 2'd2 :
                          (dist_cur <= GLOW_HALO)  ? 2'd1 : 2'd0;
    wire [1:0] glow_rec = (dist_rec <= GLOW_CORE)  ? 2'd3 :
                          (dist_rec <= GLOW_INNER) ? 2'd2 :
                          (dist_rec <= GLOW_HALO)  ? 2'd1 : 2'd0;
    wire [1:0] glow_mid = (dist_mid <= GLOW_CORE)  ? 2'd3 :
                          (dist_mid <= GLOW_INNER) ? 2'd2 :
                          (dist_mid <= GLOW_HALO)  ? 2'd1 : 2'd0;
    wire [1:0] glow_old = (dist_old <= GLOW_CORE)  ? 2'd3 :
                          (dist_old <= GLOW_INNER) ? 2'd2 :
                          (dist_old <= GLOW_HALO)  ? 2'd1 : 2'd0;

    wire [1:0] glow_max_01 = (glow_cur >= glow_rec) ? glow_cur : glow_rec;
    wire [1:0] glow_max_23 = (glow_mid >= glow_old) ? glow_mid : glow_old;
    wire [1:0] glow_max    = (glow_max_01 >= glow_max_23) ? glow_max_01 : glow_max_23;

    wire [2:0] glow_sel = (glow_max == 2'd0)   ? 3'd0 :
                          (glow_cur == glow_max) ? 3'd1 :
                          (glow_rec == glow_max) ? 3'd2 :
                          (glow_mid == glow_max) ? 3'd3 :
                          (glow_old == glow_max) ? 3'd4 : 3'd0;

    // ------------------------------------------------------------------
    // Dashboard background (pure function of radius and angle)
    // ------------------------------------------------------------------
    wire [4:0] grad_level = radius_q[15:11];         // 0..19, linear in r
    wire [8:0] grad_sq    = grad_level * grad_level; // quadratic falloff
    wire [3:0] grad_quad  = grad_sq[8:5];            // 0..11 at the rim

    wire ring_lo = (radius_q > RING1_LO) && (radius_q < RING1_HI);
    wire ring_md = (radius_q > RING2_LO) && (radius_q < RING2_HI);
    wire ring_hi = (radius_q > RING3_LO) && (radius_q < RING3_HI);

    wire spoke = (angle_p2[11:0] < SPOKE_WIDTH) || (angle_p2[11:0] > (12'd4096 - SPOKE_WIDTH));
    wire tick  = (angle_p2[9:0] < TICK_WIDTH) && (radius_q > TICK_R_LO) && (radius_q < TICK_R_HI);

    wire bloom   = (radius_q < BLOOM_R);
    wire bloom2  = (radius_q < BLOOM2_R);
    wire rim     = (radius_q > RIM_LO) && (radius_q < RIM_HI);
    wire rimhalo = (radius_q > RIMHALO_LO) && (radius_q < RIMHALO_HI);

    // additive colour per element (r, g, b)
    wire [4:0] add_ring_r = (ring_lo | ring_md | ring_hi) ? 5'd2 : 5'd0;
    wire [4:0] add_ring_g = (ring_lo | ring_md | ring_hi) ? 5'd4 : 5'd0;
    wire [4:0] add_ring_b = (ring_lo | ring_md | ring_hi) ? 5'd6 : 5'd0;
    wire [4:0] add_spoke_r = spoke ? 5'd1 : 5'd0;
    wire [4:0] add_spoke_g = spoke ? 5'd3 : 5'd0;
    wire [4:0] add_spoke_b = spoke ? 5'd4 : 5'd0;
    wire [4:0] add_tick_r  = tick  ? 5'd3 : 5'd0;
    wire [4:0] add_tick_g  = tick  ? 5'd6 : 5'd0;
    wire [4:0] add_tick_b  = tick  ? 5'd8 : 5'd0;
    wire [4:0] add_rim_r   = rim ? 5'd10 : (rimhalo ? 5'd2 : 5'd0);
    wire [4:0] add_rim_g   = rim ? 5'd14 : (rimhalo ? 5'd3 : 5'd0);
    wire [4:0] add_rim_b   = rim ? 5'd18 : (rimhalo ? 5'd4 : 5'd0);
    wire [4:0] add_bloom_r = bloom ? 5'd18 : (bloom2 ? 5'd6 : 5'd0);
    wire [4:0] add_bloom_g = bloom ? 5'd18 : (bloom2 ? 5'd6 : 5'd0);
    wire [4:0] add_bloom_b = bloom ? 5'd22 : (bloom2 ? 5'd8 : 5'd0);

    wire [7:0] bg_r_sum = {5'b0, grad_quad[3:2]} + {3'b0, add_ring_r} + {3'b0, add_spoke_r}
                        + {3'b0, add_tick_r} + {3'b0, add_rim_r} + {3'b0, add_bloom_r};
    wire [7:0] bg_g_sum = {4'b0, grad_quad[3:1]} + {3'b0, add_ring_g} + {3'b0, add_spoke_g}
                        + {3'b0, add_tick_g} + {3'b0, add_rim_g} + {3'b0, add_bloom_g};
    wire [7:0] bg_b_sum = {4'b0, grad_quad}      + {3'b0, add_ring_b} + {3'b0, add_spoke_b}
                        + {3'b0, add_tick_b} + {3'b0, add_rim_b} + {3'b0, add_bloom_b};

    wire [5:0] bg_r = (bg_r_sum > 8'd63) ? 6'd63 : bg_r_sum[5:0];
    wire [5:0] bg_g = (bg_g_sum > 8'd63) ? 6'd63 : bg_g_sum[5:0];
    wire [5:0] bg_b = (bg_b_sum > 8'd63) ? 6'd63 : bg_b_sum[5:0];

    // ------------------------------------------------------------------
    // Curve palette and glow scaling (100 % / 50 % / 25 %)
    // ------------------------------------------------------------------
    reg [5:0] pal_r, pal_g, pal_b;
    always_comb begin
        pal_r = 6'h00;
        pal_g = 6'h00;
        pal_b = 6'h00;
        if (!theme) begin
            case (glow_sel)
                3'd1: begin pal_r = 6'h3F; pal_g = 6'h3F; pal_b = 6'h00; end // age 0
                3'd2: begin pal_r = 6'h00; pal_g = 6'h3F; pal_b = 6'h3F; end // age 3
                3'd3: begin pal_r = 6'h3F; pal_g = 6'h00; pal_b = 6'h3F; end // age 7
                3'd4: begin pal_r = 6'h00; pal_g = 6'h10; pal_b = 6'h3F; end // age 15
                default: ;
            endcase
        end
        else begin
            case (glow_sel)
                3'd1: begin pal_r = 6'h3F; pal_g = 6'h3F; pal_b = 6'h3F; end
                3'd2: begin pal_r = 6'h30; pal_g = 6'h30; pal_b = 6'h30; end
                3'd3: begin pal_r = 6'h1C; pal_g = 6'h1C; pal_b = 6'h1C; end
                3'd4: begin pal_r = 6'h10; pal_g = 6'h10; pal_b = 6'h10; end
                default: ;
            endcase
        end
    end

    wire [5:0] glow_r = (glow_max == 2'd3) ? pal_r :
                        (glow_max == 2'd2) ? {1'b0, pal_r[5:1]} : {2'b0, pal_r[5:2]};
    wire [5:0] glow_g = (glow_max == 2'd3) ? pal_g :
                        (glow_max == 2'd2) ? {1'b0, pal_g[5:1]} : {2'b0, pal_g[5:2]};
    wire [5:0] glow_b = (glow_max == 2'd3) ? pal_b :
                        (glow_max == 2'd2) ? {1'b0, pal_b[5:1]} : {2'b0, pal_b[5:2]};

    // inside the circle: dashboard + curve glow, saturating
    wire [6:0] in_r_sum = {1'b0, bg_r} + {1'b0, glow_r};
    wire [6:0] in_g_sum = {1'b0, bg_g} + {1'b0, glow_g};
    wire [6:0] in_b_sum = {1'b0, bg_b} + {1'b0, glow_b};

    wire [5:0] in_r = (in_r_sum > 7'd63) ? 6'd63 : in_r_sum[5:0];
    wire [5:0] in_g = (in_g_sum > 7'd63) ? 6'd63 : in_g_sum[5:0];
    wire [5:0] in_b = (in_b_sum > 7'd63) ? 6'd63 : in_b_sum[5:0];

    // ------------------------------------------------------------------
    // Sky: two parallax layers + meteor (no storage)
    //   far : 4x4 cells, 1 px, 8..15, steady
    //   near: 8x8 cells, 2x2 px, 14..29, twinkles with its own phase
    // ------------------------------------------------------------------
    logic [15:0] frame_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            frame_cnt <= '0;
        else if (frame_pulse)
            frame_cnt <= frame_cnt + 16'd1;
    end

    // far layer
    // The sky has only one register of lookahead before RGB, unlike the
    // 17-cycle CORDIC path. Keep its logical position stable in either scan
    // direction instead of shifting the star field by the CORDIC latency.
    wire [10:0] sky_x = REVERSE_SCAN ? ({1'b0,pix_x}-11'd1) : ({1'b0,pix_x}+11'd1);
    wire [7:0]  far_cell_x = sky_x[9:2];
    wire [7:0]  far_cell_y = pix_y[9:2];
    wire [15:0] far_seed   = {8'b0, far_cell_x} * FAR_SEED_X
                           + {8'b0, far_cell_y} * FAR_SEED_Y;
    wire [15:0] far_mix1   = far_seed ^ (far_seed >> 7);
    wire [15:0] far_mix2   = far_mix1 * HASH_MIX;
    wire [7:0]  far_hash   = far_mix2[7:0] ^ {1'b0, far_mix2[15:9]};
    wire far_pixel = (far_hash < FAR_DENSITY)
                  && (sky_x[1:0] == far_hash[1:0])
                  && (pix_y[1:0]  == far_hash[3:2]);
    wire [5:0] far_level = far_pixel ? (FAR_LEVEL + {3'b0, far_mix2[12:10]}) : 6'd0;

    // near layer (different seeds so the two skies are independent)
    wire [6:0]  near_cell_x = sky_x[9:3];
    wire [6:0]  near_cell_y = pix_y[9:3];
    wire [15:0] near_seed   = {9'b0, near_cell_x} * NEAR_SEED_X
                            + {9'b0, near_cell_y} * NEAR_SEED_Y;
    wire [15:0] near_mix1   = near_seed ^ (near_seed >> 7);
    wire [15:0] near_mix2   = near_mix1 * HASH_MIX;
    wire [7:0]  near_hash   = near_mix2[7:0] ^ {1'b0, near_mix2[15:9]};
    wire near_pixel = (near_hash < NEAR_DENSITY)
                   && (sky_x[2:1] == near_hash[1:0])
                   && (pix_y[2:1]  == near_hash[3:2]);
    wire [5:0] near_base = NEAR_LEVEL + {2'b0, near_mix2[11:8]};

    wire [6:0] twinkle_phase = frame_cnt[6:0] + near_hash[6:0];
    wire [6:0] twinkle_tri   = twinkle_phase[6] ? (TWINKLE_HALF - twinkle_phase)
                                                : twinkle_phase;
    wire [1:0] twinkle_level = twinkle_tri[5:4];
    wire [5:0] near_level = !near_pixel ? 6'd0 :
                            (twinkle_level == 2'd3) ? near_base :
                            (twinkle_level == 2'd2) ? (near_base - {2'b0, near_base[5:2]}) :
                            (twinkle_level == 2'd1) ? {1'b0, near_base[5:1]}
                                                    : {2'b0, near_base[5:2]};

    // meteor: one every 170 frames (~3.2 s), 45 degree line, 16 px per frame
    logic [7:0] meteor_phase;   // 0 .. METEOR_PERIOD-1
    logic [7:0] meteor_index;   // advances once per meteor (varies its y)

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meteor_phase <= 8'd0;
            meteor_index <= 8'd0;
        end
        else if (frame_pulse) begin
            if (meteor_phase == METEOR_PERIOD - 8'd1) begin
                meteor_phase <= 8'd0;
                meteor_index <= meteor_index + 8'd1;
            end
            else begin
                meteor_phase <= meteor_phase + 8'd1;
            end
        end
    end

    wire        meteor_active = (meteor_phase < METEOR_FRAMES);
    wire [9:0]  meteor_head_x = {2'b0, meteor_phase} * METEOR_STEP - METEOR_X0;
    wire [9:0]  meteor_y0     = METEOR_Y0 + {meteor_index[5:0], 2'b00};
    wire signed [11:0] meteor_delta = $signed({2'b0, pix_y})
                                    - $signed({2'b0, sky_x[9:0]})
                                    - $signed({2'b0, meteor_y0}) - 12'sd40;
    wire meteor_on_line = (meteor_delta > -METEOR_TOL) && (meteor_delta < METEOR_TOL);
    wire [9:0] meteor_back = meteor_head_x - sky_x[9:0];
    wire meteor_in_trail = meteor_active && meteor_on_line
                        && (sky_x[9:0] <= meteor_head_x)
                        && (meteor_back < METEOR_TRAIL);
    wire [5:0] meteor_level = meteor_in_trail
                            ? (METEOR_LEVEL - {2'b0, meteor_back[5:2]}) : 6'd0;

    wire [6:0] sky_sum   = {1'b0, far_level} + {1'b0, near_level};
    wire [5:0] sky_level = (sky_sum > 7'd63) ? 6'd63 : sky_sum[5:0];

    // Register the sky one stage before the RGB mux: this keeps the hash
    // multipliers off the path that ends at the RGB register.  The star
    // pattern shifts by one pixel, which is invisible for noise.
    logic [5:0] sky_level_q, meteor_level_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sky_level_q    <= 6'd0;
            meteor_level_q <= 6'd0;
        end
        else if (valid_p2) begin
            sky_level_q    <= sky_level;
            meteor_level_q <= meteor_level;
        end
        else begin
            sky_level_q    <= 6'd0;
            meteor_level_q <= 6'd0;
        end
    end

    // halo: from the rim outward, 15 -> 0 over ~66 px
    wire [19:0] radius_out = radius_q - {4'b0, RAW_RING};
    wire [3:0]  halo_level = (radius_q <= {4'b0, RAW_RING}) ? 4'd0 :
                             (radius_out > HALO_SPAN) ? 4'd0
                             : (HALO_MAX - radius_out[13:10]);

    // two broken arcs, 33 deg window per quadrant
    wire [13:0] angle_q14 = angle_p2[13:0];
    wire arc_window = (angle_q14 < ARC_WIN);
    wire arc1 = (radius_q > ARC1_LO) && (radius_q < ARC1_HI);
    wire arc2 = (radius_q > ARC2_LO) && (radius_q < ARC2_HI);
    wire arc  = arc_window && (arc1 || arc2);

    wire [7:0] out_r_sum = {2'b0, sky_level_q} + {4'b0, halo_level[3:2]}
                         + (arc ? 8'd2 : 8'd0);
    wire [7:0] out_g_sum = {2'b0, sky_level_q} + {3'b0, halo_level[3:1]}
                         + (arc ? 8'd6 : 8'd0);
    wire [7:0] out_b_sum = {2'b0, sky_level_q} + {2'b0, halo_level}
                         + (arc ? 8'd8 : 8'd0);

    wire [5:0] out_r = (out_r_sum > 8'd63) ? 6'd63 : out_r_sum[5:0];
    wire [5:0] out_g = (out_g_sum > 8'd63) ? 6'd63 : out_g_sum[5:0];
    wire [5:0] out_b = (out_b_sum > 8'd63) ? 6'd63 : out_b_sum[5:0];

    // ------------------------------------------------------------------
    // Compose inside / outside, add the meteor, monochrome theme
    // ------------------------------------------------------------------
    wire page_in = (radius_q <= RAW_EDGE);

    wire [5:0] base_r = page_in ? (theme ? in_g : in_r) : (theme ? out_g : out_r);
    wire [5:0] base_g = page_in ? in_g                  : out_g;
    wire [5:0] base_b = page_in ? (theme ? in_g : in_b) : (theme ? out_g : out_b);

    wire [6:0] fin_r_sum = {1'b0, base_r} + {1'b0, meteor_level_q};
    wire [6:0] fin_g_sum = {1'b0, base_g} + {1'b0, meteor_level_q};
    wire [6:0] fin_b_sum = {1'b0, base_b} + {1'b0, meteor_level_q};

    wire [5:0] fin_r = (fin_r_sum > 7'd63) ? 6'd63 : fin_r_sum[5:0];
    wire [5:0] fin_g = (fin_g_sum > 7'd63) ? 6'd63 : fin_g_sum[5:0];
    wire [5:0] fin_b = (fin_b_sum > 7'd63) ? 6'd63 : fin_b_sum[5:0];

    // ------------------------------------------------------------------
    // Output registers
    // ------------------------------------------------------------------
    logic [5:0] r_out_q, g_out_q, b_out_q;
    logic       hit_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            radius_p1 <= '0;
            radius_p2 <= '0;
            angle_p1  <= '0;
            angle_p2  <= '0;
            r_cur_q   <= '0;
            r_old_q   <= '0;
            r_mid_q   <= '0;
            r_rec_q   <= '0;
            valid_p1  <= 1'b0;
            valid_p2  <= 1'b0;
            r_out_q   <= 6'd0;
            g_out_q   <= 6'd0;
            b_out_q   <= 6'd0;
            hit_q     <= 1'b0;
        end
        else begin
            radius_p1 <= cord_r;
            radius_p2 <= radius_p1;
            angle_p1  <= cord_a;
            angle_p2  <= angle_p1;
            r_cur_q   <= r_cur_raw;
            r_old_q   <= r_old_raw;
            r_mid_q   <= r_mid_raw;
            r_rec_q   <= r_rec_raw;
            valid_p1  <= cord_v;
            valid_p2  <= valid_p1;

            if (valid_p2) begin
                r_out_q <= fin_r;
                g_out_q <= fin_g;
                b_out_q <= fin_b;
                hit_q   <= 1'b1;
            end
            else begin
                r_out_q <= 6'd0;
                g_out_q <= 6'd0;
                b_out_q <= 6'd0;
                hit_q   <= 1'b0;
            end
        end
    end

    assign hit = hit_q;
    assign r   = r_out_q;
    assign g   = g_out_q;
    assign b   = b_out_q;

endmodule
