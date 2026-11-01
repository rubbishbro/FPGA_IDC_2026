`timescale 1ns/1ps
module test2_project_top #(
    parameter int DEBOUNCE_CYCLES=1_000_000
)(
    input wire clk,rst_n,key0,key1,
    output wire amp_bclk,amp_ws,amp_din,amp_sd,
    output wire dac_bck,dac_ws,dac_din,dac_pa_en
);
    tone_test_core #(.USE_PROJECT_TX(1),.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) u_core(.*);
endmodule
