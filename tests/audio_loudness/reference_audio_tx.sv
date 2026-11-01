`timescale 1ns/1ps
// Independent shift-register implementation, no project audio modules.
// 50MHz / 1024 frames; I2S 64x16 clocks, PT8211 32x32 clocks.
module reference_audio_tx(
    input wire clk,rst_n,
    input wire [31:0] pcm_pair,
    output wire amp_bclk,dac_bck,
    output logic amp_ws,amp_din,dac_ws,dac_din,frame_tick
);
    logic [9:0] count;
    logic [63:0] i2s_shift;
    logic [31:0] pt_shift;
    wire [5:0] next_i2s=count[9:4]+6'd1;
    wire [4:0] next_pt=count[9:5]+5'd1;
    assign amp_bclk=count[3];
    assign dac_bck=count[4];
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            count<=0;i2s_shift<=0;pt_shift<=0;
            amp_ws<=0;amp_din<=0;dac_ws<=0;dac_din<=0;frame_tick<=0;
        end else begin
            count<=count+1'b1;
            frame_tick<=count==1023;
            if(count[3:0]==15)begin
                amp_ws<=next_i2s[5];
                if(count==1023)begin
                    amp_din<=0; // Standard I2S one-bit delay before left MSB.
                    i2s_shift<={pcm_pair[31:16],15'd0,1'b0,pcm_pair[15:0],15'd0,1'b0};
                end else begin
                    amp_din<=i2s_shift[63];i2s_shift<=i2s_shift<<1;
                end
            end
            if(count[4:0]==31)begin
                dac_ws<=next_pt[4];
                if(count==1023)begin
                    // PT8211: right MSB immediately at WS falling edge.
                    dac_din<=pcm_pair[15];
                    pt_shift<={pcm_pair[14:0],pcm_pair[31:16],1'b0};
                end else begin
                    dac_din<=pt_shift[31];pt_shift<=pt_shift<<1;
                end
            end
        end
    end
endmodule
