`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// transport_v2_link -- Bluetooth session/protocol v2 stream adapter.
//
// Keeps the original transport_link business-facing byte/frame/reply interface
// and adds the v2 session control inputs.  The SLIP/CRC/queue work is delegated
// to comm_v2_codec; this module owns the fixed v2 wire contract:
//   * four-step HELLO/CONFIRM handshake with maintenance_done barrier
//   * session/epoch checks, MIDI sequence checks and playback recovery
//   * control replies, generic FF replies and CONFIG replies bound to the
//     session that submitted the configuration
//   * heartbeat and progress supervision, error window and hard revoke
//
// Business frames are still exposed as the original byte-stream frame.  A
// staged frame is immutable until its last byte handshake.  Ordinary flush does
// NOT flush the codec/control path; stale codec frames are drained and rejected
// using their session/epoch metadata.
// -----------------------------------------------------------------------------
module transport_v2_link #(
    parameter int FRAME_DEPTH = 8,
    parameter int TIMEOUT_CYCLES = 100000000,
    parameter int CLK_HZ = 100000000,
    parameter int HEARTBEAT_CYCLES = 2 * CLK_HZ,
    parameter int PROGRESS_CYCLES = CLK_HZ / 4,
    parameter int ERROR_LIMIT = 8,
    parameter int ERROR_WINDOW_CYCLES = CLK_HZ
) (
    input  logic        clk,
    input  logic        rst_n,

    // Original transport_link maintenance interface.  flush/pin only affect the
    // business stream; the codec and control/TX path are deliberately not reset.
    input  logic        flush,
    input  logic        pin,

    input  logic        rx_valid,
    output logic        rx_ready,
    input  logic [7:0]  rx_data,

    output logic        tx_valid,
    input  logic        tx_ready,
    output logic [7:0]  tx_data,

    output logic        frame_valid,
    input  logic        frame_ready,
    output logic [7:0]  frame_data,
    output logic [7:0]  frame_type,
    output logic [15:0] frame_seq,
    output logic [5:0]  frame_payload_len,
    output logic        frame_first,
    output logic        frame_last,
    output logic        frame_available,

    output logic [7:0]  protocol_errors,

    // Original v1 CONFIG reply producer interface (parser_dispatch).
    input  logic        reply_valid,
    output logic        reply_ready,
    input  logic [15:0] reply_seq,
    input  logic [7:0]  reply_command,
    input  logic [7:0]  reply_result,

    output logic        tx_busy,

    // v2 session/maintenance sideband.
    input  logic        maintenance_done,
    input  logic        physical_fault,
    input  logic        disconnect_event,
    input  logic        midi_error,
    output logic        cleanup_request
);

    localparam int CONTROL_DEPTH = 4;
    localparam int REPLY_DEPTH   = 8;
    localparam int REPLY_PTR_W   = (REPLY_DEPTH <= 2) ? 1 : $clog2(REPLY_DEPTH);
    localparam int REPLY_CNT_W   = $clog2(REPLY_DEPTH + 1);

    localparam logic [7:0] TYPE_MIDI   = 8'h01;
    localparam logic [7:0] TYPE_CONFIG = 8'h02;
    localparam logic [7:0] TYPE_CONFIG_REPLY = 8'h80;
    localparam logic [7:0] TYPE_CONTROL_REPLY = 8'h81;
    localparam logic [7:0] TYPE_RESYNC  = 8'h86;
    localparam logic [7:0] TYPE_FAULT   = 8'h87;
    localparam logic [7:0] TYPE_FF      = 8'hFF;

    localparam logic [7:0] CMD_HELLO     = 8'h01;
    localparam logic [7:0] CMD_CONFIRM   = 8'h02;
    localparam logic [7:0] CMD_PING      = 8'h03;
    localparam logic [7:0] CMD_STATUS_GET= 8'h04;
    localparam logic [7:0] CMD_RESUME    = 8'h05;

    localparam logic [7:0] RESULT_UNSUPPORTED = 8'h01;
    localparam logic [7:0] RESULT_BAD_LENGTH  = 8'h02;
    localparam logic [7:0] RESULT_OUT_OF_RANGE= 8'h03;
    localparam logic [7:0] RESULT_NOT_READY   = 8'h06;

    localparam logic [15:0] CAPS = 16'h000F;  // session, heartbeat, resume, config

    typedef enum logic [2:0] {
        ST_WAIT_HELLO   = 3'd0,
        ST_CLEANUP      = 3'd1,
        ST_WAIT_CONFIRM = 3'd2,
        ST_ACTIVE       = 3'd3,
        ST_RESYNC       = 3'd4
    } state_t;

    // ---------------------------------------------------------------------
    // Codec instance.  The codec owns SLIP/CRC, the independent control and
    // business queues, and the complete-frame TX encoder.  Ordinary transport
    // maintenance is intentionally not forwarded to its flush input.
    // ---------------------------------------------------------------------
    logic        codec_ctrl_valid, codec_ctrl_ready;
    logic [15:0] codec_ctrl_seq;
    logic [31:0] codec_ctrl_session;
    logic [5:0]  codec_ctrl_len;
    logic [255:0] codec_ctrl_payload;

    logic        codec_biz_valid, codec_biz_ready;
    logic [7:0]  codec_biz_type;
    logic [15:0] codec_biz_seq;
    logic [31:0] codec_biz_session;
    logic [5:0]  codec_biz_len;
    logic [255:0] codec_biz_payload;

    logic [7:0]  codec_errors;

    logic        codec_send_valid, codec_send_ready;
    logic [7:0]  codec_send_type;
    logic [15:0] codec_send_seq;
    logic [31:0] codec_send_session;
    logic [5:0]  codec_send_len;
    logic [255:0] codec_send_payload;

    logic        codec_tx_valid, codec_tx_ready;
    logic [7:0]  codec_tx_data;

    comm_v2_codec #(
        .FRAME_DEPTH(FRAME_DEPTH),
        .CONTROL_DEPTH(CONTROL_DEPTH),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) u_codec (
        .clk(clk), .rst_n(rst_n), .flush(1'b0),
        .rx_valid(rx_valid), .rx_ready(rx_ready), .rx_data(rx_data),
        .ctrl_valid(codec_ctrl_valid), .ctrl_ready(codec_ctrl_ready),
        .ctrl_seq(codec_ctrl_seq), .ctrl_session(codec_ctrl_session),
        .ctrl_len(codec_ctrl_len), .ctrl_payload(codec_ctrl_payload),
        .biz_valid(codec_biz_valid), .biz_ready(codec_biz_ready),
        .biz_type(codec_biz_type), .biz_seq(codec_biz_seq),
        .biz_session(codec_biz_session), .biz_len(codec_biz_len),
        .biz_payload(codec_biz_payload),
        .errors(codec_errors),
        .send_valid(codec_send_valid), .send_ready(codec_send_ready),
        .send_type(codec_send_type), .send_seq(codec_send_seq),
        .send_session(codec_send_session), .send_len(codec_send_len),
        .send_payload(codec_send_payload),
        .tx_valid(codec_tx_valid), .tx_ready(codec_tx_ready), .tx_data(codec_tx_data)
    );

    assign tx_valid = codec_tx_valid;
    assign tx_data  = codec_tx_data;
    assign codec_tx_ready = tx_ready;
    assign protocol_errors = codec_errors;

    // ---------------------------------------------------------------------
    // Session state.
    // ---------------------------------------------------------------------
    state_t      state;
    logic [31:0] session;
    logic [31:0] session_counter;
    logic [31:0] hs_nonce;
    logic [15:0] hello_seq;
    logic [15:0] epoch;
    logic [15:0] expected_seq;

    logic        welcome_pending;
    logic        maint_seen;
    logic        welcome_push;
    logic        resync_cleanup_seen;
    logic        resync_notified;
    logic        resync_push;
    logic [7:0]  last_reason;

    logic        rec_valid;
    logic [15:0] rec_epoch;
    logic [15:0] rec_first;
    logic [15:0] rec_expected;

    logic [31:0] heartbeat_cnt;
    logic [31:0] confirm_cnt;
    logic [31:0] progress_timer;
    logic        progress_active;
    logic [15:0] progress_target;

    logic [31:0] error_count;
    logic [31:0] error_window_cnt;
    logic        error_window_active;

    // Edge detect for level/pulse sideband inputs.
    logic        physical_fault_r;
    logic        disconnect_event_r;
    logic        midi_error_r;

    logic        out_active;
    logic [7:0]  out_type;
    logic [15:0] out_seq;
    logic [5:0]  out_len;
    logic [255:0] out_payload;
    logic [5:0]  out_idx;
    logic        out_started;
    logic        out_is_config;
    logic [31:0] out_session;
    logic [15:0] out_epoch;

    logic        config_pending;
    logic [15:0] config_seq;
    logic [31:0] config_session;

    logic        fault_pending;
    logic [7:0]  fault_reason;
    logic [31:0] fault_session;

    // ---------------------------------------------------------------------
    // Control payload decode (little endian, payload byte 0 is [7:0]).
    // ---------------------------------------------------------------------
    logic [7:0]  ctrl_cmd;
    logic        ctrl_session_ok;
    logic [31:0] ctrl_hello_nonce;
    logic [31:0] ctrl_confirm_nonce;
    logic [7:0]  ctrl_ping_has;
    logic [15:0] ctrl_ping_last;
    logic [15:0] ctrl_ping_epoch;
    logic [15:0] ctrl_resume_epoch;
    logic [15:0] ctrl_resume_first;

    assign ctrl_cmd           = codec_ctrl_payload[7:0];
    assign ctrl_session_ok    = (codec_ctrl_session == session);
    assign ctrl_hello_nonce   = codec_ctrl_payload[39:8];
    assign ctrl_confirm_nonce = codec_ctrl_payload[39:8];
    assign ctrl_ping_has      = codec_ctrl_payload[15:8];
    assign ctrl_ping_last     = codec_ctrl_payload[31:16];
    assign ctrl_ping_epoch    = codec_ctrl_payload[47:32];
    assign ctrl_resume_epoch  = codec_ctrl_payload[23:8];
    assign ctrl_resume_first  = codec_ctrl_payload[39:24];

    // ---------------------------------------------------------------------
    // Reply queue.  Full frame metadata + payload, independent from the codec
    // control queue.  One complete frame is handed to the codec at a time.
    // Entries from an older session are discarded lazily, except CONFIG replies
    // and FAULT notifications (their header must remain bound to the submitting
    // session / the revoked session).
    // ---------------------------------------------------------------------
    logic [7:0]   rq_type    [0:REPLY_DEPTH-1];
    logic [15:0]  rq_seq     [0:REPLY_DEPTH-1];
    logic [31:0]  rq_session [0:REPLY_DEPTH-1];
    logic [5:0]   rq_len     [0:REPLY_DEPTH-1];
    logic [255:0] rq_payload [0:REPLY_DEPTH-1];
    logic [7:0]   rq_gen     [0:REPLY_DEPTH-1];

    logic [REPLY_PTR_W-1:0] rq_rd;
    logic [REPLY_PTR_W-1:0] rq_wr;
    logic [REPLY_CNT_W-1:0] rq_count;
    logic [7:0]             reply_gen;

    wire rq_empty = (rq_count == 0);
    wire [REPLY_CNT_W-1:0] rq_free = REPLY_DEPTH[REPLY_CNT_W-1:0] - rq_count;
    wire [7:0] rq_head_type = rq_type[rq_rd];
    wire rq_head_keep = (rq_head_type == TYPE_CONFIG_REPLY) ||
                        ((rq_head_type == TYPE_CONTROL_REPLY) &&
                         (rq_payload[rq_rd][7:0] == TYPE_FAULT));
    wire rq_head_stale = !rq_empty && (rq_gen[rq_rd] != reply_gen) && !rq_head_keep;
    wire rq_push_free = (rq_count < REPLY_DEPTH) || rq_head_stale;

    // ---------------------------------------------------------------------
    // Edge/error events.
    // ---------------------------------------------------------------------
    wire phys_edge = physical_fault && !physical_fault_r;
    wire disc_edge = disconnect_event && !disconnect_event_r;
    wire midi_err_edge = midi_error && !midi_error_r;

    wire err_event = |codec_errors[4:0];
    wire window_expired = error_window_active && (ERROR_WINDOW_CYCLES > 0) &&
                          (error_window_cnt >= ERROR_WINDOW_CYCLES - 1);
    logic [31:0] error_count_eff;
    always_comb begin
        if (err_event && (!error_window_active || window_expired))
            error_count_eff = 32'd1;
        else if (err_event)
            error_count_eff = error_count + 32'd1;
        else
            error_count_eff = error_count;
    end
    wire error_limit_hit = (ERROR_LIMIT != 0) && (error_count_eff >= ERROR_LIMIT);

    // MIDI checks only apply to frames that claim the current session and epoch
    // while the link is active.  Stale session/epoch frames are silently dropped.
    // Only inspect the codec head when it is actually eligible to be staged.
    // While an earlier frame is streaming, expected_seq has not advanced yet;
    // comparing the queued successor then would create a false gap.
    wire biz_midi_candidate = codec_biz_valid && (codec_biz_type == TYPE_MIDI) &&
                              (codec_biz_session == session) &&
                              (state == ST_ACTIVE) && !flush && !out_active;
    wire biz_midi_epoch_match = (codec_biz_len >= 6'd2) &&
                                (codec_biz_payload[15:0] == epoch);
    wire biz_midi_len_bad = biz_midi_candidate &&
                            ((codec_biz_len < 6'd3) || (codec_biz_len > 6'd32)) &&
                            ((codec_biz_len < 6'd2) || biz_midi_epoch_match);
    wire biz_midi_seq_gap = biz_midi_candidate && (codec_biz_len >= 6'd3) &&
                            (codec_biz_len <= 6'd32) && biz_midi_epoch_match &&
                            (codec_biz_seq != expected_seq);

    wire heartbeat_timeout = (state == ST_ACTIVE) && (HEARTBEAT_CYCLES > 0) &&
                             (heartbeat_cnt >= HEARTBEAT_CYCLES - 1);
    wire progress_timeout = (state == ST_ACTIVE) && progress_active &&
                            (PROGRESS_CYCLES > 0) &&
                            (progress_timer >= PROGRESS_CYCLES - 1);
    wire confirm_fail = (state == ST_WAIT_CONFIRM) && (TIMEOUT_CYCLES > 0) &&
                        (confirm_cnt >= TIMEOUT_CYCLES - 1);

    wire midi_error_active = midi_err_edge && (state == ST_ACTIVE);

    wire soft_event = biz_midi_seq_gap || biz_midi_len_bad || midi_error_active ||
                      progress_timeout;

    logic [7:0] soft_reason;
    always_comb begin
        if (biz_midi_seq_gap)       soft_reason = 8'd1;
        else if (biz_midi_len_bad)  soft_reason = 8'd2;
        else if (midi_error_active) soft_reason = 8'd2;
        else if (progress_timeout)  soft_reason = 8'd7;
        else                        soft_reason = 8'd0;
    end

    wire epoch_exhaust = soft_event && (epoch == 16'hFFFF);
    wire hard_event = phys_edge || disc_edge || codec_errors[5] ||
                      error_limit_hit || epoch_exhaust || heartbeat_timeout;
    wire hard_event_all = hard_event;
    wire revoke_now = hard_event || soft_event || confirm_fail;

    logic [7:0] hard_reason;
    always_comb begin
        if (phys_edge)             hard_reason = 8'd5;
        else if (disc_edge)        hard_reason = 8'd4;
        else if (codec_errors[5])  hard_reason = 8'd5;
        else if (heartbeat_timeout) hard_reason = 8'd3;
        else if (error_limit_hit)  hard_reason = 8'd6;
        else if (epoch_exhaust)    hard_reason = 8'd6;
        else                       hard_reason = 8'd0;
    end

    // ---------------------------------------------------------------------
    // Control decode, reply generation and reply-queue admission.
    // ---------------------------------------------------------------------
    logic        ctrl_needs_reply;
    logic        ctrl_fire;
    logic        ctrl_push;
    logic        hello_new_dec;
    logic        hello_new_fire;
    logic        confirm_activate;
    logic        confirm_replay;
    logic        ping_valid;
    logic        ping_active_valid;
    logic        resume_accept;
    logic        resume_replay;

    logic [255:0] resp_payload;
    logic [7:0]   resp_type;
    logic [15:0]  resp_seq;
    logic [31:0]  resp_session;
    logic [5:0]   resp_len;
    logic         resp_valid;

    wire [7:0] resp_state = {5'd0, state};

    function automatic logic [255:0] mk_ff(input logic [7:0] cmd,
                                           input logic [7:0] res);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = TYPE_FF;
            p[15:8]  = cmd;
            p[23:16] = res;
            mk_ff = p;
        end
    endfunction

    function automatic logic [255:0] mk_welcome(input logic [31:0] nonce,
                                                input logic [15:0] ep,
                                                input logic [15:0] caps,
                                                input logic [7:0] max_midi,
                                                input logic [7:0] max_config);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = TYPE_CONTROL_REPLY;
            p[15:8]  = nonce[7:0];
            p[23:16] = nonce[15:8];
            p[31:24] = nonce[23:16];
            p[39:32] = nonce[31:24];
            p[47:40] = ep[7:0];
            p[55:48] = ep[15:8];
            p[63:56] = caps[7:0];
            p[71:64] = caps[15:8];
            p[79:72] = max_midi;
            p[87:80] = max_config;
            mk_welcome = p;
        end
    endfunction

    function automatic logic [255:0] mk_ready(input logic [15:0] ep,
                                              input logic [15:0] exp_seq);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = 8'h82;
            p[15:8]  = ep[7:0];
            p[23:16] = ep[15:8];
            p[31:24] = exp_seq[7:0];
            p[39:32] = exp_seq[15:8];
            mk_ready = p;
        end
    endfunction

    function automatic logic [255:0] mk_pong(input logic [7:0] st,
                                             input logic [15:0] ep,
                                             input logic [15:0] exp_seq);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = 8'h83;
            p[15:8]  = st;
            p[23:16] = ep[7:0];
            p[31:24] = ep[15:8];
            p[39:32] = exp_seq[7:0];
            p[47:40] = exp_seq[15:8];
            mk_pong = p;
        end
    endfunction

    function automatic logic [255:0] mk_status(input logic [7:0] st,
                                               input logic [15:0] ep,
                                               input logic [15:0] exp_seq,
                                               input logic [7:0] reason);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = 8'h84;
            p[15:8]  = st;
            p[23:16] = ep[7:0];
            p[31:24] = ep[15:8];
            p[39:32] = exp_seq[7:0];
            p[47:40] = exp_seq[15:8];
            p[55:48] = reason;
            mk_status = p;
        end
    endfunction

    function automatic logic [255:0] mk_playback_ready(input logic [15:0] ep,
                                                       input logic [15:0] exp_seq);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = 8'h85;
            p[15:8]  = ep[7:0];
            p[23:16] = ep[15:8];
            p[31:24] = exp_seq[7:0];
            p[39:32] = exp_seq[15:8];
            mk_playback_ready = p;
        end
    endfunction

    function automatic logic [255:0] mk_resync(input logic [15:0] ep,
                                               input logic [7:0] reason);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = TYPE_RESYNC;
            p[15:8]  = ep[7:0];
            p[23:16] = ep[15:8];
            p[31:24] = reason;
            mk_resync = p;
        end
    endfunction

    function automatic logic [255:0] mk_fault(input logic [7:0] reason);
        logic [255:0] p;
        begin
            p = '0;
            p[7:0]   = TYPE_FAULT;
            p[15:8]  = reason;
            mk_fault = p;
        end
    endfunction

    // New HELLO is decided without depending on ctrl_fire, avoiding a loop via
    // welcome_push.  A retry with the same nonce is NOT new.
    assign hello_new_dec = codec_ctrl_valid && (codec_ctrl_len == 6'd5) &&
                           (ctrl_cmd == CMD_HELLO) && (codec_ctrl_session == 32'd0) &&
                           !((state == ST_CLEANUP) && (ctrl_hello_nonce == hs_nonce)) &&
                           !((state == ST_WAIT_CONFIRM) && (ctrl_hello_nonce == hs_nonce)) &&
                           !((state == ST_ACTIVE) && (ctrl_hello_nonce == hs_nonce)) &&
                           !((state == ST_RESYNC) && (ctrl_hello_nonce == hs_nonce)) &&
                           (session_counter != 32'hFFFF_FFFF);

    // Pushes that can precede a control reply in the single TX scheduler.
    wire fault_push = fault_pending && rq_push_free;
    wire config_push = config_pending && reply_valid &&
                       rq_push_free && !fault_push;
    wire welcome_push_c = (state == ST_CLEANUP) && welcome_pending && maint_seen &&
                          !config_pending && rq_push_free &&
                          !fault_push && !config_push &&
                          !hello_new_dec && !revoke_now;
    wire resync_push_c = (state == ST_RESYNC) && resync_cleanup_seen &&
                         !resync_notified && !config_pending && rq_push_free &&
                         !fault_push && !config_push &&
                         !hello_new_dec && !revoke_now;
    assign welcome_push = welcome_push_c;
    assign resync_push  = resync_push_c;

    wire ctrl_slot_free = rq_push_free && !fault_push && !config_push &&
                          !welcome_push && !resync_push && !revoke_now;

    always_comb begin
        ctrl_needs_reply = 1'b0;
        resp_valid   = 1'b0;
        resp_type    = 8'h00;
        resp_seq     = codec_ctrl_seq;
        resp_session = session;
        resp_len     = 6'd0;
        resp_payload = '0;

        if (codec_ctrl_valid) begin
            if (codec_ctrl_len == 6'd0) begin
                if (ctrl_session_ok) begin
                    ctrl_needs_reply = 1'b1;
                    resp_valid   = 1'b1;
                    resp_type    = TYPE_CONTROL_REPLY;
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(8'h00, RESULT_BAD_LENGTH);
                end
            end else if (ctrl_cmd == CMD_HELLO) begin
                if (codec_ctrl_session != 32'd0) begin
                    if (ctrl_session_ok) begin
                        ctrl_needs_reply = 1'b1;
                        resp_valid   = 1'b1;
                        resp_type    = TYPE_CONTROL_REPLY;
                        resp_len     = 6'd3;
                        resp_payload = mk_ff(CMD_HELLO, RESULT_OUT_OF_RANGE);
                    end
                end else if (codec_ctrl_len != 6'd5) begin
                    ctrl_needs_reply = 1'b1;
                    resp_valid   = 1'b1;
                    resp_type    = TYPE_CONTROL_REPLY;
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_HELLO, RESULT_BAD_LENGTH);
                end else if ((state == ST_CLEANUP) &&
                             (ctrl_hello_nonce == hs_nonce)) begin
                    // Same-nonce retry during CLEANUP: do not restart cleanup,
                    // do not emit a second WELCOME.
                end else if (((state == ST_WAIT_CONFIRM) || (state == ST_ACTIVE)) &&
                             (ctrl_hello_nonce == hs_nonce)) begin
                    ctrl_needs_reply = 1'b1;
                    resp_valid   = 1'b1;
                    resp_type    = TYPE_CONTROL_REPLY;
                    resp_len     = 6'd11;
                    resp_payload = mk_welcome(hs_nonce, epoch, CAPS, 8'd30, 8'd16);
                end else if ((state == ST_RESYNC) &&
                             (ctrl_hello_nonce == hs_nonce)) begin
                    ctrl_needs_reply = 1'b1;
                    resp_valid   = 1'b1;
                    resp_type    = TYPE_CONTROL_REPLY;
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_HELLO, RESULT_NOT_READY);
                end else if (session_counter == 32'hFFFF_FFFF) begin
                    ctrl_needs_reply = 1'b1;
                    resp_valid   = 1'b1;
                    resp_type    = TYPE_CONTROL_REPLY;
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_HELLO, RESULT_NOT_READY);
                end else begin
                    // HELLO accepted; WELCOME is emitted after the real cleanup
                    // barrier (maintenance_done) and after old CONFIG retirement.
                end
            end else if (!ctrl_session_ok) begin
                // Old-session control is silently discarded.
            end else if (ctrl_cmd == CMD_CONFIRM) begin
                ctrl_needs_reply = 1'b1;
                resp_valid   = 1'b1;
                resp_type    = TYPE_CONTROL_REPLY;
                if (codec_ctrl_len != 6'd5) begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_CONFIRM, RESULT_BAD_LENGTH);
                end else if ((state == ST_WAIT_CONFIRM) &&
                             (ctrl_confirm_nonce == hs_nonce)) begin
                    resp_len     = 6'd5;
                    resp_payload = mk_ready(epoch, expected_seq);
                end else if ((state == ST_ACTIVE) &&
                             (ctrl_confirm_nonce == hs_nonce)) begin
                    resp_len     = 6'd5;
                    resp_payload = mk_ready(epoch, expected_seq);
                end else if ((state == ST_WAIT_CONFIRM) || (state == ST_ACTIVE)) begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_CONFIRM, RESULT_OUT_OF_RANGE);
                end else begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_CONFIRM, RESULT_NOT_READY);
                end
            end else if (ctrl_cmd == CMD_PING) begin
                ctrl_needs_reply = 1'b1;
                resp_valid   = 1'b1;
                resp_type    = TYPE_CONTROL_REPLY;
                if (codec_ctrl_len != 6'd6) begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_PING, RESULT_BAD_LENGTH);
                end else if ((state == ST_WAIT_HELLO) || (state == ST_CLEANUP)) begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_PING, RESULT_NOT_READY);
                end else if ((ctrl_ping_epoch != epoch) || (ctrl_ping_has > 8'd1)) begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_PING, RESULT_OUT_OF_RANGE);
                end else begin
                    resp_len     = 6'd6;
                    resp_payload = mk_pong(resp_state, epoch, expected_seq);
                end
            end else if (ctrl_cmd == CMD_STATUS_GET) begin
                ctrl_needs_reply = 1'b1;
                resp_valid   = 1'b1;
                resp_type    = TYPE_CONTROL_REPLY;
                if (codec_ctrl_len != 6'd1) begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_STATUS_GET, RESULT_BAD_LENGTH);
                end else begin
                    resp_len     = 6'd7;
                    resp_payload = mk_status(resp_state, epoch, expected_seq, last_reason);
                end
            end else if (ctrl_cmd == CMD_RESUME) begin
                ctrl_needs_reply = 1'b1;
                resp_valid   = 1'b1;
                resp_type    = TYPE_CONTROL_REPLY;
                if (codec_ctrl_len != 6'd5) begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_RESUME, RESULT_BAD_LENGTH);
                end else if (state == ST_RESYNC) begin
                    if (!resync_notified) begin
                        resp_len     = 6'd3;
                        resp_payload = mk_ff(CMD_RESUME, RESULT_NOT_READY);
                    end else if (ctrl_resume_epoch != epoch) begin
                        resp_len     = 6'd3;
                        resp_payload = mk_ff(CMD_RESUME, RESULT_OUT_OF_RANGE);
                    end else begin
                        resp_len     = 6'd5;
                        resp_payload = mk_playback_ready(epoch, ctrl_resume_first);
                    end
                end else if (state == ST_ACTIVE) begin
                    if (rec_valid && (ctrl_resume_epoch == rec_epoch) &&
                        (ctrl_resume_first == rec_first)) begin
                        resp_len     = 6'd5;
                        resp_payload = mk_playback_ready(rec_epoch, rec_expected);
                    end else if (ctrl_resume_epoch != epoch) begin
                        resp_len     = 6'd3;
                        resp_payload = mk_ff(CMD_RESUME, RESULT_OUT_OF_RANGE);
                    end else begin
                        resp_len     = 6'd3;
                        resp_payload = mk_ff(CMD_RESUME, RESULT_NOT_READY);
                    end
                end else begin
                    resp_len     = 6'd3;
                    resp_payload = mk_ff(CMD_RESUME, RESULT_NOT_READY);
                end
            end else begin
                ctrl_needs_reply = 1'b1;
                resp_valid   = 1'b1;
                resp_type    = TYPE_CONTROL_REPLY;
                resp_len     = 6'd3;
                resp_payload = mk_ff(ctrl_cmd, RESULT_UNSUPPORTED);
            end
        end
    end

    assign codec_ctrl_ready = codec_ctrl_valid &&
                              ((!ctrl_needs_reply && !revoke_now) ||
                               (ctrl_needs_reply && ctrl_slot_free));
    assign ctrl_fire = codec_ctrl_valid && codec_ctrl_ready;
    assign ctrl_push = ctrl_fire && ctrl_needs_reply;

    assign hello_new_fire   = hello_new_dec && ctrl_fire;
    assign confirm_activate = ctrl_fire && (ctrl_cmd == CMD_CONFIRM) &&
                              ctrl_session_ok && (codec_ctrl_len == 6'd5) &&
                              (ctrl_confirm_nonce == hs_nonce) &&
                              (state == ST_WAIT_CONFIRM);
    assign confirm_replay   = ctrl_fire && (ctrl_cmd == CMD_CONFIRM) &&
                              ctrl_session_ok && (codec_ctrl_len == 6'd5) &&
                              (ctrl_confirm_nonce == hs_nonce) &&
                              (state == ST_ACTIVE);
    assign ping_valid       = ctrl_fire && (ctrl_cmd == CMD_PING) &&
                              ctrl_session_ok && (codec_ctrl_len == 6'd6) &&
                              (ctrl_ping_epoch == epoch) && (ctrl_ping_has <= 8'd1) &&
                              ((state == ST_WAIT_CONFIRM) || (state == ST_ACTIVE));
    assign ping_active_valid = ping_valid && (state == ST_ACTIVE);
    assign resume_accept    = ctrl_fire && (ctrl_cmd == CMD_RESUME) &&
                              ctrl_session_ok && (codec_ctrl_len == 6'd5) &&
                              (state == ST_RESYNC) && resync_notified &&
                              (ctrl_resume_epoch == epoch);
    assign resume_replay    = ctrl_fire && (ctrl_cmd == CMD_RESUME) &&
                              ctrl_session_ok && (codec_ctrl_len == 6'd5) &&
                              (state == ST_ACTIVE) && rec_valid &&
                              (ctrl_resume_epoch == rec_epoch) &&
                              (ctrl_resume_first == rec_first);

    // ---------------------------------------------------------------------
    // Single TX push scheduler: one complete frame per cycle.
    // ---------------------------------------------------------------------
    logic        push_sel;
    logic [7:0]  push_type;
    logic [15:0] push_seq;
    logic [31:0] push_session;
    logic [5:0]  push_len;
    logic [255:0] push_payload;

    always_comb begin
        push_sel = 1'b0;
        push_type = 8'h00;
        push_seq = 16'h0000;
        push_session = 32'd0;
        push_len = 6'd0;
        push_payload = '0;

        if (fault_push) begin
            push_sel     = 1'b1;
            push_type    = TYPE_CONTROL_REPLY;
            push_seq     = 16'h0000;
            push_session = fault_session;
            push_len     = 6'd2;
            push_payload = mk_fault(fault_reason);
        end else if (config_push) begin
            push_sel     = 1'b1;
            push_type    = TYPE_CONFIG_REPLY;
            push_seq     = reply_seq;
            push_session = config_session;
            push_len     = 6'd3;
            push_payload = {232'd0, reply_result, reply_command, 8'h02};
        end else if (welcome_push) begin
            push_sel     = 1'b1;
            push_type    = TYPE_CONTROL_REPLY;
            push_seq     = hello_seq;
            push_session = session;
            push_len     = 6'd11;
            push_payload = mk_welcome(hs_nonce, epoch, CAPS, 8'd30, 8'd16);
        end else if (resync_push) begin
            push_sel     = 1'b1;
            push_type    = TYPE_CONTROL_REPLY;
            push_seq     = 16'h0000;
            push_session = session;
            push_len     = 6'd4;
            push_payload = mk_resync(epoch, last_reason);
        end else if (ctrl_push) begin
            push_sel     = 1'b1;
            push_type    = resp_type;
            push_seq     = resp_seq;
            push_session = resp_session;
            push_len     = resp_len;
            push_payload = resp_payload;
        end
    end

    // CONFIG reply is only accepted while its submitting session is still
    // tracked; otherwise it is retired without emitting a mislabelled frame.
    assign reply_ready = !config_pending || (rq_push_free && !fault_push);

    // ---------------------------------------------------------------------
    // TX frame output from the reply queue.
    // ---------------------------------------------------------------------
    assign codec_send_valid   = !rq_empty && !rq_head_stale && !revoke_now;
    assign codec_send_type    = rq_type[rq_rd];
    assign codec_send_seq     = rq_seq[rq_rd];
    assign codec_send_session = rq_session[rq_rd];
    assign codec_send_len     = rq_len[rq_rd];
    assign codec_send_payload = rq_payload[rq_rd];

    wire tx_fire = codec_send_valid && codec_send_ready;
    logic tx_inflight;
    logic tx_seen_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_inflight   <= 1'b0;
            tx_seen_valid <= 1'b0;
        end else begin
            if (tx_fire) begin
                tx_inflight   <= 1'b1;
                tx_seen_valid <= 1'b0;
            end else if (tx_inflight) begin
                if (codec_tx_valid)
                    tx_seen_valid <= 1'b1;
                else if (tx_seen_valid) begin
                    tx_inflight   <= 1'b0;
                    tx_seen_valid <= 1'b0;
                end
            end
        end
    end

    assign tx_busy = !rq_empty || tx_inflight;

    // ---------------------------------------------------------------------
    // Reply queue update.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq_rd    <= '0;
            rq_wr    <= '0;
            rq_count <= '0;
            for (int i = 0; i < REPLY_DEPTH; i = i + 1) begin
                rq_type[i]    <= 8'h00;
                rq_seq[i]     <= 16'h0000;
                rq_session[i] <= 32'd0;
                rq_len[i]     <= 6'd0;
                rq_payload[i] <= '0;
                rq_gen[i]     <= 8'd0;
            end
        end else begin
            if (push_sel) begin
                rq_type[rq_wr]    <= push_type;
                rq_seq[rq_wr]     <= push_seq;
                rq_session[rq_wr] <= push_session;
                rq_len[rq_wr]     <= push_len;
                rq_payload[rq_wr] <= push_payload;
                rq_gen[rq_wr]     <= reply_gen;
                rq_wr <= (rq_wr == REPLY_DEPTH - 1) ? '0 : (rq_wr + 1'b1);
            end

            if (!rq_empty && rq_head_stale) begin
                rq_rd <= (rq_rd == REPLY_DEPTH - 1) ? '0 : (rq_rd + 1'b1);
                if (!push_sel)
                    rq_count <= rq_count - 1'b1;
            end else if (tx_fire) begin
                rq_rd <= (rq_rd == REPLY_DEPTH - 1) ? '0 : (rq_rd + 1'b1);
                if (!push_sel)
                    rq_count <= rq_count - 1'b1;
            end else if (push_sel) begin
                rq_count <= rq_count + 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Business stream staging and original byte-frame output.
    // ---------------------------------------------------------------------
    wire biz_fire = codec_biz_valid && codec_biz_ready;
    assign codec_biz_ready = !out_active;

    wire take_midi = biz_fire && (codec_biz_type == TYPE_MIDI) &&
                     (codec_biz_session == session) && (state == ST_ACTIVE) &&
                     (codec_biz_len >= 6'd3) && (codec_biz_len <= 6'd32) &&
                     (codec_biz_payload[15:0] == epoch) &&
                     (codec_biz_seq == expected_seq) && !flush && !revoke_now &&
                     !hello_new_dec;
    wire take_config = biz_fire && (codec_biz_type == TYPE_CONFIG) &&
                       (codec_biz_session == session) && (state == ST_ACTIVE) &&
                       (codec_biz_len >= 6'd1) && (codec_biz_len <= 6'd16) &&
                       !config_pending && !flush && !revoke_now &&
                       !hello_new_dec;

    // A CONFIG frame that never reached the parser can be forgotten together
    // with its pending-binding.  Once any byte was accepted, retirement is
    // proven by the maintenance barrier (or by the parser's reply).
    wire drop_uncommitted_config = out_active && out_is_config && !out_started &&
                                   !pin && (flush || revoke_now || hello_new_dec);

    assign frame_valid = out_active && !revoke_now && (!flush || pin) &&
                         (!hello_new_dec || pin);
    assign frame_data  = out_payload[{out_idx[4:0], 3'b000} +: 8];
    assign frame_type  = out_type;
    assign frame_seq   = out_seq;
    assign frame_payload_len = out_len;
    assign frame_first = out_active && (out_idx == 6'd0);
    assign frame_last  = out_active && (out_idx == (out_len - 6'd1));
    assign frame_available = out_active || codec_biz_valid;

    wire out_fire = frame_valid && frame_ready;
    wire out_last = out_fire && (out_idx == (out_len - 6'd1));
    wire out_last_midi = out_last && !out_is_config;
    wire out_last_midi_current = out_last_midi && (out_session == session) &&
                                 (out_epoch == epoch) && (state == ST_ACTIVE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_active  <= 1'b0;
            out_type    <= 8'h00;
            out_seq     <= 16'h0000;
            out_len     <= 6'd0;
            out_payload <= '0;
            out_idx     <= 6'd0;
            out_started <= 1'b0;
            out_is_config <= 1'b0;
            out_session <= 32'd0;
            out_epoch <= 16'd0;
        end else begin
            if (out_fire) begin
                out_started <= 1'b1;
                if (out_last) begin
                    out_active  <= 1'b0;
                    out_idx     <= 6'd0;
                    out_started <= 1'b0;
                    out_is_config <= 1'b0;
                end else begin
                    out_idx <= out_idx + 6'd1;
                end
            end
            if ((revoke_now || flush || hello_new_dec) &&
                !(out_active && pin)) begin
                out_active    <= 1'b0;
                out_idx       <= 6'd0;
                out_started   <= 1'b0;
                out_is_config <= 1'b0;
            end
            if (take_midi || take_config) begin
                out_active    <= 1'b1;
                out_idx       <= 6'd0;
                out_started   <= 1'b0;
                out_is_config <= take_config;
                if (take_midi) begin
                    out_session <= codec_biz_session;
                    out_epoch   <= codec_biz_payload[15:0];
                    out_type    <= TYPE_MIDI;
                    out_seq     <= codec_biz_seq;
                    out_len     <= codec_biz_len - 6'd2;
                    out_payload <= codec_biz_payload >> 16;
                end else begin
                    out_type    <= TYPE_CONFIG;
                    out_seq     <= codec_biz_seq;
                    out_len     <= codec_biz_len;
                    out_payload <= codec_biz_payload;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // Main session FSM.  Hard events have absolute priority, then soft
    // playback recovery, then wait-CONFIRM timeout, then normal control.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_WAIT_HELLO;
            session            <= 32'd0;
            session_counter    <= 32'd0;
            hs_nonce           <= 32'd0;
            hello_seq          <= 16'd0;
            epoch              <= 16'd0;
            expected_seq       <= 16'd0;
            welcome_pending    <= 1'b0;
            maint_seen         <= 1'b0;
            resync_cleanup_seen<= 1'b0;
            resync_notified    <= 1'b0;
            last_reason        <= 8'd0;
            rec_valid          <= 1'b0;
            rec_epoch          <= 16'd0;
            rec_first          <= 16'd0;
            rec_expected       <= 16'd0;
            config_pending     <= 1'b0;
            config_seq         <= 16'd0;
            config_session     <= 32'd0;
            fault_pending      <= 1'b0;
            fault_reason       <= 8'd0;
            fault_session      <= 32'd0;
            cleanup_request    <= 1'b0;
            reply_gen          <= 8'd0;
        end else begin
            cleanup_request <= 1'b0;

            // A maintenance pulse from before a new HELLO is ignored unless a
            // HELLO cleanup is already in flight (then it covers the new nonce
            // as well, because no business is admitted in ST_CLEANUP).
            if (maintenance_done && !hard_event && !soft_event && !confirm_fail) begin
                if (state == ST_CLEANUP)
                    maint_seen <= 1'b1;
                else if ((state == ST_RESYNC) && !hello_new_fire)
                    resync_cleanup_seen <= 1'b1;
                if (!hello_new_fire)
                    config_pending <= 1'b0;
            end

            if (hard_event) begin
                cleanup_request <= 1'b1;
                if (session != 32'd0) begin
                    fault_pending <= 1'b1;
                    fault_reason  <= hard_reason;
                    fault_session <= session;
                end else begin
                    fault_pending <= 1'b0;
                end
                session             <= 32'd0;
                state               <= ST_WAIT_HELLO;
                epoch               <= 16'd0;
                expected_seq        <= 16'd0;
                hs_nonce            <= 32'd0;
                welcome_pending     <= 1'b0;
                maint_seen          <= 1'b0;
                resync_cleanup_seen <= 1'b0;
                resync_notified     <= 1'b0;
                rec_valid           <= 1'b0;
                // Keep an old CONFIG binding until its reply arrives or the
                // maintenance barrier proves that the parser context retired.
                last_reason         <= hard_reason;
                reply_gen           <= reply_gen + 8'd1;
            end else if (soft_event) begin
                cleanup_request <= 1'b1;
                epoch           <= epoch + 16'd1;
                state           <= ST_RESYNC;
                resync_cleanup_seen <= 1'b0;
                resync_notified     <= 1'b0;
                rec_valid           <= 1'b0;
                welcome_pending     <= 1'b0;
                last_reason         <= soft_reason;
                // config_pending is retained until the maintenance barrier
                // proves the old parser context retired.
            end else if (confirm_fail) begin
                cleanup_request <= 1'b1;
                session             <= 32'd0;
                state               <= ST_WAIT_HELLO;
                epoch               <= 16'd0;
                expected_seq        <= 16'd0;
                hs_nonce            <= 32'd0;
                welcome_pending     <= 1'b0;
                maint_seen          <= 1'b0;
                resync_cleanup_seen <= 1'b0;
                resync_notified     <= 1'b0;
                rec_valid           <= 1'b0;
                config_pending      <= 1'b0;
                last_reason         <= 8'd6;
                reply_gen           <= reply_gen + 8'd1;
            end else begin
                if (hello_new_fire) begin
                    cleanup_request <= 1'b1;
                    session         <= session_counter + 32'd1;
                    session_counter <= session_counter + 32'd1;
                    hs_nonce        <= ctrl_hello_nonce;
                    hello_seq       <= codec_ctrl_seq;
                    epoch           <= 16'd0;
                    expected_seq    <= 16'd0;
                    state           <= ST_CLEANUP;
                    welcome_pending <= 1'b1;
                    if (state != ST_CLEANUP)
                        maint_seen <= 1'b0;
                    resync_cleanup_seen <= 1'b0;
                    resync_notified     <= 1'b0;
                    rec_valid           <= 1'b0;
                    last_reason         <= 8'd0;
                    reply_gen           <= reply_gen + 8'd1;
                end else begin
                    if (welcome_push) begin
                        state           <= ST_WAIT_CONFIRM;
                        welcome_pending <= 1'b0;
                        last_reason     <= 8'd0;
                    end
                    if (resync_push)
                        resync_notified <= 1'b1;

                    if (confirm_activate) begin
                        state        <= ST_ACTIVE;
                        last_reason  <= 8'd0;
                    end

                    if (out_last_midi_current)
                        expected_seq <= expected_seq + 16'd1;

                    if (resume_accept) begin
                        expected_seq <= ctrl_resume_first;
                        rec_valid    <= 1'b1;
                        rec_epoch    <= epoch;
                        rec_first    <= ctrl_resume_first;
                        rec_expected <= ctrl_resume_first;
                        state        <= ST_ACTIVE;
                        last_reason  <= 8'd0;
                    end

                    if (take_config) begin
                        config_pending <= 1'b1;
                        config_seq     <= codec_biz_seq;
                        config_session <= codec_biz_session;
                    end else if (config_push || maintenance_done ||
                                 drop_uncommitted_config || hard_event ||
                                 confirm_fail) begin
                        config_pending <= 1'b0;
                    end
                end
            end

            if (fault_push && !hard_event)
                fault_pending <= 1'b0;
        end
    end

    // ---------------------------------------------------------------------
    // Timers and error window.  Kept in one block so every counter has one
    // driver while still reacting to the combinational event flags above.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            physical_fault_r    <= 1'b0;
            disconnect_event_r  <= 1'b0;
            midi_error_r        <= 1'b0;
            heartbeat_cnt       <= 32'd0;
            confirm_cnt         <= 32'd0;
            progress_timer      <= 32'd0;
            progress_active     <= 1'b0;
            progress_target     <= 16'd0;
            error_count         <= 32'd0;
            error_window_cnt    <= 32'd0;
            error_window_active <= 1'b0;
        end else begin
            physical_fault_r   <= physical_fault;
            disconnect_event_r <= disconnect_event;
            midi_error_r       <= midi_error;

            // Heartbeat: only a valid ACTIVE PING refreshes it.
            if (hard_event || soft_event || confirm_fail || hello_new_fire ||
                confirm_activate || resume_accept)
                heartbeat_cnt <= 32'd0;
            else if (ping_active_valid)
                heartbeat_cnt <= 32'd0;
            else if ((state == ST_ACTIVE) && (HEARTBEAT_CYCLES > 0) &&
                     (heartbeat_cnt < HEARTBEAT_CYCLES - 1))
                heartbeat_cnt <= heartbeat_cnt + 32'd1;

            // Wait-CONFIRM supervisory timeout.
            if (hard_event || soft_event || confirm_fail || hello_new_fire ||
                welcome_push)
                confirm_cnt <= 32'd0;
            else if ((state == ST_WAIT_CONFIRM) && (TIMEOUT_CYCLES > 0) &&
                     (confirm_cnt < TIMEOUT_CYCLES - 1))
                confirm_cnt <= confirm_cnt + 32'd1;

            // Playback progress.  A lagging PING starts the timer but never
            // triggers immediate cleanup; catching up cancels it.
            if (hard_event || soft_event || confirm_fail || hello_new_fire ||
                confirm_activate || resume_accept) begin
                progress_active <= 1'b0;
                progress_timer  <= 32'd0;
            end else if (ping_active_valid) begin
                if ((ctrl_ping_has == 8'd0) ||
                    ((ctrl_ping_last + 16'd1) == expected_seq)) begin
                    progress_active <= 1'b0;
                    progress_timer  <= 32'd0;
                end else if (((ctrl_ping_last + 16'd1) - expected_seq) < 16'h8000) begin
                    progress_target <= ctrl_ping_last + 16'd1;
                    progress_active <= 1'b1;
                    if (!progress_active)
                        progress_timer <= 32'd0;
                    else if ((PROGRESS_CYCLES > 0) &&
                             (progress_timer < PROGRESS_CYCLES - 1))
                        progress_timer <= progress_timer + 32'd1;
                end else begin
                    progress_active <= 1'b0;
                    progress_timer  <= 32'd0;
                end
            end else if (out_last_midi_current && progress_active) begin
                if ((expected_seq + 16'd1) == progress_target) begin
                    progress_active <= 1'b0;
                    progress_timer  <= 32'd0;
                end else if ((PROGRESS_CYCLES > 0) &&
                             (progress_timer < PROGRESS_CYCLES - 1))
                    progress_timer <= progress_timer + 32'd1;
            end else if (progress_active) begin
                if ((PROGRESS_CYCLES > 0) &&
                    (progress_timer < PROGRESS_CYCLES - 1))
                    progress_timer <= progress_timer + 32'd1;
            end

            // Error window: first error opens a window; errors in that window
            // are counted once per codec error pulse.
            if (hard_event || soft_event || confirm_fail || hello_new_fire ||
                confirm_activate || resume_accept) begin
                error_count         <= 32'd0;
                error_window_cnt    <= 32'd0;
                error_window_active <= 1'b0;
            end else begin
                if (error_window_active && (ERROR_WINDOW_CYCLES > 0)) begin
                    if (window_expired) begin
                        error_count         <= 32'd0;
                        error_window_cnt    <= 32'd0;
                        error_window_active <= 1'b0;
                    end else begin
                        error_window_cnt <= error_window_cnt + 32'd1;
                    end
                end
                if (err_event) begin
                    if (!error_window_active || window_expired) begin
                        error_window_active <= 1'b1;
                        error_count         <= 32'd1;
                        error_window_cnt    <= 32'd0;
                    end else begin
                        error_count <= error_count + 32'd1;
                    end
                end
            end
        end
    end

endmodule
