// Generated glyph constants only; label text lives in sidebar_labels.mem.
// Bitmap source: Noto Sans CJK SC (OFL-1.1).
package sidebar_font_pkg;
    function automatic logic[7:0] digit_glyph(input logic[3:0] digit);
        case(digit)
            4'd0:digit_glyph=8'd5;
            4'd1:digit_glyph=8'd6;
            4'd2:digit_glyph=8'd7;
            4'd3:digit_glyph=8'd8;
            4'd4:digit_glyph=8'd9;
            4'd5:digit_glyph=8'd10;
            4'd6:digit_glyph=8'd11;
            4'd7:digit_glyph=8'd12;
            4'd8:digit_glyph=8'd13;
            4'd9:digit_glyph=8'd14;
            default:digit_glyph=0;
        endcase
    endfunction
    localparam logic[7:0] GLYPH_PERCENT=8'd2;
    localparam logic[7:0] GLYPH_HASH=8'd1;
    localparam logic[7:0] GLYPH_LEFT=8'd15;
    localparam logic[7:0] GLYPH_RIGHT=8'd16;
endpackage
