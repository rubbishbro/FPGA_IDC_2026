`timescale 1ns/1ps
// TEMP_FMAP_DISPLAY_20261101: temporary raw PAD debug overlay. Remove this
// file, its sources.f entry and the marked instrument_system connections to undo.
// 4x4 unsigned decimal values (000..255), slot 0 at top left, slot 15 bottom right.
// No font ROM: small seven-segment digits. Raw bytes, BEFORE force_map scaling.
module temporary_fmap_display(
    input wire rst_n,core_clk,pix_clk,frame_pulse,lcd_valid,
    input wire [127:0] fmap_raw,
    input wire [9:0] pix_x,pix_y,
    input wire [5:0] base_r,base_g,base_b,
    output wire [5:0] lcd_r,lcd_g,lcd_b
);
    wire snapshot_valid;
    wire [127:0] snapshot;
    // Whole-map handshake keeps the source bus stable across clock domains.
    // Accept at frame end only; displayed numbers stay fixed for the next frame.
    sidebar_mailbox #(.WIDTH(128)) u_snapshot(
        .rst_n(rst_n),.src_clk(core_clk),.dst_clk(pix_clk),
        .src_valid(1'b1),.src_ready(),.src_data(fmap_raw),
        .src_done(),.src_done_data(),.dst_valid(snapshot_valid),
        .dst_ready(frame_pulse),.dst_data(snapshot));

    function automatic [11:0] decimal_byte(input logic [7:0] value);
        logic [11:0] bcd;
        begin
            bcd=0;
            for(integer b=7;b>=0;b=b-1)begin
                for(integer d=0;d<3;d=d+1)
                    if(bcd[d*4 +:4]>=5)bcd[d*4 +:4]=bcd[d*4 +:4]+4'd3;
                bcd={bcd[10:0],value[b]};
            end
            decimal_byte=bcd;
        end
    endfunction
    logic [11:0] numbers[0:15];
    always_ff @(posedge pix_clk or negedge rst_n)begin
        if(!rst_n)for(integer i=0;i<16;i=i+1)numbers[i]<=0;
        else if(frame_pulse && snapshot_valid)
            for(integer i=0;i<16;i=i+1)numbers[i]<=decimal_byte(snapshot[i*8 +:8]);
    end

    // Segment order: top, upper-right, lower-right, bottom, lower-left,
    // upper-left, middle (bits 6..0).
    function automatic [6:0] segments(input logic [3:0] digit);
        case(digit)
            0:segments=7'b1111110;1:segments=7'b0110000;
            2:segments=7'b1101101;3:segments=7'b1111001;
            4:segments=7'b0110011;5:segments=7'b1011011;
            6:segments=7'b1011111;7:segments=7'b1110000;
            8:segments=7'b1111111;9:segments=7'b1111011;
            default:segments=0;
        endcase
    endfunction
    // Panel x=320..575, y=48..175: 64x32 pixels per cell, outside the sidebar.
    wire panel=lcd_valid && pix_x>=320 && pix_x<576 && pix_y>=48 && pix_y<176;
    wire [9:0] x=pix_x-10'd320,y=pix_y-10'd48;
    wire [3:0] slot={y[6:5],x[7:6]};
    logic [3:0] digit;
    logic [5:0] dx;
    wire [4:0] dy=y[4:0]-5'd8;
    logic digit_area;
    logic [6:0] seg;
    logic ink;
    always_comb begin
        digit=0;dx=0;digit_area=1;
        if(x[5:0]>=14 && x[5:0]<22)begin digit=numbers[slot][11:8];dx=x[5:0]-6'd14;end
        else if(x[5:0]>=26 && x[5:0]<34)begin digit=numbers[slot][7:4];dx=x[5:0]-6'd26;end
        else if(x[5:0]>=38 && x[5:0]<46)begin digit=numbers[slot][3:0];dx=x[5:0]-6'd38;end
        else digit_area=0;
        seg=segments(digit);
        ink=panel && digit_area && dy<14 && (
            (seg[6] && dy<2 && dx>=1 && dx<7) ||
            (seg[5] && dx>=6 && dy>=1 && dy<7) ||
            (seg[4] && dx>=6 && dy>=7 && dy<13) ||
            (seg[3] && dy>=12 && dx>=1 && dx<7) ||
            (seg[2] && dx<2 && dy>=7 && dy<13) ||
            (seg[1] && dx<2 && dy>=1 && dy<7) ||
            (seg[0] && dy>=6 && dy<8 && dx>=1 && dx<7));
    end
    // Match sidebar_system's three pixel stages plus final RGB/DE register.
    // No extra clock is inserted in the LCD clock, DE or base RGB path.
    logic [3:0] hit_q,ink_q,grid_q;
    always_ff @(posedge pix_clk or negedge rst_n)begin
        if(!rst_n)begin hit_q<=0;ink_q<=0;grid_q<=0;end
        else begin
            hit_q<={hit_q[2:0],panel};ink_q<={ink_q[2:0],ink};
            grid_q<={grid_q[2:0],panel && (x[5:0]==0 || y[4:0]==0 || x==255 || y==127)};
        end
    end
    assign lcd_r=hit_q[3] ? (ink_q[3]?6'd63:6'd0) : base_r;
    assign lcd_g=hit_q[3] ? (ink_q[3]?6'd63:(grid_q[3]?6'd16:6'd0)) : base_g;
    assign lcd_b=hit_q[3] ? (ink_q[3]?6'd0:(grid_q[3]?6'd40:6'd8)) : base_b;
endmodule
