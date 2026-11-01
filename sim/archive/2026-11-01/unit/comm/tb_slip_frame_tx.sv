`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_slip_frame_tx -- self-checking unit test for slip_frame_tx.
//
// Covers: the TYPE=80/LEN=3 standard reply vector, escaped header/seq/CRC
// bytes, CRC-escape search case, random output stalls, descriptor backpressure
// (s_ready stays low until the trailing C0 is handed off), maintenance flush,
// and reset in mid-frame.
// -----------------------------------------------------------------------------
module tb_slip_frame_tx;

    import comm_pkg::*;

    localparam logic [7:0] C0 = 8'hC0;
    localparam logic [7:0] DB = 8'hDB;
    localparam logic [7:0] DC = 8'hDC;
    localparam logic [7:0] DD = 8'hDD;

    logic clk;
    logic rst_n;
    logic flush;

    logic        s_valid;
    logic        s_ready;
    logic [15:0] s_seq;
    logic [7:0]  s_command;
    logic [7:0]  s_result;

    logic        m_valid;
    logic        m_ready;
    logic [7:0]  m_data;
    logic        busy;

    logic [1:0] ready_mode;   // 0=always ready, 1=hold, 2=random
    logic       rnd_ready;

    int errors;

    logic [7:0] exp_buf [0:63];
    int         exp_len;
    logic [7:0] got_buf [0:63];
    int         got_len;
    logic       expect_sready_low;

    assign m_ready = !rst_n ? 1'b0 :
                     (ready_mode == 2'd0) ? 1'b1 :
                     (ready_mode == 2'd1) ? 1'b0 : rnd_ready;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(negedge clk)
        rnd_ready <= $urandom_range(0, 1);

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    slip_frame_tx dut (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_seq(s_seq), .s_command(s_command), .s_result(s_result),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data),
        .busy(busy)
    );

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    task automatic fail(input string msg);
        errors = errors + 1;
        $display("  ERROR: %s (time=%0t)", msg, $time);
    endtask

    function automatic logic [15:0] reply_crc(
        input logic [15:0] seq, input logic [7:0] cmd, input logic [7:0] res
    );
        logic [15:0] c;
        begin
            c = 16'hFFFF;
            c = crc16_byte(c, 8'h01);
            c = crc16_byte(c, 8'h80);
            c = crc16_byte(c, seq[7:0]);
            c = crc16_byte(c, seq[15:8]);
            c = crc16_byte(c, 8'h03);
            c = crc16_byte(c, 8'h00);
            c = crc16_byte(c, 8'h02);
            c = crc16_byte(c, cmd);
            c = crc16_byte(c, res);
            reply_crc = c;
        end
    endfunction

    task automatic exp_add(input logic [7:0] b);
        exp_buf[exp_len] = b;
        exp_len = exp_len + 1;
    endtask

    task automatic exp_add_esc(input logic [7:0] b);
        if (b == C0) begin
            exp_add(DB); exp_add(DC);
        end else if (b == DB) begin
            exp_add(DB); exp_add(DD);
        end else begin
            exp_add(b);
        end
    endtask

    task automatic build_expected(
        input logic [15:0] seq, input logic [7:0] cmd, input logic [7:0] res
    );
        logic [15:0] c;
        logic [7:0] b [0:10];
        c = reply_crc(seq, cmd, res);
        b[0]  = 8'h01;
        b[1]  = 8'h80;
        b[2]  = seq[7:0];
        b[3]  = seq[15:8];
        b[4]  = 8'h03;
        b[5]  = 8'h00;
        b[6]  = 8'h02;
        b[7]  = cmd;
        b[8]  = res;
        b[9]  = c[7:0];
        b[10] = c[15:8];

        exp_len = 0;
        exp_add(C0);
        for (int i = 0; i < 11; i = i + 1)
            exp_add_esc(b[i]);
        exp_add(C0);
    endtask

    task automatic do_reset();
        rst_n = 1'b0;
        flush = 1'b0;
        s_valid = 1'b0;
        s_seq = 16'h0000;
        s_command = 8'h00;
        s_result = 8'h00;
        ready_mode = 2'd0;
        expect_sready_low = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
    endtask

    task automatic send_desc(
        input logic [15:0] seq, input logic [7:0] cmd, input logic [7:0] res
    );
        @(negedge clk);
        s_valid   = 1'b1;
        s_seq     = seq;
        s_command = cmd;
        s_result  = res;
        #1;
        while (!s_ready) begin
            @(negedge clk);
            #1;
        end
        @(posedge clk);          // descriptor accepted
        @(negedge clk);
        s_valid = 1'b0;
        #1;
    endtask

    task automatic wait_mvalid(input int maxc);
        int n;
        n = 0;
        while (!m_valid) begin
            @(negedge clk);
            #1;
            n = n + 1;
            if (n > maxc) begin
                fail("wait_mvalid timeout");
                disable wait_mvalid;
            end
        end
    endtask

    // Collect n UART bytes, checking that valid/data are stable while stalled.
    // starts by holding, then releases the selected ready mode at a negedge so
    // no byte can handshake before it is sampled.
    task automatic recv_n(input int n, input int mode);
        int idx;
        int guard;
        logic stalled;
        logic [7:0] snap;

        ready_mode = 2'd1;
        idx = 0; guard = 0; stalled = 1'b0;

        while (idx < n) begin
            @(negedge clk);
            if (idx == 0 && !stalled)
                ready_mode = mode[1:0];
            #1;
            guard = guard + 1;
            if (guard > 250000) begin
                fail($sformatf("recv_n timeout idx=%0d/%0d", idx, n));
                disable recv_n;
            end

            if (m_valid) begin
                if (!stalled) begin
                    snap = m_data;
                end else begin
                    if (m_data !== snap)
                        fail($sformatf("TX output changed while stalled idx=%0d", idx));
                end

                if (expect_sready_low && s_ready)
                    fail($sformatf("s_ready high while busy idx=%0d", idx));

                if (m_ready) begin
                    got_buf[idx] = m_data;
                    idx = idx + 1;
                    stalled = 1'b0;
                    if (idx == n) begin
                        @(posedge clk);   // final wire byte handshake
                        #1;
                        got_len = idx;
                        ready_mode = 2'd1;
                        disable recv_n;
                    end
                end else begin
                    stalled = 1'b1;
                end
            end else if (stalled) begin
                fail($sformatf("TX m_valid withdrawn under stall idx=%0d", idx));
                stalled = 1'b0;
            end
        end
    endtask

    task automatic check_frame();
        if (got_len != exp_len)
            fail($sformatf("wire length got=%0d exp=%0d", got_len, exp_len));
        for (int i = 0; i < exp_len; i = i + 1) begin
            if (got_buf[i] !== exp_buf[i])
                fail($sformatf("wire[%0d] got=%02h exp=%02h", i, got_buf[i], exp_buf[i]));
        end
    endtask

    task automatic run_reply(
        input logic [15:0] seq, input logic [7:0] cmd, input logic [7:0] res,
        input int mode
    );
        build_expected(seq, cmd, res);
        send_desc(seq, cmd, res);
        #1;
        if (!busy) fail("busy did not assert after descriptor accept");
        if (s_ready) fail("s_ready high while encoding");
        got_len = exp_len;
        recv_n(exp_len, mode);
        check_frame();
        #1;
        if (busy) fail("busy did not deassert after trailing C0");
        if (!s_ready) fail("s_ready did not return after trailing C0");
    endtask

    task automatic flush_one();
        @(negedge clk);
        flush = 1'b1;
        #1;
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        #1;
    endtask

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------
    initial begin
        errors = 0;
        exp_len = 0;
        got_len = 0;
        do_reset();

        $display("[tx] standard REPLY vector (SEQ=1, cmd=2, res=0)");
        build_expected(16'd1, 8'h02, 8'h00);
        if (exp_len != 13) fail("standard wire length is not 13");
        if ((exp_buf[0]  !== 8'hC0) || (exp_buf[1]  !== 8'h01) ||
            (exp_buf[2]  !== 8'h80) || (exp_buf[3]  !== 8'h01) ||
            (exp_buf[4]  !== 8'h00) || (exp_buf[5]  !== 8'h03) ||
            (exp_buf[6]  !== 8'h00) || (exp_buf[7]  !== 8'h02) ||
            (exp_buf[8]  !== 8'h02) || (exp_buf[9]  !== 8'h00) ||
            (exp_buf[10] !== 8'h61) || (exp_buf[11] !== 8'h50) ||
            (exp_buf[12] !== 8'hC0))
            fail("standard reply does not match frame_vectors.json config_ack");
        send_desc(16'd1, 8'h02, 8'h00);
        #1;
        if (!busy) fail("standard: busy low after accept");
        if (s_ready) fail("standard: s_ready high while busy");
        got_len = exp_len;
        recv_n(exp_len, 0);
        check_frame();
        #1;
        if (busy) fail("standard: busy high after finish");
        if (!s_ready) fail("standard: s_ready low after finish");

        $display("[tx] escaped seq/header/result/CRC cases");
        run_reply(16'h1BC0, 8'hDB, 8'hC0, 0);  // seq_lo, cmd, res, crc_lo escape
        run_reply(16'hDBC0, 8'hDB, 8'hC0, 0);  // seq_lo, seq_hi, cmd, res escape
        run_reply(16'd9,   8'hC0, 8'h01, 0);   // cmd and CRC high escape

        // Independent hard-coded reference for the first escaped case:
        // seq=1BC0 cmd=DB res=C0, CRC=31C0.
        build_expected(16'h1BC0, 8'hDB, 8'hC0);
        if (exp_len != 17) fail("escaped reference length is not 17");
        if ((exp_buf[0]  !== 8'hC0) || (exp_buf[1]  !== 8'h01) ||
            (exp_buf[2]  !== 8'h80) || (exp_buf[3]  !== 8'hDB) ||
            (exp_buf[4]  !== 8'hDC) || (exp_buf[5]  !== 8'h1B) ||
            (exp_buf[6]  !== 8'h03) || (exp_buf[7]  !== 8'h00) ||
            (exp_buf[8]  !== 8'h02) || (exp_buf[9]  !== 8'hDB) ||
            (exp_buf[10] !== 8'hDD) || (exp_buf[11] !== 8'hDB) ||
            (exp_buf[12] !== 8'hDC) || (exp_buf[13] !== 8'hDB) ||
            (exp_buf[14] !== 8'hDC) || (exp_buf[15] !== 8'h31) ||
            (exp_buf[16] !== 8'hC0))
            fail("escaped reference bytes do not match independent calculation");

        $display("[tx] CRC-escape search case");
        begin
            int found;
            logic [15:0] c;
            found = -1;
            for (int s = 0; s < 8192; s = s + 1) begin
                c = reply_crc(s[15:0], 8'h02, 8'h00);
                if ((c[7:0] == C0) || (c[7:0] == DB) ||
                    (c[15:8] == C0) || (c[15:8] == DB)) begin
                    found = s;
                    break;
                end
            end
            if (found < 0)
                fail("no CRC-escape descriptor found");
            else begin
                build_expected(found[15:0], 8'h02, 8'h00);
                if (exp_len == 13)
                    fail("searched CRC-escape case did not actually escape");
                send_desc(found[15:0], 8'h02, 8'h00);
                got_len = exp_len;
                recv_n(exp_len, 0);
                check_frame();
            end
        end

        $display("[tx] random output stalls");
        for (int k = 0; k < 4; k = k + 1) begin
            run_reply(16'd1000 + k, 8'h10 + k[7:0], 8'h30 + k[7:0], 2);
        end

        $display("[tx] deterministic long output stall");
        build_expected(16'd200, 8'hC0, 8'hDB);
        send_desc(16'd200, 8'hC0, 8'hDB);
        ready_mode = 2'd1;
        #1;
        wait_mvalid(10000);
        for (int i = 0; i < 30; i = i + 1) begin
            @(negedge clk); #1;
            if (!m_valid) fail("long stall: m_valid dropped");
            if (m_data !== C0) fail("long stall: first byte changed");
            if (s_ready) fail("long stall: s_ready high");
        end
        got_len = exp_len;
        recv_n(exp_len, 0);
        check_frame();
        #1;
        if (busy) fail("long stall: busy high after finish");

        $display("[tx] descriptor backpressure during an in-flight reply");
        build_expected(16'd10, 8'h11, 8'h12);
        begin
            logic [7:0] exp2 [0:63];
            int exp2_len;

            // frame 1
            send_desc(16'd10, 8'h11, 8'h12);
            // hold descriptor 2 while frame 1 is still encoding
            @(negedge clk);
            s_valid   = 1'b1;
            s_seq     = 16'd20;
            s_command = 8'h21;
            s_result  = 8'h22;
            #1;
            if (s_ready) fail("second descriptor accepted while busy");
            expect_sready_low = 1'b1;
            got_len = exp_len;
            recv_n(exp_len, 0);          // frame 1 finishes; desc2 still held
            check_frame();
            expect_sready_low = 1'b0;
            #1;
            if (!s_ready) fail("s_ready did not assert after frame 1");
            @(posedge clk);              // descriptor 2 accepted
            @(negedge clk);
            s_valid = 1'b0;
            #1;

            // frame 2
            build_expected(16'd20, 8'h21, 8'h22);
            for (int i = 0; i < exp_len; i = i + 1) exp2[i] = exp_buf[i];
            exp2_len = exp_len;
            got_len = exp2_len;
            recv_n(exp2_len, 0);
            if (got_len != exp2_len) fail("frame2 length mismatch");
            for (int i = 0; i < exp2_len; i = i + 1)
                if (got_buf[i] !== exp2[i])
                    fail($sformatf("frame2 wire[%0d] got=%02h exp=%02h",
                                   i, got_buf[i], exp2[i]));
            #1;
            if (busy) fail("frame2 still busy after finish");
        end

        $display("[tx] flush cancels in-flight encoding");
        build_expected(16'd30, 8'h31, 8'h32);
        send_desc(16'd30, 8'h31, 8'h32);
        got_len = 3;
        recv_n(3, 0);                    // consume 3 wire bytes, then hold
        wait_mvalid(10000);
        flush_one();
        #1;
        if (busy) fail("busy high after flush");
        if (m_valid) fail("m_valid high after flush");
        if (!s_ready) fail("s_ready low after flush");
        repeat (10) @(negedge clk);
        if (m_valid) fail("stale TX byte after flush");
        if (busy) fail("stale busy after flush");

        $display("[tx] flush while idle then new reply");
        @(negedge clk);
        flush = 1'b1;
        #1;
        if (s_ready) fail("s_ready high during idle flush");
        @(posedge clk);
        @(negedge clk);
        flush = 1'b0;
        #1;
        if (!s_ready) fail("s_ready not restored after idle flush");
        run_reply(16'd40, 8'h41, 8'h42, 0);

        $display("[tx] reset in mid-frame");
        build_expected(16'd50, 8'h51, 8'h52);
        send_desc(16'd50, 8'h51, 8'h52);
        got_len = 4;
        recv_n(4, 0);
        rst_n = 1'b0;
        s_valid = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);
        if (busy) fail("busy high after reset");
        if (m_valid) fail("m_valid high after reset");
        if (!s_ready) fail("s_ready low after reset");
        run_reply(16'd60, 8'h61, 8'h62, 0);

        repeat (10) @(negedge clk);
        if (errors == 0)
            $display("TB_SLIP_FRAME_TX: PASS");
        else
            $display("TB_SLIP_FRAME_TX: FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
