`timescale 1ns/1ps
// Independent wide reference proves the shortened carry chain keeps rounding,
// negative ties, saturation and every allowed shift boundary unchanged.
module tb_pcm_equivalence;
    i2s_audio_output #(.PCM_HEADROOM_BITS(0)) h0(.clk(1'b0),.audio_clk(1'b0),.rst_n(1'b0),
        .active(1'b0),.in_valid(1'b0),.in_data(64'sd0),.sample_tick(),.amp_bclk(),.amp_ws(),.amp_din(),.deadline_miss(),.overflow(),.underflow());
    i2s_audio_output #(.PCM_HEADROOM_BITS(3)) h3(.clk(1'b0),.audio_clk(1'b0),.rst_n(1'b0),
        .active(1'b0),.in_valid(1'b0),.in_data(64'sd0),.sample_tick(),.amp_bclk(),.amp_ws(),.amp_din(),.deadline_miss(),.overflow(),.underflow());
    i2s_audio_output #(.PCM_HEADROOM_BITS(53)) h53(.clk(1'b0),.audio_clk(1'b0),.rst_n(1'b0),
        .active(1'b0),.in_valid(1'b0),.in_data(64'sd0),.sample_tick(),.amp_bclk(),.amp_ws(),.amp_din(),.deadline_miss(),.overflow(),.underflow());
    function automatic logic[15:0] reference(input logic signed[63:0] value,input integer shift);
        logic signed[64:0] scaled;
        scaled=($signed({value[63],value})+(65'sd1<<(shift-1)))>>>shift;
        return scaled>32767?16'h7fff:scaled< -32768?16'h8000:16'(scaled);
    endfunction
    integer count=0,seed=873212;
    task automatic check(input logic signed[63:0] value);
        if(h0.pcm16(value)!==reference(value,9) || h3.pcm16(value)!==reference(value,12) || h53.pcm16(value)!==reference(value,62))
            $fatal(1,"FAIL PCM equivalence value=%h",value);
        count++;
    endtask
    initial begin
        check(64'sh8000000000000000);check(64'sh7fffffffffffffff);check(0);check(-1);
        for(longint signed q=-32770;q<=32769;q++)begin
            check((q<<<12));check((q<<<12)+2047);check((q<<<12)+2048);check((q<<<12)+4095);
            check((q<<<9));check((q<<<9)+255);check((q<<<9)+256);check((q<<<9)+511);
        end
        repeat(100000)check({$urandom(seed),$urandom(seed)});
        $display("PASS tb_pcm_equivalence vectors=%d headroom=0/3/53",count);$finish;
    end
endmodule
