module lcd_ui (
    input  logic       lcd_valid,
    input  logic [9:0] pix_x,
    input  logic [9:0] pix_y,
    input  logic [1:0] page,
    input  logic [1:0] setting_sel,
    input  logic [3:0] effects,

    output logic       ui_hit,
    output logic [5:0] ui_r,
    output logic [5:0] ui_g,
    output logic [5:0] ui_b
);

    import ui_pkg::*;

    localparam logic [9:0] TAB0_X = 10'd12;
    localparam logic [9:0] TAB1_X = 10'd204;
    localparam logic [9:0] TAB2_X = 10'd396;
    localparam logic [9:0] TAB3_X = 10'd588;
    localparam logic [9:0] TAB_Y  = 10'd4;
    localparam logic [9:0] TAB_W  = 10'd184;
    localparam logic [9:0] TAB_H  = 10'd28;

    localparam logic [4:0] G_A = 5'd0;
    localparam logic [4:0] G_B = 5'd1;
    localparam logic [4:0] G_E = 5'd2;
    localparam logic [4:0] G_F = 5'd3;
    localparam logic [4:0] G_H = 5'd4;
    localparam logic [4:0] G_I = 5'd5;
    localparam logic [4:0] G_K = 5'd6;
    localparam logic [4:0] G_L = 5'd7;
    localparam logic [4:0] G_P = 5'd8;
    localparam logic [4:0] G_R = 5'd9;
    localparam logic [4:0] G_S = 5'd10;
    localparam logic [4:0] G_T = 5'd11;
    localparam logic [4:0] G_U = 5'd12;
    localparam logic [4:0] G_V = 5'd13;
    localparam logic [4:0] G_W = 5'd14;
    localparam logic [4:0] G_Y = 5'd15;
    localparam logic [4:0] G_SP = 5'd16;
    localparam logic [4:0] G_M  = 5'd17;
    localparam logic [4:0] G_G  = 5'd18;
    localparam logic [4:0] G_D  = 5'd19;

    function automatic [4:0] glyph(input [4:0] ch, input [2:0] row);
        case (ch)
            G_A: case (row)
                3'd0: glyph = 5'b01110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b11111;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b10001;
            endcase
            G_B: case (row)
                3'd0: glyph = 5'b11110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b11110;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b11110;
            endcase
            G_E: case (row)
                3'd0: glyph = 5'b11111; 3'd1: glyph = 5'b10000;
                3'd2: glyph = 5'b10000; 3'd3: glyph = 5'b11110;
                3'd4: glyph = 5'b10000; 3'd5: glyph = 5'b10000;
                default: glyph = 5'b11111;
            endcase
            G_F: case (row)
                3'd0: glyph = 5'b11111; 3'd1: glyph = 5'b10000;
                3'd2: glyph = 5'b10000; 3'd3: glyph = 5'b11110;
                3'd4: glyph = 5'b10000; 3'd5: glyph = 5'b10000;
                default: glyph = 5'b10000;
            endcase
            G_H: case (row)
                3'd0: glyph = 5'b10001; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b11111;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b10001;
            endcase
            G_I: case (row)
                3'd0: glyph = 5'b11111; 3'd1: glyph = 5'b00100;
                3'd2: glyph = 5'b00100; 3'd3: glyph = 5'b00100;
                3'd4: glyph = 5'b00100; 3'd5: glyph = 5'b00100;
                default: glyph = 5'b11111;
            endcase
            G_K: case (row)
                3'd0: glyph = 5'b10001; 3'd1: glyph = 5'b10010;
                3'd2: glyph = 5'b10100; 3'd3: glyph = 5'b11000;
                3'd4: glyph = 5'b10100; 3'd5: glyph = 5'b10010;
                default: glyph = 5'b10001;
            endcase
            G_L: case (row)
                3'd0: glyph = 5'b10000; 3'd1: glyph = 5'b10000;
                3'd2: glyph = 5'b10000; 3'd3: glyph = 5'b10000;
                3'd4: glyph = 5'b10000; 3'd5: glyph = 5'b10000;
                default: glyph = 5'b11111;
            endcase
            G_P: case (row)
                3'd0: glyph = 5'b11110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b11110;
                3'd4: glyph = 5'b10000; 3'd5: glyph = 5'b10000;
                default: glyph = 5'b10000;
            endcase
            G_R: case (row)
                3'd0: glyph = 5'b11110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b11110;
                3'd4: glyph = 5'b10100; 3'd5: glyph = 5'b10010;
                default: glyph = 5'b10001;
            endcase
            G_S: case (row)
                3'd0: glyph = 5'b01111; 3'd1: glyph = 5'b10000;
                3'd2: glyph = 5'b10000; 3'd3: glyph = 5'b01110;
                3'd4: glyph = 5'b00001; 3'd5: glyph = 5'b00001;
                default: glyph = 5'b11110;
            endcase
            G_T: case (row)
                3'd0: glyph = 5'b11111; 3'd1: glyph = 5'b00100;
                3'd2: glyph = 5'b00100; 3'd3: glyph = 5'b00100;
                3'd4: glyph = 5'b00100; 3'd5: glyph = 5'b00100;
                default: glyph = 5'b00100;
            endcase
            G_U: case (row)
                3'd0: glyph = 5'b10001; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b10001;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b01110;
            endcase
            G_V: case (row)
                3'd0: glyph = 5'b10001; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b10001;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b01010;
                default: glyph = 5'b00100;
            endcase
            G_W: case (row)
                3'd0: glyph = 5'b10001; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b10101;
                3'd4: glyph = 5'b10101; 3'd5: glyph = 5'b11011;
                default: glyph = 5'b10001;
            endcase
            G_Y: case (row)
                3'd0: glyph = 5'b10001; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b01010; 3'd3: glyph = 5'b00100;
                3'd4: glyph = 5'b00100; 3'd5: glyph = 5'b00100;
                default: glyph = 5'b00100;
            endcase
            G_M: case (row)
                3'd0: glyph = 5'b10001; 3'd1: glyph = 5'b11011;
                3'd2: glyph = 5'b10101; 3'd3: glyph = 5'b10101;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b10001;
            endcase
            G_G: case (row)
                3'd0: glyph = 5'b01110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10000; 3'd3: glyph = 5'b10111;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b01110;
            endcase
            G_D: case (row)
                3'd0: glyph = 5'b11110; 3'd1: glyph = 5'b10001;
                3'd2: glyph = 5'b10001; 3'd3: glyph = 5'b10001;
                3'd4: glyph = 5'b10001; 3'd5: glyph = 5'b10001;
                default: glyph = 5'b11110;
            endcase
            default: glyph = 5'b00000;
        endcase
    endfunction

    function automatic [4:0] tab_char(input [1:0] tab, input [1:0] idx);
        case (tab)
            UI_PAGE_BARS: case (idx)
                2'd0: tab_char = G_B; 2'd1: tab_char = G_A;
                2'd2: tab_char = G_R; default: tab_char = G_S;
            endcase
            UI_PAGE_WAVE: case (idx)
                2'd0: tab_char = G_W; 2'd1: tab_char = G_A;
                2'd2: tab_char = G_V; default: tab_char = G_E;
            endcase
            UI_PAGE_FALL: case (idx)
                2'd0: tab_char = G_F; 2'd1: tab_char = G_A;
                2'd2: tab_char = G_L; default: tab_char = G_L;
            endcase
            default: case (idx)
                2'd0: tab_char = G_S; 2'd1: tab_char = G_E;
                2'd2: tab_char = G_T; default: tab_char = G_SP;
            endcase
        endcase
    endfunction

    function automatic [4:0] row_char(input [1:0] row, input [2:0] idx);
        case (row)
            2'd0: case (idx)
                3'd0: row_char = G_S; 3'd1: row_char = G_M;
                3'd2: row_char = G_T; 3'd3: row_char = G_H;
                default: row_char = G_SP;
            endcase
            2'd1: case (idx)
                3'd0: row_char = G_P; 3'd1: row_char = G_E;
                3'd2: row_char = G_A; 3'd3: row_char = G_K;
                default: row_char = G_SP;
            endcase
            2'd2: case (idx)
                3'd0: row_char = G_T; 3'd1: row_char = G_H;
                3'd2: row_char = G_E; 3'd3: row_char = G_M;
                default: row_char = G_SP;
            endcase
            default: case (idx)
                3'd0: row_char = G_G; 3'd1: row_char = G_R;
                3'd2: row_char = G_I; 3'd3: row_char = G_D;
                default: row_char = G_SP;
            endcase
        endcase
    endfunction

    wire in_top = (pix_y < 10'd36);
    wire [1:0] tab_idx = (pix_x < TAB1_X) ? 2'd0 :
                         (pix_x < TAB2_X) ? 2'd1 :
                         (pix_x < TAB3_X) ? 2'd2 : 2'd3;
    wire [9:0] tab_x = (tab_idx == 2'd0) ? TAB0_X :
                       (tab_idx == 2'd1) ? TAB1_X :
                       (tab_idx == 2'd2) ? TAB2_X : TAB3_X;
    wire [9:0] tab_off = pix_x - tab_x;
    wire in_tab = (pix_x >= TAB0_X) && (pix_x < TAB3_X + TAB_W) &&
                  (pix_y >= TAB_Y) && (pix_y < TAB_Y + TAB_H) &&
                  (tab_off < TAB_W);
    wire tab_active = (page == tab_idx);
    wire tab_border = (tab_off < 10'd2) || (tab_off >= TAB_W - 10'd2) ||
                      (pix_y < TAB_Y + 10'd2) || (pix_y >= TAB_Y + TAB_H - 10'd2);

    wire [9:0] label_x = tab_x + 10'd76;
    wire in_label_x = (pix_x >= label_x) && (pix_x < label_x + 10'd32);
    wire [4:0] label_off = (pix_x - label_x) & 5'h1f;
    wire [1:0] label_idx = label_off[4:3];
    wire [2:0] label_fx  = label_off[2:0];
    wire [2:0] label_fy  = pix_y[2:0] - 3'd6;
    wire [4:0] label_ch  = tab_char(tab_idx, label_idx);
    wire [4:0] label_row = glyph(label_ch, label_fy);
    wire label_hit = in_tab && in_label_x &&
                     (pix_y >= 10'd14) && (pix_y < 10'd21) &&
                     (label_fx < 3'd5) && label_row[4 - label_fx];

    wire in_panel = (page == UI_PAGE_SETTINGS) &&
                    (pix_x >= 10'd100) && (pix_x < 10'd700) &&
                    (pix_y >= 10'd80)  && (pix_y < 10'd440);
    wire panel_border = (pix_x < 10'd102) || (pix_x >= 10'd698) ||
                        (pix_y < 10'd82)  || (pix_y >= 10'd438);

    wire srow_hit = in_panel && ((pix_y >= 10'd96  && pix_y < 10'd140) ||
                                 (pix_y >= 10'd168 && pix_y < 10'd212) ||
                                 (pix_y >= 10'd240 && pix_y < 10'd284) ||
                                 (pix_y >= 10'd312 && pix_y < 10'd356));
    wire [1:0] srow = (pix_y < 10'd168) ? 2'd0 :
                      (pix_y < 10'd240) ? 2'd1 :
                      (pix_y < 10'd312) ? 2'd2 : 2'd3;
    logic [9:0] row_y;
    always_comb begin
        case (srow)
            2'd0: row_y = 10'd96;
            2'd1: row_y = 10'd168;
            2'd2: row_y = 10'd240;
            default: row_y = 10'd312;
        endcase
    end

    wire srow_sel = (srow == setting_sel);
    wire row_border = srow_hit && ((pix_x < 10'd112) || (pix_x >= 10'd688) ||
                                   (pix_y < row_y + 10'd2) ||
                                   (pix_y >= row_y + 10'd42));
    wire in_stext_x = (pix_x >= 10'd124) && (pix_x < 10'd164);
    wire [4:0] stext_off = (pix_x - 10'd124) & 5'h1f;
    wire [2:0] stext_idx = stext_off[4:3];
    wire [2:0] stext_fx  = stext_off[2:0];
    wire [2:0] stext_fy  = pix_y[2:0] - row_y[2:0];
    wire [4:0] stext_ch  = row_char(srow, stext_idx);
    wire [4:0] stext_row = glyph(stext_ch, stext_fy);
    wire stext_hit = srow_hit && in_stext_x &&
                     (pix_y >= row_y + 10'd16) &&
                     (pix_y < row_y + 10'd23) &&
                     (stext_fx < 3'd5) && stext_row[4 - stext_fx];

    wire row_on = effects[srow];
    wire switch_hit = srow_hit &&
                      (pix_x >= 10'd560) && (pix_x < 10'd660) &&
                      (pix_y >= row_y + 10'd12) &&
                      (pix_y < row_y + 10'd32);
    wire switch_border = switch_hit &&
                         ((pix_x < 10'd562) || (pix_x >= 10'd658) ||
                          (pix_y < row_y + 10'd14) ||
                          (pix_y >= row_y + 10'd30));
    wire knob_hit = switch_hit &&
                    (pix_y >= row_y + 10'd15) &&
                    (pix_y < row_y + 10'd29) &&
                    ((row_on && (pix_x >= 10'd640) && (pix_x < 10'd656)) ||
                     (!row_on && (pix_x >= 10'd564) && (pix_x < 10'd580)));

    always_comb begin
        ui_hit = 1'b0;
        ui_r = 6'd0;
        ui_g = 6'd0;
        ui_b = 6'd0;

        if (in_top) begin
            ui_hit = 1'b1;
            ui_r = 6'h02; ui_g = 6'h04; ui_b = 6'h08;

            if (in_tab) begin
                if (tab_border) begin
                    ui_r = tab_active ? 6'h0C : 6'h10;
                    ui_g = tab_active ? 6'h3F : 6'h14;
                    ui_b = tab_active ? 6'h3F : 6'h18;
                end
                else begin
                    ui_r = tab_active ? 6'h08 : 6'h05;
                    ui_g = tab_active ? 6'h20 : 6'h08;
                    ui_b = tab_active ? 6'h20 : 6'h0C;
                end

                if (label_hit) begin
                    ui_r = tab_active ? 6'h3F : 6'h18;
                    ui_g = tab_active ? 6'h3F : 6'h18;
                    ui_b = tab_active ? 6'h3F : 6'h18;
                end
            end
        end
        else if (in_panel) begin
            ui_hit = 1'b1;
            ui_r = 6'h03; ui_g = 6'h05; ui_b = 6'h08;

            if (panel_border) begin
                ui_r = 6'h0A; ui_g = 6'h18; ui_b = 6'h20;
            end

            if (srow_hit) begin
                ui_r = srow_sel ? 6'h08 : 6'h04;
                ui_g = srow_sel ? 6'h16 : 6'h08;
                ui_b = srow_sel ? 6'h1A : 6'h0C;

                if (row_border) begin
                    ui_r = srow_sel ? 6'h0C : 6'h10;
                    ui_g = srow_sel ? 6'h3F : 6'h14;
                    ui_b = srow_sel ? 6'h3F : 6'h18;
                end

                if (switch_hit) begin
                    ui_r = row_on ? 6'h0C : 6'h10;
                    ui_g = row_on ? 6'h30 : 6'h10;
                    ui_b = row_on ? 6'h18 : 6'h10;
                end

                if (switch_border) begin
                    ui_r = 6'h0C; ui_g = 6'h3F; ui_b = 6'h3F;
                end

                if (knob_hit) begin
                    ui_r = 6'h3F; ui_g = 6'h3F; ui_b = 6'h3F;
                end

                if (stext_hit) begin
                    ui_r = 6'h3F; ui_g = 6'h3F; ui_b = 6'h3F;
                end
            end
        end
    end

endmodule
