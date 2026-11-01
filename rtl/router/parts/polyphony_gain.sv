`timescale 1ns/1ps
// One common gain before stereo: 1/sqrt(N), including release voices.
// Q12 lookup and sample-rate slew; no division or audio-dependent gain boosting.
module polyphony_gain #(
    parameter bit ENABLE=1,
    parameter int DOWN_SHIFT=3,UP_SHIFT=12
)(
    input logic clk,rst_n,clear,in_valid,
    input logic signed[63:0] in_data,
    input logic[4:0] voices,
    output logic out_valid,
    output logic signed[63:0] out_data,
    output logic[12:0] gain_q12
);
    logic[12:0] target,next_gain,step_value;
    logic signed[77:0] product;
    logic product_valid;
    always_comb begin
        target=!ENABLE ? 13'd4096 : voices==0 ? gain_q12 : performance_gain_pkg::count_scale(voices);
        next_gain=gain_q12;step_value=0;
        if(target<gain_q12)begin
            step_value=(gain_q12-target)>>DOWN_SHIFT;
            next_gain=gain_q12-(step_value==0 ? 13'd1 : step_value);
        end else if(target>gain_q12)begin
            step_value=(target-gain_q12)>>UP_SHIFT;
            next_gain=gain_q12+(step_value==0 ? 13'd1 : step_value);
        end
    end
    always_ff @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin gain_q12<=4096;product<=0;product_valid<=0;out_valid<=0;out_data<=0;end
        else if(clear)begin gain_q12<=4096;product<=0;product_valid<=0;out_valid<=0;out_data<=0;end
        else begin
            product_valid<=in_valid;out_valid<=product_valid;
            if(in_valid)begin
                gain_q12<=next_gain;
                product<=$signed(in_data)*$signed({1'b0,next_gain});
            end
            if(product_valid)out_data<=64'((product+78'sd2048)>>>12);
        end
    end
endmodule
