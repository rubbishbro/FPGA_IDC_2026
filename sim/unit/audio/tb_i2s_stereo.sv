`timescale 1ns/1ps
// Wire-only decoder observes BOTH channels, padding and the standard I2S bit delay.
module i2s_stereo_scoreboard(
    input logic clk,rst_n,bclk,ws,din,expected_valid,
    input logic [31:0] expected_pair,
    output integer frames,nonzero_frames,different_frames
);
    logic [31:0] expected[$];
    logic [31:0] current=0;
    logic [15:0] left=0,right=0;
    logic prev_ws=0;
    integer bitno=0;
    always @(posedge clk)begin
        if(!rst_n)expected.delete();
        else if(expected_valid)expected.push_back(expected_pair);
    end
    always @(negedge ws)if(rst_n)
        current=expected.size()>0?expected.pop_front():32'd0;
    always @(posedge bclk or negedge rst_n)begin
        if(!rst_n)begin frames=0;nonzero_frames=0;different_frames=0;prev_ws=0;bitno=0;left=0;right=0;current=0;end
        else begin
            if(ws!=prev_ws)begin bitno=0;if(!ws)begin left=0;right=0;end end
            else bitno++;
            if(bitno>=1 && bitno<=16)begin
                if(!ws)left={left[14:0],din};else right={right[14:0],din};
            end else if(din!==0)$fatal(1,"FAIL stereo I2S padding ws=%b bit=%d",ws,bitno);
            if(ws && bitno==16)begin
                frames++;
                if({left,right}!==current)$fatal(1,"FAIL stereo I2S frame=%d actual=%h,%h expected=%h",frames,left,right,current);
                if(current!=0)nonzero_frames++;
                if(left!=right)different_frames++;
            end
            prev_ws=ws;
        end
    end
endmodule

module tb_i2s_stereo;
    parameter int HEADROOM=3,MAX_ITD=4;
    parameter bit EXACT_48K=0;
    localparam real AH=EXACT_48K?40.6901041666667:40.0;
    logic clk=0,aclk=0,rst_n=0,active=0,yv=0,itd=0;
    always #5 clk=~clk;
    initial begin #3.137;forever #(AH)aclk=~aclk;end
    logic signed [63:0] x=0;
    logic [5:0] pan=16;
    logic tick,bclk,ws,din,late,overflow,underflow;
    logic signed [83:0] el,er;
    logic [9:0] ep,edl,edr;
    logic [12:0] egl,egr;
    logic clear;
    logic fault_tests=0;
    logic [31:0] expected_pair=0;
    integer fd,n,rows=0,frames,nz,different;
    string filename;
    i2s_audio_output #(.PCM_HEADROOM_BITS(HEADROOM),.ITD_MAX_SAMPLES(MAX_ITD)) dut(
        .clk(clk),.audio_clk(aclk),.rst_n(rst_n),.active(active),.in_valid(yv),.in_data(x),
        .pan_position(pan),.itd_enable(itd),.sample_tick(tick),.amp_bclk(bclk),.amp_ws(ws),.amp_din(din),
        .deadline_miss(late),.overflow(overflow),.underflow(underflow));
    function automatic logic [15:0] reference_pcm(input logic signed [83:0] value);
        logic signed [99:0] v;
        v=(100'($signed(value))+(100'sd1<<(26+HEADROOM)))>>>(27+HEADROOM);
        return v>32767?16'h7fff:v< -32768?16'h8000:16'(v);
    endfunction
    i2s_stereo_scoreboard checkwire(clk,rst_n,bclk,ws,din,tick,expected_pair,frames,nz,different);
    always @(negedge clk)if(rst_n && !fault_tests && (late || overflow || underflow))
        $fatal(1,"FAIL stereo bridge diagnostics %b%b%b row=%d",late,overflow,underflow,rows);
    initial begin
        if(!$value$plusargs("VECTORS=%s",filename))$fatal(1,"FAIL missing VECTORS");
        repeat(6)@(negedge clk);rst_n=1;
        fd=$fopen(filename,"r");if(!fd)$fatal(1,"FAIL vector file");
        while(!$feof(fd))begin
            @(posedge tick);@(negedge clk);
            n=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h\n",x,pan,itd,clear,el,er,ep,egl,egr,edl,edr);
            if(n!=11)$fatal(1,"FAIL bridge vector row");
            active=!clear;yv=active;
            expected_pair={reference_pcm(el),reference_pcm(er)};rows++;
            @(negedge clk);yv=0;
        end
        $fclose(fd);
        // Stop must mask all old delay history; drain already queued frames first.
        repeat(8)begin @(posedge tick);@(negedge clk);active=0;expected_pair=0;end
        if(frames<rows || nz<100 || (MAX_ITD!=0 && different<100))$fatal(1,"FAIL stereo coverage");
        fault_tests=1;active=1;
        repeat(5)begin @(posedge tick);@(negedge clk);expected_pair=0;end
        if(!late || overflow || underflow)$fatal(1,"FAIL stereo missing-result diagnostic");
        repeat(50)@(negedge clk);x=512;yv=1;
        repeat(2)@(negedge clk);yv=0;
        if(!overflow || underflow)$fatal(1,"FAIL stereo duplicate-result diagnostic");
        $display("PASS tb_i2s_stereo headroom=%0d max_itd=%0d exact48=%0d vectors=%0d frames=%0d nonzero=%0d different=%0d",
            HEADROOM,MAX_ITD,EXACT_48K,rows,frames,nz,different);
        $finish;
    end
    initial begin #150000000;$fatal(1,"FAIL stereo I2S timeout");end
endmodule
