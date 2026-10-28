`timescale 1ns/1ps
// 独立会话策略测试：诊断/故障分类、来源隔离、重启锁存和逐层退休屏障。
module tb_session_ctrl;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic [1:0] restart=0, connect_ev=0, disconnect_ev=0, fe=0, brk=0, ov=0;
    logic [15:0] pe=0, sticky;
    logic [1:0] midi_error=0;
    logic [63:0] counts;
    logic [1:0] cleanup=0, ops=0, quarantine, pending, fault, req, cancel, flush, cache;
    logic arb_busy=0, arb_src=0, parser_busy=0, parser_src=0;
    logic push=0, push_src=0, pop=0, pop_src=0;
    session_ctrl #(.EVENT_DEPTH(4)) dut (
        .clk(clk), .rst_n(rst_n), .session_restart(restart),
        .connect_event(connect_ev), .disconnect_event(disconnect_ev),
        .framing_err(fe), .break_detect(brk), .overflow(ov), .protocol_errors(pe),.midi_error(midi_error),
        .source_cleanup_done(cleanup), .source_ops_idle(ops),
        .arb_busy(arb_busy), .arb_source(arb_src), .parser_busy(parser_busy), .parser_source(parser_src),
        .event_push(push), .event_push_source(push_src), .event_pop(pop), .event_pop_source(pop_src),
        .source_quarantine(quarantine), .link_fault_pending(pending), .fault_now(fault),
        .restart_req(req), .cancel_source(cancel), .flush_link(flush), .cache_reset(cache),
        .error_sticky(sticky), .rx_error_count(counts)
    );
    task automatic clocks(input int n); repeat(n) @(negedge clk); endtask
    task automatic held();
        clocks(3);
        if(quarantine!==2'b01 || pending!==2'b01 || cache!=0)
            $fatal(1,"source reopened before retirement");
    endtask
    initial begin
        clocks(4); rst_n=1; clocks(2);
        // 一拍多种协议错误隔离来源；错误周期只增加一次。
        pe=16'h000F; clocks(1); pe=0; clocks(1);
        if(quarantine!=1 || sticky!=16'h000F || counts!=1)
            $fatal(1,"diagnostic classification/count");
        cleanup=1;ops=1;restart=1;clocks(1);restart=0;clocks(2);
        if(quarantine!=0) $fatal(1,"protocol fault restart failed");
        cleanup=0;ops=0;
        push=1; clocks(1); push=0; // 源 0 的事件仍在共享队列。
        fe=1; #1;
        if(fault!==2'b01 || cancel!==2'b01 || flush!==2'b01)
            $fatal(1,"fault must cancel same cycle");
        clocks(1); fe=0;
        restart=1; clocks(1); restart=0;
        held();
        cleanup=1; ops=1; held(); // 仍有源 0 的事件。
        // 源 1 同拍入/出队不影响源 0 的恢复条件。
        push=1; pop=1; push_src=1; pop_src=1; clocks(1); push=0; pop=0;
        held();
        arb_busy=1; arb_src=0; parser_busy=1; parser_src=0;
        pop=1; pop_src=0; clocks(1); pop=0;
        held();
        arb_busy=0; held(); // 帧读完但 parser/已接受的后级操作仍未退休。
        parser_busy=0;
        clocks(1);
        if(quarantine!=0 || cache!==2'b01 || flush!==2'b01)
            $fatal(1,"source retirement/cache reset");
        clocks(1);
        if(cache!=0) $fatal(1,"cache reset must pulse");

        // 有物理重连也必须等业务清理；连接并不等于会话已恢复。
        disconnect_ev=2; clocks(1); disconnect_ev=0;
        connect_ev=2; clocks(1); connect_ev=0; clocks(3);
        if(quarantine!==2'b10) $fatal(1,"connect bypassed cleanup");
        cleanup=3; ops=3; clocks(1);
        if(quarantine!=0 || cache!==2'b10) $fatal(1,"BT restart failed");
        clocks(1);
        // framing/break/overflow/timeout 都应隔离；清音确认本身不能重开。
        brk=1; ov=2; pe=16'h1010; clocks(1); brk=0; ov=0; pe=0; clocks(3);
        if(quarantine!==2'b11 || sticky!==16'h907F || counts[31:0]!=3 || counts[63:32]!=1)
            $fatal(1,"fatal masks/counters/restart requirement");
        restart=3; clocks(1); restart=0; clocks(1);
        if(quarantine!=0 || cache!==2'b11) $fatal(1,"dual restart failed");
        clocks(1);cleanup=0;ops=0;midi_error=2;clocks(1);midi_error=0;
        if(quarantine!=2 || !sticky[12]) $fatal(1,"MIDI syntax error did not isolate physical source");
        restart=2;clocks(1);restart=0;clocks(2);
        if(quarantine!=2) $fatal(1,"syntax recovery skipped cleanup");
        cleanup=3;ops=3;clocks(2);
        if(quarantine!=0) $fatal(1,"syntax recovery failed");
        $display("PASS tb_session_ctrl"); $finish;
    end
    initial begin #20000; $fatal(1,"session watchdog"); end
endmodule
