`timescale 1ns/1ps
// PT8211 Japanese/LSBJ, 16 bits per slot: WS=0 right, WS=1 left.
// DIN/WS change at BCK falling edges, MSB with the slot's first edge.
// Frame length = 32*CLK_DIV audio clocks. With CLK_DIV=8 and 12.5MHz,
// BCK=1.5625MHz and Fs=48.828125kHz. Boundary matches I2S CLK_DIV=4.
module pt8211_tx #(parameter int CLK_DIV=8)(
    input logic clk,rst_n,
    input logic in_valid,
    output logic in_ready,
    input logic [31:0] in_data, // {left, right}, atomic at a frame boundary
    output logic dac_bck,dac_ws,dac_din,
    output logic frame_tick
);
    localparam int TW=$clog2(CLK_DIV);
    logic [TW-1:0] phase;
    logic [4:0] bit_index;
    logic [31:0] pair;
    wire falling=phase==CLK_DIV-1;
    wire [4:0] next_bit=bit_index+5'd1;
    wire [31:0] selected=next_bit==0 ? (in_valid?in_data:32'd0) : pair;
    assign dac_bck=phase>=CLK_DIV/2;
    assign in_ready=falling && next_bit==0;
    initial if(CLK_DIV<2 || CLK_DIV%2!=0)$error("PT8211 CLK_DIV must be even and >=2");
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin phase<=0;bit_index<=0;pair<=0;dac_ws<=0;dac_din<=0;frame_tick<=0;end
        else begin
            phase<=falling?'0:phase+1'b1;
            frame_tick<=in_ready;
            if(falling)begin
                bit_index<=next_bit;
                if(next_bit==0)pair<=in_valid?in_data:32'd0;
                dac_ws<=next_bit[4];
                dac_din<=next_bit[4] ? selected[31-next_bit[3:0]] : selected[15-next_bit[3:0]];
            end
        end
    end
endmodule
