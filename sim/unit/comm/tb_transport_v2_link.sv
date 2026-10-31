`timescale 1ns/1ps
// Self-checking unit test for transport_v2_link against the real comm_v2_codec.
//
// The testbench drives the v2 SLIP/CRC wire format and observes the original
// transport_link business frame stream.  It intentionally does not model the
// codec or the session controller; maintenance_done is the explicit barrier
// pulse supplied by the integration.
module tb_transport_v2_link;
    import comm_pkg::*;

    localparam int CLK_PERIOD = 10;
    localparam int MAXQ = 128;

    logic clk = 0;
    logic rst_n = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // DUT pins
    logic        flush = 0;
    logic        pin;
    logic        rx_valid = 0;
    logic        rx_ready;
    logic [7:0]  rx_data = 0;
    logic        tx_valid;
    logic        tx_ready = 1;
    logic [7:0]  tx_data;
    logic        frame_valid;
    logic        frame_ready;
    logic [7:0]  frame_data;
    logic [7:0]  frame_type;
    logic [15:0] frame_seq;
    logic [5:0]  frame_payload_len;
    logic        frame_first, frame_last, frame_available;
    logic [7:0]  protocol_errors;
    logic        reply_valid = 0;
    logic        reply_ready;
    logic [15:0] reply_seq = 0;
    logic [7:0]  reply_command = 0, reply_result = 0;
    logic        tx_busy;
    logic        maintenance_done = 0;
    logic        physical_fault = 0;
    logic        disconnect_event = 0;
    logic        midi_error = 0;
    logic        cleanup_request;

    int errors = 0;
    int cleanup_pulses = 0;

    // ---------------------------------------------------------------------
    // Reply queue monitor (DUT TX)
    // ---------------------------------------------------------------------
    logic [7:0]  tx_body [0:127];
    int          tx_bn = 0;
    logic        tx_started = 0, tx_esc = 0, tx_bad = 0;
    int          tx_bad_frames = 0;
    int          tx_frame_count = 0;

    logic [7:0]   rxq_type    [0:MAXQ-1];
    logic [15:0]  rxq_seq     [0:MAXQ-1];
    logic [31:0]  rxq_session [0:MAXQ-1];
    logic [5:0]   rxq_len     [0:MAXQ-1];
    logic [255:0] rxq_payload [0:MAXQ-1];
    int           rxq_wr = 0, rxq_rd = 0, rxq_count = 0;

    logic [7:0]   g_type;
    logic [15:0]  g_seq;
    logic [31:0]  g_session;
    logic [5:0]   g_len;
    logic [255:0] g_payload;

    // ---------------------------------------------------------------------
    // Business frame monitor/consumer
    // ---------------------------------------------------------------------
    logic        biz_ready = 1;
    logic        biz_in_frame = 0;
    logic        pin_reg = 0;
    int          biz_idx = 0;
    logic [7:0]  biz_type_r;
    logic [15:0] biz_seq_r;
    logic [5:0]  biz_len_r;
    logic [7:0]  biz_buf [0:63];

    logic [7:0]   bizq_type    [0:MAXQ-1];
    logic [15:0]  bizq_seq     [0:MAXQ-1];
    logic [5:0]   bizq_len     [0:MAXQ-1];
    logic [255:0] bizq_payload [0:MAXQ-1];
    int           bizq_wr = 0, bizq_rd = 0, bizq_count = 0;

    assign frame_ready = biz_ready;
    assign pin = pin_reg;

    transport_v2_link #(
        .FRAME_DEPTH(8),
        .TIMEOUT_CYCLES(3000),
        .CLK_HZ(100),
        .HEARTBEAT_CYCLES(20000),
        .PROGRESS_CYCLES(1000),
        .ERROR_LIMIT(3),
        .ERROR_WINDOW_CYCLES(10000)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .flush(flush), .pin(pin),
        .rx_valid(rx_valid), .rx_ready(rx_ready), .rx_data(rx_data),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data),
        .frame_valid(frame_valid), .frame_ready(frame_ready), .frame_data(frame_data),
        .frame_type(frame_type), .frame_seq(frame_seq),
        .frame_payload_len(frame_payload_len),
        .frame_first(frame_first), .frame_last(frame_last),
        .frame_available(frame_available),
        .protocol_errors(protocol_errors),
        .reply_valid(reply_valid), .reply_ready(reply_ready),
        .reply_seq(reply_seq), .reply_command(reply_command), .reply_result(reply_result),
        .tx_busy(tx_busy),
        .maintenance_done(maintenance_done),
        .physical_fault(physical_fault),
        .disconnect_event(disconnect_event),
        .midi_error(midi_error),
        .cleanup_request(cleanup_request)
    );

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    task automatic fail_msg(input string msg);
        begin
            $display("FAIL [%0t] %s", $time, msg);
            errors = errors + 1;
            $fatal(1);
        end
    endtask

    task automatic check(input bit cond, input string msg);
        begin
            if (!cond)
                fail_msg(msg);
        end
    endtask

    function automatic logic [15:0] crc16_bytes(input logic [7:0] b0,
                                                input logic [7:0] b1,
                                                input logic [7:0] b2,
                                                input logic [7:0] b3,
                                                input logic [7:0] b4,
                                                input logic [7:0] b5,
                                                input logic [7:0] b6,
                                                input logic [7:0] b7,
                                                input logic [7:0] b8,
                                                input logic [7:0] b9);
        logic [15:0] c;
        begin
            c = 16'hFFFF;
            c = crc16_byte(c, b0); c = crc16_byte(c, b1);
            c = crc16_byte(c, b2); c = crc16_byte(c, b3);
            c = crc16_byte(c, b4); c = crc16_byte(c, b5);
            c = crc16_byte(c, b6); c = crc16_byte(c, b7);
            c = crc16_byte(c, b8); c = crc16_byte(c, b9);
            crc16_bytes = c;
        end
    endfunction

    function automatic bit payload_eq(input logic [255:0] a,
                                      input logic [255:0] b,
                                      input int n);
        bit ok;
        begin
            ok = 1'b1;
            for (int i = 0; i < n; i = i + 1)
                if (a[i*8 +: 8] !== b[i*8 +: 8])
                    ok = 1'b0;
            payload_eq = ok;
        end
    endfunction

    task automatic append_tx_body(input logic [7:0] b);
        begin
            if (tx_bn < 128)
                tx_body[tx_bn] = b;
            tx_bn = tx_bn + 1;
        end
    endtask

    task automatic store_tx_frame;
        integer i;
        logic [15:0] len16, crc, want;
        begin
            if (tx_bn < 12) begin
                tx_bad_frames = tx_bad_frames + 1;
            end else if (tx_body[0] != 8'h02) begin
                tx_bad_frames = tx_bad_frames + 1;
            end else begin
                len16 = {tx_body[5], tx_body[4]};
                if (tx_bn != (len16 + 12)) begin
                    tx_bad_frames = tx_bad_frames + 1;
                end else begin
                    crc = 16'hFFFF;
                    for (i = 0; i < tx_bn - 2; i = i + 1)
                        crc = crc16_byte(crc, tx_body[i]);
                    want = {tx_body[tx_bn-1], tx_body[tx_bn-2]};
                    if (crc !== want) begin
                        tx_bad_frames = tx_bad_frames + 1;
                    end else begin
                        rxq_type[rxq_wr] = tx_body[1];
                        rxq_seq[rxq_wr] = {tx_body[3], tx_body[2]};
                        rxq_len[rxq_wr] = tx_body[4][5:0];
                        rxq_session[rxq_wr] = {tx_body[9], tx_body[8],
                                                tx_body[7], tx_body[6]};
                        rxq_payload[rxq_wr] = '0;
                        for (i = 0; i < tx_body[4]; i = i + 1)
                            rxq_payload[rxq_wr][i*8 +: 8] = tx_body[10+i];
                        rxq_wr = (rxq_wr + 1) % MAXQ;
                        if (rxq_count == MAXQ)
                            fail_msg("TX monitor queue overflow");
                        else
                            rxq_count = rxq_count + 1;
                        tx_frame_count = tx_frame_count + 1;
                    end
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && tx_valid && tx_ready) begin
            if (tx_data == 8'hC0) begin
                if (tx_started && !tx_bad && (tx_bn != 0))
                    store_tx_frame();
                else if (tx_started && tx_bad)
                    tx_bad_frames = tx_bad_frames + 1;
                tx_started = 1'b1;
                tx_bn = 0;
                tx_esc = 1'b0;
                tx_bad = 1'b0;
            end else if (tx_started && !tx_bad) begin
                if (tx_esc) begin
                    if (tx_data == 8'hDC)
                        append_tx_body(8'hC0);
                    else if (tx_data == 8'hDD)
                        append_tx_body(8'hDB);
                    else
                        tx_bad = 1'b1;
                    tx_esc = 1'b0;
                end else if (tx_data == 8'hDB) begin
                    tx_esc = 1'b1;
                end else begin
                    append_tx_body(tx_data);
                end
                if (tx_bn > 100)
                    tx_bad = 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (frame_valid && frame_ready) begin
                if (frame_first) begin
                    biz_idx = 0;
                    biz_type_r = frame_type;
                    biz_seq_r = frame_seq;
                    biz_len_r = frame_payload_len;
                    biz_in_frame = 1'b1;
                    pin_reg = 1'b1;
                end
                if (biz_idx < 64)
                    biz_buf[biz_idx] = frame_data;
                biz_idx = biz_idx + 1;
                if (frame_last) begin
                    bizq_type[bizq_wr] = biz_type_r;
                    bizq_seq[bizq_wr] = biz_seq_r;
                    bizq_len[bizq_wr] = biz_len_r;
                    bizq_payload[bizq_wr] = '0;
                    for (int i = 0; i < biz_len_r; i = i + 1)
                        bizq_payload[bizq_wr][i*8 +: 8] = biz_buf[i];
                    bizq_wr = (bizq_wr + 1) % MAXQ;
                    if (bizq_count == MAXQ)
                        fail_msg("business monitor queue overflow");
                    else
                        bizq_count = bizq_count + 1;
                    biz_in_frame = 1'b0;
                    pin_reg = 1'b0;
                end
            end
        end else begin
            biz_in_frame = 1'b0;
            pin_reg = 1'b0;
            biz_idx = 0;
        end
    end

    always @(posedge clk) begin
        if (rst_n && cleanup_request)
            cleanup_pulses = cleanup_pulses + 1;
    end

    // ---------------------------------------------------------------------
    // Wire-side sender
    // ---------------------------------------------------------------------
    task automatic send_wire_byte(input logic [7:0] b);
        begin
            @(negedge clk);
            rx_valid = 1'b1;
            rx_data = b;
            @(posedge clk);
            while (!rx_ready)
                @(posedge clk);
            @(negedge clk);
            rx_valid = 1'b0;
            rx_data = 8'h00;
        end
    endtask

    task automatic send_escaped(input logic [7:0] b);
        begin
            if (b == 8'hC0) begin
                send_wire_byte(8'hDB);
                send_wire_byte(8'hDC);
            end else if (b == 8'hDB) begin
                send_wire_byte(8'hDB);
                send_wire_byte(8'hDD);
            end else begin
                send_wire_byte(b);
            end
        end
    endtask

    task automatic send_frame(input logic [7:0] typ,
                              input logic [15:0] seq,
                              input logic [31:0] sess,
                              input logic [255:0] payload,
                              input int plen,
                              input bit corrupt_crc);
        logic [7:0] body [0:63];
        logic [15:0] crc;
        int i, n;
        begin
            body[0] = 8'h02;
            body[1] = typ;
            body[2] = seq[7:0];
            body[3] = seq[15:8];
            body[4] = plen[7:0];
            body[5] = plen[15:8];
            body[6] = sess[7:0];
            body[7] = sess[15:8];
            body[8] = sess[23:16];
            body[9] = sess[31:24];
            for (i = 0; i < plen; i = i + 1)
                body[10+i] = payload[i*8 +: 8];
            crc = crc16_bytes(body[0], body[1], body[2], body[3], body[4],
                              body[5], body[6], body[7], body[8], body[9]);
            for (i = 10; i < 10 + plen; i = i + 1)
                crc = crc16_byte(crc, body[i]);
            if (corrupt_crc)
                crc = crc ^ 16'h0001;
            body[10+plen] = crc[7:0];
            body[11+plen] = crc[15:8];
            n = 12 + plen;
            send_wire_byte(8'hC0);
            for (i = 0; i < n; i = i + 1)
                send_escaped(body[i]);
            send_wire_byte(8'hC0);
        end
    endtask

    task automatic send_hello(input logic [15:0] seq, input logic [31:0] nonce);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h01;
            p[15:8] = nonce[7:0];
            p[23:16] = nonce[15:8];
            p[31:24] = nonce[23:16];
            p[39:32] = nonce[31:24];
            send_frame(8'h03, seq, 32'd0, p, 5, 1'b0);
        end
    endtask

    task automatic send_confirm(input logic [15:0] seq,
                                input logic [31:0] sess,
                                input logic [31:0] nonce);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h02;
            p[15:8] = nonce[7:0];
            p[23:16] = nonce[15:8];
            p[31:24] = nonce[23:16];
            p[39:32] = nonce[31:24];
            send_frame(8'h03, seq, sess, p, 5, 1'b0);
        end
    endtask

    task automatic send_ping(input logic [15:0] seq,
                             input logic [31:0] sess,
                             input logic [7:0] has_midi,
                             input logic [15:0] last_seq,
                             input logic [15:0] ep);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h03;
            p[15:8] = has_midi;
            p[23:16] = last_seq[7:0];
            p[31:24] = last_seq[15:8];
            p[39:32] = ep[7:0];
            p[47:40] = ep[15:8];
            send_frame(8'h03, seq, sess, p, 6, 1'b0);
        end
    endtask

    task automatic send_status(input logic [15:0] seq, input logic [31:0] sess);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h04;
            send_frame(8'h03, seq, sess, p, 1, 1'b0);
        end
    endtask

    task automatic send_resume(input logic [15:0] seq,
                               input logic [31:0] sess,
                               input logic [15:0] ep,
                               input logic [15:0] first_seq);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h05;
            p[15:8] = ep[7:0];
            p[23:16] = ep[15:8];
            p[31:24] = first_seq[7:0];
            p[39:32] = first_seq[15:8];
            send_frame(8'h03, seq, sess, p, 5, 1'b0);
        end
    endtask

    task automatic send_raw_command(input logic [15:0] seq,
                                    input logic [31:0] sess,
                                    input logic [255:0] payload,
                                    input int plen);
        begin
            send_frame(8'h03, seq, sess, payload, plen, 1'b0);
        end
    endtask

    task automatic send_midi(input logic [31:0] sess,
                             input logic [15:0] ep,
                             input logic [15:0] seq,
                             input logic [255:0] midi,
                             input int mlen,
                             input bit corrupt_crc);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = ep[7:0];
            p[15:8] = ep[15:8];
            for (int i = 0; i < mlen; i = i + 1)
                p[16 + i*8 +: 8] = midi[i*8 +: 8];
            send_frame(8'h01, seq, sess, p, mlen + 2, corrupt_crc);
        end
    endtask

    task automatic send_config(input logic [31:0] sess,
                               input logic [15:0] seq,
                               input logic [255:0] payload,
                               input int plen);
        begin
            send_frame(8'h02, seq, sess, payload, plen, 1'b0);
        end
    endtask

    task automatic give_config_reply(input logic [15:0] seq,
                                     input logic [7:0] cmd,
                                     input logic [7:0] res);
        begin
            @(negedge clk);
            reply_valid = 1'b1;
            reply_seq = seq;
            reply_command = cmd;
            reply_result = res;
            @(posedge clk);
            while (!reply_ready)
                @(posedge clk);
            @(negedge clk);
            reply_valid = 1'b0;
        end
    endtask

    task automatic pulse_maintenance;
        begin
            @(negedge clk);
            maintenance_done = 1'b1;
            @(posedge clk);
            @(negedge clk);
            maintenance_done = 1'b0;
        end
    endtask

    task automatic pulse_disconnect;
        begin
            @(negedge clk);
            disconnect_event = 1'b1;
            @(posedge clk);
            @(negedge clk);
            disconnect_event = 1'b0;
        end
    endtask

    task automatic pulse_physical;
        begin
            @(negedge clk);
            physical_fault = 1'b1;
            @(posedge clk);
            @(negedge clk);
            physical_fault = 1'b0;
        end
    endtask

    task automatic pulse_midi_error;
        begin
            @(negedge clk);
            midi_error = 1'b1;
            @(posedge clk);
            @(negedge clk);
            midi_error = 1'b0;
        end
    endtask

    // ---------------------------------------------------------------------
    // Receivers
    // ---------------------------------------------------------------------
    task automatic pop_rx(input string label);
        integer timeout;
        begin
            timeout = 0;
            while (rxq_count == 0) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 50000)
                    fail_msg({label, ": timed out waiting for TX frame"});
            end
            g_type = rxq_type[rxq_rd];
            g_seq = rxq_seq[rxq_rd];
            g_session = rxq_session[rxq_rd];
            g_len = rxq_len[rxq_rd];
            g_payload = rxq_payload[rxq_rd];
            rxq_rd = (rxq_rd + 1) % MAXQ;
            rxq_count = rxq_count - 1;
        end
    endtask

    task automatic expect_frame(input logic [7:0] typ,
                                input logic [15:0] seq,
                                input logic [31:0] sess,
                                input int plen,
                                input logic [255:0] payload,
                                input string label);
        begin
            pop_rx(label);
            if (g_type !== typ)
                fail_msg({label, ": wrong TYPE"});
            if (g_seq !== seq)
                fail_msg({label, ": wrong SEQ"});
            if (g_session !== sess)
                fail_msg({label, ": wrong SESSION"});
            if (g_len !== plen[5:0])
                fail_msg({label, ": wrong LEN"});
            if (!payload_eq(g_payload, payload, plen))
                fail_msg({label, ": wrong payload"});
        end
    endtask

    task automatic expect_welcome(input logic [15:0] seq,
                                  input logic [31:0] nonce,
                                  input bit check_sess,
                                  input logic [31:0] sess,
                                  input string label);
        begin
            pop_rx(label);
            if (g_type !== 8'h81 || g_len !== 6'd11)
                fail_msg({label, ": not a WELCOME"});
            if (g_seq !== seq)
                fail_msg({label, ": WELCOME SEQ mismatch"});
            if (g_session == 32'd0)
                fail_msg({label, ": WELCOME session is zero"});
            if (check_sess && (g_session !== sess))
                fail_msg({label, ": WELCOME session not replayed"});
            if (g_payload[7:0] !== 8'h81)
                fail_msg({label, ": WELCOME command"});
            if (g_payload[39:8] !== nonce)
                fail_msg({label, ": WELCOME nonce"});
            if (g_payload[55:40] !== 16'd0)
                fail_msg({label, ": WELCOME epoch not zero"});
            if (g_payload[71:56] !== 16'h000F)
                fail_msg({label, ": WELCOME caps"});
            if (g_payload[79:72] !== 8'd30 || g_payload[87:80] !== 8'd16)
                fail_msg({label, ": WELCOME max lengths"});
            g_session = g_session;
        end
    endtask

    task automatic expect_ready(input logic [15:0] seq,
                                input logic [31:0] sess,
                                input logic [15:0] ep,
                                input logic [15:0] exp_seq,
                                input string label);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h82;
            p[15:8] = ep[7:0];
            p[23:16] = ep[15:8];
            p[31:24] = exp_seq[7:0];
            p[39:32] = exp_seq[15:8];
            expect_frame(8'h81, seq, sess, 5, p, label);
        end
    endtask

    task automatic expect_pong(input logic [15:0] seq,
                               input logic [31:0] sess,
                               input logic [7:0] st,
                               input logic [15:0] ep,
                               input logic [15:0] exp_seq,
                               input string label);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h83;
            p[15:8] = st;
            p[23:16] = ep[7:0];
            p[31:24] = ep[15:8];
            p[39:32] = exp_seq[7:0];
            p[47:40] = exp_seq[15:8];
            expect_frame(8'h81, seq, sess, 6, p, label);
        end
    endtask

    task automatic expect_status(input logic [15:0] seq,
                                 input logic [31:0] sess,
                                 input logic [7:0] st,
                                 input logic [15:0] ep,
                                 input logic [15:0] exp_seq,
                                 input logic [7:0] reason,
                                 input string label);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h84;
            p[15:8] = st;
            p[23:16] = ep[7:0];
            p[31:24] = ep[15:8];
            p[39:32] = exp_seq[7:0];
            p[47:40] = exp_seq[15:8];
            p[55:48] = reason;
            expect_frame(8'h81, seq, sess, 7, p, label);
        end
    endtask

    task automatic expect_playback(input logic [15:0] seq,
                                   input logic [31:0] sess,
                                   input logic [15:0] ep,
                                   input logic [15:0] exp_seq,
                                   input string label);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h85;
            p[15:8] = ep[7:0];
            p[23:16] = ep[15:8];
            p[31:24] = exp_seq[7:0];
            p[39:32] = exp_seq[15:8];
            expect_frame(8'h81, seq, sess, 5, p, label);
        end
    endtask

    task automatic expect_resync(input logic [31:0] sess,
                                 input logic [15:0] ep,
                                 input logic [7:0] reason,
                                 input string label);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h86;
            p[15:8] = ep[7:0];
            p[23:16] = ep[15:8];
            p[31:24] = reason;
            expect_frame(8'h81, 16'h0000, sess, 4, p, label);
        end
    endtask

    task automatic expect_fault(input logic [31:0] sess,
                                input logic [7:0] reason,
                                input string label);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'h87;
            p[15:8] = reason;
            expect_frame(8'h81, 16'h0000, sess, 2, p, label);
        end
    endtask

    task automatic expect_ff(input logic [15:0] seq,
                             input logic [31:0] sess,
                             input logic [7:0] cmd,
                             input logic [7:0] res,
                             input string label);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0] = 8'hFF;
            p[15:8] = cmd;
            p[23:16] = res;
            expect_frame(8'h81, seq, sess, 3, p, label);
        end
    endtask

    task automatic pop_biz(input string label);
        integer timeout;
        begin
            timeout = 0;
            while (bizq_count == 0) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 50000)
                    fail_msg({label, ": timed out waiting for business frame"});
            end
            g_type = bizq_type[bizq_rd];
            g_seq = bizq_seq[bizq_rd];
            g_session = 32'd0;
            g_len = bizq_len[bizq_rd];
            g_payload = bizq_payload[bizq_rd];
            bizq_rd = (bizq_rd + 1) % MAXQ;
            bizq_count = bizq_count - 1;
        end
    endtask

    task automatic expect_biz(input logic [7:0] typ,
                              input logic [15:0] seq,
                              input int plen,
                              input logic [255:0] payload,
                              input string label);
        begin
            pop_biz(label);
            if (g_type !== typ)
                fail_msg({label, ": wrong business TYPE"});
            if (g_seq !== seq)
                fail_msg({label, ": wrong business SEQ"});
            if (g_len !== plen[5:0])
                fail_msg({label, ": wrong business LEN"});
            if (!payload_eq(g_payload, payload, plen))
                fail_msg({label, ": wrong business payload"});
        end
    endtask

    task automatic check_no_rx(input int cycles, input string label);
        begin
            repeat (cycles) @(negedge clk);
            if (rxq_count != 0)
                fail_msg({label, ": unexpected TX frame"});
        end
    endtask

    task automatic check_no_biz(input int cycles, input string label);
        begin
            repeat (cycles) @(negedge clk);
            if (bizq_count != 0)
                fail_msg({label, ": unexpected business frame"});
        end
    endtask

    task automatic wait_cleanup_to(input int target, input string label);
        integer timeout;
        begin
            timeout = 0;
            while (cleanup_pulses < target) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 50000)
                    fail_msg({label, ": timed out waiting cleanup_request"});
            end
        end
    endtask

    task automatic check_no_cleanup(input int cycles, input string label);
        int base;
        begin
            base = cleanup_pulses;
            repeat (cycles) @(negedge clk);
            if (cleanup_pulses != base)
                fail_msg({label, ": unexpected cleanup_request"});
        end
    endtask

    // ---------------------------------------------------------------------
    // Test sequence
    // ---------------------------------------------------------------------
    logic [31:0] sess;
    logic [31:0] old_sess;
    logic [31:0] nonce;
    logic [15:0] ep;
    logic [15:0] tb_seq;
    logic [255:0] p;
    logic [255:0] midi;
    int base_cleanup;

    task automatic new_session(input logic [31:0] n,
                               input logic [15:0] hseq,
                               input logic [15:0] cseq,
                               input string label);
        begin
            base_cleanup = cleanup_pulses;
            send_hello(hseq, n);
            wait_cleanup_to(base_cleanup + 1, {label, " HELLO cleanup"});
            check_no_rx(8, {label, " no early WELCOME"});
            pulse_maintenance();
            expect_welcome(hseq, n, 1'b0, 32'd0, {label, " WELCOME"});
            sess = g_session;
            ep = 16'd0;
            tb_seq = 16'd0;
            check(sess != 32'd0, {label, " WELCOME session nonzero"});
            send_confirm(cseq, sess, n);
            expect_ready(cseq, sess, ep, 16'd0, {label, " READY"});
            check_no_rx(5, {label, " no extra after READY"});
        end
    endtask

    task automatic resume_at(input logic [15:0] first_seq, input string label);
        begin
            send_resume(16'h5000 + first_seq, sess, ep, first_seq);
            expect_playback(16'h5000 + first_seq, sess, ep, first_seq,
                            {label, " PLAYBACK_READY"});
            tb_seq = first_seq;
        end
    endtask

    initial begin
        // Watchdog.
        fork
            begin
                repeat (2000000) @(posedge clk);
                $display("FAIL watchdog timeout");
                $fatal(1);
            end
        join_none

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        // =============================================================
        // 1. HELLO/CONFIRM, idempotent retries, escaping nonce
        // =============================================================
        nonce = 32'hC0DB_DBC0;  // forces SLIP escaping on both RX and TX
        base_cleanup = cleanup_pulses;
        send_hello(16'h1000, nonce);
        wait_cleanup_to(base_cleanup + 1, "HELLO cleanup");
        check_no_rx(10, "HELLO before maintenance_done");
        // Same nonce retry during CLEANUP must not restart cleanup.
        send_hello(16'h1000, nonce);
        repeat (6) @(negedge clk);
        check(cleanup_pulses == base_cleanup + 1, "duplicate HELLO restarted cleanup");
        check_no_rx(5, "duplicate HELLO during CLEANUP");
        pulse_maintenance();
        expect_welcome(16'h1000, nonce, 1'b0, 32'd0, "first WELCOME");
        sess = g_session;
        ep = 16'd0;
        tb_seq = 16'd0;
        check(sess != 0, "session zero");

        // HELLO replay in WAIT_CONFIRM.
        send_hello(16'h1001, nonce);
        expect_welcome(16'h1001, nonce, 1'b1, sess, "WELCOME replay");
        // CONFIRM and duplicate.
        send_confirm(16'h1002, sess, nonce);
        expect_ready(16'h1002, sess, ep, 16'd0, "CONFIRM READY");
        send_confirm(16'h1003, sess, nonce);
        expect_ready(16'h1003, sess, ep, 16'd0, "duplicate CONFIRM READY");
        // Same-nonce HELLO retry in ACTIVE replays WELCOME and does not reset.
        send_hello(16'h1004, nonce);
        expect_welcome(16'h1004, nonce, 1'b1, sess, "ACTIVE WELCOME replay");
        check_no_rx(5, "after active WELCOME replay");

        // Generic replies and stale-session silence.
        send_status(16'h1010, sess);
        expect_status(16'h1010, sess, 8'd3, ep, 16'd0, 8'd0, "STATUS");
        p = '0; p[7:0] = 8'h7F;
        send_raw_command(16'h1011, sess, p, 1);
        expect_ff(16'h1011, sess, 8'h7F, 8'h01, "unknown command");
        // PING with a short payload but valid header.
        p = '0; p[7:0] = 8'h03; p[15:8] = 8'd1;
        send_raw_command(16'h1012, sess, p, 2);
        expect_ff(16'h1012, sess, 8'h03, 8'h02, "bad PING length");
        // Old session control is silent.
        send_ping(16'h1013, sess - 32'd1, 8'd0, 16'd0, ep);
        check_no_rx(10, "old-session PING silence");
        // HELLO with a non-zero session is a bad parameter, not a new session.
        p = '0; p[7:0] = 8'h01; p[39:8] = nonce;
        send_raw_command(16'h1014, sess, p, 5);
        expect_ff(16'h1014, sess, 8'h01, 8'h03, "HELLO with session");
        // HELLO with a short payload is a bad length, not a new session.
        p = '0; p[7:0] = 8'h01;
        send_raw_command(16'h1015, 32'd0, p, 1);
        expect_ff(16'h1015, sess, 8'h01, 8'h02, "short HELLO");

        // =============================================================
        // 2. MIDI epoch/sequence stripping and stale rejection
        // =============================================================
        midi = '0;
        midi[7:0] = 8'h90; midi[15:8] = 8'h3C; midi[23:16] = 8'h64;
        send_midi(sess, ep, 16'd0, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h90; p[15:8] = 8'h3C; p[23:16] = 8'h64;
        expect_biz(8'h01, 16'd0, 3, p, "MIDI 0");
        midi = '0;
        midi[7:0] = 8'h80; midi[15:8] = 8'h3C; midi[23:16] = 8'h00;
        send_midi(sess, ep, 16'd1, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h80; p[15:8] = 8'h3C; p[23:16] = 8'h00;
        expect_biz(8'h01, 16'd1, 3, p, "MIDI 1");
        // Stale epoch and stale session are silent and do not advance expected.
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h3E; midi[23:16] = 8'h40;
        send_midi(sess, ep + 16'd1, 16'd2, midi, 3, 1'b0);
        check_no_biz(10, "stale epoch");
        send_midi(sess - 32'd1, ep, 16'd2, midi, 3, 1'b0);
        check_no_biz(10, "stale session");
        send_midi(sess, ep, 16'd2, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h90; p[15:8] = 8'h3E; p[23:16] = 8'h40;
        expect_biz(8'h01, 16'd2, 3, p, "MIDI 2");
        // Escaped MIDI payload.
        midi = '0; midi[7:0] = 8'hC0; midi[15:8] = 8'h01;
        midi[23:16] = 8'hDB; midi[31:24] = 8'h02;
        send_midi(sess, ep, 16'd3, midi, 4, 1'b0);
        p = '0; p[7:0] = 8'hC0; p[15:8] = 8'h01;
        p[23:16] = 8'hDB; p[31:24] = 8'h02;
        expect_biz(8'h01, 16'd3, 4, p, "escaped MIDI");
        tb_seq = 16'd4;

        // =============================================================
        // 3. Sequence gap -> RESYNC, RESUME idempotency
        // =============================================================
        base_cleanup = cleanup_pulses;
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h40; midi[23:16] = 8'h20;
        send_midi(sess, ep, 16'd5, midi, 3, 1'b0);  // expected 4
        wait_cleanup_to(base_cleanup + 1, "sequence gap cleanup");
        check_no_biz(5, "gap frame not delivered");
        ep = ep + 16'd1;
        pulse_maintenance();
        expect_resync(sess, ep, 8'd1, "RESYNC gap");
        send_status(16'h1105, sess);
        expect_status(16'h1105, sess, 8'd4, ep, 16'd4, 8'd1, "STATUS RESYNC");
        // Wrong epoch RESUME is rejected, matching epoch accepted.
        send_resume(16'h1100, sess, ep - 16'd1, 16'd10);
        expect_ff(16'h1100, sess, 8'h05, 8'h03, "old-epoch RESUME");
        send_resume(16'h1101, sess, ep, 16'd10);
        expect_playback(16'h1101, sess, ep, 16'd10, "first RESUME");
        tb_seq = 16'd10;
        // Duplicate RESUME before progress.
        send_resume(16'h1102, sess, ep, 16'd10);
        expect_playback(16'h1102, sess, ep, 16'd10, "duplicate RESUME pre-progress");
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h41; midi[23:16] = 8'h22;
        send_midi(sess, ep, 16'd10, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h90; p[15:8] = 8'h41; p[23:16] = 8'h22;
        expect_biz(8'h01, 16'd10, 3, p, "post-resume MIDI 10");
        tb_seq = 16'd11;
        // Duplicate RESUME must replay original expected, not current progress.
        send_resume(16'h1103, sess, ep, 16'd10);
        expect_playback(16'h1103, sess, ep, 16'd10, "duplicate RESUME no reset");
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h42; midi[23:16] = 8'h23;
        send_midi(sess, ep, 16'd11, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h90; p[15:8] = 8'h42; p[23:16] = 8'h23;
        expect_biz(8'h01, 16'd11, 3, p, "post-resume MIDI 11");
        tb_seq = 16'd12;

        // =============================================================
        // 4. PING progress: lag tolerated, catch-up cancels, timeout recovers
        // =============================================================
        base_cleanup = cleanup_pulses;
        send_ping(16'h1200, sess, 8'd1, 16'd15, ep);  // expected now 12, target16
        expect_pong(16'h1200, sess, 8'd3, ep, 16'd12, "PING lag PONG");
        check_no_cleanup(12, "PING lag must not clean immediately");
        for (int i = 12; i < 16; i = i + 1) begin
            midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h50;
            midi[23:16] = i[7:0];
            send_midi(sess, ep, i[15:0], midi, 3, 1'b0);
            p = '0; p[7:0] = 8'h90; p[15:8] = 8'h50; p[23:16] = i[7:0];
            expect_biz(8'h01, i[15:0], 3, p, "catch-up MIDI");
        end
        tb_seq = 16'd16;
        check_no_cleanup(200, "caught-up progress timer must cancel");
        // New lag: timer expires.
        base_cleanup = cleanup_pulses;
        send_ping(16'h1201, sess, 8'd1, 16'd18, ep);  // target19
        expect_pong(16'h1201, sess, 8'd3, ep, 16'd16, "PING second lag");
        wait_cleanup_to(base_cleanup + 1, "progress timeout cleanup");
        ep = ep + 16'd1;
        pulse_maintenance();
        expect_resync(sess, ep, 8'd7, "RESYNC progress timeout");
        resume_at(16'd19, "resume after progress");
        // A late stale-epoch frame must still be rejected after RESUME.
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h60; midi[23:16] = 8'h33;
        send_midi(sess, ep - 16'd1, 16'd19, midi, 3, 1'b0);
        check_no_biz(10, "late stale epoch after resume");
        send_midi(sess, ep, 16'd19, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h90; p[15:8] = 8'h60; p[23:16] = 8'h33;
        expect_biz(8'h01, 16'd19, 3, p, "current epoch after stale");
        tb_seq = 16'd20;

        // =============================================================
        // 5. midi_error -> RESYNC reason 2 and sequence wrap
        // =============================================================
        base_cleanup = cleanup_pulses;
        pulse_midi_error();
        wait_cleanup_to(base_cleanup + 1, "midi_error cleanup");
        ep = ep + 16'd1;
        pulse_maintenance();
        expect_resync(sess, ep, 8'd2, "RESYNC midi syntax");
        // Resume near wrap and exercise FFFF -> 0000.
        send_resume(16'h1300, sess, ep, 16'hFFFE);
        expect_playback(16'h1300, sess, ep, 16'hFFFE, "RESUME near wrap");
        tb_seq = 16'hFFFE;
        for (int i = 0; i < 4; i = i + 1) begin
            logic [15:0] sq;
            sq = tb_seq + i[15:0];
            midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h70; midi[23:16] = sq[7:0];
            send_midi(sess, ep, sq, midi, 3, 1'b0);
            p = '0; p[7:0] = 8'h90; p[15:8] = 8'h70; p[23:16] = sq[7:0];
            expect_biz(8'h01, sq, 3, p, "wrap MIDI");
        end
        tb_seq = 16'h0002;
        send_resume(16'h1301, sess, ep, 16'hFFFE);
        expect_playback(16'h1301, sess, ep, 16'hFFFE, "duplicate RESUME wrap");
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h71; midi[23:16] = 8'h02;
        send_midi(sess, ep, 16'h0002, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h90; p[15:8] = 8'h71; p[23:16] = 8'h02;
        expect_biz(8'h01, 16'h0002, 3, p, "post-wrap MIDI");
        tb_seq = 16'h0003;

        // =============================================================
        // 6. Heartbeat timeout (no PING, MIDI must not substitute)
        // =============================================================
        base_cleanup = cleanup_pulses;
        // An invalid PING must not refresh heartbeat.
        p = '0; p[7:0] = 8'h03; p[15:8] = 8'd1;
        send_raw_command(16'h1250, sess, p, 2);
        expect_ff(16'h1250, sess, 8'h03, 8'h02, "invalid heartbeat PING");
        // Keep sending MIDI while waiting: it must NOT refresh heartbeat.
        for (int i = 0; i < 4; i = i + 1) begin
            midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h72;
            midi[23:16] = tb_seq[7:0];
            send_midi(sess, ep, tb_seq, midi, 3, 1'b0);
            p = '0; p[7:0] = 8'h90; p[15:8] = 8'h72; p[23:16] = tb_seq[7:0];
            expect_biz(8'h01, tb_seq, 3, p, "heartbeat MIDI");
            tb_seq = tb_seq + 16'd1;
        end
        wait_cleanup_to(base_cleanup + 1, "heartbeat timeout cleanup");
        expect_fault(sess, 8'd3, "FAULT heartbeat");
        pulse_maintenance();
        new_session(32'h5152_5354, 16'h1251, 16'h1252, "reconnect after heartbeat");

        // =============================================================
        // 7. flush/pin: preserve accepted stream, drop uncommitted frame
        // =============================================================
        // 7a. Accepted/pinned frame survives flush to its last byte.
        midi = '0;
        for (int i = 0; i < 10; i = i + 1)
            midi[i*8 +: 8] = 8'h90 + i[7:0];
        send_midi(sess, ep, tb_seq, midi, 10, 1'b0);
        // Wait until the consumer has accepted a few bytes.
        begin
            int guard;
            guard = 0;
            while (!(biz_in_frame && (biz_idx >= 3)) && (guard < 2000)) begin
                @(negedge clk);
                guard = guard + 1;
            end
            check(biz_in_frame && (biz_idx >= 3), "frame did not start");
        end
        @(negedge clk);
        flush = 1'b1;
        biz_ready = 1'b0;  // pause the pinned stream, pin stays high
        repeat (3) @(negedge clk);
        // Control/TX must not be flushed by ordinary business maintenance.
        send_status(16'h1500, sess);
        expect_status(16'h1500, sess, 8'd3, ep, tb_seq, 8'd0, "STATUS during flush");
        // pin is high, so the rest must be delivered.
        biz_ready = 1'b1;
        begin
            logic [255:0] want;
            want = '0;
            for (int i = 0; i < 10; i = i + 1)
                want[i*8 +: 8] = 8'h90 + i[7:0];
            expect_biz(8'h01, tb_seq, 10, want, "pinned frame after flush");
        end
        @(negedge clk);
        flush = 1'b0;
        tb_seq = tb_seq + 16'd1;

        // 7b. Uncommitted staged frame is dropped by flush and expected does not advance.
        biz_ready = 1'b0;
        midi = '0;
        for (int i = 0; i < 8; i = i + 1)
            midi[i*8 +: 8] = 8'h80 + i[7:0];
        send_midi(sess, ep, tb_seq, midi, 8, 1'b0);
        repeat (20) @(negedge clk);
        check(frame_valid, "staged frame not visible for drop test");
        @(negedge clk);
        flush = 1'b1;
        repeat (3) @(negedge clk);
        flush = 1'b0;
        biz_ready = 1'b1;
        check_no_biz(30, "flushed uncommitted frame");
        // Same sequence number must still be accepted (expected did not advance).
        midi = '0;
        for (int i = 0; i < 8; i = i + 1)
            midi[i*8 +: 8] = 8'hA0 + i[7:0];
        send_midi(sess, ep, tb_seq, midi, 8, 1'b0);
        begin
            logic [255:0] want;
            want = '0;
            for (int i = 0; i < 8; i = i + 1)
                want[i*8 +: 8] = 8'hA0 + i[7:0];
            expect_biz(8'h01, tb_seq, 8, want, "resend after flush");
        end
        tb_seq = tb_seq + 16'd1;

        // =============================================================
        // 8. Control path reachable with business backend stalled
        // =============================================================
        biz_ready = 1'b0;
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h7F; midi[23:16] = 8'h44;
        send_midi(sess, ep, tb_seq, midi, 3, 1'b0);
        repeat (20) @(negedge clk);
        check(frame_valid, "stalled business frame not visible");
        old_sess = sess;
        base_cleanup = cleanup_pulses;
        send_hello(16'h1400, 32'h1122_3344);
        wait_cleanup_to(base_cleanup + 1, "stalled-backend HELLO cleanup");
        pulse_maintenance();
        expect_welcome(16'h1400, 32'h1122_3344, 1'b0, 32'd0, "HELLO during stall");
        sess = g_session;
        check(sess > old_sess, "session counter did not increase");
        ep = 16'd0;
        tb_seq = 16'd0;
        send_confirm(16'h1401, sess, 32'h1122_3344);
        expect_ready(16'h1401, sess, ep, 16'd0, "CONFIRM after stall");
        biz_ready = 1'b1;
        check_no_biz(10, "old stalled frame leaked into new session");
        // Old-session MIDI queued in the codec must be rejected.
        send_midi(old_sess, 16'd0, 16'd0, midi, 3, 1'b0);
        check_no_biz(10, "old session queued MIDI");
        send_midi(sess, ep, 16'd0, midi, 3, 1'b0);
        p = '0; p[7:0] = 8'h90; p[15:8] = 8'h7F; p[23:16] = 8'h44;
        expect_biz(8'h01, 16'd0, 3, p, "new session MIDI");
        tb_seq = 16'd1;

        // =============================================================
        // 9. CONFIG reply bound to submitting session, WELCOME barrier
        // =============================================================
        old_sess = sess;
        p = '0; p[7:0] = 8'h02; p[15:8] = 8'h01;  // REVERB_SET HALL
        send_config(sess, 16'h2000, p, 2);
        expect_biz(8'h02, 16'h2000, 2, p, "CONFIG request");
        base_cleanup = cleanup_pulses;
        send_hello(16'h2001, 32'h5566_7788);
        wait_cleanup_to(base_cleanup + 1, "CONFIG-session HELLO cleanup");
        check_no_rx(15, "WELCOME before old CONFIG retirement");
        // Old parser result arrives while CLEANUP: bind it to the old session.
        give_config_reply(16'h2000, 8'h02, 8'h00);
        expect_frame(8'h80, 16'h2000, old_sess, 3,
                     {232'd0, 8'h00, 8'h02, 8'h02}, "CONFIG reply old session");
        check_no_rx(8, "WELCOME before maintenance_done");
        pulse_maintenance();
        expect_welcome(16'h2001, 32'h5566_7788, 1'b0, 32'd0, "WELCOME after CONFIG");
        sess = g_session;
        check(sess > old_sess, "session counter after CONFIG");
        ep = 16'd0;
        tb_seq = 16'd0;
        send_confirm(16'h2002, sess, 32'h5566_7788);
        expect_ready(16'h2002, sess, ep, 16'd0, "CONFIRM after CONFIG");

        // =============================================================
        // 10. Error window: below limit tolerated, limit hard-revokes
        // =============================================================
        midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h55; midi[23:16] = 8'h11;
        base_cleanup = cleanup_pulses;
        send_midi(sess, ep, tb_seq, midi, 3, 1'b1);  // CRC error 1
        repeat (8) @(negedge clk);
        send_midi(sess, ep, tb_seq, midi, 3, 1'b1);  // CRC error 2
        repeat (8) @(negedge clk);
        check(cleanup_pulses == base_cleanup, "error below limit revoked");
        check_no_biz(5, "CRC-error frame delivered");
        // A valid PING refreshes heartbeat while the error window expires.
        send_ping(16'h20F0, sess, 8'd0, 16'd0, ep);
        expect_pong(16'h20F0, sess, 8'd3, ep, tb_seq, "PING before error window expiry");
        repeat (10100) @(negedge clk);
        check(cleanup_pulses == base_cleanup, "error window did not expire");
        send_midi(sess, ep, tb_seq, midi, 3, 1'b1);  // new window error 1
        repeat (8) @(negedge clk);
        send_midi(sess, ep, tb_seq, midi, 3, 1'b1);  // new window error 2
        repeat (8) @(negedge clk);
        check(cleanup_pulses == base_cleanup, "post-window errors below limit revoked");
        base_cleanup = cleanup_pulses;
        send_midi(sess, ep, tb_seq, midi, 3, 1'b1);  // error 3 -> hard revoke
        wait_cleanup_to(base_cleanup + 1, "error limit cleanup");
        old_sess = sess;
        expect_fault(old_sess, 8'd6, "FAULT error limit");
        check_no_biz(5, "hard revoke delivered frame");
        // HELLO must still be reachable after hard revoke/quarantine.
        base_cleanup = cleanup_pulses;
        send_hello(16'h2100, 32'h99AA_BBCC);
        wait_cleanup_to(base_cleanup + 1, "hard-fault HELLO cleanup");
        pulse_maintenance();
        expect_welcome(16'h2100, 32'h99AA_BBCC, 1'b0, 32'd0, "HELLO after hard fault");
        sess = g_session;
        check(sess > old_sess, "session counter after hard fault");
        ep = 16'd0;
        tb_seq = 16'd0;
        send_confirm(16'h2101, sess, 32'h99AA_BBCC);
        expect_ready(16'h2101, sess, ep, 16'd0, "CONFIRM after hard fault");

        // =============================================================
        // 11. Physical disconnect -> hard revoke; disconnect while HELLO
        // =============================================================
        old_sess = sess;
        base_cleanup = cleanup_pulses;
        pulse_disconnect();
        wait_cleanup_to(base_cleanup + 1, "disconnect cleanup");
        expect_fault(old_sess, 8'd4, "FAULT disconnect");
        // HELLO is still processed while the source is quarantined.
        base_cleanup = cleanup_pulses;
        send_hello(16'h2200, 32'hDEAD_BEEF);
        wait_cleanup_to(base_cleanup + 1, "disconnect HELLO cleanup");
        pulse_maintenance();
        expect_welcome(16'h2200, 32'hDEAD_BEEF, 1'b0, 32'd0, "HELLO after disconnect");
        sess = g_session;
        ep = 16'd0;
        tb_seq = 16'd0;
        send_confirm(16'h2201, sess, 32'hDEAD_BEEF);
        expect_ready(16'h2201, sess, ep, 16'd0, "CONFIRM after disconnect");

        // =============================================================
        // 12. Physical fault reason and codec queue overflow hard revoke
        // =============================================================
        old_sess = sess;
        base_cleanup = cleanup_pulses;
        pulse_physical();
        wait_cleanup_to(base_cleanup + 1, "physical fault cleanup");
        expect_fault(old_sess, 8'd5, "FAULT physical");
        base_cleanup = cleanup_pulses;
        send_hello(16'h2400, 32'h0BAD_F00D);
        wait_cleanup_to(base_cleanup + 1, "physical-fault HELLO cleanup");
        pulse_maintenance();
        expect_welcome(16'h2400, 32'h0BAD_F00D, 1'b0, 32'd0, "HELLO after physical");
        sess = g_session;
        ep = 16'd0;
        tb_seq = 16'd0;
        send_confirm(16'h2401, sess, 32'h0BAD_F00D);
        expect_ready(16'h2401, sess, ep, 16'd0, "CONFIRM after physical");

        // Fill the codec business queue while the stream is stalled.  The
        // One frame is staged outside the codec; the 10th frame overflows
        // its eight queued slots and must hard-revoke (bit5).
        old_sess = sess;
        biz_ready = 1'b0;
        base_cleanup = cleanup_pulses;
        for (int i = 0; i < 10; i = i + 1) begin
            midi = '0; midi[7:0] = 8'h90; midi[15:8] = 8'h7A;
            midi[23:16] = i[7:0];
            send_midi(sess, ep, i[15:0], midi, 3, 1'b0);
        end
        wait_cleanup_to(base_cleanup + 1, "codec overflow cleanup");
        expect_fault(old_sess, 8'd5, "FAULT overflow");
        biz_ready = 1'b1;  // drain old queued frames in WAIT_HELLO
        check_no_biz(60, "old overflow frames leaked");
        base_cleanup = cleanup_pulses;
        send_hello(16'h2500, 32'h1357_9BDF);
        wait_cleanup_to(base_cleanup + 1, "overflow HELLO cleanup");
        pulse_maintenance();
        expect_welcome(16'h2500, 32'h1357_9BDF, 1'b0, 32'd0, "HELLO after overflow");
        sess = g_session;
        ep = 16'd0;
        tb_seq = 16'd0;
        send_confirm(16'h2501, sess, 32'h1357_9BDF);
        expect_ready(16'h2501, sess, ep, 16'd0, "CONFIRM after overflow");

        // =============================================================
        // 13. Wait-CONFIRM timeout
        // =============================================================
        old_sess = sess;
        base_cleanup = cleanup_pulses;
        send_hello(16'h2300, 32'hCAFE_F00D);
        wait_cleanup_to(base_cleanup + 1, "confirm-timeout HELLO cleanup");
        pulse_maintenance();
        expect_welcome(16'h2300, 32'hCAFE_F00D, 1'b0, 32'd0, "WELCOME timeout test");
        sess = g_session;
        ep = 16'd0;
        tb_seq = 16'd0;
        // Do not confirm.  TIMEOUT_CYCLES=3000.
        wait_cleanup_to(base_cleanup + 2, "wait-CONFIRM timeout");
        check(cleanup_pulses >= base_cleanup + 2, "confirm timeout did not request cleanup");
        // A fresh HELLO must be accepted after the timeout.
        base_cleanup = cleanup_pulses;
        send_hello(16'h2301, 32'h1234_5678);
        wait_cleanup_to(base_cleanup + 1, "post-timeout HELLO cleanup");
        pulse_maintenance();
        expect_welcome(16'h2301, 32'h1234_5678, 1'b0, 32'd0, "HELLO after confirm timeout");
        sess = g_session;
        ep = 16'd0;
        tb_seq = 16'd0;
        send_confirm(16'h2302, sess, 32'h1234_5678);
        expect_ready(16'h2302, sess, ep, 16'd0, "CONFIRM after timeout");

        // =============================================================
        // Final health checks
        // =============================================================
        check(tx_bad_frames == 0, "DUT emitted malformed/reply CRC frame");
        check_no_rx(20, "unexpected final TX frame");
        check_no_biz(10, "unexpected final business frame");
        repeat (5) @(negedge clk);
        if (errors == 0) begin
            $display("PASS tb_transport_v2_link: %0d TX frames, %0d cleanup pulses",
                     tx_frame_count, cleanup_pulses);
            $finish;
        end else begin
            $display("FAIL tb_transport_v2_link: %0d checks failed", errors);
            $fatal(1);
        end
    end

endmodule
