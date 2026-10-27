`timescale 1ns/1ps

module tb_lcd_polar_curve;

    reg         clk;
    reg         rst_n;
    reg         frame_pulse;
    reg         lcd_valid;
    reg  [9:0]  pix_x;
    reg  [9:0]  pix_y;
    wire [9:0]  curve_rd_addr;
    reg  [39:0] curve_rd_data;
    reg         theme;
    wire        hit;
    wire [5:0]  r;
    wire [5:0]  g;
    wire [5:0]  b;
    wire        render_done;

    integer errors;

    lcd_polar_curve dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .frame_pulse   (frame_pulse),
        .lcd_valid     (lcd_valid),
        .pix_x         (pix_x),
        .pix_y         (pix_y),
        .curve_rd_addr (curve_rd_addr),
        .curve_rd_data (curve_rd_data),
        .theme         (theme),
        .hit           (hit),
        .r             (r),
        .g             (g),
        .b             (b),
        .render_done   (render_done)
    );

    always #15 clk = ~clk;

    // curve word = {cur=300, old=200, mid=100, recent=50}
    // R = 190 - h*150/512:
    // age0=103, age1=176, age2=161, age3=132.
    always @(posedge clk) begin
        curve_rd_data <= {10'd300, 10'd200, 10'd100, 10'd50};
    end

    task automatic check_pixel(
        input [9:0] x,
        input [9:0] y,
        input       exp_hit,
        input [3:0] exp_color
    );
        begin
            pix_x     = x;
            pix_y     = y;
            lcd_valid = 1'b1;
            repeat (2) @(posedge clk);
            #1;

            if (hit !== exp_hit) begin
                $display("HIT MISMATCH (%0d,%0d): got %0b exp %0b",
                         x, y, hit, exp_hit);
                errors = errors + 1;
            end
            else if (exp_hit) begin
                case (exp_color)
                    4'd1: if ({r,g,b} !== {6'h3F,6'h3F,6'h00}) begin
                        $display("COLOR1 MISMATCH (%0d,%0d): %h %h %h", x, y, r, g, b);
                        errors = errors + 1;
                    end
                    4'd2: if ({r,g,b} !== {6'h00,6'h3F,6'h3F}) begin
                        $display("COLOR2 MISMATCH (%0d,%0d): %h %h %h", x, y, r, g, b);
                        errors = errors + 1;
                    end
                    4'd3: if ({r,g,b} !== {6'h3F,6'h00,6'h3F}) begin
                        $display("COLOR3 MISMATCH (%0d,%0d): %h %h %h", x, y, r, g, b);
                        errors = errors + 1;
                    end
                    4'd4: if ({r,g,b} !== {6'h00,6'h10,6'h3F}) begin
                        $display("COLOR4 MISMATCH (%0d,%0d): %h %h %h", x, y, r, g, b);
                        errors = errors + 1;
                    end
                    4'd5: if ({r,g,b} !== {6'h18,6'h20,6'h28}) begin
                        $display("BASE COLOR MISMATCH (%0d,%0d): %h %h %h", x, y, r, g, b);
                        errors = errors + 1;
                    end
                    default: ;
                endcase
            end
        end
    endtask

    initial begin
        clk           = 1'b0;
        rst_n         = 1'b0;
        frame_pulse   = 1'b0;
        lcd_valid     = 1'b0;
        pix_x         = 10'd0;
        pix_y         = 10'd0;
        curve_rd_data = 40'd0;
        theme         = 1'b0;
        errors        = 0;

        #40;
        rst_n = 1'b1;

        wait (render_done);
        repeat (2) @(posedge clk);

        frame_pulse = 1'b1;
        @(posedge clk);
        frame_pulse = 1'b0;
        repeat (3) @(posedge clk);

        // Top: outer base ring, then four inward curves.
        check_pixel(10'd400, 10'd51,  1'b1, 4'd5); // base, R=190
        check_pixel(10'd400, 10'd65,  1'b1, 4'd2); // age1, R=176
        check_pixel(10'd400, 10'd80,  1'b1, 4'd3); // age2, R=161
        check_pixel(10'd400, 10'd109, 1'b1, 4'd4); // age3, R=132
        check_pixel(10'd400, 10'd138, 1'b1, 4'd1); // age0, R=103

        // Right / bottom.
        check_pixel(10'd590, 10'd240, 1'b1, 4'd5);
        check_pixel(10'd503, 10'd240, 1'b1, 4'd1);
        check_pixel(10'd532, 10'd240, 1'b1, 4'd4);
        check_pixel(10'd400, 10'd344, 1'b1, 4'd1);

        // Center, outside, and between curves must be transparent.
        check_pixel(10'd400, 10'd240, 1'b0, 4'd0);
        check_pixel(10'd400, 10'd20,  1'b0, 4'd0);
        check_pixel(10'd400, 10'd120, 1'b0, 4'd0);

        if (errors == 0)
            $display("=== LCD POLAR CURVE TEST PASSED ===");
        else
            $display("=== LCD POLAR CURVE TEST FAILED: %0d error(s) ===", errors);

        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT state=%0d pass=%0d angle=%0d step=%0d phase=%0d brush=%0d",
                 dut.state, dut.pass, dut.angle_idx, dut.line_step, dut.pix_phase, dut.brush_idx);
        $finish;
    end

endmodule
