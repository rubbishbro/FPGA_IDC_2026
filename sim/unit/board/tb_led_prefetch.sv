`timescale 1ns/1ps
module tb_led_prefetch;
    import clk_rst_pkg::*;
    import pad_driver_pkg::*;
    logic clk=0,rst_n=0,wr=1;
    always #5 clk=~clk;
    logic[5:0] div=0;
    wire ce=div==39;
    always @(posedge clk)if(!rst_n)div<=0;else if(ce)div<=0;else div<=div+1'b1;
    clk_rst cr;
    assign cr={clk,ce,rst_n};
    logic[2:0] x=0,y=0;
    pixel_t pixel='0;
    wire original,optimized;
    led8x8 #(.PIPELINED_READ(0)) reference_led(.cr(cr),.x(x),.y(y),.pix(pixel),.wr(wr),.dat(original));
    led8x8 #(.PIPELINED_READ(1)) pipelined_led(.cr(cr),.x(x),.y(y),.pix(pixel),.wr(wr),.dat(optimized));
    integer checks=0,bits=0,seed=54365;
    always @(negedge clk)if(rst_n)begin
        if(original!==optimized)$fatal(1,"FAIL LED prefetch changed wire waveform at %d",checks);
        checks++;
    end
    always @(posedge clk)if(rst_n && ce && reference_led.state==1 && reference_led.idx<1536 && reference_led.t0_v==4)bits++;
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        repeat(2)begin
            wr=1;
            for(integer cell_index=0;cell_index<64;cell_index++)begin
                @(negedge clk);while(!ce)@(negedge clk);
                x=3'(cell_index/8);y=3'(cell_index%8);pixel=24'($urandom(seed));
            end
            @(negedge clk);wr=0;
            wait(reference_led.state==3);@(negedge clk);
        end
        if(bits!=3072)$fatal(1,"FAIL incomplete LED frames bits=%d",bits);
        $display("PASS tb_led_prefetch wire_checks=%d LED_bits=%d two_random_frames",checks,bits);$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL LED timeout");end
endmodule
