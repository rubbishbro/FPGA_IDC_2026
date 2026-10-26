`timescale 1ns/1ps
module tb_comm_top;
    localparam int CLK_HZ=1_600_000, BAUD=100_000, BIT_CYC=16;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic [1:0] rx_i=3,tx_o;
    logic [1:0] restart=0,quarantine,fault;
    logic [15:0] errors;
    logic [63:0] error_count;
    logic ev_valid,ev_ready,ev_source,parse_error;
    logic [31:0] ev_data;
    logic hold_events=0,midi_idle=1;
    logic [15:0] random_bits=16'hace1;
    logic cv,cr,cs,cdv,cdr;
    logic [15:0] cseq;
    logic [7:0] ccmd,cresult;
    logic [4:0] clen;
    logic [127:0] shadow;
    logic backend_pending=0;
    integer backend_delay=0,commit_requests=0,commits=0;
    logic [7:0] backend_result=0;
    logic [127:0] backend_shadow;
    logic backend_source;
    logic [15:0] backend_seq;
    logic [7:0] backend_command;
    integer preset=-1;
    logic done_seen[0:1][0:31];
    logic [31:0] expected_events[0:1][0:255];
    integer expect_ec[0:1],seen_ec[0:1];
    logic [15:0] expected_seq[0:1][0:63];
    logic [7:0] expected_cmd[0:1][0:63],expected_result[0:1][0:63];
    integer expect_rc[0:1],seen_rc[0:1];
    logic [1:0] tx_byte_valid,tx_frame_error,tx_break,tx_false;
    logic [15:0] tx_byte_data;
    logic [7:0] reply_body[0:1][0:39];
    integer reply_count[0:1];
    logic [1:0] reply_escape=0,reply_started=0;
    logic was_stalled=0,held_source;
    logic [31:0] held_event;
    logic [255:0] payload;

    comm_top #(.CLK_HZ(CLK_HZ),.WIRED_BAUD(BAUD),.BT_BAUD(BAUD),
        .RX_DEPTH(64),.FRAME_DEPTH(2),.EVENT_DEPTH(4),.TIMEOUT_CYCLES(4096)) dut (
        .clk(clk),.rst_n(rst_n),.rx_i(rx_i),.tx_o(tx_o),.hc05_state_async(1'b0),
        .session_restart(restart),.source_cleanup_done(2'b11),.source_ops_idle(2'b11),
        .midi_ops_idle(midi_idle),.source_quarantine(quarantine),.link_fault_pending(fault),
        .error_sticky(errors),.rx_error_count(error_count),
        .event_valid(ev_valid),.event_ready(ev_ready),.event_data(ev_data),
        .event_source_id(ev_source),.midi_parse_error(parse_error),
        .cfg_valid(cv),.cfg_ready(cr),.cfg_source_id(cs),.cfg_seq(cseq),.cfg_command(ccmd),
        .cfg_payload_len(clen),.cfg_shadow(shadow),
        .cfg_done_valid(cdv),.cfg_done_ready(cdr),.cfg_result(cresult)
    );
    assign ev_ready=!hold_events&&(random_bits[0]||random_bits[1]);
    assign cr=!backend_pending;
    assign cdv=backend_pending&&backend_delay==0;
    assign cresult=backend_result;
    for(genvar g=0;g<2;g++) begin : g_monitor
        comm_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.OVERSAMPLE(16)) decoder (
            .clk(clk),.rst_n(rst_n),.rx_i(tx_o[g]),.rx_stb(tx_byte_valid[g]),
            .rx_data(tx_byte_data[g*8+:8]),.framing_err(tx_frame_error[g]),
            .break_detect(tx_break[g]),.false_start(tx_false[g])
        );
    end
    function automatic [15:0] crc_byte(input [15:0] old,input [7:0] b);
        reg[15:0] c;
        begin
            c=old^{b,8'b0};
            for(int i=0;i<8;i++) c=c[15]?(c<<1)^16'h1021:c<<1;
            return c;
        end
    endfunction
    function automatic [31:0] event_word(input integer kind,ch,d1,d2);
        return {4'(kind),4'(ch),7'(d1),7'(d2),10'b0};
    endfunction
    task automatic expect_event(input integer src,input logic[31:0] data);
        expected_events[src][expect_ec[src]]=data;expect_ec[src]++;
    endtask
    task automatic expect_reply(input integer src,seq,cmd,result);
        expected_seq[src][expect_rc[src]]=16'(seq);
        expected_cmd[src][expect_rc[src]]=8'(cmd);
        expected_result[src][expect_rc[src]]=8'(result);expect_rc[src]++;
    endtask
    task automatic uart_byte(input integer src,input logic[7:0] b);
        @(negedge clk);rx_i[src]=0;
        repeat(BIT_CYC) @(negedge clk);
        for(int i=0;i<8;i++) begin rx_i[src]=b[i];repeat(BIT_CYC) @(negedge clk);end
        rx_i[src]=1;repeat(BIT_CYC) @(negedge clk);
    endtask
    task automatic escaped_byte(input integer src,input logic[7:0] b);
        if(b==8'hc0) begin uart_byte(src,8'hdb);uart_byte(src,8'hdc);end
        else if(b==8'hdb) begin uart_byte(src,8'hdb);uart_byte(src,8'hdd);end
        else uart_byte(src,b);
    endtask
    task automatic send_frame(input integer src,typ,seq,len,input logic[255:0] data,input logic corrupt);
        reg[7:0] body[0:39];reg[15:0] checksum;
        begin
            body[0]=1;body[1]=8'(typ);body[2]=8'(seq);body[3]=8'(seq>>8);
            body[4]=8'(len);body[5]=8'(len>>8);
            for(int i=0;i<len;i++) body[6+i]=data[i*8+:8];
            checksum=16'hffff;
            for(int i=0;i<len+6;i++) checksum=crc_byte(checksum,body[i]);
            if(corrupt) checksum=checksum^1;
            body[6+len]=checksum[7:0];body[7+len]=checksum[15:8];
            uart_byte(src,8'hc0);
            for(int i=0;i<len+8;i++) escaped_byte(src,body[i]);
            uart_byte(src,8'hc0);
        end
    endtask
    task automatic check_reply(input integer src);
        reg[15:0] checksum,seq;
        integer n;
        begin
            n=seen_rc[src];
            if(reply_count[src]!=11 || reply_body[src][0]!=1 || reply_body[src][1]!=8'h80 ||
               reply_body[src][4]!=3 || reply_body[src][5]!=0 || reply_body[src][6]!=2)
                $fatal(1,"bad reply header src=%0d count=%0d",src,reply_count[src]);
            checksum=16'hffff;
            for(int i=0;i<9;i++) checksum=crc_byte(checksum,reply_body[src][i]);
            if(checksum!={reply_body[src][10],reply_body[src][9]}) $fatal(1,"reply CRC");
            seq={reply_body[src][3],reply_body[src][2]};
            if(n>=expect_rc[src] || seq!=expected_seq[src][n] ||
               reply_body[src][7]!=expected_cmd[src][n] || reply_body[src][8]!=expected_result[src][n])
                $fatal(1,"unexpected reply src=%0d seq=%0d cmd=%0d result=%0d index=%0d",src,seq,reply_body[src][7],reply_body[src][8],n);
            if(reply_body[src][8]==0 && !done_seen[src][seq%32]) $fatal(1,"ACK before real commit");
            seen_rc[src]++;
        end
    endtask
    task automatic wait_all;
        integer cycles;
        begin
            cycles=0;
            while(seen_ec[0]!=expect_ec[0] || seen_ec[1]!=expect_ec[1] ||
                  seen_rc[0]!=expect_rc[0] || seen_rc[1]!=expect_rc[1]) begin
                @(negedge clk);cycles++;
                if(cycles>100000) $fatal(1,"waiting events %0d/%0d %0d/%0d replies %0d/%0d %0d/%0d",seen_ec[0],expect_ec[0],seen_ec[1],expect_ec[1],seen_rc[0],expect_rc[0],seen_rc[1],expect_rc[1]);
            end
            repeat(20) @(negedge clk);
        end
    endtask

    always @(negedge clk) if(rst_n)
        random_bits={random_bits[14:0],random_bits[15]^random_bits[13]^random_bits[12]^random_bits[10]};
    always @(posedge clk) if(rst_n) begin
        if(was_stalled&&!quarantine[held_source]&&!restart[held_source]&&
           (!ev_valid || ev_source!==held_source || ev_data!==held_event)) $fatal(1,"stalled event changed");
        was_stalled<=ev_valid&&!ev_ready;held_source<=ev_source;held_event<=ev_data;
        if(ev_valid&&ev_ready) begin
            if(seen_ec[ev_source]>=expect_ec[ev_source] || ev_data!==expected_events[ev_source][seen_ec[ev_source]])
                $fatal(1,"unexpected event src=%0d index=%0d data=%h",ev_source,seen_ec[ev_source],ev_data);
            seen_ec[ev_source]++;
        end
        if(cv&&cr) begin
            if(dut.ev_level!=0 || !midi_idle) $fatal(1,"config crossed MIDI barrier");
            commit_requests++;
            backend_pending<=1;backend_delay<=20;backend_shadow<=shadow;
            backend_source<=cs;backend_seq<=cseq;backend_command<=ccmd;
            backend_result<=ccmd==1?8'd6:8'd0; // deliberately no EQ backend
        end else if(backend_pending) begin
            if(backend_delay>0) backend_delay<=backend_delay-1;
            else if(cdv&&cdr) begin
                backend_pending<=0;
                if(backend_result==0) begin
                    commits++;done_seen[backend_source][backend_seq%32]<=1;
                    if(backend_command==2) preset<=backend_shadow[15:8];
                end
            end
        end
        for(int src=0;src<2;src++) begin
            if(tx_frame_error[src]||tx_break[src]) $fatal(1,"bad TX waveform");
            if(tx_byte_valid[src]) begin
                if(tx_byte_data[src*8+:8]==8'hc0) begin
                    if(reply_escape[src]) $fatal(1,"dangling reply escape");
                    if(reply_started[src]&&reply_count[src]>0) check_reply(src);
                    reply_started[src]=1;reply_count[src]=0;reply_escape[src]=0;
                end else if(reply_started[src]) begin
                    if(reply_escape[src]) begin
                        if(tx_byte_data[src*8+:8]!=8'hdc && tx_byte_data[src*8+:8]!=8'hdd) $fatal(1,"bad reply escape");
                        reply_body[src][reply_count[src]]=tx_byte_data[src*8+:8]==8'hdc ? 8'hc0 : 8'hdb;
                        reply_count[src]++;reply_escape[src]=0;
                    end else if(tx_byte_data[src*8+:8]==8'hdb) reply_escape[src]=1;
                    else begin reply_body[src][reply_count[src]]=tx_byte_data[src*8+:8];reply_count[src]++;end
                end
            end
        end
    end

    initial begin
        for(int src=0;src<2;src++) begin
            expect_ec[src]=0;seen_ec[src]=0;expect_rc[src]=0;seen_rc[src]=0;reply_count[src]=0;
            for(int j=0;j<32;j++) done_seen[src][j]=0;
        end
        repeat(5) @(negedge clk);rst_n=1;
        expect_event(0,event_word(1,0,60,100));expect_event(0,event_word(1,0,62,80));
        expect_event(0,event_word(2,0,1,32));expect_event(0,event_word(4,0,0,64));
        expect_event(1,event_word(3,1,2,0));expect_event(1,event_word(1,1,64,96));expect_event(1,event_word(2,1,11,64));
        fork
            send_frame(0,1,0,11,256'h4000e02001b0503e643c90,0);
            send_frame(1,1,0,8,256'h400bb160409102c1,0);
        join
        wait_all();
        $display("integration: concurrent UART MIDI and source tags PASS");

        // A queued event plus an application-busy flag must block both configs.
        hold_events=1;midi_idle=0;
        expect_event(0,event_word(1,0,65,70));
        send_frame(0,1,1,3,256'h464190,0);
        expect_reply(0,1,2,0);expect_reply(1,1,2,0);
        fork send_frame(0,2,1,2,256'h0102,0);send_frame(1,2,1,2,256'h0002,0);join
        repeat(30) @(negedge clk);
        if(commit_requests!=0) $fatal(1,"config ignored event barrier");
        hold_events=0;repeat(50) @(negedge clk);
        if(commit_requests!=0) $fatal(1,"config ignored consumer retirement");
        midi_idle=1;wait_all();
        if(commit_requests!=2 || commits!=2) $fatal(1,"both-source config count");
        $display("integration: same SEQ per source and true commit ACK PASS");

        expect_reply(0,1,2,0);send_frame(0,2,1,2,256'h0102,0);wait_all();
        expect_reply(0,1,2,5);send_frame(0,2,1,2,256'h0202,0);wait_all();
        expect_reply(0,1,2,0);send_frame(0,2,1,2,256'h0102,0);wait_all();
        if(commit_requests!=2) $fatal(1,"duplicate or conflict committed");
        send_frame(0,2,10,2,256'h0102,1);
        send_frame(0,2,11,17,256'h02,0);
        expect_event(0,event_word(0,0,60,0));send_frame(0,1,2,3,256'h003c90,0);wait_all();
        if(!errors[2] || !errors[1] || commit_requests!=2) $fatal(1,"bad CRC/length recovery");

        hold_events=1;payload=0;
        for(int i=0;i<16;i++) begin payload[i*16+:8]=8'hc0;payload[i*16+8+:8]=8'(i);expect_event(0,event_word(3,0,i,0));end
        send_frame(0,1,3,32,payload,0);
        repeat(100) @(negedge clk);hold_events=0;wait_all();
        $display("integration: max32 payload, backpressure and bad-frame isolation PASS");

        // Fill/stall events, then restart while an admitted frame is pinned.
        // No old-source event may be delivered after cleanup/reopening.
        hold_events=1;
        send_frame(0,1,4,32,payload,0);
        wait(dut.pin[0] && dut.ev_level!=0);
        @(negedge clk);restart=1;
        @(negedge clk);restart=0;
        wait(quarantine[0]);wait(!quarantine[0]);
        repeat(20) @(negedge clk);hold_events=0;
        expect_reply(0,1,2,0);send_frame(0,2,1,2,256'h0202,0);wait_all();
        if(commit_requests!=3 || preset!=2) $fatal(1,"session restart did not clear source cache");
        expect_reply(1,1,2,0);send_frame(1,2,1,2,256'h0002,0);wait_all();
        if(commit_requests!=3) $fatal(1,"other-source cache cleared");

        // Hard UART fault quarantines source0, while source1 still runs.
        @(negedge clk);rx_i[0]=0;repeat(BIT_CYC*14) @(negedge clk);rx_i[0]=1;
        wait(quarantine[0]);
        expect_event(1,event_word(0,1,64,0));send_frame(1,1,1,3,256'h004081,0);wait_all();
        @(negedge clk);restart=1;@(negedge clk);restart=0;wait(!quarantine[0]);
        expect_reply(0,2,1,6);send_frame(0,2,2,10,256'h0100fa0003e800010001,0);wait_all();
        if(commit_requests!=4 || commits!=3) $fatal(1,"NOT_READY backend result lost");
        repeat(200) @(negedge clk);
        if(dut.dispatch_busy || dut.ev_level!=0) $fatal(1,"not quiescent");
        $display("PASS tb_comm_top events=%0d replies=%0d commits=%0d; dual RX/TX, barriers, replay, restart, faults",seen_ec[0]+seen_ec[1],seen_rc[0]+seen_rc[1],commits);
        $finish;
    end
    initial begin #10000000;$fatal(1,"integration watchdog");end
endmodule
