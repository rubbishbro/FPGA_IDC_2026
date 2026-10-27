`timescale 1ns/1ps

module lcd_3d_spectrum_tb;

    logic       clk;
    logic       rst_n;
    logic       lcd_valid;
    logic [9:0] pix_x;
    logic [9:0] pix_y;
    logic [5:0] wf_base_row;
    logic [9:0] wf_rd_data;
    logic       theme;
    wire  [5:0] wf_rd_row;
    wire  [6:0] wf_rd_col;
    wire        hit;
    wire  [5:0] r, g, b;

    integer errors;

    lcd_3d_spectrum dut (
        .clk(clk), .rst_n(rst_n), .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .wf_base_row(wf_base_row), .wf_rd_data(wf_rd_data),
        .theme(theme),
        .wf_rd_row(wf_rd_row), .wf_rd_col(wf_rd_col),
        .hit(hit), .r(r), .g(g), .b(b)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic set_pixel(input integer px, input integer py);
        begin
            pix_x = px[9:0];
            pix_y = py[9:0];
            repeat (3) @(posedge clk);
            #1;
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        lcd_valid = 1'b1;
        pix_x = 10'd0;
        pix_y = 10'd0;
        wf_base_row = 6'd0;
        wf_rd_data = 10'd1023;
        theme = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        set_pixel(391, 460);
        if (!hit) begin
            $error("front bar missing at (391,460)");
            errors = errors + 1;
        end
        if (r !== 6'h3F || g !== 6'h10 || b !== 6'h00) begin
            $error("front bar color unexpected: %02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        set_pixel(391, 450);
        if (hit) begin
            $error("bar extends above band at (391,450)");
            errors = errors + 1;
        end

        set_pixel(10, 460);
        if (hit) begin
            $error("invalid bar region at (10,460)");
            errors = errors + 1;
        end

        set_pixel(391, 20);
        if (!hit) begin
            $error("back bar missing at (391,20)");
            errors = errors + 1;
        end

        theme = 1'b1;
        set_pixel(391, 460);
        if (r !== 6'h3F || g !== 6'h3F || b !== 6'h3F) begin
            $error("monochrome theme color unexpected: %02x/%02x/%02x", r, g, b);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== LCD 3D SPECTRUM TEST PASSED ===");
        else
            $display("=== LCD 3D SPECTRUM TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
