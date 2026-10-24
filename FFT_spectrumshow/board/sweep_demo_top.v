// sweep_demo_top.v -- board wrapper for the 1 kHz -> 10 kHz sweep test bitstream
module sweep_demo_top (
    input           clk,
    input           rst_n,
    input           key0,
    input           key1,
    output          lcd_clk,
    output          lcd_en,
    output  [5:0]   lcd_r,
    output  [5:0]   lcd_g,
    output  [5:0]   lcd_b
);

    ui_demo_top #(
        .SWEEP_MODE (1'b1)
    ) u_demo (
        .clk     (clk),
        .rst_n   (rst_n),
        .key0    (key0),
        .key1    (key1),
        .lcd_clk (lcd_clk),
        .lcd_en  (lcd_en),
        .lcd_r   (lcd_r),
        .lcd_g   (lcd_g),
        .lcd_b   (lcd_b)
    );

endmodule
