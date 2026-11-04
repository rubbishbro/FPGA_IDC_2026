`timescale 1ns/1ps
// Actual shared parser: both external sources retain the original reverb IDs.
module tb_chorus_wire_contract;
    logic clk=0,rst_n=0;always #5 clk=~clk;
    logic s_valid=0,s_ready,s_first=0,s_last=0,s_source_id=0;
    logic [7:0] s_data=0;
    logic [15:0] s_seq=0;
    logic cfg_valid,cfg_done_ready,done_valid=0,reply_valid,reply_source;
    logic [15:0] reply_seq;
    logic [7:0] reply_command,reply_result;
    integer submits=0,checks=0;
    logic retire=0;
    config_analyzer dut(.clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_first(s_first),.s_last(s_last),.s_source_id(s_source_id),.s_seq(s_seq),
        .s_payload_len(7'd2),.session_reset(2'd0),.cancel_source(2'd0),.barrier_ready(1'b1),
        .cfg_valid(cfg_valid),.cfg_source_id(),.cfg_seq(),.cfg_command(),.cfg_payload_len(),.cfg_shadow(),
        .cfg_ready(1'b1),.cfg_done_valid(done_valid),.cfg_done_ready(cfg_done_ready),.cfg_result(8'd0),
        .reply_valid(reply_valid),.reply_ready(retire),.reply_source_id(reply_source),.reply_seq(reply_seq),
        .reply_command(reply_command),.reply_result(reply_result),.frame_done(),.busy());
    always @(posedge clk)begin
        if(!rst_n)begin done_valid<=0;submits<=0;end
        else begin
            if(done_valid&&cfg_done_ready)done_valid<=0;
            if(cfg_valid)begin done_valid<=1;submits<=submits+1;end
        end
    end
    // Retire replies explicitly, keeping descriptor fields stable for assertions.

    task automatic send_byte(input logic[7:0] value,input logic first,last);
        @(negedge clk);while(!s_ready)@(negedge clk);
        s_data=value;s_first=first;s_last=last;s_valid=1;
        @(negedge clk);s_valid=0;
    endtask
    task automatic check_value(input integer source,value);
        integer before_count;
        before_count=submits;s_source_id=1'(source);s_seq=16'(source*16+value);
        send_byte(2,1,0);send_byte(8'(value),0,1);
        wait(reply_valid);@(negedge clk);
        if(reply_source!==1'(source)||reply_seq!==s_seq||reply_command!==2 ||
           reply_result!==(value<4?8'd0:8'd3) || submits-before_count!=(value<4?1:0))
            $fatal(1,"FAIL external preset source=%0d value=%0d result=%0d submits=%0d",source,value,reply_result,submits-before_count);
        checks++;retire=1;@(negedge clk);retire=0;repeat(3)@(negedge clk);
    endtask
    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        for(int source=0;source<2;source++)begin
            for(int value=0;value<5;value++)check_value(source,value);
            check_value(source,255);
        end
        $display("PASS tb_chorus_wire_contract checks=%0d wired/BT IDs0..3 accepted,4/255 rejected before backend",checks);$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL wire contract watchdog");end
endmodule
