module lcd_background (
    input       [9:0]   pix_x,
    input       [9:0]   pix_y,
    input               grid_en,

    output              grid_hit,    // 1 if on grid line or border
    output      [5:0]   grid_r,
    output      [5:0]   grid_g,
    output      [5:0]   grid_b
);

    // grid: line every 32 px/row
    wire grid_v = (pix_x[4:0] == 5'd0);
    wire grid_h = (pix_y[4:0] == 5'd0);
    wire border = (pix_x == 10'd0) || (pix_x == 10'd799) ||
                  (pix_y == 10'd0) || (pix_y == 10'd479);

    // border white, grid grey
    assign grid_hit = border || (grid_en && (grid_v || grid_h));
    assign grid_r = border ? 6'h3F : 6'h08;
    assign grid_g = border ? 6'h3F : 6'h08;
    assign grid_b = border ? 6'h3F : 6'h08;

endmodule