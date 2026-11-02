`timescale 1ns/1ps
// Full LCD page, three pixel stages, matching lcd_sidebar's synchronous font path.
module lcd_pad_guide #(parameter FONT_FILE="sidebar_font.mem",parameter LABEL_FILE="sidebar_labels.mem")(
    input logic clk,rst_n,frame_pulse,lcd_valid,
    input logic [9:0] pix_x,pix_y,
    input config_pkg::guide_display_t view,
    output logic hit,
    output wire [5:0] r,g,b
);
    import config_pkg::*;
    import sidebar_font_pkg::*;
    function automatic logic[23:0] decimal_glyphs(input logic[6:0] value);
        logic [11:0] bcd;
        begin
            bcd=0;
            for(integer bitpos=6;bitpos>=0;bitpos--)begin
                for(integer d=0;d<3;d++)if(bcd[d*4 +:4]>=5)bcd[d*4 +:4]=bcd[d*4 +:4]+4'd3;
                bcd={bcd[10:0],value[bitpos]};
            end
            return {digit_glyph(bcd[11:8]),digit_glyph(bcd[7:4]),digit_glyph(bcd[3:0])};
        end
    endfunction
    wire [111:0] note_map=view.note_map;
    wire [15:0] targets=view.target,presses=view.pressed,glows=view.glow,matched=view.matched;
    logic [15:0][23:0] note_digits;
    logic [23:0] channel_digits,outside_digits;
    logic prep;
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin note_digits<=0;channel_digits<=0;outside_digits<=0;prep<=0;end
        else begin
            // Pixel snapshot is applied on frame_pulse; format during following blanking.
            prep<=frame_pulse;
            if(prep)begin
                for(integer i=0;i<16;i++)note_digits[i]<=decimal_glyphs(note_map[i*7 +:7]);
                channel_digits<=decimal_glyphs({2'b0,view.audio.channel});
                outside_digits<=decimal_glyphs(view.last_outside);
            end
        end
    end
    logic [7:0] label_id,override_glyph;
    logic [3:0] character,font_x,font_y,cell_index,slot_index;
    logic [9:0] text_x,text_y,lx,ly;
    logic [1:0] col,row;
    logic text_on,hit_now,cell_border;
    logic [17:0] background,color;
    logic [23:0] digits;
    integer char_offset;
    always_comb begin
        hit_now=lcd_valid && view.enabled;
        label_id=0;override_glyph=0;character=0;font_x=0;font_y=0;
        text_on=0;text_x=0;text_y=0;lx=0;ly=0;col=0;row=0;cell_index=0;slot_index=0;
        digits=0;char_offset=0;cell_border=0;
        background={6'h02,6'h05,6'h08};color={6'h37,6'h3c,6'h3e};
        if(pix_y<48)begin
            background={6'h04,6'h0b,6'h10};text_y=16;
            if(pix_x<176)begin text_x=24;label_id=95;end
            else if(pix_x<352)begin text_x=184;label_id=view.audio.source==2?63:62;end
            else if(pix_x<544)begin text_x=376;label_id=config_pkg::instrument_label(view.audio.instrument);end
            else if(pix_x<688)begin
                if(pix_x<608)begin text_x=552;label_id=120;end
                else begin text_x=608;digits={channel_digits[15:0],8'd0};end
            end else begin text_x=704;label_id=view.audio.custom_keys?126:(view.banked?(view.audio.bank?60:59):114);end
        end else if(pix_y<80)begin
            text_y=56;
            if(pix_x<400)begin text_x=80;label_id=121;end
            else begin
                text_x=544;
                label_id=view.fault?77:view.waiting_release?86:view.link_fault?116:(|targets)?123:118;
            end
        end else if(pix_x>=80 && pix_x<720 && pix_y>=88 && pix_y<408)begin
            col=pix_x<240?0:pix_x<400?1:pix_x<560?2:3;
            row=pix_y<168?0:pix_y<248?1:pix_y<328?2:3;
            cell_index={row,col};slot_index=guide_cell_slot(cell_index);
            lx=pix_x-(10'd80+{col,7'd0}+{col,5'd0});
            ly=pix_y-(10'd88+{row,6'd0}+{row,4'd0});
            if(lx>=6 && lx<154 && ly>=6 && ly<74)begin
                cell_border=lx<8 || lx>=152 || ly<8 || ly>=72;
                background={6'h07,6'h0e,6'h13};
                if(targets[slot_index])begin
                    background=matched[slot_index]?{6'h08,6'h27,6'h1b}:{6'h2d,6'h23,6'h07};
                end else if(glows[slot_index])background={6'h16,6'h13,6'h08};
                if(cell_border)begin
                    if(presses[slot_index] && !targets[slot_index])background={6'h0c,6'h28,6'h3e};
                    else if(targets[slot_index])background=matched[slot_index]?{6'h13,6'h38,6'h27}:{6'h3c,6'h30,6'h0b};
                end
                if(ly<36)begin
                    text_y=10'd88+{row,6'd0}+{row,4'd0}+10'd14;
                    if(lx<96)begin
                        text_x=10'd80+{col,7'd0}+{col,5'd0}+10'd16;
                        char_offset=int'(lx-16)>>4;
                        case(char_offset)
                            0:label_id=119;
                            1:override_glyph=digit_glyph(slot_index>=9?4'd1:4'd0);
                            2:override_glyph=digit_glyph(slot_index>=9?slot_index-4'd9:slot_index+1'b1);
                            default:override_glyph=0;
                        endcase
                    end else begin
                        text_x=10'd80+{col,7'd0}+{col,5'd0}+10'd104;
                        label_id=targets[slot_index]?(matched[slot_index]?111:110):
                                 presses[slot_index]?112:glows[slot_index]?113:0;
                    end
                end else begin
                    text_y=10'd88+{row,6'd0}+{row,4'd0}+10'd44;
                    if(lx<80)begin text_x=10'd80+{col,7'd0}+{col,5'd0}+10'd16;label_id=122;end
                    else begin text_x=10'd80+{col,7'd0}+{col,5'd0}+10'd88;digits=note_digits[slot_index];end
                end
            end
        end else if(pix_y>=424 && pix_y<448)begin
            text_y=428;
            if(pix_x<240)begin text_x=104;label_id=110;color={6'h3c,6'h30,6'h0b};end
            else if(pix_x<400)begin text_x=264;label_id=111;color={6'h13,6'h38,6'h27};end
            else if(pix_x<560)begin text_x=424;label_id=112;color={6'h0c,6'h28,6'h3e};end
            else begin text_x=584;label_id=113;color={6'h28,6'h25,6'h13};end
        end else if(pix_y>=448)begin
            text_y=456;
            if(view.outside_count!=0)begin
                if(pix_x<224)begin text_x=80;label_id=115;end
                else begin text_x=224;digits=outside_digits;end
            end
        end
        if(pix_x>=text_x && pix_x<text_x+256 && pix_y>=text_y && pix_y<text_y+16)begin
            character=4'((pix_x-text_x)>>4);font_x=4'(pix_x-text_x);font_y=4'(pix_y-text_y);
            text_on=1;
            if(digits!=0)begin
                case(character)
                    0:override_glyph=digits[23:16];1:override_glyph=digits[15:8];2:override_glyph=digits[7:0];
                    default:override_glyph=0;
                endcase
            end
        end
    end
    logic hit_a,hit_b,text_a,text_b;
    logic [7:0] label_a,override_a,bypass_glyph_b,label_glyph_b;
    logic use_label_b;
    wire [7:0] glyph_b=use_label_b ? label_glyph_b : bypass_glyph_b;
    logic [3:0] character_a,font_x_a,font_y_a,font_x_b,font_y_b,column_q;
    logic [17:0] bg_a,bg_b,bg_q,color_a,color_b,color_q;
    logic [15:0] font_rom[0:4095],font_bits;
    logic text_q;
    initial $readmemh(FONT_FILE,font_rom);
    // Stage B: registered label address -> synchronous glyph ROM. Bypass and
    // pixel coordinates are registered on the same edge; stage C reads bitmap.
    sidebar_label_rom #(.LABEL_FILE(LABEL_FILE)) u_labels(
        .clk(clk),.label_id(label_a),.character(character_a),.glyph(label_glyph_b));
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            hit_a<=0;hit_b<=0;hit<=0;text_a<=0;text_b<=0;text_q<=0;
            label_a<=0;override_a<=0;bypass_glyph_b<=0;use_label_b<=0;character_a<=0;
            font_x_a<=0;font_y_a<=0;font_x_b<=0;font_y_b<=0;column_q<=0;
            bg_a<=0;bg_b<=0;bg_q<=0;color_a<=0;color_b<=0;color_q<=0;font_bits<=0;
        end else begin
            hit_a<=hit_now;text_a<=text_on;label_a<=label_id;override_a<=override_glyph;character_a<=character;
            font_x_a<=font_x;font_y_a<=font_y;bg_a<=background;color_a<=color;
            hit_b<=hit_a;text_b<=text_a;bypass_glyph_b<=override_a;use_label_b<=override_a==0;
            font_x_b<=font_x_a;font_y_b<=font_y_a;bg_b<=bg_a;color_b<=color_a;
            hit<=hit_b;text_q<=text_b;font_bits<=font_rom[{glyph_b,font_y_b}];column_q<=font_x_b;bg_q<=bg_b;color_q<=color_b;
        end
    end
    assign {r,g,b}=text_q && font_bits[15-column_q]?color_q:bg_q;
endmodule
