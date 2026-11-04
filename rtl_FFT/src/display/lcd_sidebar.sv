`timescale 1ns/1ps
// Three pixel stages: region/descriptor -> glyph -> synchronous font ROM.
// The compositor must delay background and DE by the same three clocks.
module lcd_sidebar #(parameter FONT_FILE="sidebar_font.mem",parameter LABEL_FILE="sidebar_labels.mem")(
    input logic clk,rst_n,frame_pulse,lcd_valid,
    input logic[9:0] pix_x,pix_y,
    input config_pkg::sidebar_snapshot_t view,
    input config_pkg::guide_display_t guide_view = '0,
    output logic hit,
    output logic[5:0] r,g,b,
    output logic[8:0] visible_width
);
    import config_pkg::*;
    import sidebar_font_pkg::*;
    cfg_values_t values;
    assign values=view.values;
    wire[config_pkg::CFG_COUNT-1:0] supported=view.supported;
    logic[3:0] progress;
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)progress<=0;
        else if(frame_pulse)begin
            if(view.scene.open && progress<12)progress<=progress+1'b1;
            else if(!view.scene.open && progress!=0)progress<=progress-1'b1;
        end
    end
    always_comb case(progress)
        0:visible_width=0;1:visible_width=4;2:visible_width=16;3:visible_width=36;
        4:visible_width=64;5:visible_width=100;6:visible_width=144;7:visible_width=188;
        8:visible_width=224;9:visible_width=252;10:visible_width=272;
        11:visible_width=284;default:visible_width=288;
    endcase
    function automatic logic[7:0] value_label(input integer index,input integer value);
        case(index)
            0:value_label=config_pkg::instrument_label(16'(value));
            2:case(value)
                integer'(router_pkg::REVERB_NONE):value_label=50;
                integer'(router_pkg::REVERB_HALL):value_label=52;
                integer'(router_pkg::REVERB_BATHROOM):value_label=53;
                integer'(router_pkg::REVERB_CHAMBER):value_label=127;
                integer'(router_pkg::REVERB_CHORUS):value_label=128;
                default:value_label=72;
            endcase
            8,9,10:value_label=value==0?50:51;
            5:value_label=value==2?126:(value==0?59:60);
            6:value_label=8'(54+value);
            7:value_label=value==0?57:58;
            11:value_label=8'(61+value);
            12:value_label=64;
            13:case(value)0:value_label=50;1:value_label=91;2:value_label=92;default:value_label=93;endcase
            18:value_label=value==0?62:63;
            20:value_label=value==0?94:95;
            default:value_label=70;
        endcase
    endfunction
    // Prepare configuration-dependent labels/digits during frame blanking.
    // view is a frame snapshot; prep_tick follows its publication by one clock.
    // No decimal division or 20x32-bit value lookup remains on a pixel path.
    // Binary -> BCD in two five-bit stages. Unlike repeated /10 and /100,
    // this has bounded small add/compare logic and needs no formatting DSPs.
    function automatic logic[15:0] bcd_five(input logic[15:0] initial_bcd,input logic[4:0] binary);
        logic[15:0] v;
        begin
            v=initial_bcd;
            for(integer bitpos=4;bitpos>=0;bitpos--)begin
                for(integer d=0;d<4;d++)if(v[d*4 +:4]>=5)v[d*4 +:4]=v[d*4 +:4]+4'd3;
                v={v[14:0],binary[bitpos]};
            end
            return v;
        end
    endfunction
    function automatic logic[31:0] number_glyphs(input logic[15:0] bcd,input logic percent);
        begin
            if(percent) number_glyphs={bcd[15:12]!=0?digit_glyph(bcd[15:12]):8'd0,
                    bcd[15:8]!=0?digit_glyph(bcd[11:8]):8'd0,digit_glyph(bcd[7:4]),GLYPH_PERCENT};
            else number_glyphs={bcd[15:8]!=0?digit_glyph(bcd[11:8]):8'd0,
                    bcd[15:4]!=0?digit_glyph(bcd[7:4]):8'd0,digit_glyph(bcd[3:0]),8'd0};
        end
    endfunction
    function automatic logic[9:0] option_descriptor(input logic[4:0] idx,input logic signed[31:0] v,input integer row_num);
        logic signed[31:0] first_v,option_v;
        logic allowed;
        begin
            first_v=v>2?v-2:0;option_v=first_v+row_num-1;
            // Show every instrument ID0..11, including not-yet-installed drums.
            // Backend admission does not grey out or remove UI options.
            allowed=option_v<=cfg_max(idx) && (idx!=0||option_v<=11) && (idx!=6||option_v<3);
            return {allowed,option_v==v,value_label(idx,option_v)};
        end
    endfunction
    logic[config_pkg::CFG_COUNT-1:0][7:0] value_labels;
    logic[config_pkg::CFG_COUNT-1:0][31:0] value_digits;
    logic[31:0] draft_digits;
    logic[5:0][9:0] options;
    logic[3:0][9:0] numeric_values;
    logic[3:0][15:0] bcd_first,bcd_done;
    logic[3:0][4:0] bcd_low;
    logic draft_percent_a,draft_percent_b;
    logic prep_tick,prep_a,prepared;
    logic channel_nonzero;
    logic[12:0] slider_target;
    logic[9:0] slider_end;
    assign numeric_values={view.scene.draft[9:0],10'(values[12]),10'(values[21]),10'(values[1])};
    always_comb begin
        value_digits='0;
        value_digits[1]=number_glyphs(bcd_done[0],1'b1);
        value_digits[21]=number_glyphs(bcd_done[1],1'b0);
        value_digits[12]=number_glyphs(bcd_done[2],1'b0);
        draft_digits=number_glyphs(bcd_done[3],draft_percent_b);
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            value_labels<='0;options<='0;channel_nonzero<=0;prep_tick<=0;prep_a<=0;prepared<=0;
            bcd_first<='0;bcd_done<='0;bcd_low<='0;draft_percent_a<=0;draft_percent_b<=0;
            slider_target<=0;slider_end<=23;
        end else begin
            prep_tick<=frame_pulse;
            prep_a<=prep_tick||!prepared;
            if(prep_tick||!prepared)begin
                prepared<=1;
                for(integer i=0;i<CFG_COUNT;i++)value_labels[i]<=value_label(i,values[i]);
                for(integer i=0;i<6;i++)options[i]<=option_descriptor(view.scene.edit_index,view.scene.draft,i);
                for(integer i=0;i<4;i++)begin
                    bcd_first[i]<=bcd_five(16'd0,5'(numeric_values[i]>>5));
                    bcd_low[i]<=5'(numeric_values[i]);
                end
                draft_percent_a<=view.scene.edit_index==1;
                channel_nonzero<=values[12]!=0;
                // floor(draft*240/1000) == floor(draft*6/25), once per view.
                slider_target<=13'(view.scene.draft[9:0])*13'd6;
            end
            if(prep_a)begin
                for(integer i=0;i<4;i++)bcd_done[i]<=bcd_five(bcd_first[i],bcd_low[i]);
                draft_percent_b<=draft_percent_a;
                slider_end<=10'd23+10'(slider_target/13'd25);
            end
        end
    end
    logic[15:0] font_rom[0:4095];
    initial $readmemh(FONT_FILE,font_rom);
    logic[7:0] glyph,label_id;
    logic[3:0] font_y,font_x;
    logic text_on,hit_now;
    logic[17:0] background,text_color;
    logic[10:0] x;
    logic[9:0] y,text_x,text_y;
    logic[2:0] row;
    logic[4:0] index;
    logic[31:0] digits;
    logic[3:0] character;
    logic character_valid;
    logic[9:0] selected_option;
    logic selected,enabled,number_text;

    always_comb begin
        x={1'b0,pix_x}+11'd288-{2'b0,visible_width};y=pix_y;
        glyph=0;label_id=0;font_x=0;font_y=0;text_on=0;hit_now=0;
        background={6'h03,6'h06,6'h09};text_color={6'h36,6'h3b,6'h3a};
        row=0;index=0;text_x=16;text_y=0;character=0;character_valid=0;digits=0;selected_option=0;
        selected=0;enabled=1;number_text=0;
        if(lcd_valid && pix_x<visible_width)begin
            hit_now=1;
            if(x>=286)background={6'h10,6'h20,6'h20};
            if(y<64)begin
                label_id=view.scene.layer==0?8'd1:8'(2+view.scene.category);text_y=24;
            end else if(y>=430)begin
                text_y=442;
                if(guide_view.waiting_release)label_id=86;
                else if(view.scene.busy)label_id=74;
                else if(view.scene.has_result)begin
                    case(view.scene.result)
                        CFG_OK:label_id=75;CFG_UNSUPPORTED:label_id=76;default:label_id=77;
                    endcase
                end else label_id=view.scene.layer==2?8'd80:8'd87;
                if(x>=184)begin label_id=71;text_x=184;end
            end else if(y>=88 && y<376)begin
                if(y<136)begin row=0;text_y=100;end
                else if(y<184)begin row=1;text_y=148;end
                else if(y<232)begin row=2;text_y=196;end
                else if(y<280)begin row=3;text_y=244;end
                else if(y<328)begin row=4;text_y=292;end
                else begin row=5;text_y=340;end
                if(view.scene.layer==0)begin
                    label_id=8'(2+row);selected=(row==view.scene.selection);
                    if(x>=248)begin text_x=248;glyph=GLYPH_RIGHT;end
                end else if(view.scene.layer==1)begin
                    index=5'(category_item(view.scene.category,int'(row)));
                    if(row<category_count(view.scene.category))begin
                        enabled=supported[index] && !(index==20 && values[11]==0);selected=(row==view.scene.selection);
                        digits=value_digits[index];label_id=8'(20+index);
                        if(x>=184)begin
                            text_x=184;
                            if(!enabled)label_id=72;
                            else if(index==1||index==21|| (index==12&&channel_nonzero))number_text=1;
                            else label_id=value_labels[index];
                        end
                    end
                end else begin
                    index=view.scene.edit_index;digits=draft_digits;
                    if(row==0)label_id=8'(20+index);
                    else if(index==1||index==21||index==12)begin
                        if(row==1)begin number_text=1;text_x=80;text_y=148;end
                        if(row==3)begin label_id=81;text_x=80;end
                    end else if(cfg_action(index))begin
                        if(row==1)label_id=70;
                        if(row==2 && index==16)label_id=86;
                    end else begin
                        selected_option=options[row];
                        if(selected_option[9])begin
                            label_id=selected_option[7:0];selected=selected_option[8];
                            text_x=32;
                        end
                    end
                end
                // Plan A: show that the custom binding capability exists even
                // before it is uploaded. This is display-only: it does not add
                // a selectable option and does not change low/high behavior.
                if(((view.scene.layer==1 && view.scene.category==2) ||
                    (view.scene.layer==2 && view.scene.edit_index==5)) &&
                   view.values[5]!=2 && y>=356 && y<372)begin
                    label_id=8'd126;text_x=16;text_y=356;
                    enabled=0;selected=0;number_text=0;
                end
                if(selected)begin
                    background={6'h07,6'h15,6'h15};
                    if(x>=8&&x<11)background={6'h0c,6'h38,6'h2c};
                end
                if(!enabled)text_color={6'h16,6'h20,6'h22};
            end
            if(view.scene.layer==2 && (view.scene.edit_index==1) &&
               y>=222&&y<232 && x>=24&&x<264)begin
                background=x<={1'b0,slider_end}?{6'h0c,6'h38,6'h2c}:{6'h0c,6'h14,6'h18};
            end
            character_valid=x>=text_x && x<text_x+10'd256;
            character=4'((x-text_x)>>4);
            if(x>=text_x && y>=text_y && y<text_y+16)begin
                font_x=4'(x-text_x);font_y=4'(y-text_y);text_on=1;
            end
        end else if(lcd_valid && y<48 && !guide_view.enabled)begin
            hit_now=1;text_x=24;text_y=16;
            label_id=8'(54+view.display_cfg.style_id);
            if(pix_x>=560)begin
                text_x=560;label_id=supported[0]?value_labels[0]:8'd72;
            end
            if(int'(pix_x)>=text_x && int'(pix_x)<text_x+240 && y>=16&&y<32)begin
                character=4'((pix_x-text_x)>>4);character_valid=1;
                font_x=4'(int'(pix_x)-text_x);font_y=4'(y-16);text_on=1;
            end
        end else if(lcd_valid && visible_width==0 && pix_x<20 && y>=200&&y<280)begin
            hit_now=1;background={6'h07,6'h12,6'h15};
            label_id=1;character=y<240?4'd0:4'd1;character_valid=1;
            font_x=4'(pix_x);font_y=4'(y-(y<240?216:248));
            text_on=pix_x<16 && ((y>=216&&y<232)||(y>=248&&y<264));
        end
        if(lcd_valid && !view.scene.open &&
           ((int'(pix_x)>=int'(view.scene.cursor_x)-4&&int'(pix_x)<=int'(view.scene.cursor_x)+4&&pix_y==view.scene.cursor_y)||
            (pix_x==view.scene.cursor_x&&int'(pix_y)>=int'(view.scene.cursor_y)-4&&int'(pix_y)<=int'(view.scene.cursor_y)+4)))begin
            hit_now=1;background={6'h20,6'h3f,6'h2c};text_on=0;
        end
    end
    logic hit_a,hit_b,text_a,text_b,char_a,number_a;
    logic[7:0] label_a,override_a;
    logic[7:0] label_glyph_b,bypass_glyph_b;
    logic use_label_b;
    wire[7:0] glyph_b=use_label_b ? label_glyph_b : bypass_glyph_b;
    logic[3:0] character_a,font_x_a,font_y_a,font_x_b,font_y_b;
    logic[31:0] digits_a;
    logic[17:0] background_a,color_a,background_b,color_b;
    logic[15:0] font_bits;
    logic[3:0] column_q;
    logic text_q;
    logic[17:0] background_q,text_color_q;
    // Stage B: registered label address -> synchronous glyph ROM. Bypass and
    // pixel coordinates are registered on the same edge; stage C reads bitmap.
    sidebar_label_rom #(.LABEL_FILE(LABEL_FILE)) u_labels(
        .clk(clk),.label_id(label_a),.character(character_a),.glyph(label_glyph_b));
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            hit_a<=0;hit_b<=0;text_a<=0;text_b<=0;char_a<=0;number_a<=0;
            label_a<=0;override_a<=0;bypass_glyph_b<=0;use_label_b<=0;character_a<=0;digits_a<=0;
            font_x_a<=0;font_y_a<=0;font_x_b<=0;font_y_b<=0;
            background_a<=0;color_a<=0;background_b<=0;color_b<=0;
            hit<=0;font_bits<=0;column_q<=0;text_q<=0;background_q<=0;text_color_q<=0;
        end else begin
            hit_a<=hit_now;text_a<=text_on;char_a<=character_valid;number_a<=number_text;
            label_a<=label_id;override_a<=glyph;character_a<=character;digits_a<=digits;
            font_x_a<=font_x;font_y_a<=font_y;background_a<=background;color_a<=text_color;
            hit_b<=hit_a;text_b<=text_a;
            bypass_glyph_b<=override_a;
            use_label_b<=!number_a && override_a==0 && label_a!=0 && char_a;
            if(number_a) begin
                case(character_a)
                    0:bypass_glyph_b<=digits_a[31:24];1:bypass_glyph_b<=digits_a[23:16];
                    2:bypass_glyph_b<=digits_a[15:8];3:bypass_glyph_b<=digits_a[7:0];default:bypass_glyph_b<=0;
                endcase
            end
            font_x_b<=font_x_a;font_y_b<=font_y_a;background_b<=background_a;color_b<=color_a;
            hit<=hit_b;font_bits<=font_rom[{glyph_b,font_y_b}];column_q<=font_x_b;
            text_q<=text_b;background_q<=background_b;text_color_q<=color_b;
        end
    end
    assign {r,g,b}=text_q&&font_bits[15-column_q]?text_color_q:background_q;
endmodule
