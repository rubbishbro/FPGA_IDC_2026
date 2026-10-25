`timescale 1ns/1ps

module lcd_curve_spectrum_tb;

    logic        clk;
    logic        rst_n;
    logic        lcd_valid;
    logic [9:0]  pix_x;
    logic [9:0]  pix_y;
    logic [39:0] curve_data;
    logic        theme;
    wire  [9:0]  curve_rd_addr;
    wire         hit;
    wire  [5:0]  r, g, b;

    integer errors;

    lcd_curve_spectrum dut (
        .clk(clk), .rst_n(rst_n), .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .curve_data(curve_data), .theme(theme),
        .curve_rd_addr(curve_rd_addr),
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
        curve_data = {10'd200, 10'd400, 10'd300, 10'd250};
        theme = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        set_pixel(100, 300);
        if (!hit || r !== 6'h03 || g !== 6'h03 || b !== 6'h00) begin
            $error("bottom fill wrong: hit=%0d rgb=%02x/%02x/%02x", hit, r, g, b);
            errors = errors + 1;
        end
        if (curve_rd_addr !== 10'd100) begin
            $error("curve address wrong: %0d", curve_rd_addr);
            errors = errors + 1;
        end

        set_pixel(100, 140);
        if (!hit || r !== 6'h3F || g !== 6'h3F || b !== 6'h00) begin
            $error("current top line wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 340);
        if (!hit || r !== 6'h1F || g !== 6'h1F || b !== 6'h00) begin
            $error("current bottom line wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 365);
        if (!hit || r !== 6'h00 || g !== 6'h1F || b !== 6'h1F) begin
            $error("bottom recent line wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 115);
        if (!hit || r !== 6'h00 || g !== 6'h3F || b !== 6'h3F) begin
            $error("recent line wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 90);
        if (!hit || r !== 6'h3F || g !== 6'h00 || b !== 6'h3F) begin
            $error("mid line wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 40);
        if (!hit || r !== 6'h00 || g !== 6'h10 || b !== 6'h3F) begin
            $error("old line wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        set_pixel(100, 10);
        if (hit) begin
            $error("unexpected hit above old curve");
            errors = errors + 1;
        end

        theme = 1'b1;
        set_pixel(100, 140);
        if (!hit || r !== 6'h3F || g !== 6'h3F || b !== 6'h3F) begin
            $error("mono current wrong: rgb=%02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== LCD CURVE SPECTRUM TEST PASSED ===");
        else
            $display("=== LCD CURVE SPECTRUM TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
