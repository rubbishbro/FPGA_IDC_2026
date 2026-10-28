`timescale 1ns/1ps
// 16x16 字模同步 ROM，输出延迟一拍；底图/DE 必须在合成处同样延迟一拍。
module lcd_sidebar #(parameter FONT_FILE="sidebar_font.mem")(
    input logic clk,rst_n,frame_pulse,lcd_valid,
    input logic[9:0] pix_x,pix_y,
    input config_pkg::sidebar_snapshot_t view,
    output logic hit,
    output logic[5:0] r,g,b,
    output logic[8:0] visible_width
);
    import config_pkg::*;
    import sidebar_font_pkg::*;
    cfg_values_t values;
    assign values=view.values;
    wire[19:0] supported=view.supported;
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
            0:value_label=(value>=0&&value<=9)?8'(100+value):8'd72;
            2:value_label=value==0?50:(value==1?52:53);
            3,8,9,10:value_label=value==0?50:51;
            5:value_label=value==0?59:60;
            6:value_label=8'(54+value);
            7:value_label=value==0?57:58;
            11:value_label=8'(61+value);
            12:value_label=64;
            13:case(value)0:value_label=50;1:value_label=91;2:value_label=92;default:value_label=93;endcase
            14:value_label=value==0?68:(value==1?66:69);
            15:value_label=value==0?65:(value==1?66:67);
            18:value_label=value==0?62:63;
            default:value_label=70;
        endcase
    endfunction
    logic[15:0] font_rom[0:4095];
    initial $readmemh(FONT_FILE,font_rom);
    logic[7:0] glyph,label_id;
    logic[3:0] font_y,font_x;
    logic text_on,hit_now;
    logic[17:0] background,text_color;
    integer x,y,row,index,value,text_x,text_y,character,first_option,option_value;
    logic selected,enabled,number_text;
    logic[9:0] number_value;
    wire[17:0] slider_target=18'(view.scene.draft[9:0])*18'd240;
    always_comb begin
        x=int'(pix_x)+288-int'(visible_width);y=int'(pix_y);
        glyph=0;label_id=0;font_x=0;font_y=0;text_on=0;hit_now=0;
        background={6'h03,6'h06,6'h09};text_color={6'h36,6'h3b,6'h3a};
        row=0;index=0;value=0;text_x=16;text_y=0;character=0;first_option=0;option_value=0;
        selected=0;enabled=1;number_text=0;number_value=0;
        if(lcd_valid && pix_x<visible_width)begin
            hit_now=1;
            if(x>=286)background={6'h10,6'h20,6'h20};
            if(y<64)begin
                label_id=view.scene.layer==0?8'd1:8'(2+view.scene.category);text_y=24;
            end else if(y>=430)begin
                text_y=442;
                if(view.scene.busy)label_id=74;
                else if(view.scene.has_result)begin
                    case(view.scene.result)
                        CFG_OK:label_id=75;CFG_UNSUPPORTED:label_id=76;default:label_id=77;
                    endcase
                end else label_id=view.scene.layer==2?8'd80:8'd87;
                if(x>=184)begin label_id=71;text_x=184;end
            end else if(y>=88 && y<376)begin
                row=(y-88)/48;text_y=100+row*48;
                if(view.scene.layer==0)begin
                    label_id=8'(2+row);selected=(row==view.scene.selection);
                    if(x>=248)begin text_x=248;glyph=GLYPH_RIGHT;end
                end else if(view.scene.layer==1)begin
                    index=category_base(view.scene.category)+row;
                    if(row<category_count(view.scene.category))begin
                        enabled=supported[index];selected=(row==view.scene.selection);
                        value=values[index];label_id=8'(20+index);
                        if(x>=184)begin
                            text_x=184;
                            if(!enabled)label_id=72;
                            else if(index==1||index==4|| (index==12&&value!=0))number_text=1;
                            else label_id=value_label(index,value);
                        end
                    end
                end else begin
                    index=view.scene.edit_index;value=view.scene.draft;
                    if(row==0)label_id=8'(20+index);
                    else if(index==1||index==4||index==12)begin
                        if(row==1)begin number_text=1;text_x=80;text_y=148;end
                        if(row==3)begin label_id=81;text_x=80;end
                    end else if(index>=16 && index!=18)begin
                        if(row==1)label_id=70;
                        if(row==2 && index==16)label_id=86;
                    end else begin
                        first_option=value>2?value-2:0;
                        option_value=first_option+row-1;
                        if(option_value<=cfg_max(index) &&
                           (index!=0||option_value<10) && (index!=6||option_value<3))begin
                            label_id=value_label(index,option_value);selected=(option_value==value);
                            text_x=32;
                        end
                    end
                end
                if(selected)begin
                    background={6'h07,6'h15,6'h15};
                    if(x>=8&&x<11)background={6'h0c,6'h38,6'h2c};
                end
                if(!enabled)text_color={6'h16,6'h20,6'h22};
            end
            if(view.scene.layer==2 && (view.scene.edit_index==1||view.scene.edit_index==4) &&
               y>=222&&y<232 && x>=24&&x<264)begin
                background=(18'(x-23)*18'd1000)<=slider_target?{6'h0c,6'h38,6'h2c}:{6'h0c,6'h14,6'h18};
            end
            // 数值的 % 显示精度为 1%；内部请求仍保存 0..1000 的完整值。
            if(number_text)begin
                number_value=10'(value);
                if(index==1||index==4)number_value=number_value/10;
                character=(x-text_x)/16;
                case(character)
                    0:glyph=number_value>=100?digit_glyph(4'((number_value/100)%10)):8'd0;
                    1:glyph=number_value>=10?digit_glyph(4'((number_value/10)%10)):8'd0;
                    2:glyph=digit_glyph(4'(number_value%10));
                    3:if(index==1||index==4)glyph=GLYPH_PERCENT;
                    default:glyph=0;
                endcase
            end else if(glyph==0 && label_id!=0 && x>=text_x && x<text_x+256)
                glyph=text_glyph(label_id,4'((x-text_x)/16));
            if(x>=text_x && y>=text_y && y<text_y+16)begin
                font_x=4'(x-text_x);font_y=4'(y-text_y);text_on=1;
            end
        end else if(lcd_valid && y<48)begin
            hit_now=1;text_x=24;text_y=16;
            label_id=8'(54+view.display_cfg.style_id);
            if(pix_x>=560)begin
                text_x=560;label_id=supported[0]?value_label(0,values[0]):8'd72;
            end
            if(int'(pix_x)>=text_x && int'(pix_x)<text_x+240 && y>=16&&y<32)begin
                glyph=text_glyph(label_id,4'((int'(pix_x)-text_x)/16));
                font_x=4'(int'(pix_x)-text_x);font_y=4'(y-16);text_on=1;
            end
        end else if(lcd_valid && visible_width==0 && pix_x<20 && y>=200&&y<280)begin
            hit_now=1;background={6'h07,6'h12,6'h15};
            glyph=text_glyph(1,y<240?4'd0:4'd1);
            font_x=4'(pix_x);font_y=4'(y-(y<240?216:248));
            text_on=pix_x<16 && ((y>=216&&y<232)||(y>=248&&y<264));
        end
        if(lcd_valid && !view.scene.open &&
           ((int'(pix_x)>=int'(view.scene.cursor_x)-4&&int'(pix_x)<=int'(view.scene.cursor_x)+4&&pix_y==view.scene.cursor_y)||
            (pix_x==view.scene.cursor_x&&int'(pix_y)>=int'(view.scene.cursor_y)-4&&int'(pix_y)<=int'(view.scene.cursor_y)+4)))begin
            hit_now=1;background={6'h20,6'h3f,6'h2c};text_on=0;
        end
    end
    logic[15:0] font_bits;
    logic[3:0] column_q;
    logic text_q;
    logic[17:0] background_q,text_color_q;
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin hit<=0;font_bits<=0;column_q<=0;text_q<=0;background_q<=0;text_color_q<=0;end
        else begin
            hit<=hit_now;font_bits<=font_rom[{glyph,font_y}];column_q<=font_x;
            text_q<=text_on;background_q<=background;text_color_q<=text_color;
        end
    end
    assign {r,g,b}=text_q&&font_bits[15-column_q]?text_color_q:background_q;
endmodule
