`timescale 1ns/1ps
module tb_record_control;
    record_bridge_probe dut();
    logic s_valid=0,s_ready,s_first=0,s_last=0,s_source=0;
    logic [7:0] s_data=0;
    logic [15:0] s_seq=0;
    logic [6:0] s_len=5;
    logic reply_valid,reply_source;
    logic [15:0] reply_seq;
    logic [7:0] reply_cmd,reply_result;
    config_analyzer parser(
        .clk(dut.clk_core),.rst_n(dut.core_n),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_first(s_first),.s_last(s_last),.s_source_id(s_source),
        .s_seq(s_seq),.s_payload_len(s_len),.session_reset(2'b0),.cancel_source(2'b0),
        .barrier_ready(1'b1),.cfg_valid(dut.cfg_valid),.cfg_ready(dut.cfg_ready),
        .cfg_source_id(dut.cfg_source),.cfg_seq(dut.cfg_seq),.cfg_command(dut.cfg_cmd),
        .cfg_payload_len(dut.cfg_len),.cfg_shadow(dut.cfg_shadow),
        .cfg_done_valid(dut.cfg_done),.cfg_done_ready(dut.cfg_done_ready),.cfg_result(dut.cfg_result),
        .reply_valid(reply_valid),.reply_ready(1'b1),.reply_source_id(reply_source),
        .reply_seq(reply_seq),.reply_command(reply_cmd),.reply_result(reply_result),.frame_done(),.busy());
    logic run_ticks=1,sink_ready=1;
    integer phase=0,start_pulses=0,stop_pulses=0,starts=0,ends=0,ons=0,offs=0,replies=0;
    integer elapsed=0;
    logic [7:0] result_seen;
    logic [31:0] last_ordinal;
    assign dut.perf_ready=sink_ready;
    always @(negedge dut.clk_core)begin
        phase=(phase+1)%20;
        dut.spatial_frame_tick=run_ticks && phase==0;
    end
    always @(posedge dut.clk_core)if(dut.core_n)begin
        elapsed++;
        if(dut.rec_start)start_pulses++;
        if(dut.rec_stop)stop_pulses++;
        if(reply_valid)begin replies++;result_seen=reply_result;end
        if(dut.perf_valid && dut.perf_ready)begin
            if(dut.perf_payload[63:32]!==dut.rec_current_id)$fatal(1,"FAIL recording take ID");
            if(dut.perf_payload[7:0]==0)last_ordinal=0;
            if(dut.perf_payload[95:64]!==last_ordinal)$fatal(1,"FAIL recording ordinal");
            last_ordinal++;
            case(dut.perf_payload[7:0])
                0:starts++;
                1:begin ons++;if(dut.perf_payload[143:128]!=16'h7f3c)$fatal(1,"FAIL captured pitch/velocity");end
                2:offs++;
                3:ends++;
            endcase
        end
    end
    task send(input bit source,input [15:0] seq,input [7:0] cmd,input [31:0] id,input integer len=5);
        logic [39:0] bytes;
        begin
            bytes={id,cmd};
            for(integer i=0;i<len;i++)begin
                @(negedge dut.clk_core);
                s_valid=1;s_first=i==0;s_last=i==len-1;s_source=source;
                s_seq=seq;s_len=7'(len);s_data=bytes[i*8 +:8];
                do @(posedge dut.clk_core);while(!s_ready);
            end
            @(negedge dut.clk_core);s_valid=0;s_first=0;s_last=0;
        end
    endtask
    task request(input bit source,input [15:0] seq,input [7:0] cmd,input [31:0] id,
                 input [7:0] expected,input integer len=5);
        integer before_reply,before_time;
        begin
            before_reply=replies;before_time=elapsed;
            send(source,seq,cmd,id,len);
            wait(replies>before_reply);@(negedge dut.clk_core);
            if(result_seen!==expected || reply_seq!==seq || reply_cmd!==cmd || reply_source!==source)
                $fatal(1,"FAIL config reply seq=%0d got=%0d expected=%0d",seq,result_seen,expected);
            if(elapsed-before_time>=500)$fatal(1,"FAIL reply exceeded host deadline");
            repeat(4)@(negedge dut.clk_core);
        end
    endtask
    task snapshot(input bit gate);
        @(negedge dut.clk_core);dut.record_snapshot_gate=16'(gate);dut.record_snapshot_valid=1;
        @(negedge dut.clk_core);dut.record_snapshot_valid=0;repeat(20)@(negedge dut.clk_core);
    endtask
    initial begin
        dut.audio_state='0;dut.audio_state.instrument=0;
        dut.record_snapshot_valid=0;dut.record_snapshot_gate=0;
        dut.record_snapshot_level={16{8'hff}};dut.record_snapshot_notes={16{7'd60}};
        repeat(4)@(negedge dut.clk_core);dut.core_n=1;
        request(0,1,'h13,0,3); // STOP before any take must not hang.
        request(0,2,'h12,42,2,4); // Invalid length never reaches the backend.
        request(1,1,'h12,42,1); // Wired-only.
        dut.remote_permission=2;request(0,15,'h12,42,6);dut.remote_permission=3;
        dut.audio_valid=0;request(0,3,'h12,42,6);dut.audio_valid=1;
        request(0,4,'h12,42,0);
        request(0,4,'h12,42,0); // Cached retry must not restart the take.
        if(start_pulses!=1)$fatal(1,"FAIL duplicate recording start");
        request(0,5,'h12,43,4);
        request(0,6,'h13,43,3);
        snapshot(1);snapshot(0);
        request(0,7,'h13,42,0);
        if(starts!=1 || ends!=1 || ons!=1 || offs!=1 || stop_pulses!=1)
            $fatal(1,"FAIL recording event/completion counts");
        request(0,8,'h13,42,0);
        if(stop_pulses!=1)$fatal(1,"FAIL completed STOP retriggered capture");
        run_ticks=0;
        fork
            request(0,9,'h12,44,6);
            begin wait(dut.rec_start);@(negedge dut.clk_core);dut.remote_permission=2;end
        join
        repeat(4)@(negedge dut.clk_core);dut.remote_permission=3;
        if(dut.rec_active || dut.rec_draining)$fatal(1,"FAIL permission cancellation");
        request(0,10,'h12,45,6); // Stopped frame clock: bounded failure, no false ACK.
        repeat(4)@(negedge dut.clk_core);run_ticks=1;
        request(0,11,'h12,46,0);sink_ready=0;
        request(0,12,'h13,46,6); // Backpressure prevents END retirement, must time out.
        repeat(4)@(negedge dut.clk_core);sink_ready=1;
        if(dut.rec_active || dut.rec_draining)$fatal(1,"FAIL timeout cancellation");
        request(0,13,'h12,47,0);
        @(negedge dut.clk_core);dut.remote_permission=2;
        repeat(6)@(negedge dut.clk_core);
        if(dut.rec_active || dut.rec_draining || !dut.rec_failed)$fatal(1,"FAIL active take permission revoke");
        dut.remote_permission=3;
        request(0,14,'h12,48,0);
        @(negedge dut.clk_core);dut.quarantine=1;
        repeat(4)@(negedge dut.clk_core);
        if(dut.rec_active || dut.rec_draining || !dut.rec_failed)$fatal(1,"FAIL quarantine cancellation");
        $display("PASS tb_record_control start_stop_notes_cache_busy_identity_permissions_timeouts");$finish;
    end
    initial begin #100000;$fatal(1,"FAIL recording control timeout");end
endmodule
