`timescale 1ns/1ps
// Real UART pins + unversioned frames. Exercise fault recovery without reset or
// session_restart, backend retirement, cache invalidation, peer isolation, and
// an entire post-recovery TYPE82 take through the production TX encoders.
module tb_comm_recovery;
    localparam int BIT_CYCLES=32, IDLE_CYCLES=32*BIT_CYCLES;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic [1:0] rx=3, tx, quarantine, cleanup=3, ops=3, restart=0;
    logic [15:0] sticky;
    logic [63:0] errors;
    logic event_valid, event_source, event_ready=1;
    logic [31:0] event_data;
    logic cfg_valid, cfg_source, cfg_done_ready;
    logic [15:0] cfg_seq;
    logic [7:0] cfg_cmd;
    logic [6:0] cfg_len;
    logic [511:0] cfg_shadow;
    logic backend_pending=0, hold_done=0;
    integer commits=0, events[2], replies[2], caches[2];
    logic [7:0] last_result[2], last_seq[2];
    logic perf_valid, perf_ready;
    logic [15:0] perf_seq;
    logic [191:0] perf_payload;
    logic tick=0, rec_start=0, rec_stop=0, snapshot=0;
    logic [15:0] gates=0;
    logic rec_active, rec_complete;
    integer starts=0, ons=0, offs=0, ends=0, wire_file;

    comm_top #(.CLK_HZ(3_200_000),.WIRED_BAUD(100_000),.BT_BAUD(100_000),
        .RX_DEPTH(8),.FRAME_DEPTH(2),.EVENT_DEPTH(4),.TIMEOUT_CYCLES(100000)) dut (
        .clk(clk),.rst_n(rst_n),.rx_i(rx),.tx_o(tx),.hc05_state_async(1'b0),
        .session_restart(restart),.source_cleanup_done(cleanup),.source_ops_idle(ops),
        .midi_ops_idle(1'b1),.source_quarantine(quarantine),.link_fault_pending(),
        .error_sticky(sticky),.rx_error_count(errors),
        .event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),
        .event_source_id(event_source),.midi_parse_error(),
        .cfg_valid(cfg_valid),.cfg_ready(!backend_pending),.cfg_source_id(cfg_source),
        .cfg_seq(cfg_seq),.cfg_command(cfg_cmd),.cfg_payload_len(cfg_len),.cfg_shadow(cfg_shadow),
        .cfg_done_valid(backend_pending && !hold_done),.cfg_done_ready(cfg_done_ready),.cfg_result(8'd0),
        .perf_valid(perf_valid),.perf_ready(perf_ready),.perf_seq(perf_seq),.perf_payload(perf_payload)
    );
    performance_capture capture (
        .clk(clk),.rst_n(rst_n),.frame_tick(tick),.abort_capture(quarantine[0]),
        .start_req(rec_start),.stop_req(rec_stop),.request_id(32'hdbc01234),
        .eligible(1'b1),.channel(4'd1),.snapshot_valid(snapshot),.snapshot_gate(gates),
        .snapshot_level(128'd128),.snapshot_notes(112'd21),.active(rec_active),.draining(),
        .completed(rec_complete),.failed(),.out_valid(perf_valid),.out_ready(perf_ready),
        .out_payload(perf_payload),.out_seq(perf_seq)
    );
    always @(posedge clk) if(rst_n) begin
        if(cfg_valid && !backend_pending)begin backend_pending<=1; commits++;end
        if(backend_pending && !hold_done && cfg_done_ready)backend_pending<=0;
        if(event_valid && event_ready)begin
            if(quarantine[event_source])$fatal(1,"FAIL quarantined event escaped");
            events[event_source]++;
        end
        for(int s=0;s<2;s++)if(dut.cache_reset[s])caches[s]++;
    end
    task automatic clocks(input int n); repeat(n)@(negedge clk); endtask
    function automatic logic [15:0] crc(input logic [15:0] old,input logic [7:0] val);
        logic [15:0] c;
        c=old^{val,8'd0};for(int j=0;j<8;j++)c=c[15]?(c<<1)^16'h1021:c<<1;
        return c;
    endfunction
    task automatic uart_byte(input int s,input logic [7:0] val);
        @(negedge clk);rx[s]=0;clocks(BIT_CYCLES);
        for(int b=0;b<8;b++)begin rx[s]=val[b];clocks(BIT_CYCLES);end
        rx[s]=1;clocks(BIT_CYCLES);
    endtask
    task automatic escaped_byte(input int s,input logic [7:0] val);
        if(val==8'hc0)begin uart_byte(s,8'hdb);uart_byte(s,8'hdc);end
        else if(val==8'hdb)begin uart_byte(s,8'hdb);uart_byte(s,8'hdd);end
        else uart_byte(s,val);
    endtask
    task automatic frame(input int s,kind,seq,len,input logic [23:0] payload);
        logic [7:0] data[6];logic [15:0] check;
        data[0]=8'(kind);data[1]=8'(seq);data[2]=8'(len);
        for(int i=0;i<len;i++)data[i+3]=payload[i*8 +:8];
        check=16'hffff;for(int i=0;i<len+3;i++)check=crc(check,data[i]);
        uart_byte(s,8'hc0);
        for(int i=0;i<len+3;i++)escaped_byte(s,data[i]);
        escaped_byte(s,check[7:0]);escaped_byte(s,check[15:8]);uart_byte(s,8'hc0);
    endtask

    // Independent bit-time TX decoder; never reads a DUT byte/FIFO signal.
    for(genvar s=0;s<2;s++)begin:g_tx
        logic [7:0] body[40];integer n=0;bit in_frame=0,escape=0;
        task automatic accept_byte(input logic [7:0] raw);
            logic [7:0] val;logic [15:0] check;
            if(s==0)$fdisplay(wire_file,"%02x",raw);
            if(raw==8'hc0)begin
                if(in_frame && n!=0)begin
                    check=16'hffff;for(int i=0;i<n-2;i++)check=crc(check,body[i]);
                    if(n<5 || check!=={body[n-1],body[n-2]} || n!=body[2]+5)
                        $fatal(1,"FAIL UART reply CRC/length source=%0d",s);
                    if(body[0]==8'h80)begin
                        if(n!=7 || body[3]!=2)$fatal(1,"FAIL CONFIG reply layout");
                        last_seq[s]=body[1];last_result[s]=body[4];replies[s]++;
                    end else if(body[0]==8'h82)begin
                        if(s!=0 || n!=29 || {body[10],body[9],body[8],body[7]}!=32'hdbc01234 || body[5]!=1)
                            $fatal(1,"FAIL performance source/length/id/channel");
                        if(body[1]!=(starts+ons+offs+ends))$fatal(1,"FAIL performance ordinal");
                        case(body[3])
                            0:starts++;
                            1:begin
                                ons++;if(body[19]!=21 || body[20]!=64)$fatal(1,"FAIL note pitch/velocity");
                            end
                            2:offs++;
                            3:begin ends++;if(body[4]!=0)$fatal(1,"FAIL incomplete take");end
                            default:$fatal(1,"FAIL unknown performance kind");
                        endcase
                    end else $fatal(1,"FAIL unexpected TX type");
                end
                in_frame=1;escape=0;n=0;
            end else if(in_frame)begin
                if(raw==8'hdb)escape=1;
                else begin
                    val=raw;
                    if(escape)begin
                        if(raw!=8'hdc && raw!=8'hdd)$fatal(1,"FAIL invalid escape");
                        val=raw==8'hdc ? 8'hc0 : 8'hdb;escape=0;
                    end
                    if(n>=40)$fatal(1,"FAIL oversized reply");
                    body[n]=val;n++;
                end
            end
        endtask
        initial forever begin
            logic [7:0] val;
            @(negedge tx[s]);clocks(BIT_CYCLES+BIT_CYCLES/2);
            for(int b=0;b<8;b++)begin val[b]=tx[s];clocks(BIT_CYCLES);end
            if(!tx[s])$fatal(1,"FAIL TX stop bit");
            accept_byte(val);
        end
    end
    task automatic config_reply(input int s,seq,preset,result);
        int old;old=replies[s];frame(s,2,seq,2,{8'd0,8'(preset),8'h02});
        wait(replies[s]>old);
        if(last_seq[s]!=seq || last_result[s]!=result)$fatal(1,"FAIL CONFIG seq/result");
    endtask
    task automatic recovered;
        int cycles;
        cycles=0;
        while(quarantine[0] && cycles<10000)begin clocks(1);cycles++;end
        if(quarantine[0])$fatal(1,"FAIL wired recovery timed out");
        clocks(4);
    endtask
    task automatic boundary;
        tick=1;clocks(1);tick=0;clocks(20);
    endtask
    task automatic snapshot_gate(input logic [15:0] next_gate);
        gates=next_gate;snapshot=1;clocks(1);snapshot=0;clocks(30);
    endtask
    initial begin
        int before_events,before_commits,before_replies;
        wire_file=$fopen("recording_recovery_uart.hex","w");
        for(int s=0;s<2;s++)begin events[s]=0;replies[s]=0;caches[s]=0;end
        clocks(5);rst_n=1;clocks(20);
        config_reply(0,7,1,0);
        config_reply(0,7,2,5); // Same SEQ with changed payload really conflicts.
        if(commits!=1)$fatal(1,"FAIL conflict reached backend");
        config_reply(1,7,1,0);

        // Bad stop with high data: framing error, no break required to recover.
        cleanup[0]=0;ops[0]=0;
        @(negedge clk);rx[0]=0;clocks(32);rx[0]=1;clocks(256);
        rx[0]=0;clocks(48);rx[0]=1;clocks(32);
        if(!quarantine[0] || !sticky[5])$fatal(1,"FAIL framing fault isolation");
        before_events=events[1];frame(1,1,1,3,24'h401591);clocks(30);
        if(events[1]!=before_events+1 || quarantine[1])$fatal(1,"FAIL peer blocked by wired fault");
        clocks(IDLE_CYCLES+20);
        if(!quarantine[0])$fatal(1,"FAIL idle bypassed cleanup");
        cleanup[0]=1;clocks(20);
        if(!quarantine[0])$fatal(1,"FAIL idle bypassed backend operations");
        // Restart the qualification with low RX while cleanup is still busy.
        rx[0]=0;clocks(32);ops[0]=1;clocks(IDLE_CYCLES*2);
        if(!quarantine[0])$fatal(1,"FAIL sustained break reopened RX");
        rx[0]=1;clocks(IDLE_CYCLES/2);rx[0]=0;clocks(8);rx[0]=1;
        clocks(IDLE_CYCLES-10);
        if(!quarantine[0])$fatal(1,"FAIL nonconsecutive idle reopened RX");
        recovered();
        if(caches[0]!=1 || caches[1]!=0 || !sticky[6])$fatal(1,"FAIL recovery cache/error scope");
        config_reply(0,7,2,0); // Same old SEQ, new content now accepted.
        before_commits=commits;config_reply(1,7,1,0);
        if(commits!=before_commits)$fatal(1,"FAIL peer cache invalidated");
        config_reply(0,7,2,0);
        if(commits!=before_commits)$fatal(1,"FAIL retry committed twice");

        // Fill real UART/transport queues behind an accepted CONFIG whose
        // completion is delayed. No force or internal RX error injection.
        hold_done=1;before_replies=replies[0];
        frame(0,2,8,2,24'h000102);wait(backend_pending);
        repeat(8)frame(0,1,9,3,24'h401591);
        if(!quarantine[0] || !sticky[7])$fatal(1,"FAIL real RX overflow not isolated");
        clocks(IDLE_CYCLES+20);
        if(!quarantine[0])$fatal(1,"FAIL accepted CONFIG retired before completion");
        before_events=events[0];hold_done=0;recovered();clocks(4000);
        if(events[0]!=before_events || replies[0]!=before_replies || caches[0]!=2)
            $fatal(1,"FAIL stale event/reply escaped recovery");
        config_reply(0,8,2,0);
        before_events=events[0];frame(0,1,10,3,24'h401591);clocks(30);
        if(events[0]!=before_events+1)$fatal(1,"FAIL MIDI not restored after overflow");

        // Repeat a complete physical break after reopening.
        rx[0]=0;clocks(32*14);
        if(!quarantine[0])$fatal(1,"FAIL repeated break not isolated");
        clocks(IDLE_CYCLES*2);
        if(!quarantine[0])$fatal(1,"FAIL break recovered while held low");
        rx[0]=1;recovered();config_reply(0,8,1,0);

        // Bluetooth uses the same bounded idle recovery, but its own pin/baud.
        rx[1]=0;clocks(32*14);rx[1]=1;clocks(IDLE_CYCLES*2);
        if(quarantine!=0)$fatal(1,"FAIL Bluetooth idle recovery");
        // A fresh BT fault can still be cleared by an explicit restart.
        rx[1]=0;clocks(32*14);rx[1]=1;clocks(4);
        if(quarantine!=2)$fatal(1,"FAIL Bluetooth fault did not isolate");
        restart=2;clocks(1);restart=0;clocks(10);
        if(quarantine!=0)$fatal(1,"FAIL explicit Bluetooth restart");

        // Post-recovery performance capture -> transport -> real UART pins.
        rec_start=1;clocks(1);rec_start=0;boundary();wait(starts==1);
        snapshot_gate(1);wait(ons==1);
        repeat(220)boundary();snapshot_gate(0);wait(offs==1);
        snapshot_gate(1);wait(ons==2);repeat(220)boundary();
        rec_stop=1;clocks(1);rec_stop=0;boundary();wait(ends==1);wait(rec_complete);
        if(rec_active || starts!=1 || ons!=2 || offs!=1 || caches[0]!=3)
            $fatal(1,"FAIL post-recovery take");
        // Full bytes are validated before enum narrowing on both UART sources.
        for(int source=0;source<2;source++)begin
            for(int preset=0;preset<4;preset++)config_reply(source,20+preset,preset,0);
            before_commits=commits;
            config_reply(source,30,4,3);config_reply(source,31,255,3);
            if(commits!=before_commits)$fatal(1,"FAIL invalid preset reached backend");
        end
        $fclose(wire_file);
        $display("PASS tb_comm_recovery framing_break_overflow_cleanup_cache_peer_full_take");
        $finish;
    end
    initial begin #10000000;$fatal(1,"FAIL recovery watchdog commits=%0d replies=%0d/%0d quarantine=%b",commits,replies[0],replies[1],quarantine);end
endmodule
