`timescale 1ns/1ps
// Real UART -> v2 transport -> existing MIDI/config parsers -> mock consumer.
// TX is decoded by an independent UART/SLIP/CRC checker, not the v2 codec.
module tb_comm_v2_top;
    localparam int CLK_HZ=1600000, BAUD=100000, BIT_CYC=16;
    logic clk=0, rst_n=0;
    always #5 clk=~clk;
    logic [1:0] rx=3, tx, quarantine, fault;
    logic [1:0] cleanup_done=3;
    logic ev_valid,ev_source,parse_error;
    logic [31:0] ev_data;
    logic cv,cs,cdv=0,cdr;
    logic [15:0] cseq;
    logic [7:0] ccmd;
    logic [4:0] clen;
    logic [127:0] shadow;
    integer events=0, configs=0, cleanups=0;
    logic prev_quarantine=0;
    logic stb, framing, brk, false_start;
    logic [7:0] decoded;
    logic started=0,escaped=0;
    logic [7:0] body[0:63];
    integer body_count=0;
    integer replies[0:255];
    logic [31:0] reply_session=0;
    logic [15:0] reply_seq_seen=0;
    logic [255:0] reply_payload=0;
    logic [31:0] sid=0, old_sid;
    integer base_count,old_events;

    comm_top #(.CLK_HZ(CLK_HZ),.WIRED_BAUD(BAUD),.BT_BAUD(BAUD),
        .BT_PROTOCOL_V2(1),.RX_DEPTH(128),.FRAME_DEPTH(4),.EVENT_DEPTH(8),
        .TIMEOUT_CYCLES(10000),.BT_HEARTBEAT_CYCLES(1000000),
        .BT_PROGRESS_CYCLES(20000),.BT_ERROR_LIMIT(3),.BT_ERROR_WINDOW_CYCLES(1000000)) dut (
        .clk(clk),.rst_n(rst_n),.rx_i(rx),.tx_o(tx),.hc05_state_async(1'b0),
        .session_restart(2'b0),.source_cleanup_done(cleanup_done),.source_ops_idle(2'b11),
        .midi_ops_idle(1'b1),.source_quarantine(quarantine),.link_fault_pending(fault),
        .error_sticky(),.rx_error_count(),.event_valid(ev_valid),.event_ready(1'b1),
        .event_data(ev_data),.event_source_id(ev_source),.midi_parse_error(parse_error),
        .cfg_valid(cv),.cfg_ready(1'b1),.cfg_source_id(cs),.cfg_seq(cseq),
        .cfg_command(ccmd),.cfg_payload_len(clen),.cfg_shadow(shadow),
        .cfg_done_valid(cdv),.cfg_done_ready(cdr),.cfg_result(8'd0));
    comm_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.OVERSAMPLE(16)) monitor (
        .clk(clk),.rst_n(rst_n),.rx_i(tx[1]),.rx_stb(stb),.rx_data(decoded),
        .framing_err(framing),.break_detect(brk),.false_start(false_start));
    function automatic [15:0] crc_byte(input [15:0] prev,input [7:0] b);
        reg [15:0] c;
        c=prev^{b,8'b0};
        for(integer i=0;i<8;i++)c=c[15]?(c<<1)^16'h1021:c<<1;
        return c;
    endfunction
    always @(posedge clk) begin
        if(rst_n)begin
            if(ev_valid)begin
                if(!ev_source)$fatal(1,"wrong MIDI source");
                events=events+1;
            end
            if(cv)configs=configs+1;
            if(quarantine[1] && !prev_quarantine)cleanups=cleanups+1;
            prev_quarantine=quarantine[1];
            if(framing||brk)$fatal(1,"TX UART error");
            if(stb)begin
                if(decoded==8'hc0)begin
                    if(started && body_count!=0)check_reply();
                    started=1;escaped=0;body_count=0;
                end else if(started)begin
                    if(escaped)begin
                        if(decoded!=8'hdc && decoded!=8'hdd)$fatal(1,"TX bad escape");
                        body[body_count]=decoded==8'hdc ? 8'hc0 : 8'hdb;
                        body_count=body_count+1;escaped=0;
                    end else if(decoded==8'hdb)escaped=1;
                    else begin body[body_count]=decoded;body_count=body_count+1;end
                    if(body_count>44)$fatal(1,"TX body overflow");
                end
            end
        end
    end
    task automatic check_reply;
        reg [15:0] checksum;
        integer len,cmd;
        begin
            len={body[5],body[4]};
            if(escaped || body_count!=len+12 || body[0]!=2 ||
               (body[1]!=8'h81 && body[1]!=8'h80))
                $fatal(1,"TX v2 header version=%h type=%h len=%0d count=%0d",body[0],body[1],len,body_count);
            checksum=16'hffff;
            for(integer i=0;i<body_count-2;i++)checksum=crc_byte(checksum,body[i]);
            if(checksum!={body[body_count-1],body[body_count-2]})$fatal(1,"TX CRC");
            reply_session={body[9],body[8],body[7],body[6]};
            reply_seq_seen={body[3],body[2]};
            reply_payload=0;
            for(integer i=0;i<len;i++)reply_payload[i*8+:8]=body[10+i];
            cmd=body[1]==8'h80 ? 8'h80 : body[10];
            replies[cmd]=replies[cmd]+1;
        end
    endtask
    task automatic byte_out(input [7:0] b);
        @(negedge clk);rx[1]=0;repeat(BIT_CYC)@(negedge clk);
        for(integer i=0;i<8;i++)begin rx[1]=b[i];repeat(BIT_CYC)@(negedge clk);end
        rx[1]=1;repeat(BIT_CYC)@(negedge clk);
    endtask
    task automatic escaped_out(input [7:0] b);
        if(b==8'hc0)begin byte_out(8'hdb);byte_out(8'hdc);end
        else if(b==8'hdb)begin byte_out(8'hdb);byte_out(8'hdd);end
        else byte_out(b);
    endtask
    task automatic send(input integer typ,seq,input [31:0] session,
                        input integer len,input [255:0] payload,input bit corrupt);
        reg [7:0] bytes[0:43];reg [15:0] checksum;
        bytes[0]=2;bytes[1]=8'(typ);bytes[2]=8'(seq);bytes[3]=8'(seq>>8);
        bytes[4]=8'(len);bytes[5]=8'(len>>8);
        for(integer i=0;i<4;i++)bytes[6+i]=session[i*8+:8];
        for(integer i=0;i<len;i++)bytes[10+i]=payload[i*8+:8];
        checksum=16'hffff;
        for(integer i=0;i<len+10;i++)checksum=crc_byte(checksum,bytes[i]);
        if(corrupt)checksum=checksum^16'h1;
        bytes[len+10]=checksum[7:0];bytes[len+11]=checksum[15:8];
        byte_out(8'hc0);
        for(integer i=0;i<len+12;i++)escaped_out(bytes[i]);
        byte_out(8'hc0);
    endtask
    task automatic await_reply(input integer cmd,count);
        integer n;
        n=0;
        while(replies[cmd]<count && n<1200000)begin @(negedge clk);n++;end
        if(replies[cmd]!=count)$fatal(1,"reply timeout cmd=%h count=%0d expected=%0d",cmd,replies[cmd],count);
    endtask
    task automatic handshake(input [31:0] nonce);
        integer n;
        n=replies[8'h81]+1;
        send(3,1,0,5,{216'd0,nonce,8'h01},0);
        await_reply(8'h81,n);sid=reply_session;
        if(sid==0 || reply_payload[39:8]!=nonce)$fatal(1,"WELCOME context");
        n=replies[8'h82]+1;
        send(3,2,sid,5,{216'd0,nonce,8'h02},0);await_reply(8'h82,n);
    endtask
    initial begin
        for(integer i=0;i<256;i++)replies[i]=0;
        repeat(8)@(negedge clk);rst_n=1;
        // Before HELLO no business may reach the MIDI parser.
        send(1,0,1,5,256'h643c900000,0);
        repeat(100)@(negedge clk);if(events!=0)$fatal(1,"prehandshake MIDI");
        cleanup_done=1;
        send(3,1,0,5,256'h1234dbc001,0);
        repeat(1000)@(negedge clk);
        if(replies[8'h81]!=0 || !quarantine[1])$fatal(1,"HELLO bypassed cleanup barrier");
        cleanup_done=3;
        await_reply(8'h81,1);sid=reply_session;
        if(sid==0 || reply_payload[39:8]!=32'h1234dbc0)$fatal(1,"initial WELCOME context");
        send(3,2,sid,5,256'h1234dbc002,0);await_reply(8'h82,1);
        base_count=cleanups;
        send(3,30,0,1,256'h01,0);await_reply(8'hff,1);
        if(cleanups!=base_count || reply_payload[23:0]!=24'h0201ff)
            $fatal(1,"malformed HELLO changed session");
        send(1,0,sid,5,256'h643c900000,0);
        repeat(100)@(negedge clk);if(events!=1)$fatal(1,"valid MIDI missing");
        // One damaged CONFIG must not clear sound or revoke the session.
        base_count=cleanups;
        send(2,1,sid,2,256'h0102,1);
        send(3,3,sid,1,256'h04,0);await_reply(8'h84,1);
        if(cleanups!=base_count || reply_payload[15:8]!=3)$fatal(1,"single CRC revoked session");
        send(1,1,sid,5,256'h003c800000,0);
        repeat(100)@(negedge clk);if(events!=2)$fatal(1,"session did not survive CRC");
        // Last NOTE_OFF missing: heartbeat watermark must reveal the hole.
        send(1,2,sid,5,256'h643c900000,0);
        send(1,3,sid,5,256'h003c800000,1);
        send(3,4,sid,6,256'h000000030103,0);
        await_reply(8'h86,1);
        if(cleanups!=base_count+1)$fatal(1,"missing off not cleaned");
        if(reply_session!=sid || reply_payload[23:8]!=1)$fatal(1,"soft recovery changed session/epoch");
        old_events=events;
        send(1,3,sid,5,256'h643d900000,0);
        repeat(100)@(negedge clk);if(events!=old_events)$fatal(1,"old epoch note executed");
        send(3,5,sid,5,256'h0000000105,0);await_reply(8'h85,1);
        send(1,0,sid,5,256'h643d900000,0);
        repeat(100)@(negedge clk);if(events!=old_events)$fatal(1,"old epoch entered active playback");
        send(1,0,sid,5,256'h643d900001,0);
        repeat(100)@(negedge clk);if(events!=old_events+1)$fatal(1,"resume missing");
        // Retrying RESUME must not reset expected MIDI sequence to zero.
        send(3,5,sid,5,256'h0000000105,0);await_reply(8'h85,2);
        send(1,1,sid,5,256'h003d800001,0);
        repeat(100)@(negedge clk);if(events!=old_events+2)$fatal(1,"duplicate RESUME rewound progress");
        // A config accepted by the backend must retire before a new WELCOME.
        send(2,8,sid,2,256'h0102,0);
        repeat(100)@(negedge clk);if(configs!=1)$fatal(1,"config not accepted");
        send(3,10,sid,1,256'h04,0);await_reply(8'h84,2);
        base_count=replies[8'h81];old_sid=sid;
        send(3,9,0,5,256'h8765432101,0);
        // A repeated HELLO must be accepted while business is quarantined.
        send(3,9,0,5,256'h8765432101,0);
        send(3,14,old_sid,1,256'h04,0);
        if(replies[8'h81]!=base_count)$fatal(1,"WELCOME before config retirement");
        @(negedge clk);cdv=1;
        while(!cdr)@(negedge clk);
        @(negedge clk);cdv=0;
        await_reply(8'h81,base_count+1);sid=reply_session;
        if(sid==old_sid)$fatal(1,"session not advanced");
        if(reply_seq_seen!=9)$fatal(1,"WELCOME did not retain HELLO sequence");
        if(replies[8'h80]!=0)$fatal(1,"old config reply escaped cancellation");
        send(3,11,sid,5,256'h8765432102,0);await_reply(8'h82,2);
        old_events=events;
        send(1,0,old_sid,5,256'h643e900000,0);
        send(1,0,sid,5,256'h643f900000,0);
        repeat(100)@(negedge clk);if(events!=old_events+1)$fatal(1,"stale session guard");
        // v2 config ACK is produced only after real backend completion.
        send(2,12,sid,2,256'h0202,0);
        repeat(1000)@(negedge clk);if(replies[8'h80]!=0)$fatal(1,"early config ACK");
        @(negedge clk);cdv=1;while(!cdr)@(negedge clk);
        @(negedge clk);cdv=0;await_reply(8'h80,1);
        if(reply_session!=sid || reply_payload[23:0]!=24'h000202)$fatal(1,"config reply context");
        // Heartbeat absence must revoke, and HELLO remains reachable afterwards.
        await_reply(8'h87,1);
        old_events=events;
        send(1,1,sid,5,256'h6440900000,0);
        repeat(100)@(negedge clk);if(events!=old_events)$fatal(1,"MIDI after timeout");
        handshake(32'h13572468);
        base_count=cleanups;
        send(2,20,sid,2,256'h0302,0);await_reply(8'h80,2);
        if(reply_payload[23:16]!=3 || cleanups!=base_count)$fatal(1,"bad config disturbed session");
        // Protocol-error threshold is separate from a single damaged frame.
        send(2,21,sid,2,256'h0102,1);
        send(2,22,sid,2,256'h0102,1);
        send(2,23,sid,2,256'h0102,1);
        await_reply(8'h87,2);
        handshake(32'h24681357);
        $display("PASS tb_comm_v2_top events=%0d configs=%0d cleanups=%0d",events,configs,cleanups);
        $finish;
    end
    initial begin repeat(4000000)@(posedge clk);$fatal(1,"global timeout");end
endmodule
