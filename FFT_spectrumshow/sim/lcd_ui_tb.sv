`timescale 1ns/1ps

module lcd_ui_tb;

    import ui_pkg::*;

    logic       lcd_valid;
    logic [9:0] pix_x;
    logic [9:0] pix_y;
    logic [1:0] page;
    logic [1:0] setting_sel;
    logic [3:0] effects;
    logic       ui_hit;
    logic [5:0] ui_r;
    logic [5:0] ui_g;
    logic [5:0] ui_b;

    integer errors;

    lcd_ui dut (
        .lcd_valid(lcd_valid),
        .pix_x(pix_x), .pix_y(pix_y),
        .page(page), .setting_sel(setting_sel), .effects(effects),
        .ui_hit(ui_hit), .ui_r(ui_r), .ui_g(ui_g), .ui_b(ui_b)
    );

    task automatic check_pixel(
        input [9:0] x,
        input [9:0] y,
        input [5:0] want_r,
        input [5:0] want_g,
        input [5:0] want_b
    );
        begin
            pix_x = x;
            pix_y = y;
            #1;
            if (!ui_hit) begin
                $error("ui_hit low at (%0d,%0d)", x, y);
                errors = errors + 1;
            end
            if (ui_r !== want_r || ui_g !== want_g || ui_b !== want_b) begin
                $error("rgb at (%0d,%0d): got %02x/%02x/%02x want %02x/%02x/%02x",
                       x, y, ui_r, ui_g, ui_b, want_r, want_g, want_b);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        lcd_valid = 1'b1;
        page = UI_PAGE_BARS;
        setting_sel = 2'd0;
        effects = 4'b1011;
        pix_x = 10'd0;
        pix_y = 10'd0;

        check_pixel(10'd20, 10'd10, 6'h08, 6'h20, 6'h20);
        check_pixel(10'd300, 10'd10, 6'h05, 6'h08, 6'h0C);
        check_pixel(10'd88, 10'd14, 6'h3F, 6'h3F, 6'h3F);

        page = UI_PAGE_SETTINGS;
        check_pixel(10'd200, 10'd110, 6'h08, 6'h16, 6'h1A);
        check_pixel(10'd200, 10'd180, 6'h04, 6'h08, 6'h0C);

        setting_sel = 2'd1;
        check_pixel(10'd200, 10'd180, 6'h08, 6'h16, 6'h1A);
        check_pixel(10'd200, 10'd110, 6'h04, 6'h08, 6'h0C);

        check_pixel(10'd600, 10'd110, 6'h0C, 6'h30, 6'h18);
        effects[0] = 1'b0;
        check_pixel(10'd600, 10'd110, 6'h10, 6'h10, 6'h10);
        effects[0] = 1'b1;

        pix_x = 10'd50;
        pix_y = 10'd100;
        #1;
        if (ui_hit) begin
            $error("ui_hit should be low outside UI at (%0d,%0d)", pix_x, pix_y);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== LCD UI TEST PASSED ===");
        else
            $display("=== LCD UI TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
