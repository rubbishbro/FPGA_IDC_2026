`timescale 1ns/1ps
module tb_midi_instrument_map;
    logic [3:0] channel;
    logic mapped;
    router_pkg::instrument_e instrument;
    integer expected[0:7]='{1,0,3,5,4,2,10,11};
    midi_instrument_map dut(.*);
    initial begin
        for(integer i=0;i<16;i++) begin
            channel=i; #1;
            if(i<8) begin
                if(!mapped || instrument!=expected[i]) $fatal(1,"FAIL channel=%0d instrument=%0d",i,instrument);
                if(config_pkg::instrument_channel(16'(instrument))!=i+1)
                    $fatal(1,"FAIL inverse mapping channel=%0d",i);
            end else if(mapped || instrument!=router_pkg::INST_NONE)
                $fatal(1,"FAIL unmapped channel=%0d",i);
        end
        if(router_pkg::eng_sel(router_pkg::INST_PIANO) || router_pkg::eng_sel(router_pkg::INST_GUITAR) ||
           !router_pkg::eng_sel(router_pkg::INST_PIANO_ABC) || !router_pkg::eng_sel(router_pkg::INST_GUITAR_ABC))
            $fatal(1,"FAIL parallel engine choices");
        if(config_pkg::instrument_label(0)!=100 || config_pkg::instrument_label(1)!=101 ||
           config_pkg::instrument_label(10)!=124 || config_pkg::instrument_label(11)!=125)
            $fatal(1,"FAIL distinct piano/guitar labels");
        $display("PASS tb_midi_instrument_map channels=16"); $finish;
    end
endmodule
