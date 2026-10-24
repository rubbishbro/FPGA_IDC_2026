`timescale 1ns/1ps

module lcd_trail_spectrum_tb;

    logic       clk;
    logic       rst_n;
    logic       lcd_valid;
    logic [9:0] pix_x;
    logic [9:0] pix_y;
    logic [9:0] q_y;
    logic [29:0] trail_data;
    logic       theme;
    wire        hit;
    wire [5:0]  r, g, b;

    integer errors;

    lcd_trail_spectrum dut (
        .clk(clk), .rst_n(rst_n), .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .q_y(q_y), .trail_data(trail_data), .theme(theme),
        .hit(hit), .r(r), .g(g), .b(b)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic set_pixel(input integer px, input integer py);
        begin
            pix_x = px[9:0];
            pix_y = py[9:0];
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        lcd_valid = 1'b1;
        pix_x = 10'd0;
        pix_y = 10'd0;
        q_y = 10'd100;
        trail_data = {10'd400, 10'd300, 10'd200};
        theme = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        set_pixel(100, 390);
        if (!hit || r !== 6'h00 || g !== 6'h08 || b !== 6'h30) begin
            $error("current band wrong: hit=%0d rgb=%02x/%02x/%02x", hit, r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 350);
        if (!hit || r !== 6'h00 || g !== 6'h04 || b !== 6'h18) begin
            $error("recent band wrong: hit=%0d rgb=%02x/%02x/%02x", hit, r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 250);
        if (!hit || r !== 6'h00 || g !== 6'h02 || b !== 6'h0C) begin
            $error("mid band wrong: hit=%0d rgb=%02x/%02x/%02x", hit, r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 100);
        if (!hit || r !== 6'h00 || g !== 6'h01 || b !== 6'h06) begin
            $error("old band wrong: hit=%0d rgb=%02x/%02x/%02x", hit, r, g, b);
            errors = errors + 1;
        end

        theme = 1'b1;
        set_pixel(100, 390);
        if (!hit || r !== 6'h06 || g !== 6'h06 || b !== 6'h06) begin
            $error("mono current wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== LCD TRAIL SPECTRUM TEST PASSED ===");
        else
            $display("=== LCD TRAIL SPECTRUM TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
