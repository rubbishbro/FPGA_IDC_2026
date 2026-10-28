`timescale 1ns/1ps
module tb_midi_instrument_map;
    logic [3:0] channel;
    logic mapped;
    router_pkg::instrument_e instrument;
    integer expected[0:5]='{1,0,3,5,4,2};
    midi_instrument_map dut(.*);
    initial begin
        for(integer i=0;i<16;i++) begin
            channel=i; #1;
            if(i<6) begin
                if(!mapped || instrument!=expected[i]) $fatal(1,"FAIL channel=%0d instrument=%0d",i,instrument);
            end else if(mapped || instrument!=router_pkg::INST_NONE)
                $fatal(1,"FAIL unmapped channel=%0d",i);
        end
        $display("PASS tb_midi_instrument_map channels=16"); $finish;
    end
endmodule
