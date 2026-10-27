`timescale 1ns/1ps
// Independent fault-stress integration TB for the dual-UART comm_top.
//
// Focus is deliberately on maintenance/fault behaviour that the normal
// integration TB does not create:
//   - real RX L1 overflow while the shared parser/event queue is stalled
//   - one-source quarantine while the peer keeps producing valid traffic
//   - explicit session_restart gated by cleanup_done/source_ops_idle
//   - no old-source event replay after reopening
//   - a CONFIG already accepted by the backend, then source fault/cancel while
//     the backend result is delayed: wait for the real result, suppress the old
//     reply, retain the committed global value
//   - cfg/reply source+SEQ matching, per-source cache invalidation/replay
//   - fault while a frame is pinned mid-stream and its next event is pending
//
// The wire BFM, UART receiver for TX, SLIP decoder and CRC are implemented here
// independently of the DUT. Drives happen on negedge; event/backend handshakes
// are sampled on posedge BEFORE DUT nonblocking updates. UART wire decoding
// samples on negedge, away from the transmitters' posedge state transitions.

module tb_comm_faults;
    localparam int CLK_HZ       = 1_600_000;
    localparam int WIRED_BAUD   = 200_000;   // 8 clocks/bit
    localparam int BT_BAUD      = 100_000;   // 16 clocks/bit
    localparam int OVERSAMPLE   = 8;
    localparam int BIT_CYC0     = 8;
    localparam int BIT_CYC1     = 16;
    localparam int RX_DEPTH     = 32;
    localparam int FRAME_DEPTH  = 2;
    localparam int EVENT_DEPTH  = 4;
    localparam int TIMEOUT_CYC  = 5000;

    localparam logic [7:0] TYPE_MIDI   = 8'h01;
    localparam logic [7:0] TYPE_CONFIG = 8'h02;
    localparam logic [7:0] TYPE_REPLY  = 8'h80;

    localparam logic [7:0] RESULT_OK        = 8'h00;
    localparam logic [7:0] RESULT_NOT_READY = 8'h06;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic [1:0] rx_i = 2'b11;
    logic [1:0] tx_o;
    logic hc05_state_async = 1'b1;

    logic [1:0] session_restart      = 2'b00;
    logic [1:0] source_cleanup_done  = 2'b11;
    logic [1:0] source_ops_idle      = 2'b11;
    logic       midi_ops_idle        = 1'b1;
    logic [1:0] source_quarantine;
    logic [1:0] link_fault_pending;
    logic [15:0] error_sticky;
    logic [63:0] rx_error_count;

    logic        event_valid;
    logic        event_ready;
    logic [31:0] event_data;
    logic        event_source_id;
    logic        midi_parse_error;
    logic        event_open   = 1'b1;
    logic        event_random = 1'b1;

    logic        cfg_valid;
    logic        cfg_ready;
    logic        cfg_source_id;
    logic [15:0] cfg_seq;
    logic [7:0]  cfg_command;
    logic [4:0]  cfg_payload_len;
    logic [127:0] cfg_shadow;
    logic        cfg_done_valid;
    logic        cfg_done_ready;
    logic [7:0]  cfg_result;

    logic [15:0] random_bits = 16'hace1;
    always @(negedge clk)
        if (rst_n)
            random_bits <= {random_bits[14:0],
                            random_bits[15] ^ random_bits[13] ^
                            random_bits[12] ^ random_bits[10]};

    // Random stalls on the event consumer, but never a permanent deadlock.
    assign event_ready = event_open &&
                         (!event_random ||
                          random_bits[0] || random_bits[2] || random_bits[5]);

    comm_top #(
        .CLK_HZ(CLK_HZ), .WIRED_BAUD(WIRED_BAUD), .BT_BAUD(BT_BAUD),
        .OVERSAMPLE(OVERSAMPLE), .RX_DEPTH(RX_DEPTH),
        .FRAME_DEPTH(FRAME_DEPTH), .EVENT_DEPTH(EVENT_DEPTH),
        .EQ_BANDS(3), .TIMEOUT_CYCLES(TIMEOUT_CYC),
        .BT_HAS_STATE(1'b0), .STATE_DEBOUNCE_CYCLES(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .rx_i(rx_i), .tx_o(tx_o),
        .hc05_state_async(hc05_state_async),
        .session_restart(session_restart),
        .source_cleanup_done(source_cleanup_done),
        .source_ops_idle(source_ops_idle),
        .midi_ops_idle(midi_ops_idle),
        .source_quarantine(source_quarantine),
        .link_fault_pending(link_fault_pending),
        .error_sticky(error_sticky), .rx_error_count(rx_error_count),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_data(event_data), .event_source_id(event_source_id),
        .midi_parse_error(midi_parse_error),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready),
        .cfg_source_id(cfg_source_id), .cfg_seq(cfg_seq),
        .cfg_command(cfg_command), .cfg_payload_len(cfg_payload_len),
        .cfg_shadow(cfg_shadow),
        .cfg_done_valid(cfg_done_valid), .cfg_done_ready(cfg_done_ready),
        .cfg_result(cfg_result)
    );

    // ---------------------------------------------------------------------
    // Mock commit backend.  It applies a global reverb value only when the
    // real completion handshake occurs, never when the request is accepted.
    // ---------------------------------------------------------------------
    logic        backend_pending   = 1'b0;
    integer      backend_delay     = 0;
    integer      backend_delay_set = 8;
    logic        backend_hold_done = 1'b0;
    logic        backend_accept_hold = 1'b0;
    logic [7:0]  backend_result    = 8'h00;
    logic [127:0] backend_shadow   = '0;
    logic        backend_source    = 1'b0;
    logic [15:0] backend_seq       = 16'd0;
    logic [7:0]  backend_command   = 8'd0;
    logic [4:0]  backend_len       = 5'd0;

    integer backend_req_count  = 0;
    integer backend_done_count = 0;
    integer commit_ok_count    = 0;
    logic [7:0] global_preset  = 8'd0;

    assign cfg_ready      = !backend_pending && !backend_accept_hold;
    assign cfg_done_valid = backend_pending && (backend_delay == 0) &&
                            !backend_hold_done;
    assign cfg_result     = backend_result;

    // Expected cfg requests (single global config context).
    logic        exp_cfg_src   [0:127];
    logic [15:0] exp_cfg_seq   [0:127];
    logic [7:0]  exp_cfg_cmd   [0:127];
    logic [4:0]  exp_cfg_len   [0:127];
    logic [127:0] exp_cfg_shadow [0:127];
    integer      exp_cfg_count = 0;
    integer      cfg_req_seen  = 0;

    // Expected replies per source.
    logic [15:0] exp_rep_seq   [0:1][0:127];
    logic [7:0]  exp_rep_cmd   [0:1][0:127];
    logic [7:0]  exp_rep_res   [0:1][0:127];
    integer      exp_rep_min_done [0:1][0:127];
    integer      exp_rep_count [0:1];
    integer      seen_rep      [0:1];

    // Expected MIDI events per source.
    logic [31:0] exp_ev_data   [0:1][0:255];
    integer      exp_ev_count  [0:1];
    integer      seen_ev       [0:1];

    // TX-side independent SLIP/CRC decoder state.
    logic        tx_in_frame [0:1];
    logic        tx_escape   [0:1];
    logic [7:0]  tx_body     [0:1][0:63];
    integer      tx_count    [0:1];

    integer i;
    integer req_before;
    integer reps_before;
    integer random_seed, seed_result;
    logic [255:0] pkt;
    logic [31:0] held_event_data;
    logic        held_event_src;
    logic        event_stalled;

    // ---------------------------------------------------------------------
    // CRC-16/CCITT-FALSE, independent of the DUT package.
    // ---------------------------------------------------------------------
    function automatic logic [15:0] crc_byte(input logic [15:0] old_crc,
                                             input logic [7:0] b);
        logic [15:0] c;
        begin
            c = old_crc ^ {b, 8'h00};
            for (int k = 0; k < 8; k = k + 1)
                c = c[15] ? ((c << 1) ^ 16'h1021) : (c << 1);
            crc_byte = c;
        end
    endfunction

    function automatic int bit_cycles(input int src);
        bit_cycles = (src == 0) ? BIT_CYC0 : BIT_CYC1;
    endfunction

    function automatic logic [31:0] event_word(input int kind, input int ch,
                                               input int d1, input int d2);
        event_word = {4'(kind), 4'(ch), 7'(d1), 7'(d2), 10'b0};
    endfunction

    // ---------------------------------------------------------------------
    // BFM: raw 8N1 serial byte, LSB first, stopped high.  Every edge is driven
    // from negedge clk; callers are serialized per physical source.
    // ---------------------------------------------------------------------
    task automatic uart_send_byte(input int src, input logic [7:0] b,
                                   input int gap);
        int bc;
        begin
            bc = bit_cycles(src);
            repeat (gap) @(negedge clk);
            @(negedge clk);
            rx_i[src] = 1'b0;
            repeat (bc) @(negedge clk);
            for (int j = 0; j < 8; j = j + 1) begin
                rx_i[src] = b[j];
                repeat (bc) @(negedge clk);
            end
            rx_i[src] = 1'b1;
            repeat (bc) @(negedge clk);
        end
    endtask

    task automatic send_wire_byte(input int src, input logic [7:0] b,
                                  input int gap);
        begin
            if (b == 8'hc0) begin
                uart_send_byte(src, 8'hdb, gap);
                uart_send_byte(src, 8'hdc, gap);
            end else if (b == 8'hdb) begin
                uart_send_byte(src, 8'hdb, gap);
                uart_send_byte(src, 8'hdd, gap);
            end else begin
                uart_send_byte(src, b, gap);
            end
        end
    endtask

    task automatic send_frame(input int src, input logic [7:0] typ,
                              input logic [15:0] seq, input int len,
                              input logic [255:0] payload,
                              input int start_gap, input int inter_gap);
        logic [7:0] body [0:39];
        logic [15:0] checksum;
        begin
            body[0] = 8'h01;
            body[1] = typ;
            body[2] = seq[7:0];
            body[3] = seq[15:8];
            body[4] = 8'(len);
            body[5] = 8'(len >> 8);
            for (int j = 0; j < len; j = j + 1)
                body[6+j] = payload[j*8 +: 8];
            checksum = 16'hffff;
            for (int j = 0; j < len + 6; j = j + 1)
                checksum = crc_byte(checksum, body[j]);
            body[6+len]   = checksum[7:0];
            body[7+len]   = checksum[15:8];

            repeat (start_gap) @(negedge clk);
            uart_send_byte(src, 8'hc0, 0);
            for (int j = 0; j < len + 8; j = j + 1)
                send_wire_byte(src, body[j], inter_gap);
            uart_send_byte(src, 8'hc0, 0);
        end
    endtask

    task automatic send_reverb(input int src, input logic [15:0] seq,
                               input int preset);
        logic [255:0] local_payload;
        begin
            local_payload = '0;
            local_payload[7:0]   = 8'h02;
            local_payload[15:8]  = 8'(preset);
            send_frame(src, TYPE_CONFIG, seq, 2, local_payload, 0, 0);
        end
    endtask

    task automatic send_midi_note(input int src, input logic [15:0] seq,
                                  input int ch, input int note,
                                  input int velocity, input int start_gap);
        logic [255:0] local_payload;
        begin
            local_payload = '0;
            local_payload[7:0]    = 8'h90 | 8'(ch);
            local_payload[15:8]   = 8'(note);
            local_payload[23:16]  = 8'(velocity);
            send_frame(src, TYPE_MIDI, seq, 3, local_payload, start_gap, 0);
        end
    endtask

    task automatic random_midi_stream(input int src, input int base_note,
                                      input int ch, input int nframes,
                                      input int seq_base);
        begin
            repeat ($urandom_range(0, 90)) @(negedge clk);
            for (int j = 0; j < nframes; j = j + 1) begin
                send_midi_note(src, 16'(seq_base + j), ch,
                               base_note + j, 100, 0);
                repeat ($urandom_range(0, 55)) @(negedge clk);
            end
        end
    endtask

    // ---------------------------------------------------------------------
    // Scoreboard helpers.
    // ---------------------------------------------------------------------
    task automatic expect_event(input int src, input logic [31:0] data);
        begin
            if (exp_ev_count[src] >= 256)
                $fatal(1, "event scoreboard overflow src=%0d", src);
            exp_ev_data[src][exp_ev_count[src]] = data;
            exp_ev_count[src] = exp_ev_count[src] + 1;
        end
    endtask

    task automatic expect_cfg(input int src, input logic [15:0] seq,
                              input logic [7:0] cmd, input int len,
                              input logic [127:0] shadow);
        begin
            if (exp_cfg_count >= 128)
                $fatal(1, "cfg request scoreboard overflow");
            exp_cfg_src[exp_cfg_count]    = src[0];
            exp_cfg_seq[exp_cfg_count]    = seq;
            exp_cfg_cmd[exp_cfg_count]    = cmd;
            exp_cfg_len[exp_cfg_count]    = 5'(len);
            exp_cfg_shadow[exp_cfg_count] = shadow;
            exp_cfg_count = exp_cfg_count + 1;
        end
    endtask

    task automatic expect_reverb_req(input int src, input logic [15:0] seq,
                                     input int preset);
        logic [127:0] sh;
        begin
            sh = '0;
            sh[7:0]  = 8'h02;
            sh[15:8] = 8'(preset);
            expect_cfg(src, seq, 8'h02, 2, sh);
        end
    endtask

    task automatic expect_reply(input int src, input logic [15:0] seq,
                                input logic [7:0] cmd, input logic [7:0] res,
                                input int needs_commit);
        integer n;
        begin
            n = exp_rep_count[src];
            if (n >= 128)
                $fatal(1, "reply scoreboard overflow src=%0d", src);
            exp_rep_seq[src][n] = seq;
            exp_rep_cmd[src][n] = cmd;
            exp_rep_res[src][n] = res;
            exp_rep_min_done[src][n] = needs_commit ?
                                       (backend_done_count + 1) : 0;
            exp_rep_count[src] = n + 1;
        end
    endtask

    task automatic check_preset(input logic [7:0] want);
        begin
            if (global_preset !== want)
                $fatal(1, "global preset=%0d expected %0d", global_preset, want);
        end
    endtask

    task automatic wait_events(input int maxc);
        int n;
        begin
            n = 0;
            while ((seen_ev[0] != exp_ev_count[0]) ||
                   (seen_ev[1] != exp_ev_count[1])) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "event timeout seen=%0d/%0d %0d/%0d",
                           seen_ev[0], exp_ev_count[0],
                           seen_ev[1], exp_ev_count[1]);
            end
            repeat (20) @(negedge clk);
        end
    endtask

    task automatic wait_replies(input int maxc);
        int n;
        begin
            n = 0;
            while ((seen_rep[0] != exp_rep_count[0]) ||
                   (seen_rep[1] != exp_rep_count[1])) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "reply timeout seen=%0d/%0d %0d/%0d",
                           seen_rep[0], exp_rep_count[0],
                           seen_rep[1], exp_rep_count[1]);
            end
            repeat (20) @(negedge clk);
        end
    endtask

    task automatic wait_quarantine(input int src, input int maxc);
        int n;
        begin
            n = 0;
            while (!source_quarantine[src]) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "timeout waiting quarantine src=%0d", src);
            end
        end
    endtask

    task automatic wait_not_quarantine(input int src, input int maxc);
        int n;
        begin
            n = 0;
            while (source_quarantine[src]) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "timeout waiting quarantine clear src=%0d", src);
            end
        end
    endtask

    task automatic wait_engine_idle(input int maxc);
        int n;
        begin
            n = 0;
            while (dut.arb_busy || dut.dispatch_busy || (dut.ev_level != 0)) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "engine idle timeout arb=%0b dispatch=%0b ev=%0d",
                           dut.arb_busy, dut.dispatch_busy, dut.ev_level);
            end
        end
    endtask

    task automatic wait_arb_dispatch_idle(input int maxc);
        int n;
        begin
            n = 0;
            while (dut.arb_busy || dut.dispatch_busy) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "arb/dispatch idle timeout arb=%0b dispatch=%0b",
                           dut.arb_busy, dut.dispatch_busy);
            end
        end
    endtask

    task automatic wait_backend_pending(input int maxc);
        int n;
        begin
            n = 0;
            while (!backend_pending) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "backend accepted-request timeout");
            end
        end
    endtask

    task automatic wait_backend_clear(input int maxc);
        int n;
        begin
            n = 0;
            while (backend_pending) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "backend completion timeout");
            end
        end
    endtask

    task automatic pulse_restart(input int src);
        begin
            @(negedge clk);
            session_restart[src] = 1'b1;
            @(negedge clk);
            @(negedge clk);
            session_restart[src] = 1'b0;
        end
    endtask

    task automatic wait_ev_level(input int want, input int maxc);
        int n;
        begin
            n = 0;
            while (dut.ev_level != want) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "event level timeout level=%0d want=%0d",
                           dut.ev_level, want);
            end
        end
    endtask

    task automatic wait_frame_pinned(input int src, input int maxc);
        int n;
        begin
            n = 0;
            while (!(dut.pin[src] && dut.arb_busy)) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "frame did not pin src=%0d", src);
            end
            // Also require a generated event waiting on the full event FIFO,
            // so the last accepted payload byte is still outstanding.
            n = 0;
            while (!dut.u_dispatch.u_midi.event_valid) begin
                @(negedge clk);
                n = n + 1;
                if (n > maxc)
                    $fatal(1, "pending event did not form in pinned frame");
            end
        end
    endtask

    task automatic check_uart_break(input int src);
        begin
            if (!(error_sticky[src*8 + 5] || error_sticky[src*8 + 6]))
                $fatal(1, "UART framing/break sticky missing src=%0d", src);
        end
    endtask

    // ---------------------------------------------------------------------
    // Independent UART receiver for the two TX pins.  Samples at bit centres
    // starting from a negedge-detected falling start edge.
    // ---------------------------------------------------------------------
    for (genvar g = 0; g < 2; g = g + 1) begin : g_txmon
        localparam int BC = (g == 0) ? BIT_CYC0 : BIT_CYC1;
        integer rx_state;
        integer rx_cnt;
        integer rx_bidx;
        logic [7:0] rx_shift;

        always @(negedge clk) begin
            if (!rst_n) begin
                rx_state <= 0;
                rx_cnt   <= 0;
                rx_bidx  <= 0;
                rx_shift <= 8'h00;
            end else if (rx_state == 0) begin
                if (!tx_o[g]) begin
                    rx_state <= 1;
                    rx_cnt   <= ((3 * BC) / 2) - 1;
                    rx_bidx  <= 0;
                end
            end else begin
                if (rx_cnt != 0) begin
                    rx_cnt <= rx_cnt - 1;
                end else if (rx_bidx < 8) begin
                    rx_shift[rx_bidx] <= tx_o[g];
                    rx_bidx <= rx_bidx + 1;
                    rx_cnt  <= BC - 1;
                end else begin
                    if (!tx_o[g])
                        $fatal(1, "TX stop bit low src=%0d", g);
                    rx_state <= 0;
                    tx_wire_byte(g, rx_shift);
                end
            end
        end
    end

    task automatic tx_wire_byte(input int src, input logic [7:0] b);
        integer n;
        begin
            if (!tx_in_frame[src]) begin
                if (b !== 8'hc0)
                    $fatal(1, "TX byte without leading C0 src=%0d b=%02h",
                           src, b);
                tx_in_frame[src] = 1'b1;
                tx_escape[src]   = 1'b0;
                tx_count[src]    = 0;
            end else if (tx_escape[src]) begin
                if (tx_count[src] >= 64)
                    $fatal(1, "TX reply body overflow src=%0d", src);
                if (b == 8'hdc)
                    tx_body[src][tx_count[src]] = 8'hc0;
                else if (b == 8'hdd)
                    tx_body[src][tx_count[src]] = 8'hdb;
                else
                    $fatal(1, "TX bad SLIP escape DB %02h src=%0d", b, src);
                tx_count[src]  = tx_count[src] + 1;
                tx_escape[src] = 1'b0;
            end else if (b == 8'hdb) begin
                tx_escape[src] = 1'b1;
            end else if (b == 8'hc0) begin
                if (tx_count[src] != 0)
                    validate_reply(src);
                tx_count[src]  = 0;
                tx_escape[src] = 1'b0;
            end else begin
                if (tx_count[src] >= 64)
                    $fatal(1, "TX reply body overflow src=%0d", src);
                tx_body[src][tx_count[src]] = b;
                tx_count[src] = tx_count[src] + 1;
            end
        end
    endtask

    task automatic validate_reply(input int src);
        logic [15:0] crc;
        logic [15:0] seq;
        integer n;
        begin
            if (tx_count[src] != 11)
                $fatal(1, "reply body length=%0d src=%0d",
                       tx_count[src], src);
            if ((tx_body[src][0] !== 8'h01) ||
                (tx_body[src][1] !== TYPE_REPLY) ||
                (tx_body[src][4] !== 8'h03) ||
                (tx_body[src][5] !== 8'h00) ||
                (tx_body[src][6] !== TYPE_CONFIG))
                $fatal(1, "reply header mismatch src=%0d", src);

            crc = 16'hffff;
            for (int j = 0; j < 9; j = j + 1)
                crc = crc_byte(crc, tx_body[src][j]);
            if (crc !== {tx_body[src][10], tx_body[src][9]})
                $fatal(1, "reply CRC mismatch src=%0d", src);

            seq = {tx_body[src][3], tx_body[src][2]};
            n = seen_rep[src];
            if (n >= exp_rep_count[src])
                $fatal(1, "unexpected reply src=%0d seq=%0d cmd=%0d res=%0d",
                       src, seq, tx_body[src][7], tx_body[src][8]);
            if ((seq !== exp_rep_seq[src][n]) ||
                (tx_body[src][7] !== exp_rep_cmd[src][n]) ||
                (tx_body[src][8] !== exp_rep_res[src][n]))
                $fatal(1, "reply mismatch src=%0d idx=%0d wire(seq=%0d cmd=%0d res=%0d) exp(seq=%0d cmd=%0d res=%0d)",
                       src, n, seq, tx_body[src][7], tx_body[src][8],
                       exp_rep_seq[src][n], exp_rep_cmd[src][n],
                       exp_rep_res[src][n]);
            if ((exp_rep_min_done[src][n] != 0) &&
                (backend_done_count < exp_rep_min_done[src][n]))
                $fatal(1, "reply before real backend completion src=%0d seq=%0d done=%0d need=%0d",
                       src, seq, backend_done_count,
                       exp_rep_min_done[src][n]);
            seen_rep[src] = n + 1;
        end
    endtask

    // ---------------------------------------------------------------------
    // Backend / config-request scoreboard.
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            backend_pending   <= 1'b0;
            backend_delay     <= 0;
            backend_hold_done <= 1'b0;
            backend_accept_hold <= 1'b0;
            backend_result    <= 8'h00;
            backend_shadow    <= '0;
            backend_source    <= 1'b0;
            backend_seq       <= 16'd0;
            backend_command   <= 8'd0;
            backend_len       <= 5'd0;
            backend_req_count <= 0;
            backend_done_count <= 0;
            commit_ok_count   <= 0;
            global_preset     <= 8'd0;
            cfg_req_seen      <= 0;
        end else if (cfg_valid && cfg_ready) begin
            if (cfg_req_seen >= exp_cfg_count)
                $fatal(1, "unexpected cfg request src=%0d seq=%0d cmd=%0d len=%0d",
                       cfg_source_id, cfg_seq, cfg_command, cfg_payload_len);
            if ((cfg_source_id !== exp_cfg_src[cfg_req_seen]) ||
                (cfg_seq !== exp_cfg_seq[cfg_req_seen]) ||
                (cfg_command !== exp_cfg_cmd[cfg_req_seen]) ||
                (cfg_payload_len !== exp_cfg_len[cfg_req_seen]) ||
                (cfg_shadow !== exp_cfg_shadow[cfg_req_seen]))
                $fatal(1, "cfg request mismatch idx=%0d wire(src=%0d seq=%0d cmd=%0d len=%0d) exp(src=%0d seq=%0d cmd=%0d len=%0d)",
                       cfg_req_seen, cfg_source_id, cfg_seq, cfg_command,
                       cfg_payload_len, exp_cfg_src[cfg_req_seen],
                       exp_cfg_seq[cfg_req_seen], exp_cfg_cmd[cfg_req_seen],
                       exp_cfg_len[cfg_req_seen]);
            cfg_req_seen      <= cfg_req_seen + 1;
            backend_req_count <= backend_req_count + 1;
            backend_pending   <= 1'b1;
            backend_delay     <= backend_delay_set;
            backend_source    <= cfg_source_id;
            backend_seq       <= cfg_seq;
            backend_command   <= cfg_command;
            backend_len       <= cfg_payload_len;
            backend_shadow    <= cfg_shadow;
            // Deliberately no EQ backend; EQ is a real, cached NOT_READY.
            backend_result    <= (cfg_command == 8'h01) ?
                                  RESULT_NOT_READY : RESULT_OK;
        end else if (backend_pending) begin
            if (backend_delay > 0) begin
                backend_delay <= backend_delay - 1;
            end else if (cfg_done_valid && cfg_done_ready) begin
                backend_pending    <= 1'b0;
                backend_done_count <= backend_done_count + 1;
                if (backend_result == RESULT_OK) begin
                    commit_ok_count <= commit_ok_count + 1;
                    if ((backend_command == 8'h02) && (backend_len == 5'd2))
                        global_preset <= backend_shadow[15:8];
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // Event scoreboard and stalled-output stability check.
    // ---------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            event_stalled    <= 1'b0;
            held_event_src   <= 1'b0;
            held_event_data  <= 32'd0;
            seen_ev[0] <= 0;
            seen_ev[1] <= 0;
            for (i = 0; i < 2; i = i + 1) begin
                exp_ev_count[i] <= 0;
                exp_rep_count[i] <= 0;
                seen_rep[i] <= 0;
                tx_in_frame[i] <= 1'b0;
                tx_escape[i] <= 1'b0;
                tx_count[i] <= 0;
            end
            exp_cfg_count <= 0;
        end else begin
            if (event_stalled) begin
                if (event_valid) begin
                    if ((event_source_id !== held_event_src) ||
                        (event_data !== held_event_data))
                        $fatal(1, "stalled event changed src=%0d data=%h",
                               event_source_id, event_data);
                end else if (!source_quarantine[held_event_src] &&
                             !link_fault_pending[held_event_src] &&
                             !session_restart[held_event_src] &&
                             !dut.fault_now[held_event_src] &&
                             !dut.restart_req[held_event_src]) begin
                    $fatal(1, "event_valid dropped without handshake src=%0d quar=%0b faultp=%0b rst=%0b faultnow=%0b lvl=%0d evc=%0b",
                           held_event_src, source_quarantine[held_event_src],
                           link_fault_pending[held_event_src],
                           session_restart[held_event_src],
                           dut.fault_now[held_event_src], dut.ev_level,
                           dut.ev_cancel);
                end
            end

            if (event_valid) begin
                event_stalled   <= !event_ready &&
                                   !source_quarantine[event_source_id] &&
                                   !session_restart[event_source_id];
                held_event_src  <= event_source_id;
                held_event_data <= event_data;

                if (event_ready) begin
                    if (seen_ev[event_source_id] >=
                        exp_ev_count[event_source_id])
                        $fatal(1, "unexpected event src=%0d data=%h",
                               event_source_id, event_data);
                    if (event_data !==
                        exp_ev_data[event_source_id][seen_ev[event_source_id]])
                        $fatal(1, "event mismatch src=%0d idx=%0d wire=%h exp=%h",
                               event_source_id, seen_ev[event_source_id],
                               event_data,
                               exp_ev_data[event_source_id]
                                          [seen_ev[event_source_id]]);
                    seen_ev[event_source_id] =
                        seen_ev[event_source_id] + 1;
                end
            end else begin
                event_stalled <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Test sequence.
    // ---------------------------------------------------------------------
    initial begin
        if ($value$plusargs("seed=%d", random_seed)) begin
            seed_result = $urandom(random_seed);
            random_bits = (random_seed[15:0] == 0) ? 16'hace1 : random_seed[15:0];
        end
        for (i = 0; i < 2; i = i + 1) begin
            exp_ev_count[i] = 0;
            seen_ev[i] = 0;
            exp_rep_count[i] = 0;
            seen_rep[i] = 0;
            tx_in_frame[i] = 1'b0;
            tx_escape[i] = 1'b0;
            tx_count[i] = 0;
        end
        exp_cfg_count = 0;
        cfg_req_seen = 0;

        // Self-check the TB's independent CRC against the protocol vector.
        begin : crc_self_check
            logic [15:0] c;
            c = 16'hffff;
            c = crc_byte(c, 8'h31);
            c = crc_byte(c, 8'h32);
            c = crc_byte(c, 8'h33);
            c = crc_byte(c, 8'h34);
            c = crc_byte(c, 8'h35);
            c = crc_byte(c, 8'h36);
            c = crc_byte(c, 8'h37);
            c = crc_byte(c, 8'h38);
            c = crc_byte(c, 8'h39);
            if (c !== 16'h29b1)
                $fatal(1, "TB CRC self-check failed: %04h", c);
        end

        repeat (12) @(negedge clk);
        rst_n = 1'b1;
        repeat (20) @(negedge clk);

        // =================================================================
        // Phase 0: same CONFIG SEQ on both sources, then distinct SEQs.
        // Both source caches must be independent; a replay of a historic OK
        // must not re-commit and must not roll back the other source's value.
        // =================================================================
        expect_reverb_req(0, 16'h5151, 1);              // HALL
        expect_reply(0, 16'h5151, 8'h02, RESULT_OK, 1);
        send_reverb(0, 16'h5151, 1);
        wait_replies(30000);
        check_preset(8'd1);

        expect_reverb_req(1, 16'h5151, 2);              // BATHROOM, same SEQ
        expect_reply(1, 16'h5151, 8'h02, RESULT_OK, 1);
        send_reverb(1, 16'h5151, 2);
        wait_replies(30000);
        check_preset(8'd2);

        req_before = backend_req_count;
        expect_reply(0, 16'h5151, 8'h02, RESULT_OK, 0); // historic replay
        send_reverb(0, 16'h5151, 1);
        wait_replies(30000);
        if (backend_req_count != req_before)
            $fatal(1, "replayed source0 CONFIG committed again");
        check_preset(8'd2);   // source1's newer global value survives

        expect_reverb_req(0, 16'h3333, 1);              // HALL
        expect_reply(0, 16'h3333, 8'h02, RESULT_OK, 1);
        send_reverb(0, 16'h3333, 1);
        wait_replies(30000);
        check_preset(8'd1);

        expect_reverb_req(1, 16'h4444, 2);              // BATHROOM
        expect_reply(1, 16'h4444, 8'h02, RESULT_OK, 1);
        send_reverb(1, 16'h4444, 2);
        wait_replies(30000);
        check_preset(8'd2);
        $display("faultTB: per-source CONFIG cache and SEQ routing PASS");

        // =================================================================
        // Phase 1: randomized source interleaving on the two real UARTs.
        // =================================================================
        event_open = 1'b1;
        event_random = 1'b1;
        for (i = 0; i < 4; i = i + 1) begin
            expect_event(0, event_word(1, 0, 8'h30 + i, 8'd100));
            expect_event(1, event_word(1, 1, 8'h50 + i, 8'd100));
        end
        fork
            random_midi_stream(0, 8'h30, 0, 4, 16'h0300);
            random_midi_stream(1, 8'h50, 1, 4, 16'h0400);
        join
        wait_events(60000);
        if (event_source_id === 1'bx)
            $fatal(1, "event source went X");
        $display("faultTB: randomized dual-source interleave PASS");

        // =================================================================
        // Phase 2: real RX L1 overflow while the event FIFO/parser is stalled.
        // The BFM keeps transmitting; the DUT must report source0 overflow,
        // quarantine only source0, and drop its old queued events.  Source1
        // must still deliver a fresh event.
        // =================================================================
        event_open = 1'b0;
        event_random = 1'b0;
        wait_engine_idle(20000);
        if (source_quarantine != 2'b00)
            $fatal(1, "unexpected quarantine before overflow test");

        for (i = 0; i < EVENT_DEPTH; i = i + 1) begin
            pkt = '0;
            pkt[7:0]   = 8'h90;
            pkt[15:8]  = 8'(8'h10 + i);
            pkt[23:16] = 8'd100;
            send_frame(0, TYPE_MIDI, 16'(16'h2000 + i), 3, pkt, 0, 0);
        end
        // Freeze the consumer with the shared event FIFO completely full, then
        // continue transmitting until the real byte FIFO overflows.
        wait_ev_level(EVENT_DEPTH, 20000);
        for (i = EVENT_DEPTH; i < 18; i = i + 1) begin
            pkt = '0;
            pkt[7:0]   = 8'h90;
            pkt[15:8]  = 8'(8'h10 + i);
            pkt[23:16] = 8'd100;
            send_frame(0, TYPE_MIDI, 16'(16'h2000 + i), 3, pkt, 0, 0);
        end
        wait_quarantine(0, 5000);
        if (source_quarantine[1])
            $fatal(1, "overflow quarantined peer source");
        if (!error_sticky[7])
            $fatal(1, "RX overflow sticky not set src0: %04h", error_sticky);
        if (rx_error_count[31:0] == 0)
            $fatal(1, "RX overflow error cycle counter is zero");

        event_open = 1'b1;
        wait_engine_idle(30000);
        if (!source_quarantine[0])
            $fatal(1, "overflow quarantine disappeared without restart");
        if (seen_ev[0] != exp_ev_count[0])
            $fatal(1, "old source0 event escaped overflow quarantine");

        expect_event(1, event_word(1, 1, 8'h70, 8'd91));
        send_midi_note(1, 16'h2400, 1, 8'h70, 8'd91, 0);
        wait_events(30000);
        if (!source_quarantine[0])
            $fatal(1, "peer traffic cleared source0 quarantine");
        $display("faultTB: RX overflow + one-source quarantine + peer PASS");

        // =================================================================
        // Phase 3: explicit session restart, gated by cleanup_done and
        // source_ops_idle.  After reopening, source0's cache is gone while
        // source1's cache and global value are retained.
        // =================================================================
        session_restart[0] = 1'b1;
        source_cleanup_done[0] = 1'b0;
        source_ops_idle[0] = 1'b0;
        @(negedge clk);
        @(negedge clk);
        session_restart[0] = 1'b0;

        wait_engine_idle(30000);
        repeat (300) @(negedge clk);
        if (!source_quarantine[0])
            $fatal(1, "restart cleared before cleanup_done/source_ops_idle");
        if (!link_fault_pending[0])
            $fatal(1, "link_fault_pending dropped before cleanup");
        if (source_quarantine[1])
            $fatal(1, "source0 restart quarantined source1");

        source_cleanup_done[0] = 1'b1;      // ops still not retired
        repeat (250) @(negedge clk);
        if (!source_quarantine[0])
            $fatal(1, "restart ignored source_ops_idle gating");

        source_ops_idle[0] = 1'b1;
        wait_not_quarantine(0, 30000);
        repeat (60) @(negedge clk);

        // Reopen source0.  Any replayed overflow event would be an immediate
        // scoreboard error because this is the first expected source0 event.
        expect_event(0, event_word(1, 0, 8'h55, 8'd77));
        send_midi_note(0, 16'h2500, 0, 8'h55, 8'd77, 0);
        wait_events(30000);
        if (seen_ev[0] != exp_ev_count[0])
            $fatal(1, "old source0 events appeared after reopen");

        // Same SEQ that was cached before the restart must commit again.
        expect_reverb_req(0, 16'h3333, 1);
        expect_reply(0, 16'h3333, 8'h02, RESULT_OK, 1);
        send_reverb(0, 16'h3333, 1);
        wait_replies(30000);
        check_preset(8'd1);

        // The other source's cache must survive source0's session reset, and
        // its historic OK replay must not revert the newer global value.
        req_before = backend_req_count;
        expect_reply(1, 16'h4444, 8'h02, RESULT_OK, 0);
        send_reverb(1, 16'h4444, 2);
        wait_replies(30000);
        if (backend_req_count != req_before)
            $fatal(1, "source1 cache was cleared by source0 restart");
        check_preset(8'd1);
        $display("faultTB: restart gating, reopen, per-source cache PASS");

        // =================================================================
        // Phase 4: CONFIG already accepted by the backend, then a hard UART
        // fault while the real completion is held.  The old reply must never
        // appear; the eventual commit must still take effect exactly once.
        // =================================================================
        wait_engine_idle(30000);
        backend_hold_done = 1'b1;
        backend_delay_set = 4;
        expect_reverb_req(0, 16'h7777, 2);
        reps_before = seen_rep[0];
        req_before = backend_req_count;
        send_reverb(0, 16'h7777, 2);
        wait_backend_pending(30000);
        if ((backend_source !== 1'b0) || (backend_seq !== 16'h7777) ||
            (backend_command !== 8'h02))
            $fatal(1, "backend accepted wrong CONFIG context");
        if (backend_req_count != req_before + 1)
            $fatal(1, "backend accepted duplicate CONFIG");

        repeat (4) @(negedge clk);
        rx_i[0] = 1'b0;
        repeat (BIT_CYC0 * 20) @(negedge clk);
        rx_i[0] = 1'b1;
        wait_quarantine(0, 30000);
        check_uart_break(0);
        check_preset(8'd1);              // backend has not completed yet
        repeat (350) @(negedge clk);
        if (seen_rep[0] != reps_before)
            $fatal(1, "cancelled accepted CONFIG emitted an old reply");
        if (!backend_pending)
            $fatal(1, "held backend request vanished after source fault");
        if (!source_quarantine[0])
            $fatal(1, "hard-fault quarantine dropped without restart");
        if (backend_req_count != req_before + 1)
            $fatal(1, "source fault re-issued accepted CONFIG");

        // Give the backend its real, delayed result after the source has
        // already been quarantined.  The committed value must survive.
        backend_hold_done = 1'b0;
        wait_backend_clear(30000);
        repeat (200) @(negedge clk);
        check_preset(8'd2);
        if (seen_rep[0] != reps_before)
            $fatal(1, "reply leaked after delayed real completion");
        if (!source_quarantine[0])
            $fatal(1, "quarantine cleared without an explicit restart");

        wait_engine_idle(30000);
        expect_event(1, event_word(1, 1, 8'h71, 8'd92));
        send_midi_note(1, 16'h2600, 1, 8'h71, 8'd92, 0);
        wait_events(30000);
        if (!source_quarantine[0])
            $fatal(1, "peer cleared faulted source0");

        pulse_restart(0);
        wait_not_quarantine(0, 30000);
        repeat (80) @(negedge clk);
        if (seen_rep[0] != reps_before)
            $fatal(1, "old CONFIG reply replayed after reopen");

        expect_event(0, event_word(1, 0, 8'h56, 8'd78));
        send_midi_note(0, 16'h2700, 0, 8'h56, 8'd78, 0);
        wait_events(30000);

        // Cache was cleared at restart: the same request must really commit.
        expect_reverb_req(0, 16'h7777, 2);
        expect_reply(0, 16'h7777, 8'h02, RESULT_OK, 1);
        send_reverb(0, 16'h7777, 2);
        wait_replies(30000);
        check_preset(8'd2);
        $display("faultTB: delayed backend cancel, no old reply, real commit PASS");

        // =================================================================
        // Phase 5: fault while a frame is pinned mid-stream and its next
        // event is pending on the full event FIFO.  Old events must die, the
        // serializer must not hang, and source1's cache must be invalidated.
        // =================================================================
        event_open = 1'b0;
        event_random = 1'b0;
        wait_engine_idle(30000);

        for (i = 0; i < EVENT_DEPTH; i = i + 1) begin
            pkt = '0;
            pkt[7:0]   = 8'h91;
            pkt[15:8]  = 8'(8'h20 + i);
            pkt[23:16] = 8'd90;
            send_frame(1, TYPE_MIDI, 16'(16'h2800 + i), 3, pkt, 0, 0);
        end
        wait_ev_level(EVENT_DEPTH, 30000);
        wait_arb_dispatch_idle(30000);
        if (dut.ev_level != EVENT_DEPTH)
            $fatal(1, "event FIFO unexpectedly drained before pin test");

        // The third byte completes the frame's last (only) musical event, but
        // the shared event FIFO is full, so it stays pending.  A trailing
        // real-time byte remains unaccepted, leaving the frame pinned.  Faulting
        // here covers both a pinned transport frame and the last pending event.
        pkt = '0;
        pkt[7:0]   = 8'h91; pkt[15:8]  = 8'h22;
        pkt[23:16] = 8'd90; pkt[31:24] = 8'hf8;
        send_frame(1, TYPE_MIDI, 16'h2900, 4, pkt, 0, 0);
        wait_frame_pinned(1, 30000);
        if (dut.ev_level != EVENT_DEPTH)
            $fatal(1, "pin scenario event FIFO is not full");

        reps_before = seen_rep[1];
        pulse_restart(1);
        wait_engine_idle(60000);
        wait_not_quarantine(1, 60000);
        if (source_quarantine[0])
            $fatal(1, "source1 restart quarantined source0");
        if (seen_rep[1] != reps_before)
            $fatal(1, "pinned-frame fault created a reply");

        event_open = 1'b1;
        repeat (250) @(negedge clk);
        if (seen_ev[1] != exp_ev_count[1])
            $fatal(1, "old pinned-source events appeared after reopen: %0d/%0d",
                   seen_ev[1], exp_ev_count[1]);

        expect_event(1, event_word(1, 1, 8'h60, 8'd93));
        send_midi_note(1, 16'h2a00, 1, 8'h60, 8'd93, 0);
        wait_events(30000);

        // Source1 cache was invalidated by its own restart.
        expect_reverb_req(1, 16'h4444, 2);
        expect_reply(1, 16'h4444, 8'h02, RESULT_OK, 1);
        send_reverb(1, 16'h4444, 2);
        wait_replies(30000);
        check_preset(8'd2);

        // Source0's unrelated cache must still be replayable without commit.
        req_before = backend_req_count;
        expect_reply(0, 16'h7777, 8'h02, RESULT_OK, 0);
        send_reverb(0, 16'h7777, 2);
        wait_replies(30000);
        if (backend_req_count != req_before)
            $fatal(1, "source0 cache cleared by source1 restart");
        check_preset(8'd2);
        $display("faultTB: pinned frame + pending event fault/reopen PASS");

        // =================================================================
        // Final conservation checks.
        // =================================================================
        wait_engine_idle(30000);
        repeat (200) @(negedge clk);
        if (source_quarantine != 2'b00)
            $fatal(1, "quarantine left asserted at end");
        if (seen_ev[0] != exp_ev_count[0] ||
            seen_ev[1] != exp_ev_count[1])
            $fatal(1, "event count mismatch at end");
        if (seen_rep[0] != exp_rep_count[0] ||
            seen_rep[1] != exp_rep_count[1])
            $fatal(1, "reply count mismatch at end");
        if (cfg_req_seen != exp_cfg_count)
            $fatal(1, "cfg request count mismatch seen=%0d exp=%0d",
                   cfg_req_seen, exp_cfg_count);
        if (backend_req_count != exp_cfg_count)
            $fatal(1, "backend request count mismatch");
        if (backend_pending)
            $fatal(1, "backend request left pending at end");
        if (dut.ev_level != 0 || dut.dispatch_busy || dut.arb_busy)
            $fatal(1, "communication engine not quiescent at end");

        $display("PASS tb_comm_faults events=%0d replies=%0d cfg_req=%0d commits=%0d errors=%04h",
                 seen_ev[0] + seen_ev[1],
                 seen_rep[0] + seen_rep[1],
                 cfg_req_seen, commit_ok_count, error_sticky);
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "fault integration watchdog");
    end

endmodule
