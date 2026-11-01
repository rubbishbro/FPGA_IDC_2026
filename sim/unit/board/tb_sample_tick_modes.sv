`timescale 1ns/1ps
module tb_sample_tick_modes;
    logic clk=0;always #5 clk=~clk;
    logic rst_n=0,sample_tick=0;
    sample_tick_probe #(.EXTERNAL_SAMPLE_TICK(1)) external_tick(.*);
    sample_tick_probe #(.EXTERNAL_SAMPLE_TICK(0)) legacy_tick(.*);
    integer phase=0,cycles=0;
    logic expected_external=0,expected_legacy=0;
    always @(posedge clk)begin
        if(!rst_n)begin phase=0;expected_external=0;expected_legacy=0;end
        else begin
            expected_external=sample_tick;
            // Public legacy rate is one tick per ten clocks, followed by
            // the router's existing one-clock input register.
            expected_legacy=phase==0 && cycles>0;
            phase=(phase+1)%10;
        end
        #1;
        if(external_tick.smp_tick_q!==expected_external || legacy_tick.smp_tick_q!==expected_legacy)
            $fatal(1,"FAIL sample tick reset/rate/alignment at cycle %0d",cycles);
        cycles++;
    end
    initial begin
        repeat(3)@(negedge clk);
        rst_n=1;
        // First legacy output follows ten elapsed active clocks.
        phase=0;cycles=0;
        for(integer i=0;i<80;i++)begin
            sample_tick=(i%7==2 || i%7==3);
            @(negedge clk);
        end
        rst_n=0;sample_tick=1;repeat(3)@(negedge clk);
        rst_n=1;phase=0;cycles=0;repeat(30)@(negedge clk);
        $display("PASS tb_sample_tick_modes external_legacy_reset_rate_alignment");$finish;
    end
endmodule
