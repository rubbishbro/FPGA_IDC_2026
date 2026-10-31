`timescale 1ns/1ps
// Test-only PLL/ADC substitutes. Production sources.f includes only vendor IP.
module Gowin_PLL_core_100M(input clkin,init_clk,output logic clkout0=0,clkout_audio=0,clkout_pix=0,lock=0);
    always #10 clkout0=~clkout0;
    always #40 clkout_audio=~clkout_audio;
    always #15 clkout_pix=~clkout_pix;
    initial begin #710;lock=1;end
endmodule
module Gowin_ADC #(parameter bit CHECK_MUX=1)(output logic adcrdy=0,output logic [13:0] adcvalue=0,
    input drstn,adcreqi,input [9:0] fscal_value,input [11:0] offset_value);
    logic [3:0] row;
    logic [2:0] ch;
    integer conversions=0;
    generate if(CHECK_MUX)begin:g_checked
    always @(posedge adcreqi)begin
        adcrdy=0;row=tb_instrument_board.pad_row;ch=tb_instrument_board.pad_ch;
        // Completion must follow the 800ns request/clear interval, as real ADC does.
        #2000;
        if(row!==tb_instrument_board.pad_row || ch!==tb_instrument_board.pad_ch)
            $fatal(1,"FAIL ADC mux/row changed during conversion");
        if(drstn)begin
            adcvalue=ch<4 ? ((row==1 && ch==0 && tb_instrument_board.pad_enabled) ? 14'd2048 : (row==1 && ch==1 ? 14'h3fff : 14'd0)) :
                           (ch==4 ? 14'd3000 : 14'd3200);
            adcrdy=1;conversions++;
        end
    end
    end else begin:g_silence
        // Control-only test fixtures need a conversion model without a reference
        // to another testbench root. Full board tests retain CHECK_MUX=1.
        always @(posedge adcreqi)begin
            adcrdy=0;
            #2000;
            if(drstn)begin adcvalue=0;adcrdy=1;conversions++;end
        end
    end endgenerate
endmodule
