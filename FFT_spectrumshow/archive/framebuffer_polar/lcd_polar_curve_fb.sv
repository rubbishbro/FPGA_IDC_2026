// lcd_polar_curve.sv - polar FALL curve renderer
//
// 128-angle closed polylines for four age curves. The base circle is the
// OUTER boundary (R_BASE) and signal magnitude moves the curve inward.
// 2px lines are drawn into an 800x480 4bpp double-banked framebuffer.
// No fill, no per-pixel atan2/sqrt, no inverse polar map.
`timescale 1ns/1ps

module lcd_polar_curve #(
    parameter int CX     = 400,
    parameter int CY     = 240,
    parameter int R_BASE = 190,
    parameter int R_MIN  = 40
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        frame_pulse,
    input  logic        lcd_valid,
    input  logic [9:0]  pix_x,
    input  logic [9:0]  pix_y,
    output logic [9:0]  curve_rd_addr,
    input  logic [39:0] curve_rd_data,
    input  logic        theme,
    output logic        hit,
    output logic [5:0]  r,
    output logic [5:0]  g,
    output logic [5:0]  b,
    output logic        render_done
);

    localparam int FB_W = 800;
    localparam int FB_H = 480;
    localparam int FB_BYTES = (FB_W * FB_H) / 2; // 4bpp packed bytes
    localparam int FB_AW    = $clog2(FB_BYTES); // 18
    localparam int SPAN     = R_BASE - R_MIN;

    localparam logic [3:0] S_CLEAR     = 4'd0;
    localparam logic [3:0] S_POINT     = 4'd1;
    localparam logic [3:0] S_WAIT      = 4'd2;
    localparam logic [3:0] S_TAKE      = 4'd3;
    localparam logic [3:0] S_LINE_INIT = 4'd4;
    localparam logic [3:0] S_LINE      = 4'd5;
    localparam logic [3:0] S_LINE_DONE = 4'd6;
    localparam logic [3:0] S_IDLE      = 4'd7;

    localparam logic [1:0] P_READ  = 2'd0;
    localparam logic [1:0] P_WRITE = 2'd1;
    localparam logic [1:0] P_ADV   = 2'd2;

    // ------------------------------------------------------------------
    // 4bpp double framebuffer. Draw uses the back bank, LCD the front bank.
    // ------------------------------------------------------------------
    logic [7:0] fb0 [0:FB_BYTES-1];
    logic [7:0] fb1 [0:FB_BYTES-1];

    logic [FB_AW-1:0] draw_raddr;
    logic [FB_AW-1:0] draw_waddr;
    logic [7:0]       draw_wdata;
    logic             draw_we;
    logic             draw_bank;
    logic             fb_ready;
    logic [7:0]       fb0_rdata;
    logic [7:0]       fb1_rdata;

    wire [FB_AW-1:0] disp_addr = pix_y * 18'd400 + pix_x[9:1];
    wire fb0_we = draw_we && !draw_bank;
    wire fb1_we = draw_we &&  draw_bank;
    wire [7:0] draw_rdata = draw_bank ? fb1_rdata : fb0_rdata;
    wire [7:0] disp_byte  = draw_bank ? fb0_rdata : fb1_rdata;

    // Draw-bank read port follows the RMW address; display-bank read port
    // follows the LCD address.
    wire [FB_AW-1:0] fb0_raddr = draw_bank ? disp_addr : draw_raddr;
    wire [FB_AW-1:0] fb1_raddr = draw_bank ? draw_raddr : disp_addr;

    always_ff @(posedge clk) begin
        if (fb0_we)
            fb0[draw_waddr] <= draw_wdata;
        if (fb1_we)
            fb1[draw_waddr] <= draw_wdata;

        fb0_rdata <= fb0[fb0_raddr];
        fb1_rdata <= fb1[fb1_raddr];
    end

    logic lcd_valid_d;
    logic pix_x_lsb_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lcd_valid_d <= 1'b0;
            pix_x_lsb_d <= 1'b0;
        end
        else begin
            lcd_valid_d <= lcd_valid;
            pix_x_lsb_d <= pix_x[0];
        end
    end

    wire [3:0] disp_color = pix_x_lsb_d ? disp_byte[7:4] : disp_byte[3:0];

    always_comb begin
        r = 6'h00;
        g = 6'h00;
        b = 6'h00;
        case (disp_color)
            4'd1: begin r = 6'h3F; g = 6'h3F; b = 6'h00; end // age 0
            4'd2: begin r = 6'h00; g = 6'h3F; b = 6'h3F; end // age 3
            4'd3: begin r = 6'h3F; g = 6'h00; b = 6'h3F; end // age 7
            4'd4: begin r = 6'h00; g = 6'h10; b = 6'h3F; end // age 15
            4'd5: begin r = 6'h18; g = 6'h20; b = 6'h28; end // base ring
            default: begin r = 6'h00; g = 6'h00; b = 6'h00; end
        endcase

        if (theme && disp_color != 4'd0) begin
            r = {disp_color, 2'b00};
            g = {disp_color, 2'b00};
            b = {disp_color, 2'b00};
        end
    end

    assign hit = fb_ready && lcd_valid_d && (disp_color != 4'd0);

    // ------------------------------------------------------------------
    // Curve source: 128 angles, every 6th column of the 768-column bank.
    // ------------------------------------------------------------------
    logic [6:0] angle_idx;
    logic [2:0] pass;   // 0 = base ring, 1..4 = age curves
    logic [3:0] state;
    logic       closing;

    wire [9:0] curve_addr = angle_idx * 10'd6;
    assign curve_rd_addr = curve_addr;

    logic signed [15:0] sine_rom [0:255];
    initial $readmemh("sine256.mem", sine_rom);

    wire [7:0] sin_idx = {angle_idx, 1'b0};
    wire [7:0] cos_idx = sin_idx + 8'd64;
    wire signed [15:0] sin_v = sine_rom[sin_idx];
    wire signed [15:0] cos_v = sine_rom[cos_idx];

    wire [9:0] h_cur    = curve_rd_data[39:30];
    wire [9:0] h_old    = curve_rd_data[29:20];
    wire [9:0] h_mid    = curve_rd_data[19:10];
    wire [9:0] h_recent = curve_rd_data[9:0];

    logic [9:0] h_sel;
    always_comb begin
        case (pass)
            3'd1: h_sel = h_cur;
            3'd2: h_sel = h_recent;
            3'd3: h_sel = h_mid;
            default: h_sel = h_old;
        endcase
    end

    wire [17:0] h_scaled = h_sel * SPAN[7:0];
    wire [10:0] r_calc = R_BASE - (h_scaled >> 9);
    wire [10:0] r_use  = (r_calc < R_MIN) ? R_MIN : r_calc;

    wire signed [10:0] base_ax = CX + (($signed({1'b0, R_BASE[7:0]}) * sin_v) >>> 15);
    wire signed [10:0] base_ay = CY - (($signed({1'b0, R_BASE[7:0]}) * cos_v) >>> 15);
    wire signed [10:0] age_ax  = CX + (($signed({1'b0, r_use}) * sin_v) >>> 15);
    wire signed [10:0] age_ay  = CY - (($signed({1'b0, r_use}) * cos_v) >>> 15);

    // ------------------------------------------------------------------
    // Current / previous / first endpoints and line rasterizer.
    // ------------------------------------------------------------------
    logic [9:0] cur_x, cur_y;
    logic [9:0] prev_x, prev_y;
    logic [9:0] first_x, first_y;
    logic signed [10:0] line_dx, line_dy;
    logic [7:0] line_step;
    logic [1:0] brush_idx;
    logic [1:0] pix_phase;
    logic [9:0] pix_x_draw, pix_y_draw;
    logic [FB_AW-1:0] pix_addr;
    logic       pix_nib;
    logic       pix_hit;
    logic [7:0] pix_old;
    logic [3:0] line_color;

    wire signed [10:0] line_px = $signed({1'b0, prev_x})
                               + (($signed(line_dx) * $signed({1'b0, line_step})) >>> 7);
    wire signed [10:0] line_py = $signed({1'b0, prev_y})
                               + (($signed(line_dy) * $signed({1'b0, line_step})) >>> 7);

    wire [9:0] brush_px = line_px[9:0] + {9'd0, brush_idx[0]};
    wire [9:0] brush_py = line_py[9:0] + {9'd0, brush_idx[1]};
    wire [FB_AW-1:0] brush_addr = brush_py * 18'd400 + brush_px[9:1];
    wire brush_nib = brush_px[0];
    wire [7:0] old_byte = pix_hit ? pix_old : draw_rdata;
    wire [7:0] new_byte = brush_nib
                        ? {line_color, old_byte[3:0]}
                        : {old_byte[7:4], line_color};

    // Write-through byte cache: handles adjacent 2x2 brush pixels in the
    // same 4bpp byte without re-reading stale RAM data.
    logic [FB_AW-1:0] cache_addr;
    logic [7:0]       cache_data;
    logic             cache_valid;

    logic [FB_AW-1:0] clear_addr;
    logic             render_done_r;
    assign render_done = render_done_r;

    wire [10:0] base_x_w = base_ax;
    wire [10:0] base_y_w = base_ay;
    wire [10:0] age_x_w  = age_ax;
    wire [10:0] age_y_w  = age_ay;

    // ------------------------------------------------------------------
    // Renderer FSM.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_CLEAR;
            draw_bank     <= 1'b1;
            fb_ready      <= 1'b0;
            render_done_r <= 1'b0;
            clear_addr    <= '0;
            angle_idx     <= 7'd0;
            pass          <= 3'd0;
            closing       <= 1'b0;
            cur_x         <= '0;
            cur_y         <= '0;
            prev_x        <= '0;
            prev_y        <= '0;
            first_x       <= '0;
            first_y       <= '0;
            line_dx       <= '0;
            line_dy       <= '0;
            line_step     <= 8'd0;
            brush_idx     <= 2'd0;
            pix_phase     <= P_READ;
            pix_x_draw    <= '0;
            pix_y_draw    <= '0;
            pix_addr      <= '0;
            pix_nib       <= 1'b0;
            pix_hit       <= 1'b0;
            pix_old       <= 8'd0;
            line_color    <= 4'd1;
            cache_addr    <= '0;
            cache_data    <= 8'd0;
            cache_valid   <= 1'b0;
            draw_raddr    <= '0;
            draw_waddr    <= '0;
            draw_wdata    <= 8'd0;
            draw_we       <= 1'b0;
        end
        else begin
            draw_we <= 1'b0;

            if (frame_pulse && render_done_r) begin
                draw_bank     <= ~draw_bank;
                render_done_r <= 1'b0;
                fb_ready      <= 1'b1;
                clear_addr    <= '0;
                angle_idx     <= 7'd0;
                pass          <= 3'd0;
                closing       <= 1'b0;
                cache_valid   <= 1'b0;
                state         <= S_CLEAR;
            end
            else begin
                case (state)
                    S_CLEAR: begin
                        draw_we    <= 1'b1;
                        draw_waddr <= clear_addr;
                        draw_wdata <= 8'd0;
                        cache_valid <= 1'b0;
                        if (clear_addr == FB_BYTES-1) begin
                            clear_addr <= '0;
                            angle_idx  <= 7'd0;
                            pass       <= 3'd0;
                            state      <= S_POINT;
                        end
                        else begin
                            clear_addr <= clear_addr + 1'b1;
                        end
                    end

                    S_POINT: begin
                        if (pass == 3'd0) begin
                            cur_x <= base_x_w[9:0];
                            cur_y <= base_y_w[9:0];
                            state <= S_TAKE;
                        end
                        else begin
                            state <= S_WAIT;
                        end
                    end

                    S_WAIT: begin
                        cur_x <= age_x_w[9:0];
                        cur_y <= age_y_w[9:0];
                        state <= S_TAKE;
                    end

                    S_TAKE: begin
                        if (angle_idx == 7'd0) begin
                            first_x <= cur_x;
                            first_y <= cur_y;
                            prev_x  <= cur_x;
                            prev_y  <= cur_y;
                            angle_idx <= 7'd1;
                            state <= S_POINT;
                        end
                        else begin
                            state <= S_LINE_INIT;
                        end
                    end

                    S_LINE_INIT: begin
                        line_dx <= $signed({1'b0, cur_x}) - $signed({1'b0, prev_x});
                        line_dy <= $signed({1'b0, cur_y}) - $signed({1'b0, prev_y});
                        line_step <= 8'd0;
                        line_color <= (pass == 3'd0) ? 4'd5 : {1'b0, pass};
                        brush_idx <= 2'd0;
                        pix_phase <= P_READ;
                        state <= S_LINE;
                    end

                    S_LINE: begin
                        case (pix_phase)
                            P_READ: begin
                                pix_x_draw <= brush_px;
                                pix_y_draw <= brush_py;
                                pix_addr <= brush_addr;
                                pix_nib <= brush_nib;
                                if (cache_valid && (brush_addr == cache_addr)) begin
                                    pix_old <= cache_data;
                                    pix_hit <= 1'b1;
                                end
                                else begin
                                    draw_raddr <= brush_addr;
                                    pix_hit <= 1'b0;
                                end
                                pix_phase <= P_WRITE;
                            end

                            P_WRITE: begin
                                draw_we    <= 1'b1;
                                draw_waddr <= pix_addr;
                                draw_wdata <= new_byte;
                                cache_addr <= pix_addr;
                                cache_data <= new_byte;
                                cache_valid <= 1'b1;
                                pix_phase <= P_ADV;
                            end

                            default: begin // P_ADV
                                pix_phase <= P_READ;
                                if (brush_idx == 2'd3) begin
                                    brush_idx <= 2'd0;
                                    if (line_step == 8'd128) begin
                                        state <= S_LINE_DONE;
                                    end
                                    else begin
                                        line_step <= line_step + 1'b1;
                                    end
                                end
                                else begin
                                    brush_idx <= brush_idx + 1'b1;
                                end
                            end
                        endcase
                    end

                    S_LINE_DONE: begin
                        if (closing) begin
                            pass      <= pass + 1'b1;
                            angle_idx <= 7'd0;
                            closing   <= 1'b0;
                            if (pass == 3'd4) begin
                                render_done_r <= 1'b1;
                                state <= S_IDLE;
                            end
                            else begin
                                state <= S_POINT;
                            end
                        end
                        else if (angle_idx == 7'd127) begin
                            prev_x  <= cur_x;
                            prev_y  <= cur_y;
                            cur_x   <= first_x;
                            cur_y   <= first_y;
                            closing <= 1'b1;
                            state   <= S_LINE_INIT;
                        end
                        else begin
                            prev_x  <= cur_x;
                            prev_y  <= cur_y;
                            angle_idx <= angle_idx + 1'b1;
                            state   <= S_POINT;
                        end
                    end

                    S_IDLE: begin
                    end

                    default: state <= S_CLEAR;
                endcase
            end
        end
    end

endmodule
