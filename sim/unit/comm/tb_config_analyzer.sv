`timescale 1ns/1ps
// Self-checking unit TB for config_analyzer (protocol v1 CONFIG commands).
//
// Coverage:
//   - EQ/reverb field boundaries and malformed length/frame handling
//   - barrier gating, backend request stability, real-completion ACK timing
//   - reply backpressure and frame_done-after-reply
//   - per-source cache replay, immutable SEQ_CONFLICT, cached errors
//   - both sources using the same SEQ, session_reset, global reset
//   - cancel while receiving, before backend acceptance, after acceptance,
//     and after backend completion but before reply acceptance
//
// The TB supplies its own mock commit backend.  No EQ/audio RTL is assumed.

module tb_config_analyzer;

    localparam int EQ_BANDS = 3;

    logic clk = 1'b0;
    logic rst_n;

    logic       s_valid;
    logic       s_ready;
    logic [7:0] s_data;
    logic       s_first;
    logic       s_last;
    logic       s_source_id;
    logic [15:0] s_seq;
    logic [5:0] s_payload_len;

    logic [1:0] session_reset;
    logic [1:0] cancel_source;
    logic       barrier_ready;

    logic        cfg_valid;
    logic        cfg_source_id;
    logic [15:0] cfg_seq;
    logic [7:0]  cfg_command;
    logic [4:0]  cfg_payload_len;
    logic [127:0] cfg_shadow;
    logic        cfg_ready;

    logic        cfg_done_valid;
    logic        cfg_done_ready;
    logic [7:0]  cfg_result;

    logic        reply_valid;
    logic        reply_ready;
    logic        reply_source_id;
    logic [15:0] reply_seq;
    logic [7:0]  reply_command;
    logic [7:0]  reply_result;

    logic        frame_done;
    logic        busy;

    // ---------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------
    config_analyzer #(
        .EQ_BANDS(EQ_BANDS)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .s_valid        (s_valid),
        .s_ready        (s_ready),
        .s_data         (s_data),
        .s_first        (s_first),
        .s_last         (s_last),
        .s_source_id    (s_source_id),
        .s_seq          (s_seq),
        .s_payload_len  (s_payload_len),
        .session_reset  (session_reset),
        .cancel_source  (cancel_source),
        .barrier_ready  (barrier_ready),
        .cfg_valid      (cfg_valid),
        .cfg_source_id  (cfg_source_id),
        .cfg_seq        (cfg_seq),
        .cfg_command    (cfg_command),
        .cfg_payload_len(cfg_payload_len),
        .cfg_shadow     (cfg_shadow),
        .cfg_ready      (cfg_ready),
        .cfg_done_valid (cfg_done_valid),
        .cfg_done_ready (cfg_done_ready),
        .cfg_result     (cfg_result),
        .reply_valid    (reply_valid),
        .reply_ready    (reply_ready),
        .reply_source_id(reply_source_id),
        .reply_seq      (reply_seq),
        .reply_command  (reply_command),
        .reply_result   (reply_result),
        .frame_done     (frame_done),
        .busy           (busy)
    );

    always #5 clk = ~clk;

    // ---------------------------------------------------------------------
    // Scoreboards / monitors
    // ---------------------------------------------------------------------
    integer cfg_req_count;
    logic        cfg_req_src  [0:511];
    logic [15:0] cfg_req_seq  [0:511];
    logic [7:0]  cfg_req_cmd  [0:511];
    logic [4:0]  cfg_req_len  [0:511];
    logic [127:0] cfg_req_shadow [0:511];

    integer reply_count;
    logic        rep_src  [0:511];
    logic [15:0] rep_seq  [0:511];
    logic [7:0]  rep_cmd  [0:511];
    logic [7:0]  rep_res  [0:511];

    integer frame_done_count;

    logic        cfg_hold;
    logic        cfg_hold_src;
    logic [15:0] cfg_hold_seq;
    logic [7:0]  cfg_hold_cmd;
    logic [4:0]  cfg_hold_len;
    logic [127:0] cfg_hold_shadow;

    logic        rep_hold;
    logic        rep_hold_src;
    logic [15:0] rep_hold_seq;
    logic [7:0]  rep_hold_cmd;
    logic [7:0]  rep_hold_res;

    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_req_count <= 0;
            cfg_hold      <= 1'b0;
        end else begin
            if (cfg_hold) begin
                if (cfg_valid) begin
                    if ((cfg_source_id   !== cfg_hold_src)  ||
                        (cfg_seq         !== cfg_hold_seq)  ||
                        (cfg_command     !== cfg_hold_cmd)  ||
                        (cfg_payload_len !== cfg_hold_len)  ||
                        (cfg_shadow      !== cfg_hold_shadow)) begin
                        $fatal(1, "cfg_valid fields changed while accepted-wait was stalled");
                    end
                end else if (!cancel_source[cfg_hold_src]) begin
                    $fatal(1, "cfg_valid dropped without handshake or cancel");
                end
                cfg_hold <= 1'b0;
            end

            if (cfg_valid && !cfg_ready) begin
                cfg_hold_src    <= cfg_source_id;
                cfg_hold_seq    <= cfg_seq;
                cfg_hold_cmd    <= cfg_command;
                cfg_hold_len    <= cfg_payload_len;
                cfg_hold_shadow <= cfg_shadow;
                cfg_hold        <= 1'b1;
            end

            if (cfg_valid && cfg_ready) begin
                if (cfg_req_count >= 511) begin
                    $fatal(1, "cfg request scoreboard overflow");
                end else begin
                    cfg_req_src[cfg_req_count]    <= cfg_source_id;
                    cfg_req_seq[cfg_req_count]    <= cfg_seq;
                    cfg_req_cmd[cfg_req_count]    <= cfg_command;
                    cfg_req_len[cfg_req_count]    <= cfg_payload_len;
                    cfg_req_shadow[cfg_req_count] <= cfg_shadow;
                    cfg_req_count                 <= cfg_req_count + 1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            reply_count    <= 0;
            frame_done_count <= 0;
            rep_hold       <= 1'b0;
        end else begin
            if (frame_done)
                frame_done_count <= frame_done_count + 1;

            if (rep_hold) begin
                if (reply_valid) begin
                    if ((reply_source_id !== rep_hold_src) ||
                        (reply_seq       !== rep_hold_seq) ||
                        (reply_command   !== rep_hold_cmd) ||
                        (reply_result    !== rep_hold_res)) begin
                        $fatal(1, "reply fields changed while reply_ready was stalled");
                    end
                end else if (!cancel_source[rep_hold_src]) begin
                    $fatal(1, "reply_valid dropped without handshake or cancel");
                end
                rep_hold <= 1'b0;
            end

            if (reply_valid && !reply_ready) begin
                rep_hold_src <= reply_source_id;
                rep_hold_seq <= reply_seq;
                rep_hold_cmd <= reply_command;
                rep_hold_res <= reply_result;
                rep_hold     <= 1'b1;
            end

            if (reply_valid && reply_ready) begin
                if (reply_count >= 511) begin
                    $fatal(1, "reply scoreboard overflow");
                end else begin
                    rep_src[reply_count] <= reply_source_id;
                    rep_seq[reply_count] <= reply_seq;
                    rep_cmd[reply_count] <= reply_command;
                    rep_res[reply_count] <= reply_result;
                    reply_count          <= reply_count + 1;
                end
                rep_hold <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Mock commit backend
    // ---------------------------------------------------------------------
    logic [7:0] be_result;
    integer     be_delay;
    logic       be_never_done;
    logic       be_pending;
    integer     be_count;
    logic [7:0] be_result_lat;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cfg_done_valid <= 1'b0;
            cfg_result     <= 8'd0;
            be_pending     <= 1'b0;
            be_count       <= 0;
            be_result_lat  <= 8'd0;
        end else begin
            if (cfg_done_valid && cfg_done_ready)
                cfg_done_valid <= 1'b0;

            if (cfg_valid && cfg_ready) begin
                be_pending    <= 1'b1;
                be_count      <= be_delay;
                be_result_lat <= be_result;
                cfg_done_valid <= 1'b0;
            end else if (be_pending && !be_never_done) begin
                if (be_count == 0) begin
                    cfg_done_valid <= 1'b1;
                    be_pending     <= 1'b0;
                end else begin
                    be_count <= be_count - 1;
                end
            end

            cfg_result <= be_result_lat;
        end
    end

    // ---------------------------------------------------------------------
    // Stimulus helpers
    // ---------------------------------------------------------------------
    logic [7:0] pbuf [0:63];

    task automatic put_u8(input integer off, input logic [7:0] val);
        pbuf[off] = val;
    endtask

    task automatic put_u16(input integer off, input logic [15:0] val);
        pbuf[off]   = val[7:0];
        pbuf[off+1] = val[15:8];
    endtask

    task automatic put_i16(input integer off, input logic signed [15:0] val);
        pbuf[off]   = val[7:0];
        pbuf[off+1] = val[15:8];
    endtask

    task automatic build_eq(
        input logic [7:0] band,
        input logic [7:0] en,
        input logic [7:0] filter_type,
        input logic [15:0] freq,
        input logic signed [15:0] gain,
        input logic [15:0] q
    );
        pbuf[0] = 8'h01;
        pbuf[1] = band;
        pbuf[2] = en;
        pbuf[3] = filter_type;
        put_u16(4, freq);
        put_i16(6, gain);
        put_u16(8, q);
    endtask

    task automatic build_reverb(input logic [7:0] preset);
        pbuf[0] = 8'h02;
        pbuf[1] = preset;
    endtask

    function automatic logic [127:0] make_shadow(input integer n);
        logic [127:0] tmp;
        integer j;
        begin
            tmp = 128'd0;
            for (j = 0; j < 16; j = j + 1)
                if (j < n)
                    tmp[j*8 +: 8] = pbuf[j];
            return tmp;
        end
    endfunction

    task automatic send_frame(
        input logic       src,
        input logic [15:0] seq,
        input logic [5:0]  declared_len,
        input integer      nbytes,
        input logic        first_ok,
        input integer      cancel_at,
        input integer      cancel_cycles,
        input logic        cancel_hold,
        input integer      spur_first_at
    );
        integer k;
        logic hold_active;
        begin
            hold_active = 1'b0;
            for (k = 0; k < nbytes; k = k + 1) begin
                @(negedge clk);
                while (!s_ready) @(negedge clk);

                s_valid       = 1'b1;
                s_data        = pbuf[k];
                s_first       = (k == 0) ? first_ok : (k == spur_first_at);
                s_last        = (k == (nbytes - 1));
                s_source_id   = src;
                s_seq         = seq;
                s_payload_len = declared_len;

                @(posedge clk);
                @(negedge clk);
                s_valid = 1'b0;

                if (k == cancel_at) begin
                    cancel_source[src] = 1'b1;
                    if (cancel_hold) begin
                        hold_active = 1'b1;
                    end else begin
                        if (cancel_cycles > 0)
                            repeat (cancel_cycles) @(negedge clk);
                        cancel_source[src] = 1'b0;
                    end
                end
            end

            @(negedge clk);
            s_valid = 1'b0;
            s_first = 1'b0;
            s_last  = 1'b0;
            if (hold_active) begin
                @(negedge clk);
                cancel_source[src] = 1'b0;
            end
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            rst_n          = 1'b0;
            s_valid        = 1'b0;
            s_first        = 1'b0;
            s_last         = 1'b0;
            s_source_id    = 1'b0;
            s_seq          = 16'd0;
            s_payload_len  = 6'd0;
            session_reset  = 2'b00;
            cancel_source  = 2'b00;
            barrier_ready  = 1'b1;
            cfg_ready      = 1'b1;
            reply_ready    = 1'b1;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (3) @(negedge clk);
        end
    endtask

    task automatic pulse_cancel(input logic src, input integer cycles);
        begin
            @(negedge clk);
            cancel_source[src] = 1'b1;
            repeat (cycles) @(negedge clk);
            cancel_source[src] = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic pulse_session_reset(input logic src);
        begin
            @(negedge clk);
            session_reset[src] = 1'b1;
            @(negedge clk);
            session_reset[src] = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic wait_frame_done(input integer base, input string msg);
        integer t;
        begin
            t = 0;
            while (frame_done_count <= base) begin
                @(posedge clk);
                #1;
                t = t + 1;
                if (t > 20000)
                    $fatal(1, "timeout waiting frame_done: %s", msg);
            end
        end
    endtask

    task automatic wait_cfg_req(input integer base, input string msg);
        integer t;
        begin
            t = 0;
            while (cfg_req_count <= base) begin
                @(posedge clk);
                #1;
                t = t + 1;
                if (t > 20000)
                    $fatal(1, "timeout waiting cfg request: %s", msg);
            end
        end
    endtask

    task automatic wait_cfg_valid_high(input string msg);
        integer t;
        begin
            t = 0;
            while (!cfg_valid) begin
                @(negedge clk);
                t = t + 1;
                if (t > 20000)
                    $fatal(1, "timeout waiting cfg_valid: %s", msg);
            end
        end
    endtask

    task automatic wait_reply_valid_high(input string msg);
        integer t;
        begin
            t = 0;
            while (!reply_valid) begin
                @(negedge clk);
                t = t + 1;
                if (t > 20000)
                    $fatal(1, "timeout waiting reply_valid: %s", msg);
            end
        end
    endtask

    task automatic expect_no_cfg(input integer base, input integer cycles,
                                 input string msg);
        begin
            repeat (cycles) @(posedge clk);
            #1;
            if (cfg_req_count != base)
                $fatal(1, "unexpected cfg request: %s (got %0d, base %0d)",
                       msg, cfg_req_count, base);
        end
    endtask

    task automatic expect_no_reply(input integer base, input integer cycles,
                                   input string msg);
        begin
            repeat (cycles) @(posedge clk);
            #1;
            if (reply_count != base)
                $fatal(1, "unexpected reply: %s (got %0d, base %0d)",
                       msg, reply_count, base);
        end
    endtask

    task automatic expect_no_frame_done(input integer base, input integer cycles,
                                        input string msg);
        begin
            repeat (cycles) @(posedge clk);
            #1;
            if (frame_done_count != base)
                $fatal(1, "unexpected frame_done: %s (got %0d, base %0d)",
                       msg, frame_done_count, base);
        end
    endtask

    task automatic check_reply(
        input integer idx,
        input logic src,
        input logic [15:0] seq,
        input logic [7:0] cmd,
        input logic [7:0] res,
        input string msg
    );
        integer t;
        begin
            t = 0;
            while (reply_count <= idx) begin
                @(posedge clk);
                #1;
                t = t + 1;
                if (t > 20000)
                    $fatal(1, "timeout waiting reply check: %s", msg);
            end
            if ((rep_src[idx] !== src) || (rep_seq[idx] !== seq) ||
                (rep_cmd[idx] !== cmd) || (rep_res[idx] !== res)) begin
                $fatal(1,
                    "reply mismatch %s: got src=%0b seq=%04h cmd=%02h res=%02h, exp src=%0b seq=%04h cmd=%02h res=%02h",
                    msg, rep_src[idx], rep_seq[idx], rep_cmd[idx], rep_res[idx],
                    src, seq, cmd, res);
            end
        end
    endtask

    task automatic check_cfg_req(
        input integer idx,
        input logic src,
        input logic [15:0] seq,
        input logic [7:0] cmd,
        input logic [4:0] len,
        input logic [127:0] shadow_exp,
        input string msg
    );
        begin
            if (cfg_req_count <= idx)
                $fatal(1, "missing cfg request: %s", msg);
            if ((cfg_req_src[idx] !== src) || (cfg_req_seq[idx] !== seq) ||
                (cfg_req_cmd[idx] !== cmd) || (cfg_req_len[idx] !== len) ||
                (cfg_req_shadow[idx] !== shadow_exp)) begin
                $fatal(1,
                    "cfg request mismatch %s: got src=%0b seq=%04h cmd=%02h len=%0d shadow=%032h, exp src=%0b seq=%04h cmd=%02h len=%0d shadow=%032h",
                    msg, cfg_req_src[idx], cfg_req_seq[idx], cfg_req_cmd[idx],
                    cfg_req_len[idx], cfg_req_shadow[idx],
                    src, seq, cmd, len, shadow_exp);
            end
        end
    endtask

    task automatic run_eq_case(
        input logic src,
        input logic [15:0] seq,
        input logic [7:0] band,
        input logic [7:0] en,
        input logic [7:0] filter_type,
        input logic [15:0] freq,
        input logic signed [15:0] gain,
        input logic [15:0] q,
        input logic expect_backend,
        input logic [7:0] exp_result,
        input string msg
    );
        integer cb, rb, fb;
        begin
            cb = cfg_req_count;
            rb = reply_count;
            fb = frame_done_count;
            build_eq(band, en, filter_type, freq, gain, q);
            send_frame(src, seq, 6'd10, 10, 1'b1, -1, 0, 1'b0, -1);
            wait_frame_done(fb, msg);
            check_reply(rb, src, seq, 8'h01, exp_result, msg);
            if (expect_backend) begin
                if (cfg_req_count != cb + 1)
                    $fatal(1, "expected one backend request: %s", msg);
                check_cfg_req(cb, src, seq, 8'h01, 5'd10, make_shadow(10), msg);
            end else begin
                if (cfg_req_count != cb)
                    $fatal(1, "unexpected backend request: %s", msg);
            end
        end
    endtask

    task automatic run_reverb_case(
        input logic src,
        input logic [15:0] seq,
        input logic [7:0] preset,
        input logic expect_backend,
        input logic [7:0] exp_result,
        input string msg
    );
        integer cb, rb, fb;
        begin
            cb = cfg_req_count;
            rb = reply_count;
            fb = frame_done_count;
            build_reverb(preset);
            send_frame(src, seq, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
            wait_frame_done(fb, msg);
            check_reply(rb, src, seq, 8'h02, exp_result, msg);
            if (expect_backend) begin
                if (cfg_req_count != cb + 1)
                    $fatal(1, "expected one backend request: %s", msg);
                check_cfg_req(cb, src, seq, 8'h02, 5'd2, make_shadow(2), msg);
            end else begin
                if (cfg_req_count != cb)
                    $fatal(1, "unexpected backend request: %s", msg);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Main sequence
    // ---------------------------------------------------------------------
    integer cb, rb, fb;
    integer t;
    logic [15:0] seq;

    initial begin
        // Defaults and reset.
        rst_n         = 1'b0;
        s_valid       = 1'b0;
        s_data        = 8'd0;
        s_first       = 1'b0;
        s_last        = 1'b0;
        s_source_id   = 1'b0;
        s_seq         = 16'd0;
        s_payload_len = 6'd0;
        session_reset = 2'b00;
        cancel_source = 2'b00;
        barrier_ready = 1'b1;
        cfg_ready     = 1'b1;
        reply_ready   = 1'b1;

        be_result     = 8'd0;
        be_delay      = 3;
        be_never_done = 1'b0;

        apply_reset();

        if (busy !== 1'b0 || cfg_valid !== 1'b0 || reply_valid !== 1'b0 ||
            frame_done !== 1'b0 || s_ready !== 1'b1)
            $fatal(1, "bad idle state after reset");

        // -----------------------------------------------------------------
        // 1. Reverb boundaries
        // -----------------------------------------------------------------
        be_result = 8'd0;
        be_delay  = 2;

        run_reverb_case(1'b0, 16'h0100, 8'd0, 1'b1, 8'd0, "reverb NONE");
        run_reverb_case(1'b0, 16'h0101, 8'd1, 1'b1, 8'd0, "reverb HALL");
        run_reverb_case(1'b0, 16'h0102, 8'd2, 1'b1, 8'd0, "reverb BATHROOM");
        run_reverb_case(1'b0, 16'h0103, 8'd3, 1'b0, 8'd3, "reverb preset OOR");

        // Reverb LEN=1 and LEN=3 are both BAD_LENGTH.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0104, 6'd1, 1, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "reverb len1");
        check_reply(rb, 1'b0, 16'h0104, 8'h02, 8'd2, "reverb len1");
        if (cfg_req_count != cb) $fatal(1, "reverb len1 reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        pbuf[2] = 8'h00;
        send_frame(1'b0, 16'h0105, 6'd3, 3, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "reverb len3");
        check_reply(rb, 1'b0, 16'h0105, 8'h02, 8'd2, "reverb len3");
        if (cfg_req_count != cb) $fatal(1, "reverb len3 reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        pbuf[0] = 8'h00;
        pbuf[1] = 8'h00;
        send_frame(1'b0, 16'h0106, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "unknown command 00");
        check_reply(rb, 1'b0, 16'h0106, 8'h00, 8'd1, "unknown command 00");
        if (cfg_req_count != cb) $fatal(1, "unknown command reached backend");

        // Unknown command with maximum legal CONFIG payload (LEN=16).
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        for (t = 0; t < 16; t = t + 1) pbuf[t] = 8'h7F;
        send_frame(1'b0, 16'h0107, 6'd16, 16, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "unknown command len16");
        check_reply(rb, 1'b0, 16'h0107, 8'h7F, 8'd1, "unknown command len16");
        if (cfg_req_count != cb) $fatal(1, "unknown len16 reached backend");

        // LEN=17 must be rejected by the CONFIG 16-byte limit.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        for (t = 0; t < 17; t = t + 1) pbuf[t] = 8'h7F;
        send_frame(1'b0, 16'h0108, 6'd17, 17, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "len17");
        check_reply(rb, 1'b0, 16'h0108, 8'h7F, 8'd2, "len17");
        if (cfg_req_count != cb) $fatal(1, "len17 reached backend");

        // -----------------------------------------------------------------
        // 2. EQ field boundaries
        // -----------------------------------------------------------------
        run_eq_case(1'b0, 16'h0110, 8'd0, 8'd0, 8'd0,
                    16'd20, -16'sd3072, 16'd26, 1'b1, 8'd0, "EQ low edge");
        run_eq_case(1'b0, 16'h0111, 8'd2, 8'd1, 8'd0,
                    16'd20000, 16'sd3072, 16'd2560, 1'b1, 8'd0, "EQ high edge");

        run_eq_case(1'b0, 16'h0112, 8'd3, 8'd1, 8'd0,
                    16'd1000, 16'sd0, 16'd256, 1'b0, 8'd3, "EQ band OOR");
        run_eq_case(1'b0, 16'h0113, 8'd1, 8'd1, 8'd0,
                    16'd19, 16'sd0, 16'd256, 1'b0, 8'd3, "EQ freq low OOR");
        run_eq_case(1'b0, 16'h0114, 8'd1, 8'd1, 8'd0,
                    16'd20001, 16'sd0, 16'd256, 1'b0, 8'd3, "EQ freq high OOR");
        run_eq_case(1'b0, 16'h0115, 8'd1, 8'd1, 8'd0,
                    16'd1000, -16'sd3073, 16'd256, 1'b0, 8'd3, "EQ gain low OOR");
        run_eq_case(1'b0, 16'h0116, 8'd1, 8'd1, 8'd0,
                    16'd1000, 16'sd3073, 16'd256, 1'b0, 8'd3, "EQ gain high OOR");
        run_eq_case(1'b0, 16'h0117, 8'd1, 8'd1, 8'd0,
                    16'd1000, 16'sd0, 16'd25, 1'b0, 8'd3, "EQ Q low OOR");
        run_eq_case(1'b0, 16'h0118, 8'd1, 8'd1, 8'd0,
                    16'd1000, 16'sd0, 16'd2561, 1'b0, 8'd3, "EQ Q high OOR");
        run_eq_case(1'b0, 16'h0119, 8'd1, 8'd2, 8'd0,
                    16'd1000, 16'sd0, 16'd256, 1'b0, 8'd3, "EQ enable OOR");
        run_eq_case(1'b0, 16'h011A, 8'd1, 8'd1, 8'd1,
                    16'd1000, 16'sd0, 16'd256, 1'b0, 8'd1, "EQ filter_type unsupported");

        // EQ LEN=9 and LEN=11 are command-length errors.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd1, 8'd1, 8'd0, 16'd1000, 16'sd0, 16'd256);
        send_frame(1'b0, 16'h011B, 6'd9, 9, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "EQ len9");
        check_reply(rb, 1'b0, 16'h011B, 8'h01, 8'd2, "EQ len9");
        if (cfg_req_count != cb) $fatal(1, "EQ len9 reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd1, 8'd1, 8'd0, 16'd1000, 16'sd0, 16'd256);
        pbuf[10] = 8'hAA;
        send_frame(1'b0, 16'h011C, 6'd11, 11, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "EQ len11");
        check_reply(rb, 1'b0, 16'h011C, 8'h01, 8'd2, "EQ len11");
        if (cfg_req_count != cb) $fatal(1, "EQ len11 reached backend");

        // Declared length vs accepted bytes mismatches are malformed frames.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd1, 8'd1, 8'd0, 16'd1000, 16'sd0, 16'd256);
        send_frame(1'b0, 16'h011D, 6'd10, 9, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "truncated frame");
        check_reply(rb, 1'b0, 16'h011D, 8'h01, 8'd2, "truncated frame");
        if (cfg_req_count != cb) $fatal(1, "truncated frame reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd1, 8'd1, 8'd0, 16'd1000, 16'sd0, 16'd256);
        pbuf[9] = 8'h55;
        send_frame(1'b0, 16'h011E, 6'd9, 10, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "overlong actual frame");
        check_reply(rb, 1'b0, 16'h011E, 8'h01, 8'd2, "overlong actual frame");
        if (cfg_req_count != cb) $fatal(1, "overlong actual frame reached backend");

        // Missing s_first and an extra s_first in the middle.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd1, 8'd1, 8'd0, 16'd1000, 16'sd0, 16'd256);
        send_frame(1'b0, 16'h011F, 6'd10, 10, 1'b0, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "missing first");
        check_reply(rb, 1'b0, 16'h011F, 8'h01, 8'd2, "missing first");
        if (cfg_req_count != cb) $fatal(1, "missing first reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd1, 8'd1, 8'd0, 16'd1000, 16'sd0, 16'd256);
        send_frame(1'b0, 16'h0120, 6'd10, 10, 1'b1, -1, 0, 1'b0, 5);
        wait_frame_done(fb, "spurious first");
        check_reply(rb, 1'b0, 16'h0120, 8'h01, 8'd2, "spurious first");
        if (cfg_req_count != cb) $fatal(1, "spurious first reached backend");

        // Declared zero length with one byte is also malformed.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0121, 6'd0, 1, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "declared len0");
        check_reply(rb, 1'b0, 16'h0121, 8'h02, 8'd2, "declared len0");
        if (cfg_req_count != cb) $fatal(1, "declared len0 reached backend");

        // -----------------------------------------------------------------
        // 3. Barrier, backend acceptance stall, ACK timing, reply stall
        // -----------------------------------------------------------------
        // Barrier must completely gate the backend request.
        @(negedge clk);
        barrier_ready = 1'b0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0200, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        expect_no_cfg(cb, 10, "barrier holds");
        if (reply_count != rb) $fatal(1, "reply before barrier");
        if (frame_done_count != fb) $fatal(1, "frame_done before barrier");
        @(negedge clk);
        barrier_ready = 1'b1;
        wait_frame_done(fb, "barrier release");
        check_reply(rb, 1'b0, 16'h0200, 8'h02, 8'd0, "barrier release");
        if (cfg_req_count != cb + 1) $fatal(1, "barrier release backend count");

        // cfg_ready stall: request fields must hold, no ACK/frame_done.
        @(negedge clk);
        cfg_ready = 1'b0;
        be_delay  = 2;
        be_result = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0201, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_cfg_valid_high("cfg_ready stall");
        repeat (5) begin
            @(negedge clk);
            if (!cfg_valid) $fatal(1, "cfg_valid dropped during cfg_ready stall");
            if (reply_valid) $fatal(1, "reply during cfg_ready stall");
            if (frame_done) $fatal(1, "frame_done during cfg_ready stall");
        end
        if (cfg_req_count != cb) $fatal(1, "backend request before cfg_ready");
        @(negedge clk);
        cfg_ready = 1'b1;
        wait_frame_done(fb, "cfg_ready release");
        check_reply(rb, 1'b1, 16'h0201, 8'h02, 8'd0, "cfg_ready release");
        if (cfg_req_count != cb + 1) $fatal(1, "cfg_ready release backend count");
        check_cfg_req(cb, 1'b1, 16'h0201, 8'h02, 5'd2, make_shadow(2),
                      "cfg_ready release");

        // Reply stall: reply descriptor stable, frame_done waits for acceptance.
        @(negedge clk);
        reply_ready = 1'b0;
        be_delay    = 6;
        be_result   = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0202, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_reply_valid_high("reply stall");
        repeat (6) begin
            @(negedge clk);
            if (!reply_valid) $fatal(1, "reply_valid dropped while stalled");
            if (frame_done) $fatal(1, "frame_done before reply accepted");
        end
        if (reply_count != rb) $fatal(1, "reply accepted while stalled");
        if (frame_done_count != fb) $fatal(1, "frame_done counted while stalled");
        @(negedge clk);
        reply_ready = 1'b1;
        wait_frame_done(fb, "reply stall release");
        check_reply(rb, 1'b0, 16'h0202, 8'h02, 8'd0, "reply stall release");

        // Backend delay: no reply until cfg_done handshake.
        be_delay  = 12;
        be_result = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0203, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_cfg_req(cb, "backend delay request");
        expect_no_reply(rb, 4, "reply before backend completion");
        expect_no_frame_done(fb, 1, "frame_done before backend completion");
        wait_frame_done(fb, "backend delay completion");
        check_reply(rb, 1'b1, 16'h0203, 8'h02, 8'd0, "backend delay completion");

        // Backend explicitly reports NOT_READY; it must be forwarded verbatim.
        be_delay  = 3;
        be_result = 8'd6;
        run_reverb_case(1'b0, 16'h0204, 8'd2, 1'b1, 8'd6, "backend NOT_READY");

        // Backend withholds completion: absolutely no ACK/frame_done until the
        // real completion handshake arrives.  Release it afterwards.
        @(negedge clk);
        be_never_done = 1'b1;
        be_delay      = 2;
        be_result     = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0205, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_cfg_req(cb, "backend withheld");
        expect_no_reply(rb, 20, "ACK with withheld backend");
        expect_no_frame_done(fb, 2, "frame_done with withheld backend");
        @(negedge clk);
        be_never_done = 1'b0;
        wait_frame_done(fb, "withheld backend release");
        check_reply(rb, 1'b0, 16'h0205, 8'h02, 8'd0, "withheld backend release");

        // Validation-error replies also wait for reply acceptance before
        // frame_done, and never touch the backend.
        @(negedge clk);
        reply_ready = 1'b0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd3);
        send_frame(1'b0, 16'h0206, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_reply_valid_high("stalled error reply");
        repeat (4) begin
            @(negedge clk);
            if (!reply_valid) $fatal(1, "error reply_valid dropped while stalled");
            if (frame_done) $fatal(1, "frame_done before error reply accepted");
        end
        @(negedge clk);
        reply_ready = 1'b1;
        wait_frame_done(fb, "stalled error reply release");
        check_reply(rb, 1'b0, 16'h0206, 8'h02, 8'd3, "stalled error reply release");
        if (cfg_req_count != cb) $fatal(1, "validation error reached backend");

        // -----------------------------------------------------------------
        // 4. Cache replay, immutable conflict, cached validation errors
        // -----------------------------------------------------------------
        be_delay  = 1;
        be_result = 8'd0;

        run_reverb_case(1'b0, 16'h0300, 8'd1, 1'b1, 8'd0, "cache origin");
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0300, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "cache replay");
        check_reply(rb, 1'b0, 16'h0300, 8'h02, 8'd0, "cache replay");
        if (cfg_req_count != cb) $fatal(1, "cache replay reached backend");

        // Same SEQ, different payload: conflict, original stays immutable.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b0, 16'h0300, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "seq conflict");
        check_reply(rb, 1'b0, 16'h0300, 8'h02, 8'd5, "seq conflict");
        if (cfg_req_count != cb) $fatal(1, "seq conflict reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0300, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "cache after conflict");
        check_reply(rb, 1'b0, 16'h0300, 8'h02, 8'd0, "cache after conflict");
        if (cfg_req_count != cb) $fatal(1, "cache after conflict reached backend");

        // Cached validation errors replay without a backend request.
        run_reverb_case(1'b0, 16'h0302, 8'd3, 1'b0, 8'd3, "cached OOR origin");
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd3);
        send_frame(1'b0, 16'h0302, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "cached OOR replay");
        check_reply(rb, 1'b0, 16'h0302, 8'h02, 8'd3, "cached OOR replay");
        if (cfg_req_count != cb) $fatal(1, "cached OOR replay reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        pbuf[0] = 8'h00;
        pbuf[1] = 8'h00;
        send_frame(1'b0, 16'h0303, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "cached unknown origin");
        check_reply(rb, 1'b0, 16'h0303, 8'h00, 8'd1, "cached unknown origin");
        if (cfg_req_count != cb) $fatal(1, "cached unknown reached backend");
        rb = reply_count; fb = frame_done_count; cb = cfg_req_count;
        send_frame(1'b0, 16'h0303, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "cached unknown replay");
        check_reply(rb, 1'b0, 16'h0303, 8'h00, 8'd1, "cached unknown replay");
        if (cfg_req_count != cb) $fatal(1, "cached unknown replay reached backend");

        // BAD_LENGTH for a well-formed outer frame is also cacheable.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0304, 6'd1, 1, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "cached BAD_LENGTH origin");
        check_reply(rb, 1'b0, 16'h0304, 8'h02, 8'd2, "cached BAD_LENGTH origin");
        if (cfg_req_count != cb) $fatal(1, "cached BAD_LENGTH reached backend");
        rb = reply_count; fb = frame_done_count; cb = cfg_req_count;
        send_frame(1'b0, 16'h0304, 6'd1, 1, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "cached BAD_LENGTH replay");
        check_reply(rb, 1'b0, 16'h0304, 8'h02, 8'd2, "cached BAD_LENGTH replay");
        if (cfg_req_count != cb) $fatal(1, "cached BAD_LENGTH replay reached backend");

        // Only the most recent per-source entry is retained.  A newer request
        // replaces 0x0300, so re-sending 0x0300 must reach the backend again.
        run_eq_case(1'b0, 16'h0305, 8'd3, 8'd1, 8'd0,
                    16'd1000, 16'sd0, 16'd256, 1'b0, 8'd3, "cache replace");
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0300, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "old seq not cached");
        check_reply(rb, 1'b0, 16'h0300, 8'h02, 8'd0, "old seq not cached");
        if (cfg_req_count != cb + 1)
            $fatal(1, "expected old seq to reach backend after replacement");
        check_cfg_req(cb, 1'b0, 16'h0300, 8'h02, 5'd2, make_shadow(2),
                      "old seq not cached");

        // -----------------------------------------------------------------
        // 5. Two sources may use the same SEQ independently
        // -----------------------------------------------------------------
        be_delay  = 1;
        be_result = 8'd0;

        run_reverb_case(1'b0, 16'h0400, 8'd1, 1'b1, 8'd0, "src0 same seq");
        run_reverb_case(1'b1, 16'h0400, 8'd2, 1'b1, 8'd0, "src1 same seq");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0400, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "src0 replay same seq");
        check_reply(rb, 1'b0, 16'h0400, 8'h02, 8'd0, "src0 replay same seq");
        if (cfg_req_count != cb) $fatal(1, "src0 replay reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0400, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "src1 replay same seq");
        check_reply(rb, 1'b1, 16'h0400, 8'h02, 8'd0, "src1 replay same seq");
        if (cfg_req_count != cb) $fatal(1, "src1 replay reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd0);
        send_frame(1'b1, 16'h0400, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "src1 conflict same seq");
        check_reply(rb, 1'b1, 16'h0400, 8'h02, 8'd5, "src1 conflict same seq");
        if (cfg_req_count != cb) $fatal(1, "src1 conflict reached backend");

        // Same SEQ, two different EQ payloads, one per source.
        run_eq_case(1'b0, 16'h0401, 8'd0, 8'd1, 8'd0,
                    16'd440, 16'sd256, 16'd512, 1'b1, 8'd0, "src0 EQ same seq");
        run_eq_case(1'b1, 16'h0401, 8'd1, 8'd1, 8'd0,
                    16'd880, -16'sd256, 16'd1024, 1'b1, 8'd0, "src1 EQ same seq");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd0, 8'd1, 8'd0, 16'd440, 16'sd256, 16'd512);
        send_frame(1'b0, 16'h0401, 6'd10, 10, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "src0 EQ replay same seq");
        check_reply(rb, 1'b0, 16'h0401, 8'h01, 8'd0, "src0 EQ replay same seq");
        if (cfg_req_count != cb) $fatal(1, "src0 EQ replay reached backend");

        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_eq(8'd1, 8'd1, 8'd0, 16'd880, -16'sd256, 16'd1024);
        send_frame(1'b1, 16'h0401, 6'd10, 10, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "src1 EQ replay same seq");
        check_reply(rb, 1'b1, 16'h0401, 8'h01, 8'd0, "src1 EQ replay same seq");
        if (cfg_req_count != cb) $fatal(1, "src1 EQ replay reached backend");

        // -----------------------------------------------------------------
        // 6. session_reset clears only the selected source cache
        // -----------------------------------------------------------------
        be_delay  = 1;
        be_result = 8'd0;

        run_reverb_case(1'b0, 16'h0500, 8'd1, 1'b1, 8'd0, "session cache src0");
        pulse_session_reset(1'b1);
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0500, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "other source session reset");
        check_reply(rb, 1'b0, 16'h0500, 8'h02, 8'd0, "other source session reset");
        if (cfg_req_count != cb) $fatal(1, "other source reset cleared src0 cache");

        pulse_session_reset(1'b0);
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0500, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "own source session reset");
        check_reply(rb, 1'b0, 16'h0500, 8'h02, 8'd0, "own source session reset");
        if (cfg_req_count != cb + 1)
            $fatal(1, "own source reset did not clear cache");
        check_cfg_req(cb, 1'b0, 16'h0500, 8'h02, 5'd2, make_shadow(2),
                      "own source session reset");

        // session_reset on src0 must not clear src1's entry.
        run_reverb_case(1'b1, 16'h0501, 8'd2, 1'b1, 8'd0, "session cache src1");
        pulse_session_reset(1'b0);
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0501, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "src1 survives src0 reset");
        check_reply(rb, 1'b1, 16'h0501, 8'h02, 8'd0, "src1 survives src0 reset");
        if (cfg_req_count != cb) $fatal(1, "src1 cache lost on src0 reset");

        // Invalidation wins over a same-cycle cache publication: keep the reply
        // stalled, then assert session_reset exactly on the accept cycle.
        @(negedge clk);
        reply_ready = 1'b0;
        be_delay    = 1;
        be_result   = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd0);
        send_frame(1'b0, 16'h0502, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_reply_valid_high("same-cycle invalidation reply");
        @(negedge clk);
        session_reset[0] = 1'b1;
        reply_ready      = 1'b1;
        @(negedge clk);
        session_reset[0] = 1'b0;
        wait_frame_done(fb, "same-cycle invalidation");
        check_reply(rb, 1'b0, 16'h0502, 8'h02, 8'd0, "same-cycle invalidation");
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd0);
        send_frame(1'b0, 16'h0502, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "same-cycle invalidation miss");
        check_reply(rb, 1'b0, 16'h0502, 8'h02, 8'd0, "same-cycle invalidation miss");
        if (cfg_req_count != cb + 1)
            $fatal(1, "session_reset lost same-cycle invalidation race");
        check_cfg_req(cb, 1'b0, 16'h0502, 8'h02, 5'd2, make_shadow(2),
                      "same-cycle invalidation miss");

        // -----------------------------------------------------------------
        // 7. cancel_source behaviour
        // -----------------------------------------------------------------
        // 7a. Cancel while receiving: consume the whole frame, no reply/cache.
        be_delay  = 1;
        be_result = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0600, 6'd2, 2, 1'b1, 0, 0, 1'b1, -1);
        wait_frame_done(fb, "cancel while receiving");
        expect_no_reply(rb, 4, "cancel while receiving");
        if (cfg_req_count != cb) $fatal(1, "cancelled receive reached backend");
        if (busy !== 1'b0) $fatal(1, "busy stuck after cancelled receive");
        // Not cached: a fresh request must reach the backend.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0600, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "post-cancel receive retry");
        check_reply(rb, 1'b0, 16'h0600, 8'h02, 8'd0, "post-cancel receive retry");
        if (cfg_req_count != cb + 1) $fatal(1, "cancel published a cache entry");
        check_cfg_req(cb, 1'b0, 16'h0600, 8'h02, 5'd2, make_shadow(2),
                      "post-cancel receive retry");

        // 7b. Cancel before backend acceptance: cfg_valid aborts, no commit.
        @(negedge clk);
        cfg_ready = 1'b0;
        be_delay  = 1;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0601, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_cfg_valid_high("cancel before backend accept");
        if (cfg_ready) $fatal(1, "test setup: cfg_ready unexpectedly high");
        pulse_cancel(1'b1, 2);
        @(negedge clk);
        if (cfg_valid) $fatal(1, "cfg_valid not aborted by cancel_source");
        wait_frame_done(fb, "cancel before backend accept");
        expect_no_reply(rb, 4, "cancel before backend accept");
        if (cfg_req_count != cb) $fatal(1, "cancelled pre-accept commit was accepted");
        @(negedge clk);
        cfg_ready = 1'b1;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0601, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "post-cancel pre-accept retry");
        check_reply(rb, 1'b1, 16'h0601, 8'h02, 8'd0, "post-cancel pre-accept retry");
        if (cfg_req_count != cb + 1) $fatal(1, "pre-accept cancel cache leak");

        // 7c. Cancel after backend acceptance: must still retire the real
        // completion, but suppress reply/cache publication.
        @(negedge clk);
        cfg_ready = 1'b1;
        be_delay  = 14;
        be_result = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0602, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_cfg_req(cb, "cancel after backend accept");
        pulse_cancel(1'b0, 3);
        @(negedge clk);
        if (!cfg_done_ready)
            $fatal(1, "cfg_done_ready dropped after accepted cancel");
        expect_no_reply(rb, 3, "cancel after backend accept");
        wait_frame_done(fb, "cancel after backend accept completion");
        expect_no_reply(rb, 4, "cancel after backend accept completion");
        if (cfg_req_count != cb + 1)
            $fatal(1, "accepted backend request count wrong after cancel");
        // Cache must not have been published.
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0602, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "post-cancel accepted retry");
        check_reply(rb, 1'b0, 16'h0602, 8'h02, 8'd0, "post-cancel accepted retry");
        if (cfg_req_count != cb + 1) $fatal(1, "accepted cancel published cache");

        // 7d. Cancel after backend completion but before reply acceptance.
        @(negedge clk);
        reply_ready = 1'b0;
        be_delay    = 1;
        be_result   = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0603, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_reply_valid_high("cancel stalled reply");
        pulse_cancel(1'b1, 2);
        @(negedge clk);
        if (reply_valid) $fatal(1, "reply not suppressed after cancel");
        wait_frame_done(fb, "cancel stalled reply");
        expect_no_reply(rb, 4, "cancel stalled reply");
        @(negedge clk);
        reply_ready = 1'b1;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0603, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "post-cancel stalled reply retry");
        check_reply(rb, 1'b1, 16'h0603, 8'h02, 8'd0, "post-cancel stalled reply retry");
        if (cfg_req_count != cb + 1) $fatal(1, "stalled cancel published cache");

        // 7e. Cancel of the other source must not disturb this context.
        @(negedge clk);
        be_delay  = 6;
        be_result = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd0);
        send_frame(1'b0, 16'h0604, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_cfg_req(cb, "other-source cancel");
        pulse_cancel(1'b1, 3);
        wait_frame_done(fb, "other-source cancel");
        check_reply(rb, 1'b0, 16'h0604, 8'h02, 8'd0, "other-source cancel");

        // -----------------------------------------------------------------
        // 8. Global reset clears context and caches
        // -----------------------------------------------------------------
        run_reverb_case(1'b0, 16'h0700, 8'd1, 1'b1, 8'd0, "reset cache origin");
        apply_reset();
        if (busy !== 1'b0 || cfg_valid !== 1'b0 || reply_valid !== 1'b0 ||
            frame_done !== 1'b0 || s_ready !== 1'b1)
            $fatal(1, "bad idle state after mid-test reset");
        be_delay  = 1;
        be_result = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd1);
        send_frame(1'b0, 16'h0700, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "reset clears cache");
        check_reply(rb, 1'b0, 16'h0700, 8'h02, 8'd0, "reset clears cache");
        if (cfg_req_count != cb + 1) $fatal(1, "reset did not clear cache");

        // Reset while a backend request is outstanding must not emit a late
        // reply or frame_done from the old context.
        be_delay = 20;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0701, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_cfg_req(cfg_req_count, "reset in-flight request");
        apply_reset();
        expect_no_reply(0, 20, "reset in-flight old reply");
        expect_no_frame_done(0, 20, "reset in-flight old frame_done");
        if (busy !== 1'b0 || cfg_valid !== 1'b0 || reply_valid !== 1'b0)
            $fatal(1, "outputs active after in-flight reset");
        be_delay  = 2;
        be_result = 8'd0;
        cb = cfg_req_count; rb = reply_count; fb = frame_done_count;
        build_reverb(8'd2);
        send_frame(1'b1, 16'h0702, 6'd2, 2, 1'b1, -1, 0, 1'b0, -1);
        wait_frame_done(fb, "post-reset new request");
        check_reply(rb, 1'b1, 16'h0702, 8'h02, 8'd0, "post-reset new request");
        if (cfg_req_count != cb + 1) $fatal(1, "post-reset request missing");

        // -----------------------------------------------------------------
        // Final quiescence check
        // -----------------------------------------------------------------
        expect_no_cfg(cfg_req_count, 5, "final quiescence cfg");
        expect_no_reply(reply_count, 5, "final quiescence reply");
        expect_no_frame_done(frame_done_count, 5, "final quiescence frame_done");
        if (busy !== 1'b0 || s_ready !== 1'b1)
            $fatal(1, "busy/s_ready not idle at end");

        $display("TB PASS: config_analyzer");
        $finish;
    end

    // Global watchdog.
    initial begin
        #50_000_000;
        $fatal(1, "GLOBAL TIMEOUT");
    end

endmodule
