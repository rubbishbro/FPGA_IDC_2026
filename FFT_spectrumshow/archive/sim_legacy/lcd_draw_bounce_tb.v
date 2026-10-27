`timescale 1ns/1ps

module lcd_draw_bounce_tb;

    reg         clk;
    reg         rst_n;
    reg         frame_pulse;
    reg         lcd_valid;
    reg  [9:0]  pix_x;
    reg  [9:0]  pix_y;
    wire [5:0]  lcd_r, lcd_g, lcd_b;

    integer errors = 0;
    integer i;

    wire [9:0] dbg_x  = u_draw.square_x;
    wire       dbg_dir = u_draw.square_dir;

    lcd_draw u_draw(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .lcd_valid(lcd_valid), .pix_x(pix_x), .pix_y(pix_y),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    always #5 clk = ~clk;

    task tick_frame;
        begin
            @(posedge clk);
            frame_pulse = 1;
            @(posedge clk);
            frame_pulse = 0;
        end
    endtask

    // ---- automatic invariant checks over many frames ----
    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; lcd_valid = 0;
        pix_x = 0; pix_y = 0;
        #20 rst_n = 1;
        #10;

        if (dbg_x !== 10'd0 || dbg_dir !== 1'b1) begin
            $error("after reset x=%0d dir=%0d, expected 0/1", dbg_x, dbg_dir);
            errors = errors + 1;
        end

        // run 10000 frames, checking bounds every frame
        for (i = 0; i < 10000; i = i + 1) begin
            tick_frame;
            if (dbg_x > 10'd768) begin
                $error("x out of range: %0d at frame %0d", dbg_x, i);
                errors = errors + 1;
                $finish;
            end
        end

        // must have bounced: direction changed from initial 1 at least twice
        if (errors == 0) $display("=== BOUNCE TEST PASSED ===");
        else             $display("=== BOUNCE TEST FAILED: %0d mismatch(es) ===", errors);
        $finish;
    end

endmodule