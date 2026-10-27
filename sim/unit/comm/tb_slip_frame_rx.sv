`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_slip_frame_rx -- self-checking unit test for slip_frame_rx.
//
// Three DUTs share one clock/reset:
//   idx 0: FRAME_DEPTH=8, long timeout  (main framing / storage / flush tests)
//   idx 1: FRAME_DEPTH=2, timeout=24    (partial-frame timeout tests)
//   idx 2: FRAME_DEPTH=1, long timeout  (depth-1 ordering / concurrency)
// -----------------------------------------------------------------------------
module tb_slip_frame_rx;

    import comm_pkg::*;

    localparam int N = 3;
    localparam logic [7:0] C0 = 8'hC0;
    localparam logic [7:0] DB = 8'hDB;
    localparam logic [7:0] DC = 8'hDC;
    localparam logic [7:0] DD = 8'hDD;

    logic clk;
    logic rst_n;

    logic [N-1:0] flush;
    logic [N-1:0] pin;
    logic [N-1:0] s_valid;
    logic [N-1:0] s_ready;
    logic [7:0]   s_data [0:N-1];

    logic [N-1:0] m_valid;
    logic [N-1:0] m_ready;
    logic [7:0]   m_data [0:N-1];
    logic [N-1:0] m_first;
    logic [N-1:0] m_last;
    logic [7:0]   m_type [0:N-1];
    logic [15:0]  m_seq  [0:N-1];
    logic [5:0]   m_len  [0:N-1];
    logic [N-1:0] frame_avail;
    logic [7:0]   err_flags [0:N-1];

    logic [1:0]   ready_mode [0:N-1]; // 0=always ready, 1=hold, 2=random
    logic [N-1:0] rnd_ready;

    logic [7:0]   err_seen [0:N-1];
    int           errors;

    // Captured frame stream and expected results.
    logic [7:0]   rx_cap [0:N-1][0:31];
    int           rx_count [0:N-1];
    logic [7:0]   rx_type [0:N-1];
    logic [15:0]  rx_seq  [0:N-1];
    logic [5:0]   rx_len  [0:N-1];

    localparam int MAX_SLOTS = 24;
    logic [7:0]   exp_pay [0:MAX_SLOTS-1][0:31];
    int           exp_len [0:MAX_SLOTS-1];
    logic [7:0]   exp_typ [0:MAX_SLOTS-1];
    logic [15:0]  exp_seq [0:MAX_SLOTS-1];

    // Wire construction buffer and current payload.
    logic [7:0]   wire_buf [0:767];
    int           wire_len;
    logic [7:0]   payload_buf [0:63];

    // Interesting escape case: seq=1BC0, cmd=DB, res=C0, CRC=31C0.
    // Header/seq/cmd/result and CRC-low all need SLIP escaping.
    localparam logic [15:0] TXSEQ_ESC = 16'h1BC0;
    localparam logic [7:0]  TXCMD_ESC = 8'hDB;
    localparam logic [7:0]  TXRES_ESC = 8'hC0;

    assign m_ready[0] = !rst_n ? 1'b0 :
                        (ready_mode[0] == 2'd0) ? 1'b1 :
                        (ready_mode[0] == 2'd1) ? 1'b0 : rnd_ready[0];
    assign m_ready[1] = !rst_n ? 1'b0 :
                        (ready_mode[1] == 2'd0) ? 1'b1 :
                        (ready_mode[1] == 2'd1) ? 1'b0 : rnd_ready[1];
    assign m_ready[2] = !rst_n ? 1'b0 :
                        (ready_mode[2] == 2'd0) ? 1'b1 :
                        (ready_mode[2] == 2'd1) ? 1'b0 : rnd_ready[2];

    // -------------------------------------------------------------------------
    // Clock / reset / ready generation
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(negedge clk) begin
        for (int i = 0; i < N; i = i + 1)
            rnd_ready[i] <= $urandom_range(0, 1);
    end

    always @(negedge clk) begin
        if (rst_n) begin
            for (int i = 0; i < N; i = i + 1)
                if (err_flags[i] != 8'h00)
                    err_seen[i] <= err_seen[i] | err_flags[i];
        end
    end

    task automatic do_reset();
        rst_n = 1'b0;
        flush = '0;
        pin   = '0;
        s_valid = '0;
        for (int i = 0; i < N; i = i + 1) begin
            s_data[i] = 8'h00;
            ready_mode[i] = 2'd0;
            err_seen[i] = 8'h00;
        end
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
    endtask

    // -------------------------------------------------------------------------
    // DUTs
    // -------------------------------------------------------------------------
    slip_frame_rx #(
        .FRAME_DEPTH(8),
        .TIMEOUT_CYCLES(100000000)
    ) dut_main (
        .clk(clk), .rst_n(rst_n), .flush(flush[0]), .pin(pin[0]),
        .s_valid(s_valid[0]), .s_ready(s_ready[0]), .s_data(s_data[0]),
        .m_valid(m_valid[0]), .m_ready(m_ready[0]), .m_data(m_data[0]),
        .m_first(m_first[0]), .m_last(m_last[0]), .m_type(m_type[0]),
        .m_seq(m_seq[0]), .m_payload_len(m_len[0]),
        .frame_available(frame_avail[0]), .err_flags(err_flags[0])
    );

    slip_frame_rx #(
        .FRAME_DEPTH(2),
        .TIMEOUT_CYCLES(24)
    ) dut_timeout (
        .clk(clk), .rst_n(rst_n), .flush(flush[1]), .pin(pin[1]),
        .s_valid(s_valid[1]), .s_ready(s_ready[1]), .s_data(s_data[1]),
        .m_valid(m_valid[1]), .m_ready(m_ready[1]), .m_data(m_data[1]),
        .m_first(m_first[1]), .m_last(m_last[1]), .m_type(m_type[1]),
        .m_seq(m_seq[1]), .m_payload_len(m_len[1]),
        .frame_available(frame_avail[1]), .err_flags(err_flags[1])
    );

    slip_frame_rx #(
        .FRAME_DEPTH(1),
        .TIMEOUT_CYCLES(1000000)
    ) dut_depth1 (
        .clk(clk), .rst_n(rst_n), .flush(flush[2]), .pin(pin[2]),
        .s_valid(s_valid[2]), .s_ready(s_ready[2]), .s_data(s_data[2]),
        .m_valid(m_valid[2]), .m_ready(m_ready[2]), .m_data(m_data[2]),
        .m_first(m_first[2]), .m_last(m_last[2]), .m_type(m_type[2]),
        .m_seq(m_seq[2]), .m_payload_len(m_len[2]),
        .frame_available(frame_avail[2]), .err_flags(err_flags[2])
    );

    // -------------------------------------------------------------------------
    // Generic helpers
    // -------------------------------------------------------------------------
    task automatic fail(input string msg);
        errors = errors + 1;
        $display("  ERROR: %s (time=%0t)", msg, $time);
    endtask

    task automatic send_byte(input int d, input logic [7:0] b);
        @(negedge clk);
        s_valid[d] = 1'b1;
        s_data[d]  = b;
        #1;
        while (!s_ready[d]) begin
            @(negedge clk);
            #1;
        end
        @(posedge clk);
        @(negedge clk);
        s_valid[d] = 1'b0;
        #1;
    endtask

    task automatic send_wire(input int d, input int n);
        for (int i = 0; i < n; i = i + 1)
            send_byte(d, wire_buf[i]);
    endtask

    task automatic wire_clear();
        wire_len = 0;
    endtask

    task automatic wire_add(input logic [7:0] b);
        wire_buf[wire_len] = b;
        wire_len = wire_len + 1;
    endtask

    task automatic wire_add_esc(input logic [7:0] b);
        if (b == C0) begin
            wire_add(DB); wire_add(DC);
        end else if (b == DB) begin
            wire_add(DB); wire_add(DD);
        end else begin
            wire_add(b);
        end
    endtask

    task automatic save_expect(
        input int slot, input logic [7:0] typ, input logic [15:0] seq, input int len
    );
        exp_typ[slot] = typ;
        exp_seq[slot] = seq;
        exp_len[slot] = len;
        for (int i = 0; i < len; i = i + 1)
            exp_pay[slot][i] = payload_buf[i];
    endtask

    // Append header + payload + CRC (escaped), but no delimiters.
    //   decl_len   is written into the header
    //   actual_len is the number of payload bytes actually appended
    task automatic append_frame_custom(
        input logic [7:0] typ, input logic [15:0] seq,
        input int decl_len, input int actual_len
    );
        logic [15:0] c;
        logic [15:0] dl;
        c  = 16'hFFFF;
        dl = decl_len[15:0];

        c = crc16_byte(c, 8'h01);          wire_add_esc(8'h01);
        c = crc16_byte(c, typ);            wire_add_esc(typ);
        c = crc16_byte(c, seq[7:0]);       wire_add_esc(seq[7:0]);
        c = crc16_byte(c, seq[15:8]);      wire_add_esc(seq[15:8]);
        c = crc16_byte(c, dl[7:0]);        wire_add_esc(dl[7:0]);
        c = crc16_byte(c, dl[15:8]);       wire_add_esc(dl[15:8]);

        for (int i = 0; i < actual_len; i = i + 1) begin
            c = crc16_byte(c, payload_buf[i]);
            wire_add_esc(payload_buf[i]);
        end

        wire_add_esc(c[7:0]);
        wire_add_esc(c[15:8]);
    endtask

    task automatic append_frame(
        input logic [7:0] typ, input logic [15:0] seq, input int len
    );
        append_frame_custom(typ, seq, len, len);
    endtask

    task automatic build_frame(
        input logic [7:0] typ, input logic [15:0] seq, input int len
    );
        wire_clear();
        wire_add(C0);
        append_frame(typ, seq, len);
        wire_add(C0);
    endtask

    // Hard-coded frame_vectors.json wire bytes.  The payload/expected metadata
    // are also loaded into payload_buf/exp_* slot 0.
    task automatic load_vector(input int v);
        wire_clear();
        case (v)
            0: begin // note_on
                exp_typ[0] = 8'h01; exp_seq[0] = 16'd0; exp_len[0] = 3;
                payload_buf[0] = 8'h90; payload_buf[1] = 8'h3C; payload_buf[2] = 8'h64;
                wire_add(C0); wire_add(8'h01); wire_add(8'h01); wire_add(8'h00);
                wire_add(8'h00); wire_add(8'h03); wire_add(8'h00); wire_add(8'h90);
                wire_add(8'h3C); wire_add(8'h64); wire_add(8'hB3); wire_add(8'h4E);
                wire_add(C0);
            end
            1: begin // program_change_escape: payload C0 must be escaped
                exp_typ[0] = 8'h01; exp_seq[0] = 16'd1; exp_len[0] = 2;
                payload_buf[0] = 8'hC0; payload_buf[1] = 8'h01;
                wire_add(C0); wire_add(8'h01); wire_add(8'h01); wire_add(8'h01);
                wire_add(8'h00); wire_add(8'h02); wire_add(8'h00); wire_add(DB);
                wire_add(DC); wire_add(8'h01); wire_add(8'h31); wire_add(8'h60);
                wire_add(C0);
            end
            2: begin // reverb_hall
                exp_typ[0] = 8'h02; exp_seq[0] = 16'd1; exp_len[0] = 2;
                payload_buf[0] = 8'h02; payload_buf[1] = 8'h01;
                wire_add(C0); wire_add(8'h01); wire_add(8'h02); wire_add(8'h01);
                wire_add(8'h00); wire_add(8'h02); wire_add(8'h00); wire_add(8'h02);
                wire_add(8'h01); wire_add(8'h85); wire_add(8'hC8); wire_add(C0);
            end
            3: begin // eq_band0
                exp_typ[0] = 8'h02; exp_seq[0] = 16'd2; exp_len[0] = 10;
                payload_buf[0] = 8'h01; payload_buf[1] = 8'h00;
                payload_buf[2] = 8'h01; payload_buf[3] = 8'h00;
                payload_buf[4] = 8'hE8; payload_buf[5] = 8'h03;
                payload_buf[6] = 8'h00; payload_buf[7] = 8'hFA;
                payload_buf[8] = 8'h00; payload_buf[9] = 8'h01;
                wire_add(C0); wire_add(8'h01); wire_add(8'h02); wire_add(8'h02);
                wire_add(8'h00); wire_add(8'h0A); wire_add(8'h00); wire_add(8'h01);
                wire_add(8'h00); wire_add(8'h01); wire_add(8'h00); wire_add(8'hE8);
                wire_add(8'h03); wire_add(8'h00); wire_add(8'hFA); wire_add(8'h00);
                wire_add(8'h01); wire_add(8'hFB); wire_add(8'h10); wire_add(C0);
            end
            4: begin // reverb_bathroom_header_escape: seq and payload escape
                exp_typ[0] = 8'h02; exp_seq[0] = 16'd56256; exp_len[0] = 2;
                payload_buf[0] = 8'h02; payload_buf[1] = 8'h02;
                wire_add(C0); wire_add(8'h01); wire_add(8'h02); wire_add(DB);
                wire_add(DC); wire_add(DB); wire_add(DD); wire_add(8'h02);
                wire_add(8'h00); wire_add(8'h02); wire_add(8'h02); wire_add(8'h6B);
                wire_add(8'hD8); wire_add(C0);
            end
            5: begin // config_ack (TYPE=80 must be rejected by device RX)
                exp_typ[0] = 8'h80; exp_seq[0] = 16'd1; exp_len[0] = 3;
                payload_buf[0] = 8'h02; payload_buf[1] = 8'h02; payload_buf[2] = 8'h00;
                wire_add(C0); wire_add(8'h01); wire_add(8'h80); wire_add(8'h01);
                wire_add(8'h00); wire_add(8'h03); wire_add(8'h00); wire_add(8'h02);
                wire_add(8'h02); wire_add(8'h00); wire_add(8'h61); wire_add(8'h50);
                wire_add(C0);
            end
            default: begin
                wire_add(C0); wire_add(C0);
            end
        endcase
        for (int i = 0; i < exp_len[0]; i = i + 1)
            exp_pay[0][i] = payload_buf[i];
    endtask

    task automatic wait_valid(input int d, input int maxc);
        int n;
        n = 0;
        while (!m_valid[d]) begin
            @(negedge clk);
            #1;
            n = n + 1;
            if (n > maxc) begin
                fail($sformatf("wait_valid timeout d=%0d", d));
                disable wait_valid;
            end
        end
    endtask

    // Receive one whole frame, checking metadata stability under stalls and
    // first/last placement.  Stops after the last handshake.
    task automatic recv_frame(input int d, input int mode);
        int idx;
        int guard;
        logic stalled;
        logic meta_set;
        logic [7:0] sd;
        logic [7:0] st;
        logic [15:0] ss;
        logic [5:0] sl;
        logic sf, slst;

        ready_mode[d] = 2'd1;       // never pop before the first sample point
        idx = 0; guard = 0; stalled = 1'b0; meta_set = 1'b0;
        rx_count[d] = 0; rx_type[d] = 8'h00; rx_seq[d] = 16'h0000; rx_len[d] = 6'd0;

        while (1'b1) begin
            @(negedge clk);
            if (idx == 0 && !stalled && !meta_set)
                ready_mode[d] = mode[1:0];
            #1;
            guard = guard + 1;
            if (guard > 250000) begin
                fail($sformatf("recv_frame timeout d=%0d idx=%0d", d, idx));
                disable recv_frame;
            end

            if (m_valid[d]) begin
                if (!frame_avail[d])
                    fail($sformatf("frame_available low while m_valid d=%0d", d));
                if (!stalled) begin
                    sd  = m_data[d];
                    st  = m_type[d];
                    ss  = m_seq[d];
                    sl  = m_len[d];
                    sf  = m_first[d];
                    slst= m_last[d];
                end else begin
                    if ((m_data[d] !== sd) || (m_type[d] !== st) ||
                        (m_seq[d] !== ss) || (m_len[d] !== sl) ||
                        (m_first[d] !== sf) || (m_last[d] !== slst)) begin
                        fail($sformatf("output changed while stalled d=%0d idx=%0d", d, idx));
                    end
                end

                if (!meta_set) begin
                    rx_type[d] = m_type[d];
                    rx_seq[d]  = m_seq[d];
                    rx_len[d]  = m_len[d];
                    meta_set = 1'b1;
                    if (m_len[d] == 6'd0)
                        fail($sformatf("empty published frame d=%0d", d));
                end else begin
                    if ((m_type[d] !== rx_type[d]) || (m_seq[d] !== rx_seq[d]) ||
                        (m_len[d] !== rx_len[d]))
                        fail($sformatf("metadata changed mid-frame d=%0d", d));
                end

                if (m_first[d] !== (idx == 0))
                    fail($sformatf("bad m_first d=%0d idx=%0d", d, idx));
                if (m_last[d] !== (idx == (rx_len[d] - 1)))
                    fail($sformatf("bad m_last d=%0d idx=%0d len=%0d", d, idx, rx_len[d]));

                if (m_ready[d]) begin
                    if (idx >= 32) begin
                        fail($sformatf("payload overflow d=%0d", d));
                        disable recv_frame;
                    end
                    rx_cap[d][idx] = m_data[d];
                    idx = idx + 1;
                    stalled = 1'b0;
                    if (m_last[d]) begin
                        if (idx != rx_len[d])
                            fail($sformatf("byte count mismatch d=%0d got=%0d len=%0d",
                                           d, idx, rx_len[d]));
                        rx_count[d] = idx;
                        @(posedge clk);
                        #1;
                        ready_mode[d] = 2'd1; // keep the next frame safe
                        disable recv_frame;
                    end
                end else begin
                    stalled = 1'b1;
                end
            end else if (stalled) begin
                fail($sformatf("m_valid withdrawn under stall d=%0d idx=%0d", d, idx));
                stalled = 1'b0;
            end
        end
    endtask

    task automatic check_frame(input int d, input int slot);
        if (rx_count[d] != exp_len[slot])
            fail($sformatf("len mismatch d=%0d slot=%0d got=%0d exp=%0d",
                           d, slot, rx_count[d], exp_len[slot]));
        if (rx_type[d] !== exp_typ[slot])
            fail($sformatf("type mismatch d=%0d slot=%0d got=%02h exp=%02h",
                           d, slot, rx_type[d], exp_typ[slot]));
        if (rx_seq[d] !== exp_seq[slot])
            fail($sformatf("seq mismatch d=%0d slot=%0d got=%04h exp=%04h",
                           d, slot, rx_seq[d], exp_seq[slot]));
        for (int i = 0; i < exp_len[slot]; i = i + 1) begin
            if (rx_cap[d][i] !== exp_pay[slot][i])
                fail($sformatf("payload[%0d] mismatch d=%0d slot=%0d got=%02h exp=%02h",
                               i, d, slot, rx_cap[d][i], exp_pay[slot][i]));
        end
    endtask

    task automatic expect_no_output(input int d);
        if (m_valid[d] !== 1'b0)
            fail($sformatf("unexpected m_valid d=%0d", d));
        if (frame_avail[d] !== 1'b0)
            fail($sformatf("unexpected frame_available d=%0d", d));
    endtask

    // Collect the first n bytes of the expected frame, then hold the output.
    task automatic collect_head(input int d, input int n, input int slot);
        int idx;
        int guard;
        ready_mode[d] = 2'd1;
        idx = 0; guard = 0;
        while (idx < n) begin
            @(negedge clk);
            if (idx == 0)
                ready_mode[d] = 2'd0;
            #1;
            guard = guard + 1;
            if (guard > 100000) begin
                fail($sformatf("collect_head timeout d=%0d", d));
                disable collect_head;
            end
            if (m_valid[d]) begin
                if ((m_type[d] !== exp_typ[slot]) || (m_seq[d] !== exp_seq[slot]) ||
                    (m_len[d] !== exp_len[slot]))
                    fail($sformatf("collect_head metadata d=%0d idx=%0d", d, idx));
                if (m_first[d] !== (idx == 0))
                    fail($sformatf("collect_head first d=%0d idx=%0d", d, idx));
                if (m_last[d] !== (idx == (exp_len[slot] - 1)))
                    fail($sformatf("collect_head last d=%0d idx=%0d", d, idx));
                if (m_ready[d]) begin
                    if (m_data[d] !== exp_pay[slot][idx])
                        fail($sformatf("collect_head data d=%0d idx=%0d", d, idx));
                    idx = idx + 1;
                    if (idx == n) begin
                        @(posedge clk);
                        @(negedge clk);
                        #1;
                        ready_mode[d] = 2'd1;
                        #1;
                        disable collect_head;
                    end
                end
            end
        end
    endtask

    // Continue collecting from start..total-1 (output already released).
    task automatic collect_range(input int d, input int start, input int total,
                                 input int slot);
        int idx;
        int guard;
        ready_mode[d] = 2'd1;
        idx = start; guard = 0;
        while (idx < total) begin
            @(negedge clk);
            if (idx == start)
                ready_mode[d] = 2'd0;
            #1;
            guard = guard + 1;
            if (guard > 100000) begin
                fail($sformatf("collect_range timeout d=%0d idx=%0d", d, idx));
                disable collect_range;
            end
            if (m_valid[d]) begin
                if ((m_type[d] !== exp_typ[slot]) || (m_seq[d] !== exp_seq[slot]) ||
                    (m_len[d] !== exp_len[slot]))
                    fail($sformatf("collect_range metadata d=%0d idx=%0d", d, idx));
                if (m_first[d] !== (idx == 0))
                    fail($sformatf("collect_range first d=%0d idx=%0d", d, idx));
                if (m_last[d] !== (idx == (total - 1)))
                    fail($sformatf("collect_range last d=%0d idx=%0d", d, idx));
                if (m_ready[d]) begin
                    if (m_data[d] !== exp_pay[slot][idx])
                        fail($sformatf("collect_range data d=%0d idx=%0d", d, idx));
                    idx = idx + 1;
                    if (idx == total) begin
                        @(posedge clk);
                        #1;
                        ready_mode[d] = 2'd1;
                        disable collect_range;
                    end
                end
            end
        end
    endtask

    task automatic flush_one(input int d, input logic p);
        @(negedge clk);
        flush[d] = 1'b1;
        pin[d]   = p;
        #1;
        @(posedge clk);
        @(negedge clk);
        flush[d] = 1'b0;
        pin[d]   = 1'b0;
        #1;
    endtask

    // -------------------------------------------------------------------------
    // Main tests (FRAME_DEPTH=8)
    // -------------------------------------------------------------------------
    task automatic run_main();
        int v;
        logic [15:0] crc_chk;

        $display("[rx] CRC-16/CCITT-FALSE check vector");
        crc_chk = 16'hFFFF;
        crc_chk = crc16_byte(crc_chk, 8'h31);
        crc_chk = crc16_byte(crc_chk, 8'h32);
        crc_chk = crc16_byte(crc_chk, 8'h33);
        crc_chk = crc16_byte(crc_chk, 8'h34);
        crc_chk = crc16_byte(crc_chk, 8'h35);
        crc_chk = crc16_byte(crc_chk, 8'h36);
        crc_chk = crc16_byte(crc_chk, 8'h37);
        crc_chk = crc16_byte(crc_chk, 8'h38);
        crc_chk = crc16_byte(crc_chk, 8'h39);
        if (crc_chk !== 16'h29B1)
            fail($sformatf("CRC check failed: %04h", crc_chk));

        $display("[rx] frame_vectors.json accepted frames");
        for (v = 0; v < 5; v = v + 1) begin
            load_vector(v);
            err_seen[0] = 8'h00;
            ready_mode[0] = 2'd1;      // hold output while sending
            send_wire(0, wire_len);
            recv_frame(0, 0);
            check_frame(0, 0);
            if (err_seen[0] !== 8'h00)
                fail($sformatf("vector %0d unexpected err %02h", v, err_seen[0]));
        end

        $display("[rx] LEN boundary acceptance (16 CONFIG / 32 MIDI)");
        for (int i = 0; i < 16; i = i + 1) begin
            if (i == 0)       payload_buf[i] = DB;
            else if (i == 1)  payload_buf[i] = C0;
            else              payload_buf[i] = 8'h30 + i[7:0];
        end
        save_expect(0, 8'h02, 16'd31, 16);
        build_frame(8'h02, 16'd31, 16);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("LEN16 err %02h", err_seen[0]));

        for (int i = 0; i < 32; i = i + 1) begin
            if (i == 0)       payload_buf[i] = C0;
            else if (i == 1)  payload_buf[i] = DB;
            else              payload_buf[i] = (i * 7) & 8'hFF;
        end
        save_expect(0, 8'h01, 16'd32, 32);
        build_frame(8'h01, 16'd32, 32);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("LEN32 err %02h", err_seen[0]));

        $display("[rx] escaped CRC byte (CRC high = C0 for seq=00AB)");
        payload_buf[0] = 8'h90; payload_buf[1] = 8'h3C; payload_buf[2] = 8'h64;
        save_expect(0, 8'h01, 16'h00AB, 3);
        build_frame(8'h01, 16'h00AB, 3);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("escaped CRC err %02h", err_seen[0]));

        $display("[rx] frame_vectors.json TYPE=80 rejection");
        load_vector(5);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h08)
            fail($sformatf("TYPE=80 expected VERSIONTYPE, got %02h", err_seen[0]));
        expect_no_output(0);
        ready_mode[0] = 2'd0;

        $display("[rx] no publish before closing C0");
        payload_buf[0] = 8'h12; payload_buf[1] = 8'h34;
        save_expect(0, 8'h01, 16'd40, 2);
        build_frame(8'h01, 16'd40, 2);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len - 1);   // everything except the trailing C0
        repeat (20) @(negedge clk);
        expect_no_output(0);
        send_byte(0, C0);             // now the frame is complete and checked
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("late-delimiter err %02h", err_seen[0]));

        $display("[rx] garbage prefix before first C0");
        // Return to HUNT so the garbage really is before the first C0.  After a
        // normal frame the closing C0 is also the next frame's shared start
        // delimiter, so non-C0 bytes there would correctly be body bytes.
        flush_one(0, 1'b0);
        payload_buf[0] = 8'h90; payload_buf[1] = 8'h3C; payload_buf[2] = 8'h64;
        save_expect(0, 8'h01, 16'd42, 3);
        wire_clear();
        wire_add(8'h11); wire_add(8'h22); wire_add(8'h7F);
        wire_add(C0); append_frame(8'h01, 16'd42, 3); wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("garbage prefix err %02h", err_seen[0]));

        $display("[rx] consecutive C0 / shared-C0 back-to-back frames");
        wire_clear();
        payload_buf[0] = 8'h90; payload_buf[1] = 8'h3C; payload_buf[2] = 8'h64;
        save_expect(0, 8'h01, 16'd10, 3);
        wire_add(C0); append_frame(8'h01, 16'd10, 3); wire_add(C0);
        wire_add(C0); // consecutive empty frame
        payload_buf[0] = 8'hC0; payload_buf[1] = 8'h01;
        save_expect(1, 8'h01, 16'd11, 2);
        append_frame(8'h01, 16'd11, 2); wire_add(C0); // shares previous C0
        payload_buf[0] = 8'h02;
        save_expect(2, 8'h02, 16'd12, 1);
        append_frame(8'h02, 16'd12, 1); wire_add(C0); // shares previous C0
        payload_buf[0] = 8'hEE; payload_buf[1] = 8'hDD;
        save_expect(3, 8'h02, 16'd13, 2);
        wire_add(C0); append_frame(8'h02, 16'd13, 2); wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        for (v = 0; v < 4; v = v + 1) begin
            recv_frame(0, 0);
            check_frame(0, v);
        end
        if (err_seen[0] !== 8'h00)
            fail($sformatf("multi-frame err %02h", err_seen[0]));

        $display("[rx] bad CRC");
        wire_clear();
        wire_add(C0); wire_add(8'h01); wire_add(8'h01); wire_add(8'h00);
        wire_add(8'h00); wire_add(8'h03); wire_add(8'h00); wire_add(8'h90);
        wire_add(8'h3C); wire_add(8'h64); wire_add(8'hB3); wire_add(8'h4F);
        wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h04)
            fail($sformatf("bad CRC expected 04, got %02h", err_seen[0]));
        expect_no_output(0);
        ready_mode[0] = 2'd0;

        $display("[rx] LEN=17 CONFIG rejection");
        for (int i = 0; i < 17; i = i + 1)
            payload_buf[i] = 8'h10 + i[7:0];
        wire_clear();
        wire_add(C0);
        append_frame_custom(8'h02, 16'd20, 17, 17);
        wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h02)
            fail($sformatf("LEN17 expected 02, got %02h", err_seen[0]));
        expect_no_output(0);
        ready_mode[0] = 2'd0;

        $display("[rx] LEN=33 MIDI rejection");
        for (int i = 0; i < 33; i = i + 1)
            payload_buf[i] = 8'h20 + i[7:0];
        wire_clear();
        wire_add(C0);
        append_frame_custom(8'h01, 16'd21, 33, 33);
        wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h02)
            fail($sformatf("LEN33 expected 02, got %02h", err_seen[0]));
        expect_no_output(0);

        // The oversized frame is discarded; the closing C0 is also the shared
        // start delimiter, so the next valid frame must still be recovered.
        payload_buf[0] = 8'h5C; payload_buf[1] = 8'h5D;
        save_expect(0, 8'h01, 16'd23, 2);
        build_frame(8'h01, 16'd23, 2);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("LEN33 recovery err %02h", err_seen[0]));

        $display("[rx] LEN=0 rejection");
        wire_clear();
        wire_add(C0);
        append_frame_custom(8'h01, 16'd22, 0, 0);
        wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h02)
            fail($sformatf("LEN0 expected 02, got %02h", err_seen[0]));
        expect_no_output(0);
        ready_mode[0] = 2'd0;

        $display("[rx] truncated frame (missing CRC)");
        load_vector(0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, 10); // header + 3 payload bytes, no CRC
        send_byte(0, C0);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h02)
            fail($sformatf("truncation expected 02, got %02h", err_seen[0]));
        expect_no_output(0);
        ready_mode[0] = 2'd0;

        $display("[rx] length underflow (declared 5, actual 3)");
        payload_buf[0] = 8'hA0; payload_buf[1] = 8'hA1; payload_buf[2] = 8'hA2;
        wire_clear();
        wire_add(C0);
        append_frame_custom(8'h01, 16'd30, 5, 3);
        wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h02)
            fail($sformatf("underflow expected 02, got %02h", err_seen[0]));
        expect_no_output(0);
        ready_mode[0] = 2'd0;

        $display("[rx] invalid escape DB 00");
        wire_clear();
        wire_add(C0); wire_add(8'h01); wire_add(8'h01); wire_add(8'h00);
        wire_add(8'h00); wire_add(8'h03); wire_add(8'h00); wire_add(8'h90);
        wire_add(DB); wire_add(8'h00); wire_add(8'h3C); wire_add(8'h64);
        wire_add(8'hB3); wire_add(8'h4E); wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        repeat (8) @(negedge clk);
        if (err_seen[0] !== 8'h01)
            fail($sformatf("invalid escape expected 01, got %02h", err_seen[0]));
        expect_no_output(0);
        ready_mode[0] = 2'd0;

        $display("[rx] invalid DB C0 boundary resync");
        wire_clear();
        wire_add(C0);
        wire_add(8'h01); wire_add(8'h01); wire_add(8'h00); wire_add(8'h00);
        wire_add(8'h03); wire_add(8'h00); wire_add(8'h90);
        wire_add(DB); wire_add(C0);       // illegal escape, C0 is the boundary
        wire_add(C0);                     // leading C0 of the next frame
        payload_buf[0] = 8'h55; payload_buf[1] = 8'h66;
        save_expect(0, 8'h01, 16'd55, 2);
        append_frame(8'h01, 16'd55, 2); wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h01)
            fail($sformatf("DB C0 expected 01, got %02h", err_seen[0]));

        $display("[rx] output held stable under backpressure");
        payload_buf[0] = 8'hDE; payload_buf[1] = 8'hAD; payload_buf[2] = 8'hBE;
        save_expect(0, 8'h01, 16'd77, 3);
        build_frame(8'h01, 16'd77, 3);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        wait_valid(0, 10000);
        for (int i = 0; i < 30; i = i + 1) begin
            @(negedge clk); #1;
            if (!m_valid[0]) fail("held output dropped");
            if ((m_data[0] !== 8'hDE) || (m_type[0] !== 8'h01) ||
                (m_seq[0] !== 16'd77) || (m_len[0] !== 6'd3) ||
                (m_first[0] !== 1'b1) || (m_last[0] !== 1'b0))
                fail("held output changed under stall");
        end
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("backpressure err %02h", err_seen[0]));

        $display("[rx] depth-8 full queue / no overwrite / concurrent pop");
        ready_mode[0] = 2'd1;
        wire_clear();
        for (int k = 0; k < 9; k = k + 1) begin
            payload_buf[0] = (k * 3);
            payload_buf[1] = 8'hA5 ^ k[7:0];
            save_expect(k, 8'h01, 16'd100 + k, 2);
            wire_add(C0); append_frame(8'h01, 16'd100 + k, 2); wire_add(C0);
        end
        err_seen[0] = 8'h00;
        fork
            send_wire(0, wire_len);
            begin
                repeat (2000) @(negedge clk);
                if (s_ready[0] !== 1'b0)
                    fail("queue-full did not backpressure s_ready");
                for (int k = 0; k < 9; k = k + 1) begin
                    recv_frame(0, 0);
                    check_frame(0, k);
                end
            end
        join
        repeat (5) @(negedge clk);
        expect_no_output(0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("queue-full err %02h", err_seen[0]));

        $display("[rx] pin=1 flush retains held head, drops rest");
        payload_buf[0] = 8'h11; payload_buf[1] = 8'h22; payload_buf[2] = 8'h33;
        payload_buf[3] = 8'h44; payload_buf[4] = 8'h55;
        save_expect(0, 8'h01, 16'd200, 5);
        wire_clear();
        wire_add(C0); append_frame(8'h01, 16'd200, 5); wire_add(C0);
        payload_buf[0] = 8'hAA; payload_buf[1] = 8'hBB; payload_buf[2] = 8'hCC;
        save_expect(1, 8'h02, 16'd201, 3);
        wire_add(C0); append_frame(8'h02, 16'd201, 3); wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        collect_head(0, 2, 0);       // consume A[0..1], then hold
        wait_valid(0, 10000);
        if ((m_data[0] !== 8'h33) || (m_type[0] !== 8'h01) ||
            (m_seq[0] !== 16'd200) || (m_len[0] !== 6'd5) ||
            (m_first[0] !== 1'b0) || (m_last[0] !== 1'b0))
            fail("pin setup: wrong held byte");
        flush_one(0, 1'b1);          // pin=1
        if (!m_valid[0]) fail("pin=1 flush dropped held output");
        if ((m_data[0] !== 8'h33) || (m_type[0] !== 8'h01) ||
            (m_seq[0] !== 16'd200) || (m_len[0] !== 6'd5) ||
            (m_first[0] !== 1'b0) || (m_last[0] !== 1'b0))
            fail("pin=1 flush changed held output");
        if (!frame_avail[0]) fail("pin=1 flush dropped retained head");
        for (int i = 0; i < 20; i = i + 1) begin
            @(negedge clk); #1;
            if (!m_valid[0]) fail("pin held output not stable");
            if (m_data[0] !== 8'h33) fail("pin held data changed");
        end
        collect_range(0, 2, 5, 0);
        repeat (6) @(negedge clk);
        expect_no_output(0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("pin flush err %02h", err_seen[0]));

        $display("[rx] pin=1 flush on the last-byte handshake");
        payload_buf[0] = 8'h21; payload_buf[1] = 8'h22;
        save_expect(0, 8'h01, 16'd205, 2);
        wire_clear();
        wire_add(C0); append_frame(8'h01, 16'd205, 2); wire_add(C0);
        payload_buf[0] = 8'h31; payload_buf[1] = 8'h32;
        save_expect(1, 8'h02, 16'd206, 2);
        wire_add(C0); append_frame(8'h02, 16'd206, 2); wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        collect_head(0, 1, 0);        // consume A[0], hold the last byte
        wait_valid(0, 10000);
        if ((m_data[0] !== 8'h22) || (m_type[0] !== 8'h01) ||
            (m_seq[0] !== 16'd205) || (m_len[0] !== 6'd2) ||
            (m_first[0] !== 1'b0) || (m_last[0] !== 1'b1))
            fail("last-byte pin setup mismatch");
        @(negedge clk);
        ready_mode[0] = 2'd0;         // last byte will handshake this cycle
        flush[0] = 1'b1;
        pin[0]   = 1'b1;
        #1;
        @(posedge clk);
        @(negedge clk);
        flush[0] = 1'b0;
        pin[0]   = 1'b0;
        #1;
        expect_no_output(0);
        repeat (8) @(negedge clk);
        expect_no_output(0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("last-byte pin flush err %02h", err_seen[0]));

        $display("[rx] pin=1 flush with a non-last byte handshaking");
        payload_buf[0] = 8'h41; payload_buf[1] = 8'h42; payload_buf[2] = 8'h43;
        save_expect(0, 8'h01, 16'd207, 3);
        wire_clear();
        wire_add(C0); append_frame(8'h01, 16'd207, 3); wire_add(C0);
        payload_buf[0] = 8'h51; payload_buf[1] = 8'h52;
        save_expect(1, 8'h02, 16'd208, 2);
        wire_add(C0); append_frame(8'h02, 16'd208, 2); wire_add(C0);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        collect_head(0, 1, 0);        // consume A[0], hold A[1]
        wait_valid(0, 10000);
        if ((m_data[0] !== 8'h42) || (m_last[0] !== 1'b0))
            fail("non-last pin setup mismatch");
        @(negedge clk);
        ready_mode[0] = 2'd0;         // A[1] hands off on this flush edge
        flush[0] = 1'b1;
        pin[0]   = 1'b1;
        #1;
        @(posedge clk);
        @(negedge clk);
        #1;
        ready_mode[0] = 2'd1;         // hold A[2]
        flush[0] = 1'b0;
        pin[0]   = 1'b0;
        #1;
        if (!frame_avail[0]) fail("non-last pin flush lost retained head");
        wait_valid(0, 10000);
        if ((m_data[0] !== 8'h43) || (m_last[0] !== 1'b1))
            fail("non-last pin flush did not continue head");
        collect_range(0, 2, 3, 0);
        repeat (6) @(negedge clk);
        expect_no_output(0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("non-last pin flush err %02h", err_seen[0]));

        $display("[rx] pin=0 flush drops held + queued, then recovers");
        payload_buf[0] = 8'h01; payload_buf[1] = 8'h02; payload_buf[2] = 8'h03;
        save_expect(0, 8'h01, 16'd210, 3);
        wire_clear();
        wire_add(C0); append_frame(8'h01, 16'd210, 3); wire_add(C0);
        payload_buf[0] = 8'h04; payload_buf[1] = 8'h05;
        save_expect(1, 8'h01, 16'd211, 2);
        wire_add(C0); append_frame(8'h01, 16'd211, 2); wire_add(C0);
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        wait_valid(0, 10000);
        flush_one(0, 1'b0);
        expect_no_output(0);
        repeat (10) @(negedge clk);
        expect_no_output(0);
        payload_buf[0] = 8'h77; payload_buf[1] = 8'h88;
        save_expect(0, 8'h01, 16'd300, 2);
        build_frame(8'h01, 16'd300, 2);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("pin0 recovery err %02h", err_seen[0]));

        $display("[rx] flush during candidate frame");
        payload_buf[0] = 8'h31; payload_buf[1] = 8'h32; payload_buf[2] = 8'h33;
        save_expect(0, 8'h01, 16'd220, 3);
        build_frame(8'h01, 16'd220, 3);
        ready_mode[0] = 2'd1;
        send_wire(0, 6);              // C0 + partial header
        flush_one(0, 1'b0);
        expect_no_output(0);
        payload_buf[0] = 8'h66; payload_buf[1] = 8'h55;
        save_expect(0, 8'h01, 16'd301, 2);
        build_frame(8'h01, 16'd301, 2);
        err_seen[0] = 8'h00;
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("candidate flush err %02h", err_seen[0]));

        $display("[rx] reset in the middle of a frame");
        payload_buf[0] = 8'h41; payload_buf[1] = 8'h42; payload_buf[2] = 8'h43;
        save_expect(0, 8'h01, 16'd230, 3);
        build_frame(8'h01, 16'd230, 3);
        ready_mode[0] = 2'd1;
        send_wire(0, 5);
        rst_n = 1'b0;
        s_valid[0] = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        err_seen[0] = 8'h00;
        repeat (3) @(negedge clk);
        expect_no_output(0);
        payload_buf[0] = 8'h91; payload_buf[1] = 8'h92;
        save_expect(0, 8'h01, 16'd302, 2);
        build_frame(8'h01, 16'd302, 2);
        ready_mode[0] = 2'd1;
        send_wire(0, wire_len);
        recv_frame(0, 0); check_frame(0, 0);
        if (err_seen[0] !== 8'h00)
            fail($sformatf("reset recovery err %02h", err_seen[0]));
    endtask

    // -------------------------------------------------------------------------
    // Timeout tests
    // -------------------------------------------------------------------------
    task automatic run_timeout();
        int k;

        $display("[rx-timeout] empty candidate never times out");
        ready_mode[1] = 2'd1;
        err_seen[1] = 8'h00;
        send_byte(1, C0);            // start, but no body byte
        repeat (100) @(negedge clk);
        if (err_seen[1] !== 8'h00)
            fail($sformatf("empty candidate timed out %02h", err_seen[1]));
        flush_one(1, 1'b0);
        expect_no_output(1);

        $display("[rx-timeout] dangling DB escape is a nonempty partial frame");
        flush_one(1, 1'b0);
        err_seen[1] = 8'h00;
        send_byte(1, C0);
        send_byte(1, DB);
        k = 0;
        while ((k < 200) && ((err_seen[1] & 8'h10) == 8'h00)) begin
            @(negedge clk);
            #1;
            k = k + 1;
        end
        if (err_seen[1] !== 8'h10)
            fail($sformatf("dangling DB expected 10, got %02h", err_seen[1]));
        flush_one(1, 1'b0);

        $display("[rx-timeout] partial frame timeout and recovery");
        for (int i = 0; i < 3; i = i + 1)
            payload_buf[i] = 8'h50 + i[7:0];
        build_frame(8'h01, 16'd400, 3);
        err_seen[1] = 8'h00;
        ready_mode[1] = 2'd1;
        send_wire(1, 5);             // C0 + 4 body bytes, then stop
        k = 0;
        while ((k < 200) && ((err_seen[1] & 8'h10) == 8'h00)) begin
            @(negedge clk);
            #1;
            k = k + 1;
        end
        if (err_seen[1] !== 8'h10)
            fail($sformatf("timeout expected 10, got %02h", err_seen[1]));
        expect_no_output(1);

        // Discard the rest of the junk, then use the terminating C0 as the
        // shared start delimiter for a fresh valid frame.
        send_byte(1, 8'h11);
        send_byte(1, 8'h22);
        send_byte(1, C0);            // end discard, also start next frame
        payload_buf[0] = 8'h5A; payload_buf[1] = 8'h5B;
        save_expect(0, 8'h01, 16'd401, 2);
        wire_clear();
        append_frame(8'h01, 16'd401, 2);
        wire_add(C0);
        err_seen[1] = 8'h00;
        ready_mode[1] = 2'd1;
        send_wire(1, wire_len);
        recv_frame(1, 0); check_frame(1, 0);
        if (err_seen[1] !== 8'h00)
            fail($sformatf("timeout recovery err %02h", err_seen[1]));

        $display("[rx-timeout] full committed queue is not a byte timeout");
        ready_mode[1] = 2'd1;
        wire_clear();
        payload_buf[0] = 8'h61;
        save_expect(0, 8'h01, 16'd500, 1);
        wire_add(C0); append_frame(8'h01, 16'd500, 1); wire_add(C0);
        payload_buf[0] = 8'h62;
        save_expect(1, 8'h01, 16'd501, 1);
        wire_add(C0); append_frame(8'h01, 16'd501, 1); wire_add(C0);
        err_seen[1] = 8'h00;
        send_wire(1, wire_len);
        repeat (150) @(negedge clk);
        if (err_seen[1] !== 8'h00)
            fail($sformatf("full-queue false timeout %02h", err_seen[1]));
        recv_frame(1, 0); check_frame(1, 0);
        recv_frame(1, 0); check_frame(1, 1);
        expect_no_output(1);
    endtask

    // -------------------------------------------------------------------------
    // FRAME_DEPTH=1 tests
    // -------------------------------------------------------------------------
    task automatic run_depth1();
        $display("[rx-depth1] ordered back-to-back frames with full/empty stalls");
        ready_mode[2] = 2'd1;
        wire_clear();
        for (int k = 0; k < 3; k = k + 1) begin
            payload_buf[0] = 8'h70 + k[7:0];
            payload_buf[1] = 8'h80 + k[7:0];
            save_expect(k, 8'h01, 16'd600 + k, 2);
            wire_add(C0); append_frame(8'h01, 16'd600 + k, 2); wire_add(C0);
        end
        err_seen[2] = 8'h00;
        fork
            send_wire(2, wire_len);
            begin
                repeat (200) @(negedge clk);
                if (s_ready[2] !== 1'b0)
                    fail("depth1 full queue did not backpressure");
                for (int k = 0; k < 3; k = k + 1) begin
                    recv_frame(2, 0);
                    check_frame(2, k);
                end
            end
        join
        repeat (5) @(negedge clk);
        expect_no_output(2);
        if (err_seen[2] !== 8'h00)
            fail($sformatf("depth1 err %02h", err_seen[2]));

        $display("[rx-depth1] random output ready, concurrent enqueue/pop");
        ready_mode[2] = 2'd2;
        wire_clear();
        for (int k = 0; k < 5; k = k + 1) begin
            payload_buf[0] = 8'h90 ^ k[7:0];
            payload_buf[1] = 8'hA5 + k[7:0];
            payload_buf[2] = 8'h5A ^ k[7:0];
            save_expect(k, 8'h02, 16'd700 + k, 3);
            wire_add(C0); append_frame(8'h02, 16'd700 + k, 3); wire_add(C0);
        end
        err_seen[2] = 8'h00;
        fork
            send_wire(2, wire_len);
            begin
                for (int k = 0; k < 5; k = k + 1) begin
                    recv_frame(2, 2);
                    check_frame(2, k);
                end
            end
        join
        ready_mode[2] = 2'd1;
        repeat (5) @(negedge clk);
        expect_no_output(2);
        if (err_seen[2] !== 8'h00)
            fail($sformatf("depth1 random err %02h", err_seen[2]));
    endtask

    // -------------------------------------------------------------------------
    // Top-level sequencing
    // -------------------------------------------------------------------------
    initial begin
        errors = 0;
        wire_len = 0;
        for (int i = 0; i < MAX_SLOTS; i = i + 1) begin
            exp_len[i] = 0;
            exp_typ[i] = 8'h00;
            exp_seq[i] = 16'h0000;
        end
        for (int i = 0; i < N; i = i + 1) begin
            ready_mode[i] = 2'd0;
            err_seen[i] = 8'h00;
            rx_count[i] = 0;
        end

        do_reset();
        run_main();
        run_timeout();
        run_depth1();

        repeat (20) @(negedge clk);
        if (errors == 0)
            $display("TB_SLIP_FRAME_RX: PASS");
        else
            $display("TB_SLIP_FRAME_RX: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
