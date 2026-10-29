`timescale 1ns/1ps
// Clock-boundary contracts: stalled bundled data, asynchronous reset phases,
// and synchronous effect clear compared sample-for-sample to a fresh instance.
module tb_clock_contracts;
    logic clk=0,pix=0,rst_n=0,pix_running=1;
    always #5 clk=~clk;
    always #17 if(pix_running)pix=~pix;else pix=0;
    logic offer=0,ready,done,valid,take=0;
    logic[63:0] payload=0,received,completed;
    integer deliveries=0;
    sidebar_mailbox #(.WIDTH(64)) mailbox(.rst_n(rst_n),.src_clk(clk),.dst_clk(pix),
        .src_valid(offer),.src_ready(ready),.src_data(payload),.src_done(done),
        .src_done_data(completed),.dst_valid(valid),.dst_ready(take),.dst_data(received));
    always @(posedge pix) if(rst_n && valid && take) deliveries++;
    task automatic put(input logic[63:0] data);
        @(negedge clk);while(!ready)@(negedge clk);
        payload=data;offer=1;@(negedge clk);offer=0;payload=~data;
    endtask
    task automatic reset_at(input integer phase);
        #phase;rst_n=0;#43;rst_n=1;
        repeat(12)@(negedge clk);
        if(done||valid||!ready)$fatal(1,"FAIL phantom mailbox transaction after reset phase=%d",phase);
    endtask
    logic effects_n=0,reference_n=0,clear_req=0,in_valid=0;
    logic ready_a,ready_b,busy_a,busy_b,body_va,body_vb,va,vb;
    logic signed[63:0] x=0,body_a,body_b,ya,yb;
    logic comparing=0;
    integer comparisons=0;
    body_router a(.clk(clk),.rst_n(effects_n),.clear_req(clear_req),.clear_busy(busy_a),
        .inst(router_pkg::INST_GUITAR),.in_valid(in_valid),.in_ready(ready_a),.x(x),.out_valid(body_va),.y(body_a));
    body_router b(.clk(clk),.rst_n(reference_n),.clear_req(1'b0),.clear_busy(busy_b),
        .inst(router_pkg::INST_GUITAR),.in_valid(in_valid&&comparing),.in_ready(ready_b),.x(x),.out_valid(body_vb),.y(body_b));
    reverb_router ra(.clk(clk),.rst_n(effects_n),.clear_req(clear_req),.preset(router_pkg::REVERB_HALL),
        .in_valid(body_va),.x(body_a),.out_valid(va),.y(ya));
    reverb_router rb(.clk(clk),.rst_n(reference_n),.clear_req(1'b0),.preset(router_pkg::REVERB_HALL),
        .in_valid(body_vb),.x(body_b),.out_valid(vb),.y(yb));
    always @(negedge clk) if(comparing) begin
        if(va!==vb)$fatal(1,"FAIL clear changed sample validity");
        if(va)begin
            if(ya!==yb)$fatal(1,"FAIL synchronous clear differs from fresh effects at sample=%d",comparisons);
            comparisons++;
        end
    end
    task automatic sample(input logic signed[63:0] v);
        @(negedge clk);while(!ready_a || (comparing&&!ready_b))@(negedge clk);
        x=v;in_valid=1;@(negedge clk);in_valid=0;
        repeat(110)@(negedge clk);
    endtask
    initial begin
        reset_at(3);
        for(integer phase=1;phase<20;phase+=3)begin
            take=0;put(64'h123456789abcdef0);wait(valid);
            repeat(4)begin
                @(negedge pix);
                if(received!==64'h123456789abcdef0 || ready||done)$fatal(1,"FAIL payload changed under backpressure");
            end
            reset_at(phase); // cancel in-flight transaction on both sides
        end
        // Reset also asserts with a stopped destination clock. A fresh source
        // transaction can wait safely until that clock resumes and releases reset.
        pix_running=0;#68;
        put(64'hdeaddeaddeaddead);#31;rst_n=0;#43;rst_n=1;
        repeat(8)@(negedge clk);
        if(valid||done)$fatal(1,"FAIL stopped-domain reset leaked transaction");
        put(64'h1122334455667788);
        repeat(8)@(negedge clk);
        if(done||valid)$fatal(1,"FAIL acknowledged while destination clock stopped");
        pix_running=1;wait(valid);
        if(received!==64'h1122334455667788)$fatal(1,"FAIL stopped-domain restart payload");
        reset_at(5);
        put(64'hfedcba9876543210);wait(valid);
        @(negedge pix);take=1;@(negedge pix);take=0;
        wait(done);@(negedge clk);
        if(completed!==64'hfedcba9876543210 || deliveries!=1)$fatal(1,"FAIL mailbox final completion");
        effects_n=1;
        for(integer i=0;i<128;i++) sample(i==0?64'sh0001000000000000:64'sd0);
        @(negedge clk);clear_req=1;reference_n=1;
        @(negedge clk);clear_req=0;
        if(!busy_a)$fatal(1,"FAIL synchronous clear acknowledged before history zero");
        wait(ready_a&&ready_b);@(negedge clk);comparing=1;
        // Cross the lazy invalidation horizon, so stale BSRAM cannot hide
        // behind clr_run throughout the comparison.
        for(integer i=0;i<2060;i++) sample(i%73==0?64'sh0000000100000000:-64'sd123456789);
        if(comparisons!=2060)$fatal(1,"FAIL lost post-clear effect samples %d",comparisons);
        $display("PASS tb_clock_contracts reset_phases=8 stopped_clock=1 post_clear_samples=%d",comparisons);$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL clock contract timeout");end
endmodule
