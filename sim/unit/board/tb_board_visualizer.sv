`timescale 1ns/1ps
// Exercise the production board tap/FIFO/FFT with independently scored samples.
// Synthetic PCM is injected only at the observation tap in this isolated test.
module tb_board_visualizer;
    logic clk=0,pix=0,audio=0,rst_n=0,pix_run=1,inject=0;
    logic signed [63:0] value=0;
    always #10 clk=~clk;
    always #15 if(pix_run)pix=~pix;
    always #40 audio=~audio;
    tri [3:0] dq;
    instrument_system dut(.clk_core(clk),.clk_audio(audio),.clk_pix(pix),.rst_n(rst_n),
        .key0(1'b1),.key1(1'b1),.uart_rx(2'b11),.session_restart(2'b0),.bt_state(1'b0),.flash_dq(dq));
    defparam dut.u_pad.input_inst.adc_inst.CHECK_MUX=0;
    logic [23:0] expected[0:8191];
    integer produced=0,consumed=0,nonzero_bars=0,fft_frames=0;
    bit observe=1;
    function automatic logic [23:0] converted(input logic signed [63:0] v);
        logic signed [63:0] q;
        q=v>>>2;
        if(q>8388607)return 24'h7fffff;
        if(q< -8388608)return 24'h800000;
        return q[23:0];
    endfunction
    always @(posedge clk)if(rst_n && dut.core_n && inject && dut.visualizer_ready && observe)begin
        expected[produced]=converted(value);produced++;
    end
    always @(posedge pix)if(rst_n && dut.pix_n)begin
        if(dut.pcm_valid_pix && observe)begin
            if(consumed>=produced || dut.pcm24_pix!==expected[consumed])
                $fatal(1,"FAIL CDC sample %0d got=%h expected=%h",consumed,dut.pcm24_pix,expected[consumed]);
            consumed++;
        end
        if(dut.u_fft_chain.sm_frame_done)fft_frames++;
        if(dut.u_fft_chain.sm_bar_we && dut.u_fft_chain.sm_bar_w>0)nonzero_bars++;
        if(dut.frame_pulse && !dut.u_fft_chain.u_fb.frame_seen && dut.q_y_fft!==0)
            $fatal(1,"FAIL uninitialized spectrum published before first complete frame");
    end
    task automatic send(input logic signed [63:0] v);
        @(negedge clk);inject=1;value=v;
        @(negedge clk);inject=0;
        repeat(69)@(negedge clk);
    endtask
    initial begin
        force dut.sample_valid=inject;force dut.sample_value=value;
        repeat(5)@(negedge clk);rst_n=1;repeat(20)@(negedge clk);
        send(64'sh7fffffffffffffff);send(-64'sh7fffffffffffffff);
        for(int n=0;n<2048;n++)send(n%32<16 ? 64'sd4194304 : -64'sd4194304);
        wait(consumed==produced);wait(fft_frames>=1 && nonzero_bars>0);
        if(dut.visualizer_overflow)$fatal(1,"FAIL observation FIFO overflow at normal sample cadence");
        // Reader stall may drop observation data, but it never backpressures synthesis.
        observe=0;@(negedge pix);pix_run=0;
        for(int n=0;n<24;n++)send(n);
        if(!dut.visualizer_overflow)$fatal(1,"FAIL missing observation overflow diagnostic");
        rst_n=0;inject=0;pix_run=1;repeat(20)@(negedge clk);rst_n=1;repeat(20)@(negedge clk);
        if(dut.visualizer_overflow || dut.pcm_valid_pix)$fatal(1,"FAIL observation reset did not flush stale samples");
        $display("PASS tb_board_visualizer CDC=%0d FFT_frames=%0d nonzero_bars=%0d saturation/stall/reset",consumed,fft_frames,nonzero_bars);$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL visualizer watchdog tx=%0d rx=%0d frames=%0d bars=%0d",produced,consumed,fft_frames,nonzero_bars);end
endmodule

module tb_polar_contracts;
    logic clk=0,rst_n=0,valid=0;
    always #5 clk=~clk;
    logic signed [10:0] x=0,y=0;
    wire [19:0] radius;
    wire [15:0] angle;
    wire ready;
    cordic_polar dut(.clk(clk),.rst_n(rst_n),.x_in(x),.y_in(y),.in_valid(valid),.r_out(radius),.ang_out(angle),.out_valid(ready));
    integer vectors=0;
    task automatic check(input integer ix,iy,target);
        integer diff;
        @(negedge clk);x=11'(ix);y=11'(iy);valid=1;
        @(negedge clk);valid=0;
        wait(ready);#1;
        diff=(integer'(angle)-target+65536)%65536;
        if(diff>32768)diff=65536-diff;
        if(diff>20 || radius<20950 || radius>21200)$fatal(1,"FAIL polar vector %0d,%0d angle=%0d radius=%0d",ix,iy,angle,radius);
        vectors++;wait(!ready);
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        check(100,0,0);check(0,100,16384);check(-100,0,32768);check(0,-100,49152);
        check(60,80,9672);check(-60,80,23096);check(-60,-80,42440);check(60,-80,55864);
        $display("PASS tb_polar_contracts vectors=%0d four-quadrant radius/angle",vectors);$finish;
    end
    initial begin #10000;$fatal(1,"FAIL polar watchdog");end
endmodule
