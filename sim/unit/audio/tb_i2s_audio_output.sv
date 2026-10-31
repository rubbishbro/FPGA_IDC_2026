`timescale 1ns/1ps
// Wire-only decoder: deliberately does not use TX internal counters or FIFO data.
module i2s_scoreboard(
    input logic clk,rst_n,bclk,ws,din,expected_valid,
    input logic [15:0] expected_pcm,
    output integer frames,nonzero_frames
);
    logic [15:0] expected[$];
    logic [15:0] current=0,left=0,right=0;
    logic prev_ws=0;
    integer bitno=0;
    always @(posedge clk) begin
        if(!rst_n) expected.delete();
        else if(expected_valid) expected.push_back(expected_pcm);
    end
    // Select expected word at the WS transition, BEFORE core sees its CDC tick.
    // Sampling the queue at the next rising BCLK would accidentally see a future token.
    always @(negedge ws) if(rst_n)
        current=expected.size()>0 ? expected.pop_front() : 16'd0;
    always @(posedge bclk or negedge rst_n) begin
        if(!rst_n) begin frames=0;nonzero_frames=0;prev_ws=0;bitno=0;left=0;right=0;current=0;end
        else begin
            if(ws!=prev_ws) begin
                bitno=0;
                if(!ws) begin
                    left=0;right=0;
                end
            end else bitno++;
            if(bitno>=1 && bitno<=16) begin
                if(!ws)left={left[14:0],din};else right={right[14:0],din};
            end else if(din!==0)$fatal(1,"FAIL I2S delay/padding bit ws=%b bit=%d din=%b",ws,bitno,din);
            if(ws && bitno==16) begin
                frames++;
                if(left!==current || right!==current)
                    $fatal(1,"FAIL I2S frame=%d L=%h R=%h expected=%h",frames,left,right,current);
                if(current!=0)nonzero_frames++;
            end
            prev_ws=ws;
        end
    end
endmodule

module tb_i2s_audio_output;
    logic clk=0,aclk=0,rst_n=0,active=0,yv=0;
    always #5 clk=~clk;
    initial begin #7;forever #40 aclk=~aclk;end
    logic signed [63:0] y=0;
    logic tick,bclk,ws,din,late,overflow,underflow;
    i2s_audio_output #(.STEREO_ENABLE(0),.PCM_HEADROOM_BITS(0)) dut(
        .clk(clk),.audio_clk(aclk),.rst_n(rst_n),.active(active),.in_valid(yv),.in_data(y),
        .sample_tick(tick),.amp_bclk(bclk),.amp_ws(ws),.amp_din(din),
        .deadline_miss(late),.overflow(overflow),.underflow(underflow));
    function automatic logic [15:0] reference(input logic signed [63:0] value);
        logic signed [64:0] scaled;
        scaled=($signed({value[63],value})+65'sd256)>>>9;
        return scaled>32767 ? 16'h7fff : scaled< -32768 ? 16'h8000 : 16'(scaled);
    endfunction
    logic have=0;
    logic [15:0] last_pcm=0,expected_pcm;
    assign expected_pcm=active && have ? last_pcm : 16'd0;
    always @(posedge clk) begin
        if(!rst_n || !active) begin have<=0;last_pcm<=0;end
        else begin
            if(yv)begin have<=1;last_pcm<=reference(y);end
            if(tick)have<=0;
        end
    end
    integer frames,nz;
    i2s_scoreboard checkwire(clk,rst_n,bclk,ws,din,tick,expected_pcm,frames,nz);
    task automatic result(input logic signed [63:0] value);
        @(posedge tick);@(negedge clk);repeat(17)@(negedge clk);y=value;yv=1;
        @(negedge clk);yv=0;
    endtask
    initial begin
        repeat(6)@(negedge clk);rst_n=1;
        repeat(3)begin @(posedge tick);@(negedge clk);end
        if(late || overflow || underflow)$fatal(1,"FAIL planned initial silence");
        wait(!tick);@(negedge clk);active=1;
        result(64'sd16777216);result(-64'sd16777216);
        result(64'sd512);result(-64'sd512);result(64'sd255);result(-64'sd256);
        result(64'sh7fffffffffffffff);result(64'sh8000000000000000);result(0);
        active=0;
        repeat(3)begin @(posedge tick);@(negedge clk);end
        if(late || overflow || underflow)$fatal(1,"FAIL normal bridge diagnostics late=%b overflow=%b under=%b",late,overflow,underflow);
        if(nz<4)$fatal(1,"FAIL PCM payload was not exercised");
        // A missed synthesis deadline is detected, without damaging serial timing.
        active=1;repeat(4)begin @(posedge tick);@(negedge clk);end
        if(!late || overflow || underflow)$fatal(1,"FAIL late synthesis detection");
        active=0;
        // A result burst is diagnosed instead of claiming it was lossless.
        @(negedge clk);active=1;yv=1;y=512;
        repeat(2)@(negedge clk);yv=0;
        if(!overflow)$fatal(1,"FAIL duplicate result detection");
        active=0;
        repeat(3)begin @(posedge tick);@(negedge clk);end
        $display("PASS tb_i2s_audio_output frames=%0d nonzero=%0d PCM/CDC/silence/deadline",frames,nz);$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL bridge timeout");end
endmodule
