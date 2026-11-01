`timescale 1ns/1ps
// Common post-reverb gain before stereo; count includes release voices.
// Fixed wiring shifts only: 1 voice x4, 2..7 voices x2, otherwise unity.
// Preserve the two-register valid/data pipeline; no multiplier or gain slew.
module polyphony_gain #(
    parameter bit ENABLE=1
)(
    input logic clk,rst_n,clear,in_valid,
    input logic signed[63:0] in_data,
    input logic[4:0] voices,
    output logic out_valid,
    output logic signed[63:0] out_data,
    output logic[14:0] gain_q12
);
    logic signed[63:0] shifted;
    logic shifted_valid;
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin gain_q12<=4096;shifted<=0;shifted_valid<=0;out_valid<=0;out_data<=0;end
        else if(clear)begin gain_q12<=4096;shifted<=0;shifted_valid<=0;out_valid<=0;out_data<=0;end
        else begin
            shifted_valid<=in_valid;out_valid<=shifted_valid;
            if(in_valid)begin
                if(ENABLE && voices==1)begin
                    shifted<={in_data[61:0],2'b00};gain_q12<=15'd16384;
                end else if(ENABLE && voices>=2 && voices<=7)begin
                    shifted<={in_data[62:0],1'b0};gain_q12<=15'd8192;
                end else begin
                    shifted<=in_data;gain_q12<=15'd4096;
                end
            end
            if(shifted_valid)out_data<=shifted;
        end
    end
endmodule
