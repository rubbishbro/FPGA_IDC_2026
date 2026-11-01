`timescale 1ns/1ps
// Self-checking testbench for midi_analyzer.
//
// All stimulus is driven on negedge clk; all checks are made on negedge or in
// a posedge monitor that reads the pre-edge registered outputs. There are no
// tasks called directly on a posedge with zero delay.

module tb_midi_analyzer;

    localparam logic [3:0] K_OFF = 4'd0;
    localparam logic [3:0] K_ON  = 4'd1;
    localparam logic [3:0] K_CC  = 4'd2;
    localparam logic [3:0] K_PRG = 4'd3;
    localparam logic [3:0] K_BND = 4'd4;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic flush = 1'b0;

    logic        s_valid = 1'b0;
    logic        s_ready;
    logic [7:0]  s_data = 8'd0;
    logic        s_first = 1'b0;
    logic        s_last = 1'b0;
    logic        s_source_id = 1'b0;
    logic [5:0]  s_payload_len = 6'd0;

    logic        event_valid;
    logic        event_ready = 1'b1;
    logic [31:0] event_data;
    logic        event_source_id;

    logic        frame_done;
    logic        parse_error;
    logic        busy;

    int errors;
    int ev_hs;
    int fd_cnt;
    int pe_cnt;

    logic [32:0] exp_mem [0:8191];
    int exp_wr;
    int exp_rd;

    logic [7:0] fb [0:63];

    always #5 clk = ~clk;

    midi_analyzer dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .flush           (flush),
        .s_valid         (s_valid),
        .s_ready         (s_ready),
        .s_data          (s_data),
        .s_first         (s_first),
        .s_last          (s_last),
        .s_source_id     (s_source_id),
        .s_payload_len   (s_payload_len),
        .event_valid     (event_valid),
        .event_ready     (event_ready),
        .event_data      (event_data),
        .event_source_id (event_source_id),
        .frame_done      (frame_done),
        .parse_error     (parse_error),
        .busy            (busy)
    );

    // ------------------------------------------------------------------
    // Event handshake monitor: active-region read at posedge sees the
    // pre-edge (currently offered) registered event.
    // ------------------------------------------------------------------
    logic [32:0] got_ev;
    always @(posedge clk) begin
        if (rst_n && !flush && event_valid && event_ready) begin
            got_ev = {event_source_id, event_data};
            if (exp_rd >= exp_wr) begin
                errors = errors + 1;
                $display("[%0t] FAIL: unexpected event %09x", $time, got_ev);
            end else if (got_ev !== exp_mem[exp_rd]) begin
                errors = errors + 1;
                $display("[%0t] FAIL: event %09x expected %09x",
                         $time, got_ev, exp_mem[exp_rd]);
            end
            exp_rd = exp_rd + 1;
            ev_hs  = ev_hs + 1;
        end
    end

    // Stable pulse counters and structural ordering checks.
    always @(negedge clk) begin
        if (rst_n && !flush) begin
            if (frame_done) begin
                fd_cnt = fd_cnt + 1;
                if (event_valid) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL: frame_done while event pending", $time);
                end
            end
            if (parse_error) pe_cnt = pe_cnt + 1;
        end
    end

    // ------------------------------------------------------------------
    // Small helpers
    // ------------------------------------------------------------------
    function automatic logic [31:0] mk(
        input logic [3:0] kind,
        input logic [3:0] ch,
        input logic [6:0] d1,
        input logic [6:0] d2
    );
        mk = {kind, ch, d1, d2, 10'b0};
    endfunction

    task automatic fail_msg(input string msg);
        begin
            errors = errors + 1;
            $display("[%0t] FAIL: %s", $time, msg);
        end
    endtask

    task automatic expect_event(input logic [31:0] data, input logic src);
        begin
            exp_mem[exp_wr] = {src, data};
            exp_wr = exp_wr + 1;
        end
    endtask

    // Drive one payload byte and wait for its accepted handshake.
    task automatic send_byte(
        input logic [7:0] b,
        input logic first,
        input logic lastb,
        input logic src,
        input logic [5:0] len
    );
        begin
            @(negedge clk);
            s_valid       = 1'b1;
            s_data        = b;
            s_first       = first;
            s_last        = lastb;
            s_source_id   = src;
            s_payload_len = len;
            while (!s_ready) @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            s_valid = 1'b0;
            s_first = 1'b0;
            s_last  = 1'b0;
        end
    endtask

    task automatic send_loaded_frame(
        input logic src,
        input int n,
        input logic [5:0] decl_len
    );
        int i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                send_byte(fb[i], (i == 0), (i == (n - 1)), src, decl_len);
            end
        end
    endtask

    task automatic wait_frame_done;
        int c;
        begin
            c = 0;
            while (!frame_done && (c < 5000)) begin
                @(negedge clk);
                c = c + 1;
            end
            if (c >= 5000) fail_msg("timeout waiting for frame_done");
        end
    endtask

    task automatic wait_idle;
        int c;
        begin
            c = 0;
            while (busy && (c < 5000)) begin
                @(negedge clk);
                c = c + 1;
            end
            if (c >= 5000) fail_msg("timeout waiting for idle");
        end
    endtask

    task automatic check_frame_counts(
        input int ev0,
        input int fd0,
        input int pe0,
        input int exp_ev,
        input int exp_err,
        input string tag
    );
        begin
            if ((ev_hs - ev0) != exp_ev) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %s event count %0d expected %0d",
                         $time, tag, ev_hs - ev0, exp_ev);
            end
            if ((fd_cnt - fd0) != 1) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %s frame_done count %0d expected 1",
                         $time, tag, fd_cnt - fd0);
            end
            if ((pe_cnt - pe0) != exp_err) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %s parse_error count %0d expected %0d",
                         $time, tag, pe_cnt - pe0, exp_err);
            end
        end
    endtask

    task automatic frame_check(
        input logic src,
        input int n,
        input logic [5:0] decl_len,
        input int exp_ev,
        input int exp_err,
        input string tag
    );
        int ev0;
        int fd0;
        int pe0;
        begin
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            send_loaded_frame(src, n, decl_len);
            wait_frame_done();
            wait_idle();
            check_frame_counts(ev0, fd0, pe0, exp_ev, exp_err, tag);
        end
    endtask

    // ------------------------------------------------------------------
    // Contract table and protocol edge vectors
    // ------------------------------------------------------------------
    task automatic test_basic_table;
        begin
            // 90 3C 64 80 3C 40
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'h80; fb[4] = 8'h3C; fb[5] = 8'h40;
            expect_event(mk(K_ON,  4'd0, 7'd60, 7'd100), 1'b0);
            expect_event(mk(K_OFF, 4'd0, 7'd60, 7'd64),  1'b0);
            frame_check(1'b0, 6, 6'd6, 2, 0, "note on/off");

            // 90 3C 00 -> Note Off, velocity normalised to zero
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h00;
            expect_event(mk(K_OFF, 4'd0, 7'd60, 7'd0), 1'b1);
            frame_check(1'b1, 3, 6'd3, 1, 0, "zero velocity");

            // 90 3C 64 3E 50 -> running status
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'h3E; fb[4] = 8'h50;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            expect_event(mk(K_ON, 4'd0, 7'd62, 7'd80),  1'b0);
            frame_check(1'b0, 5, 6'd5, 2, 0, "running note on");

            // C0 05 06 -> running program change
            fb[0] = 8'hC0; fb[1] = 8'h05; fb[2] = 8'h06;
            expect_event(mk(K_PRG, 4'd0, 7'd5, 7'd0), 1'b1);
            expect_event(mk(K_PRG, 4'd0, 7'd6, 7'd0), 1'b1);
            frame_check(1'b1, 3, 6'd3, 2, 0, "running program change");

            // 90 3C F8 64 3E 50 -> realtime inserted mid-message
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'hF8;
            fb[3] = 8'h64; fb[4] = 8'h3E; fb[5] = 8'h50;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            expect_event(mk(K_ON, 4'd0, 7'd62, 7'd80),  1'b0);
            frame_check(1'b0, 6, 6'd6, 2, 0, "realtime F8");

            // 90 3C FF 64 -> System Reset is realtime, not private reset
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'hFF; fb[3] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 4, 6'd4, 1, 0, "realtime FF");

            // 80 3C 40 3D 41 -> running Note Off, release velocity kept
            fb[0] = 8'h80; fb[1] = 8'h3C; fb[2] = 8'h40;
            fb[3] = 8'h3D; fb[4] = 8'h41;
            expect_event(mk(K_OFF, 4'd0, 7'd60, 7'd64), 1'b1);
            expect_event(mk(K_OFF, 4'd0, 7'd61, 7'd65), 1'b1);
            frame_check(1'b1, 5, 6'd5, 2, 0, "running note off");

            // B0 07 64 0B 40 -> supported CC via running status
            fb[0] = 8'hB0; fb[1] = 8'h07; fb[2] = 8'h64;
            fb[3] = 8'h0B; fb[4] = 8'h40;
            expect_event(mk(K_CC, 4'd0, 7'd7, 7'd100), 1'b0);
            expect_event(mk(K_CC, 4'd0, 7'd11, 7'd64), 1'b0);
            frame_check(1'b0, 5, 6'd5, 2, 0, "running supported CC");

            // E0 00 40
            fb[0] = 8'hE0; fb[1] = 8'h00; fb[2] = 8'h40;
            expect_event(mk(K_BND, 4'd0, 7'd0, 7'd64), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "bend centre");

            // E0 00 00 E0 7F 7F
            fb[0] = 8'hE0; fb[1] = 8'h00; fb[2] = 8'h00;
            fb[3] = 8'hE0; fb[4] = 8'h7F; fb[5] = 8'h7F;
            expect_event(mk(K_BND, 4'd0, 7'd0,  7'd0),   1'b1);
            expect_event(mk(K_BND, 4'd0, 7'd127, 7'd127), 1'b1);
            frame_check(1'b1, 6, 6'd6, 2, 0, "bend min/max");

            // B0 01 20 B0 07 60 B0 0B 40
            fb[0] = 8'hB0; fb[1] = 8'h01; fb[2] = 8'h20;
            fb[3] = 8'hB0; fb[4] = 8'h07; fb[5] = 8'h60;
            fb[6] = 8'hB0; fb[7] = 8'h0B; fb[8] = 8'h40;
            expect_event(mk(K_CC, 4'd0, 7'd1,  7'h20), 1'b0);
            expect_event(mk(K_CC, 4'd0, 7'd7,  7'h60), 1'b0);
            expect_event(mk(K_CC, 4'd0, 7'd11, 7'h40), 1'b0);
            frame_check(1'b0, 9, 6'd9, 3, 0, "CC1/7/11");

            // B0 40 3F B0 40 40
            fb[0] = 8'hB0; fb[1] = 8'h40; fb[2] = 8'h3F;
            fb[3] = 8'hB0; fb[4] = 8'h40; fb[5] = 8'h40;
            expect_event(mk(K_CC, 4'd0, 7'd64, 7'h3F), 1'b1);
            expect_event(mk(K_CC, 4'd0, 7'd64, 7'h40), 1'b1);
            frame_check(1'b1, 6, 6'd6, 2, 0, "CC64 off/on");

            // B0 7B 00 B0 78 00
            fb[0] = 8'hB0; fb[1] = 8'h7B; fb[2] = 8'h00;
            fb[3] = 8'hB0; fb[4] = 8'h78; fb[5] = 8'h00;
            expect_event(mk(K_CC, 4'd0, 7'd123, 7'd0), 1'b0);
            expect_event(mk(K_CC, 4'd0, 7'd120, 7'd0), 1'b0);
            frame_check(1'b0, 6, 6'd6, 2, 0, "CC123/120");

            // D0 10 20 90 3C 64
            fb[0] = 8'hD0; fb[1] = 8'h10; fb[2] = 8'h20;
            fb[3] = 8'h90; fb[4] = 8'h3C; fb[5] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 6, 6'd6, 1, 0, "channel pressure skip");

            // A0 3C 20 3D 30 90 40 64
            fb[0] = 8'hA0; fb[1] = 8'h3C; fb[2] = 8'h20;
            fb[3] = 8'h3D; fb[4] = 8'h30;
            fb[5] = 8'h90; fb[6] = 8'h40; fb[7] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd64, 7'd100), 1'b0);
            frame_check(1'b0, 8, 6'd8, 1, 0, "poly pressure skip");

            // F0 7D 01 F8 02 F7 90 3C 64
            fb[0] = 8'hF0; fb[1] = 8'h7D; fb[2] = 8'h01;
            fb[3] = 8'hF8; fb[4] = 8'h02; fb[5] = 8'hF7;
            fb[6] = 8'h90; fb[7] = 8'h3C; fb[8] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 9, 6'd9, 1, 0, "SysEx skip plus realtime");

            // F0 7D 01 90 3C 64 -> new channel status terminates SysEx
            fb[0] = 8'hF0; fb[1] = 8'h7D; fb[2] = 8'h01;
            fb[3] = 8'h90; fb[4] = 8'h3C; fb[5] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 6, 6'd6, 1, 0, "SysEx terminated by status");

            // 90 3C F2 00 00 3E 50
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'hF2;
            fb[3] = 8'h00; fb[4] = 8'h00; fb[5] = 8'h3E;
            fb[6] = 8'h50;
            frame_check(1'b1, 7, 6'd7, 0, 3, "F2 aborts partial, orphans");

            // 90 3C 90 3D 64
            fb[0] = 8'h90; fb[1] = 8'h3C;
            fb[2] = 8'h90; fb[3] = 8'h3D; fb[4] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd61, 7'd100), 1'b0);
            frame_check(1'b0, 5, 6'd5, 1, 1, "status interrupts partial");

            // 90 3C 00 3D 40 -> running status, zero velocity then note on
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h00;
            fb[3] = 8'h3D; fb[4] = 8'h40;
            expect_event(mk(K_OFF, 4'd0, 7'd60, 7'd0),  1'b1);
            expect_event(mk(K_ON,  4'd0, 7'd61, 7'd64), 1'b1);
            frame_check(1'b1, 5, 6'd5, 2, 0, "running zero velocity");

            // B0 05 7F 07 64 -> unsupported CC ignored, running retained
            fb[0] = 8'hB0; fb[1] = 8'h05; fb[2] = 8'h7F;
            fb[3] = 8'h07; fb[4] = 8'h64;
            expect_event(mk(K_CC, 4'd0, 7'd7, 7'h64), 1'b0);
            frame_check(1'b0, 5, 6'd5, 1, 0, "unsupported CC running");

            // B0 78 01 78 00 -> CC120 non-zero ignored, zero emitted
            fb[0] = 8'hB0; fb[1] = 8'h78; fb[2] = 8'h01;
            fb[3] = 8'h78; fb[4] = 8'h00;
            expect_event(mk(K_CC, 4'd0, 7'd120, 7'd0), 1'b1);
            frame_check(1'b1, 5, 6'd5, 1, 0, "CC120 non-zero ignored");

            // E0 00 00 7F 7F -> running bend
            fb[0] = 8'hE0; fb[1] = 8'h00; fb[2] = 8'h00;
            fb[3] = 8'h7F; fb[4] = 8'h7F;
            expect_event(mk(K_BND, 4'd0, 7'd0,   7'd0),   1'b0);
            expect_event(mk(K_BND, 4'd0, 7'd127, 7'd127), 1'b0);
            frame_check(1'b0, 5, 6'd5, 2, 0, "running bend");

            // F6 / F7 / F4 / F5 single-byte frames
            fb[0] = 8'hF6;
            frame_check(1'b0, 1, 6'd1, 0, 0, "F6 single");
            fb[0] = 8'hF7;
            frame_check(1'b1, 1, 6'd1, 0, 0, "F7 single");
            fb[0] = 8'hF4;
            frame_check(1'b0, 1, 6'd1, 0, 0, "F4 single");
            fb[0] = 8'hF5;
            frame_check(1'b1, 1, 6'd1, 0, 0, "F5 single");

            // System Common data consumption followed by a new message
            fb[0] = 8'hF1; fb[1] = 8'h01; fb[2] = 8'h90;
            fb[3] = 8'h3C; fb[4] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 5, 6'd5, 1, 0, "F1 consumes one");

            fb[0] = 8'hF2; fb[1] = 8'h00; fb[2] = 8'h40;
            fb[3] = 8'h90; fb[4] = 8'h3C; fb[5] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 6, 6'd6, 1, 0, "F2 consumes two");

            fb[0] = 8'hF3; fb[1] = 8'h05; fb[2] = 8'h90;
            fb[3] = 8'h3C; fb[4] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 5, 6'd5, 1, 0, "F3 consumes one");

            // Truncated System Common
            fb[0] = 8'hF2; fb[1] = 8'h00;
            frame_check(1'b1, 2, 6'd2, 0, 1, "F2 truncated");

            // Realtime reserved bytes F9/FD/FE/FF preserve pending
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'hF9;
            fb[3] = 8'h64; fb[4] = 8'hFD; fb[5] = 8'h3E;
            fb[6] = 8'hFE; fb[7] = 8'h50; fb[8] = 8'hFF;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            expect_event(mk(K_ON, 4'd0, 7'd62, 7'd80),  1'b0);
            frame_check(1'b0, 9, 6'd9, 2, 0, "reserved realtime");

            // Entire F8..FF realtime range is ignored before a message
            fb[0] = 8'hF8; fb[1] = 8'hF9; fb[2] = 8'hFA;
            fb[3] = 8'hFB; fb[4] = 8'hFC; fb[5] = 8'hFD;
            fb[6] = 8'hFE; fb[7] = 8'hFF; fb[8] = 8'h90;
            fb[9] = 8'h3C; fb[10] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 11, 6'd11, 1, 0, "all realtime values");

            // Realtime inside SysEx
            fb[0] = 8'hF0; fb[1] = 8'h01; fb[2] = 8'hF9;
            fb[3] = 8'h02; fb[4] = 8'hFD; fb[5] = 8'hF7;
            fb[6] = 8'h90; fb[7] = 8'h3C; fb[8] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 9, 6'd9, 1, 0, "realtime in SysEx");

            // Unclosed SysEx at frame end
            fb[0] = 8'hF0; fb[1] = 8'h7D; fb[2] = 8'h01;
            frame_check(1'b0, 3, 6'd3, 0, 1, "unclosed SysEx");

            // Complete event retained, then a truncated new message
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'h90; fb[4] = 8'h3D;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 5, 6'd5, 1, 1, "prior event not rolled back");

            // Complete event retained, then running data left incomplete
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'h3D;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 4, 6'd4, 1, 1, "prior running event kept");

            // F6 clears pending and running status
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'hF6;
            fb[3] = 8'h3D; fb[4] = 8'h64;
            frame_check(1'b1, 5, 6'd5, 0, 3, "F6 clears pending/running");
        end
    endtask

    task automatic test_more_running;
        begin
            // A running status: two ignored messages, no error
            fb[0] = 8'hA0; fb[1] = 8'h3C; fb[2] = 8'h20;
            fb[3] = 8'h3D; fb[4] = 8'h30;
            frame_check(1'b0, 5, 6'd5, 0, 0, "running poly pressure");

            // D running status: two ignored messages, no error
            fb[0] = 8'hD0; fb[1] = 8'h10; fb[2] = 8'h20;
            frame_check(1'b1, 3, 6'd3, 0, 0, "running channel pressure");

            // Orphan data frame
            fb[0] = 8'h00; fb[1] = 8'h01; fb[2] = 8'h02;
            frame_check(1'b0, 3, 6'd3, 0, 3, "orphan data");

            // System Common clears running status: trailing data is orphan
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'hF2; fb[4] = 8'h00; fb[5] = 8'h40;
            fb[6] = 8'h3D; fb[7] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 8, 6'd8, 1, 2, "F2 clears running");

            // New channel status interrupts an incomplete F2 data pair.
            fb[0] = 8'hF2; fb[1] = 8'h00; fb[2] = 8'h90;
            fb[3] = 8'h3C; fb[4] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 5, 6'd5, 1, 1, "F2 interrupted by status");

            // F7 clears running status outside SysEx
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'hF7; fb[4] = 8'h3D; fb[5] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 6, 6'd6, 1, 2, "F7 clears running");

            // F6 clears running status outside a pending message
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'hF6; fb[4] = 8'h3D; fb[5] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 6, 6'd6, 1, 2, "F6 clears running");

            // F1 consumes its byte, then F6 clears cleanly
            fb[0] = 8'hF1; fb[1] = 8'h01; fb[2] = 8'hF6;
            frame_check(1'b0, 3, 6'd3, 0, 0, "F1 then F6");

            // CC1/7/11/64 endpoints 0 and 127
            fb[0] = 8'hB0; fb[1] = 8'h07; fb[2] = 8'h00;
            expect_event(mk(K_CC, 4'd0, 7'd7, 7'd0), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "CC7 value 0");
            fb[0] = 8'hB0; fb[1] = 8'h07; fb[2] = 8'h7F;
            expect_event(mk(K_CC, 4'd0, 7'd7, 7'd127), 1'b1);
            frame_check(1'b1, 3, 6'd3, 1, 0, "CC7 value 127");
            fb[0] = 8'hB0; fb[1] = 8'h01; fb[2] = 8'h00;
            expect_event(mk(K_CC, 4'd0, 7'd1, 7'd0), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "CC1 value 0");
            fb[0] = 8'hB0; fb[1] = 8'h0B; fb[2] = 8'h7F;
            expect_event(mk(K_CC, 4'd0, 7'd11, 7'd127), 1'b1);
            frame_check(1'b1, 3, 6'd3, 1, 0, "CC11 value 127");
            fb[0] = 8'hB0; fb[1] = 8'h40; fb[2] = 8'h00;
            expect_event(mk(K_CC, 4'd0, 7'd64, 7'd0), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "CC64 value 0");
            fb[0] = 8'hB0; fb[1] = 8'h40; fb[2] = 8'h7F;
            expect_event(mk(K_CC, 4'd0, 7'd64, 7'd127), 1'b1);
            frame_check(1'b1, 3, 6'd3, 1, 0, "CC64 value 127");
        end
    endtask

    task automatic test_all_cc_numbers;
        int cc;
        begin
            for (cc = 0; cc < 128; cc = cc + 1) begin
                fb[0] = 8'hB0;
                fb[1] = cc[7:0];
                fb[2] = 8'h55;
                if ((cc == 1) || (cc == 7) || (cc == 11) || (cc == 64)) begin
                    expect_event(mk(K_CC, 4'd0, cc[6:0], 7'h55), 1'b0);
                    frame_check(1'b0, 3, 6'd3, 1, 0, "CC all numbers supported");
                end else if ((cc == 120) || (cc == 123)) begin
                    // non-zero 120/123 is ignored
                    frame_check(1'b1, 3, 6'd3, 0, 0, "CC all numbers ignored");
                end else begin
                    frame_check(1'b1, 3, 6'd3, 0, 0, "CC all numbers ignored");
                end
            end
            // 120/123 only emit at value 0
            fb[0] = 8'hB0; fb[1] = 8'd120; fb[2] = 8'd0;
            expect_event(mk(K_CC, 4'd0, 7'd120, 7'd0), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "CC120 value 0");
            fb[0] = 8'hB0; fb[1] = 8'd123; fb[2] = 8'd0;
            expect_event(mk(K_CC, 4'd0, 7'd123, 7'd0), 1'b1);
            frame_check(1'b1, 3, 6'd3, 1, 0, "CC123 value 0");
        end
    endtask

    task automatic test_all_channels;
        int ch;
        logic [7:0] st_on;
        logic [7:0] st_off;
        logic [7:0] st_cc;
        logic [7:0] st_prg;
        logic [7:0] st_bnd;
        logic [7:0] st_poly;
        logic [7:0] st_press;
        logic       src;
        begin
            for (ch = 0; ch < 16; ch = ch + 1) begin
                st_on    = 8'h90 | ch[7:0];
                st_off   = 8'h80 | ch[7:0];
                st_cc    = 8'hB0 | ch[7:0];
                st_prg   = 8'hC0 | ch[7:0];
                st_bnd   = 8'hE0 | ch[7:0];
                st_poly  = 8'hA0 | ch[7:0];
                st_press = 8'hD0 | ch[7:0];
                src      = ch[0];

                fb[0] = st_on;  fb[1] = 8'h3C; fb[2] = 8'h64;
                fb[3] = st_off; fb[4] = 8'h3C; fb[5] = 8'h40;
                expect_event(mk(K_ON,  ch[3:0], 7'd60, 7'd100), src);
                expect_event(mk(K_OFF, ch[3:0], 7'd60, 7'd64),  src);
                frame_check(src, 6, 6'd6, 2, 0, "all channels note");

                fb[0] = st_prg; fb[1] = 8'h05;
                expect_event(mk(K_PRG, ch[3:0], 7'd5, 7'd0), src);
                frame_check(src, 2, 6'd2, 1, 0, "all channels program");

                fb[0] = st_bnd; fb[1] = 8'h00; fb[2] = 8'h40;
                expect_event(mk(K_BND, ch[3:0], 7'd0, 7'd64), src);
                frame_check(src, 3, 6'd3, 1, 0, "all channels bend");

                fb[0] = st_cc; fb[1] = 8'h07; fb[2] = 8'h64;
                expect_event(mk(K_CC, ch[3:0], 7'd7, 7'd100), src);
                frame_check(src, 3, 6'd3, 1, 0, "all channels CC");

                fb[0] = st_poly; fb[1] = 8'h3C; fb[2] = 8'h20;
                frame_check(src, 3, 6'd3, 0, 0, "all channels poly");

                fb[0] = st_press; fb[1] = 8'h10;
                frame_check(src, 2, 6'd2, 0, 0, "all channels pressure");
            end
        end
    endtask

    task automatic test_cross_frame;
        begin
            // Frame A establishes running status; frame B must not inherit it.
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "cross-frame A");
            fb[0] = 8'h3D; fb[1] = 8'h64;
            frame_check(1'b1, 2, 6'd2, 0, 2, "cross-frame B no running");

            // Truncated data in frame A must not be completed by frame B.
            fb[0] = 8'h90; fb[1] = 8'h3C;
            frame_check(1'b1, 2, 6'd2, 0, 1, "cross-frame truncated A");
            fb[0] = 8'h64;
            frame_check(1'b0, 1, 6'd1, 0, 1, "cross-frame truncated B");

            // SysEx skip state must not survive into the next frame.
            fb[0] = 8'hF0; fb[1] = 8'h7D; fb[2] = 8'h01;
            frame_check(1'b0, 3, 6'd3, 0, 1, "cross-frame SysEx A");
            fb[0] = 8'h3C; fb[1] = 8'h64;
            frame_check(1'b1, 2, 6'd2, 0, 2, "cross-frame SysEx B");
        end
    endtask

    task automatic test_max_len;
        int i;
        begin
            // Exactly 32 payload bytes: C0 + 31 one-data running messages.
            // The status plus 31 data bytes produce 31 Program Change events.
            fb[0] = 8'hC0;
            for (i = 1; i < 32; i = i + 1) begin
                fb[i] = i - 1;
                expect_event(mk(K_PRG, 4'd0, (i - 1), 7'd0), 1'b1);
            end
            frame_check(1'b1, 32, 6'd32, 31, 0, "max 32-byte frame");

            // 33 physical bytes with declared LEN=32: the first 32 bytes
            // (31 complete events) are kept, the extra byte is drained and
            // flagged.
            fb[0] = 8'hC0;
            for (i = 1; i < 32; i = i + 1) begin
                fb[i] = i - 1;
                expect_event(mk(K_PRG, 4'd0, (i - 1), 7'd0), 1'b0);
            end
            fb[32] = 8'h7F;
            frame_check(1'b0, 33, 6'd32, 31, 1, "overrun declared len");
        end
    endtask

    task automatic test_len_errors;
        begin
            // Physical 5 bytes, declared LEN=4. The fifth byte is drained.
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            fb[3] = 8'h3E; fb[4] = 8'h50;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 5, 6'd4, 1, 1, "overrun small");

            // Short declared LEN keeps syntactically valid events, then flags.
            fb[0] = 8'hC0; fb[1] = 8'h05; fb[2] = 8'h06;
            expect_event(mk(K_PRG, 4'd0, 7'd5, 7'd0), 1'b0);
            expect_event(mk(K_PRG, 4'd0, 7'd6, 7'd0), 1'b0);
            frame_check(1'b0, 3, 6'd5, 2, 1, "declared len too long");

            // Invalid declared lengths 0 and 33: no parsing, one error.
            fb[0] = 8'hF6;
            frame_check(1'b1, 1, 6'd0, 0, 1, "declared len zero");
            fb[0] = 8'hC0; fb[1] = 8'h05; fb[2] = 8'h06;
            frame_check(1'b0, 3, 6'd33, 0, 1, "declared len 33");
        end
    endtask

    task automatic test_bad_frames;
        int ev0;
        int fd0;
        int pe0;
        int k;
        begin
            // Bytes that arrive without first while the parser is idle are
            // rejected without starting a frame.
            for (k = 0; k < 2; k = k + 1) begin
                ev0 = ev_hs;
                fd0 = fd_cnt;
                pe0 = pe_cnt;
                @(negedge clk);
                s_valid       = 1'b1;
                s_data        = (k == 0) ? 8'h90 : 8'h80;
                s_first       = 1'b0;
                s_last        = (k == 1);
                s_source_id   = 1'b0;
                s_payload_len = 6'd3;
                @(posedge clk);
                @(negedge clk);
                s_valid = 1'b0;
                s_last  = 1'b0;
                repeat (2) @(negedge clk);
                if ((pe_cnt - pe0) != 1) fail_msg("missing error on missing first");
                if ((fd_cnt - fd0) != 0) fail_msg("frame_done on missing first");
                if ((ev_hs - ev0) != 0)  fail_msg("event on missing first");
                if (busy)                fail_msg("busy after missing first");
            end

            // Recovery after the malformed bytes.
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "recover after missing first");

            // Unexpected first in the middle of an active frame is flagged
            // but neither drops the byte nor admits a new frame.
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            send_byte(8'h90, 1'b1, 1'b0, 1'b1, 6'd3);
            send_byte(8'h3C, 1'b1, 1'b0, 1'b1, 6'd3);
            send_byte(8'h64, 1'b0, 1'b1, 1'b1, 6'd3);
            wait_frame_done();
            wait_idle();
            check_frame_counts(ev0, fd0, pe0, 1, 1, "unexpected first");

            // Single status byte with first+last: truncated, no event.
            fb[0] = 8'h90;
            frame_check(1'b0, 1, 6'd1, 0, 1, "single status truncated");
            fb[0] = 8'hC0;
            frame_check(1'b1, 1, 6'd1, 0, 1, "single program truncated");
            fb[0] = 8'hA0;
            frame_check(1'b0, 1, 6'd1, 0, 1, "single poly truncated");
            fb[0] = 8'hF1;
            frame_check(1'b1, 1, 6'd1, 0, 1, "single F1 truncated");
            fb[0] = 8'hF0;
            frame_check(1'b0, 1, 6'd1, 0, 1, "single F0 unclosed");

            // Last asserted early with two-byte message.
            fb[0] = 8'h90; fb[1] = 8'h3C;
            frame_check(1'b1, 2, 6'd2, 0, 1, "last early");
        end
    endtask

    task automatic test_backpressure;
        int ev0;
        int fd0;
        int pe0;
        int j;
        begin
            // Stall on the final event: s_ready must stay low and frame_done
            // must not appear until the event is accepted.
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            @(negedge clk);
            event_ready = 1'b0;
            send_byte(8'h90, 1'b1, 1'b0, 1'b1, 6'd3);
            send_byte(8'h3C, 1'b0, 1'b0, 1'b1, 6'd3);
            send_byte(8'h64, 1'b0, 1'b1, 1'b1, 6'd3);

            repeat (4) begin
                @(negedge clk);
                if (!event_valid) fail_msg("event absent during tail stall");
                if (event_valid && (event_data !== mk(K_ON, 4'd0, 7'd60, 7'd100)))
                    fail_msg("event data changed during tail stall");
                if (event_valid && (event_source_id !== 1'b1))
                    fail_msg("event source changed during tail stall");
                if (s_ready)      fail_msg("s_ready high during tail stall");
                if (frame_done)   fail_msg("frame_done before tail event accepted");
                if (!busy)        fail_msg("busy low during tail stall");
            end

            @(negedge clk);
            event_ready = 1'b1;
            wait_frame_done();
            wait_idle();
            check_frame_counts(ev0, fd0, pe0, 1, 0, "tail stall");

            // Stall after a mid-frame event, present the next byte while
            // stalled, then release and finish the frame.
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            expect_event(mk(K_ON, 4'd0, 7'd62, 7'd80),  1'b0);
            @(negedge clk);
            event_ready = 1'b0;
            send_byte(8'h90, 1'b1, 1'b0, 1'b0, 6'd5);
            send_byte(8'h3C, 1'b0, 1'b0, 1'b0, 6'd5);
            send_byte(8'h64, 1'b0, 1'b0, 1'b0, 6'd5);

            repeat (3) begin
                @(negedge clk);
                if (!event_valid) fail_msg("mid event absent during stall");
                if (event_valid && (event_data !== mk(K_ON, 4'd0, 7'd60, 7'd100)))
                    fail_msg("mid event data changed during stall");
                if (event_valid && (event_source_id !== 1'b0))
                    fail_msg("mid event source changed during stall");
                if (s_ready)    fail_msg("s_ready high during mid stall");
                if (frame_done) fail_msg("frame_done during mid stall");
            end

            @(negedge clk);
            s_valid       = 1'b1;
            s_data        = 8'h3E;
            s_first       = 1'b0;
            s_last        = 1'b0;
            s_source_id   = 1'b0;
            s_payload_len = 6'd5;
            repeat (3) begin
                @(negedge clk);
                if (s_ready) fail_msg("input accepted while output stalled");
                if (event_valid && (event_data !== mk(K_ON, 4'd0, 7'd60, 7'd100)))
                    fail_msg("held event changed while input presented");
            end

            @(negedge clk);
            event_ready = 1'b1;
            @(posedge clk);   // event accepted
            @(negedge clk);
            if (!s_ready) fail_msg("s_ready did not reopen after event drain");
            @(posedge clk);   // held 3E accepted
            @(negedge clk);
            s_valid = 1'b0;
            send_byte(8'h50, 1'b0, 1'b1, 1'b0, 6'd5);
            wait_frame_done();
            wait_idle();
            check_frame_counts(ev0, fd0, pe0, 2, 0, "mid stall");
        end
    endtask

    task automatic test_flush_reset;
        int ev0;
        int fd0;
        int pe0;
        begin
            // Flush while a channel message is partially assembled.
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            send_byte(8'h90, 1'b1, 1'b0, 1'b0, 6'd3);
            send_byte(8'h3C, 1'b0, 1'b0, 1'b0, 6'd3);
            @(negedge clk);
            flush = 1'b1;
            #1;
            if (busy)        fail_msg("busy asserted during flush");
            if (s_ready)     fail_msg("s_ready asserted during flush");
            if (event_valid) fail_msg("event_valid asserted during flush");
            @(negedge clk);
            flush = 1'b0;
            @(negedge clk);
            if (busy)        fail_msg("busy after mid-frame flush");
            if (!s_ready)    fail_msg("s_ready not restored after flush");
            if (event_valid) fail_msg("event after mid-frame flush");
            if (!rst_n)      fail_msg("reset unexpectedly active");
            if ((ev_hs - ev0) != 0) fail_msg("event from flushed frame");
            if ((fd_cnt - fd0) != 0) fail_msg("frame_done from flushed frame");
            if ((pe_cnt - pe0) != 0) fail_msg("error from clean flush");

            // Running status was cleared, so this data-only frame is orphan.
            fb[0] = 8'h3D; fb[1] = 8'h64;
            frame_check(1'b1, 2, 6'd2, 0, 2, "flush cleared running");

            // New frame works immediately after flush.
            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "after mid flush");

            // Flush while a completed tail event is waiting for ready.
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            @(negedge clk);
            event_ready = 1'b0;
            send_byte(8'h90, 1'b1, 1'b0, 1'b1, 6'd3);
            send_byte(8'h3C, 1'b0, 1'b0, 1'b1, 6'd3);
            send_byte(8'h64, 1'b0, 1'b1, 1'b1, 6'd3);
            @(negedge clk);
            if (!event_valid) fail_msg("tail event missing before flush");
            if (frame_done)   fail_msg("frame_done before tail flush");
            flush = 1'b1;
            #1;
            if (event_valid) fail_msg("stalled event not cleared by flush");
            if (busy)        fail_msg("busy after tail flush");
            @(negedge clk);
            flush = 1'b0;
            event_ready = 1'b1;
            repeat (2) @(negedge clk);
            if ((ev_hs - ev0) != 0)  fail_msg("event delivered from flushed tail");
            if ((fd_cnt - fd0) != 0) fail_msg("frame_done from flushed tail");
            if ((pe_cnt - pe0) != 0) fail_msg("error from tail flush");

            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 3, 6'd3, 1, 0, "after tail flush");

            // Asynchronous reset in the middle of a frame.
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            send_byte(8'h90, 1'b1, 1'b0, 1'b0, 6'd3);
            send_byte(8'h3C, 1'b0, 1'b0, 1'b0, 6'd3);
            @(negedge clk);
            rst_n = 1'b0;
            #1;
            if (busy)        fail_msg("busy during reset");
            if (s_ready)     fail_msg("s_ready during reset");
            if (event_valid) fail_msg("event during reset");
            if (frame_done)  fail_msg("frame_done during reset");
            if (parse_error) fail_msg("parse_error during reset");
            repeat (2) @(negedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
            if (busy)        fail_msg("busy after reset");
            if (!s_ready)    fail_msg("s_ready not restored after reset");
            if ((ev_hs - ev0) != 0)  fail_msg("event from reset frame");
            if ((fd_cnt - fd0) != 0) fail_msg("frame_done from reset frame");
            if ((pe_cnt - pe0) != 0) fail_msg("error from clean reset");

            // Running status was cleared, so this data-only frame is orphan.
            fb[0] = 8'h3D; fb[1] = 8'h64;
            frame_check(1'b1, 2, 6'd2, 0, 2, "reset cleared running");

            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b0);
            frame_check(1'b0, 3, 6'd3, 1, 0, "after reset");

            // Reset while a stalled event is pending.
            ev0 = ev_hs;
            fd0 = fd_cnt;
            pe0 = pe_cnt;
            @(negedge clk);
            event_ready = 1'b0;
            send_byte(8'h90, 1'b1, 1'b0, 1'b1, 6'd3);
            send_byte(8'h3C, 1'b0, 1'b0, 1'b1, 6'd3);
            send_byte(8'h64, 1'b0, 1'b1, 1'b1, 6'd3);
            @(negedge clk);
            if (!event_valid) fail_msg("tail event missing before reset");
            rst_n = 1'b0;
            #1;
            if (event_valid) fail_msg("event not cleared by reset");
            if (busy)        fail_msg("busy during tail reset");
            repeat (2) @(negedge clk);
            rst_n = 1'b1;
            event_ready = 1'b1;
            repeat (2) @(negedge clk);
            if ((ev_hs - ev0) != 0)  fail_msg("event delivered after reset");
            if ((fd_cnt - fd0) != 0) fail_msg("frame_done after reset tail");
            if ((pe_cnt - pe0) != 0) fail_msg("error after reset tail");

            fb[0] = 8'h90; fb[1] = 8'h3C; fb[2] = 8'h64;
            expect_event(mk(K_ON, 4'd0, 7'd60, 7'd100), 1'b1);
            frame_check(1'b1, 3, 6'd3, 1, 0, "after tail reset");
        end
    endtask

    // ------------------------------------------------------------------
    // Main sequence
    // ------------------------------------------------------------------
    initial begin
        rst_n       = 1'b0;
        flush       = 1'b0;
        s_valid     = 1'b0;
        s_data      = 8'd0;
        s_first     = 1'b0;
        s_last      = 1'b0;
        s_source_id = 1'b0;
        s_payload_len = 6'd0;
        event_ready = 1'b1;
        errors  = 0;
        ev_hs   = 0;
        fd_cnt  = 0;
        pe_cnt  = 0;
        exp_wr  = 0;
        exp_rd  = 0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        test_basic_table();
        test_more_running();
        test_all_cc_numbers();
        test_all_channels();
        test_cross_frame();
        test_max_len();
        test_len_errors();
        test_bad_frames();
        test_backpressure();
        test_flush_reset();

        repeat (2) @(negedge clk);
        if (event_valid) fail_msg("event left pending at end");
        if (frame_done)  fail_msg("frame_done left asserted at end");
        if (busy)        fail_msg("busy left asserted at end");
        if (exp_rd != exp_wr) begin
            errors = errors + 1;
            $display("[%0t] FAIL: expected queue has %0d unchecked entries",
                     $time, exp_wr - exp_rd);
        end
        if (errors != 0) begin
            $fatal(1, "FAIL: midi_analyzer testbench: %0d error(s)", errors);
        end
        $display("PASS: midi_analyzer contract testbench (%0d events checked)",
                 ev_hs);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "FAIL: global testbench timeout");
    end

endmodule
