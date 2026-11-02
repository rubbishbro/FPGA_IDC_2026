`timescale 1ns/1ps
// Unversioned session policy: idle recovery uses every existing retirement
// barrier and resets only the faulted source's cache, exactly once.
module tb_session_recovery;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic [1:0] restart=0, connect_ev=0, disconnect_ev=0, fe=0, brk=0, ov=0;
    logic [15:0] pe=0, sticky;
    logic [63:0] counts;
    logic [1:0] cleanup=0, ops=0, idle=0, quarantine, pending, fault, req, cancel, flush, cache;
    logic arb_busy=0, arb_src=0, parser_busy=0, parser_src=0;
    logic push=0, push_src=0, pop=0, pop_src=0;
    session_ctrl #(.EVENT_DEPTH(4)) dut (
        .clk(clk), .rst_n(rst_n), .session_restart(restart),
        .connect_event(connect_ev), .disconnect_event(disconnect_ev),
        .framing_err(fe), .break_detect(brk), .overflow(ov), .protocol_errors(pe), .midi_error(2'b0),
        .source_cleanup_done(cleanup), .source_ops_idle(ops), .idle_recovery_ready(idle),
        .arb_busy(arb_busy), .arb_source(arb_src), .parser_busy(parser_busy), .parser_source(parser_src),
        .event_push(push), .event_push_source(push_src), .event_pop(pop), .event_pop_source(pop_src),
        .source_quarantine(quarantine), .link_fault_pending(pending), .fault_now(fault),
        .restart_req(req), .cancel_source(cancel), .flush_link(flush), .cache_reset(cache),
        .error_sticky(sticky), .rx_error_count(counts)
    );
    task automatic clocks(input int n); repeat(n) @(negedge clk); endtask
    task automatic held;
        clocks(3);
        if(quarantine!==2'b01 || pending!==2'b01 || cache!=0)
            $fatal(1,"FAIL source reopened before retirement");
    endtask
    initial begin
        clocks(4); rst_n=1; clocks(2);
        // CRC/format errors are diagnostic by default, not link isolation.
        pe=16'h000f; clocks(1); pe=0; clocks(1);
        if(quarantine!=0 || sticky!=16'h000f || counts!=1)
            $fatal(1,"FAIL protocol diagnostics");
        push=1; clocks(1); push=0;
        fe=1; #1;
        if(fault!==2'b01 || cancel!==2'b01 || flush!==2'b01)
            $fatal(1,"FAIL fault must cancel same cycle");
        clocks(1); fe=0; held();
        idle=1; held(); // Idle cannot bypass backend cleanup.
        cleanup=1; held();
        ops=1; held(); // Nor may it bypass pending source events.
        arb_busy=1; parser_busy=1;
        // Peer enqueue/dequeue must not change the faulted source's count.
        push=1; pop=1; push_src=1; pop_src=1; clocks(1); push=0; pop=0;
        held();
        pop=1; pop_src=0; clocks(1); pop=0; held();
        arb_busy=0; held();
        // Idle recovery is a live level, not a restart latched before cleanup.
        idle=0; parser_busy=0; held();
        idle=1; clocks(1);
        if(quarantine!=0 || cache!==2'b01 || flush!==2'b01 || req!=0)
            $fatal(1,"FAIL automatic retirement/cache reset");
        clocks(4);
        if(cache!=0) $fatal(1,"FAIL cache reset must pulse once");

        // A peer context does not block source 0; an explicit local restart
        // still works even when idle qualification has not been reached.
        idle=0; arb_busy=1; arb_src=1; parser_busy=1; parser_src=1;
        ov=1; clocks(1); ov=0; held();
        restart=1; clocks(1); restart=0; clocks(1);
        if(quarantine!=0 || cache!==2'b01) $fatal(1,"FAIL explicit restart");
        arb_busy=0; parser_busy=0; clocks(2);

        // Bluetooth remains isolated until its own connect/restart arrives.
        brk=2; clocks(1); brk=0; cleanup=3; ops=3; idle=1; clocks(10);
        if(quarantine!==2'b10) $fatal(1,"FAIL wired idle reopened Bluetooth");
        connect_ev=2; clocks(1); connect_ev=0; clocks(1);
        if(quarantine!=0 || cache!==2'b10) $fatal(1,"FAIL Bluetooth reconnect");
        if(!sticky[5] || !sticky[7] || !sticky[14] || counts[31:0]!=3 || counts[63:32]!=1)
            $fatal(1,"FAIL physical errors lost after recovery");
        $display("PASS tb_session_recovery idle_cleanup_events_arbiter_parser_cache_peer_explicit");
        $finish;
    end
    initial begin #20000; $fatal(1,"FAIL session watchdog"); end
endmodule
