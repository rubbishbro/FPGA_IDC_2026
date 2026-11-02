`timescale 1ns/1ps

module lcd_effects_tb;

    logic       clk;
    logic       rst_n;
    logic       grid_en;
    logic       bg_hit;
    logic [5:0] bg_r, bg_g, bg_b;

    logic       wave_theme;
    logic       wave_hit;
    logic [5:0] wave_r, wave_g, wave_b;
    logic [9:0] wave_addr;

    integer errors;

    lcd_background u_bg (
        .pix_x(10'd32), .pix_y(10'd32), .grid_en(grid_en),
        .grid_hit(bg_hit), .grid_r(bg_r), .grid_g(bg_g), .grid_b(bg_b)
    );

    lcd_wave u_wave (
        .clk(clk), .rst_n(rst_n), .lcd_valid(1'b1),
        .pix_x(10'd10), .pix_y(10'd240), .theme(wave_theme),
        .wave_rd_data(10'd240), .wave_rd_addr(wave_addr),
        .wave_hit(wave_hit), .wave_r(wave_r), .wave_g(wave_g), .wave_b(wave_b)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        errors = 0;
        rst_n = 1'b0;
        grid_en = 1'b0;
        wave_theme = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (3) @(posedge clk);

        if (bg_hit) begin
            $error("grid disabled but grid_hit still high");
            errors = errors + 1;
        end

        grid_en = 1'b1;
        #1;
        if (!bg_hit) begin
            $error("grid enabled but grid_hit low");
            errors = errors + 1;
        end

        wave_theme = 1'b0;
        @(posedge clk); #1;
        if (wave_r !== 6'h08 || wave_g !== 6'h38 || wave_b !== 6'h28) begin
            $error("wave theme0 color unexpected");
            errors = errors + 1;
        end

        wave_theme = 1'b1;
        @(posedge clk); #1;
        if (wave_r !== 6'h3F || wave_g !== 6'h3F || wave_b !== 6'h3F) begin
            $error("wave theme1 color unexpected");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== LCD EFFECTS TEST PASSED ===");
        else
            $display("=== LCD EFFECTS TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
