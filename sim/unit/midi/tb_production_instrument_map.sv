`timescale 1ns/1ps
module tb_production_instrument_map;
    import router_pkg::*;
    import config_pkg::*;
    logic [3:0] channel;
    logic mapped;
    instrument_e inst;
    audio_config_t cfg;
    midi_instrument_map dut(.channel(channel),.mapped(mapped),.instrument(inst));
    initial begin
        for(int c=0;c<16;c++)begin
            channel=4'(c);#1;
            if(mapped!==(c<12))$fatal(1,"FAIL MIDI map admission");
            if(c<12)begin
                if(inst==INST_NONE || instrument_channel(16'(inst))!=c+1)
                    $fatal(1,"FAIL MIDI map inverse");
                cfg='0;cfg.source=1;cfg.channel=5'(c+1);cfg.instrument=16'(inst);
                if(!audio_config_valid(cfg))$fatal(1,"FAIL backend denies mapped instrument");
            end
        end
        for(int i=0;i<12;i++)begin
            if(uses_mod1(instrument_e'(i)) !== (i!=0 && i!=1 && i!=7 && i!=10))
                $fatal(1,"FAIL mod1 route");
            if(is_sustain(instrument_e'(i)) !== (i>=2 && i<=6))
                $fatal(1,"FAIL sustained route");
        end
        $display("PASS tb_production_instrument_map 12 MIDI mappings, 8 mod1 routes, pianos/drums modulation disabled");$finish;
    end
endmodule
