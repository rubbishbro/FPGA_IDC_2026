`timescale 1ns/1ps

module tb_control_loop #(
    parameter int SOURCES = 3,
    parameter int REQUEST_W = 17
);
    localparam int SOURCE_W = (SOURCES > 1) ? $clog2(SOURCES) : 1;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, poll_tick = 0, req_ready = 0;
    logic [SOURCES-1:0] src_valid = '0, src_ready;
    logic [SOURCES-1:0][REQUEST_W-1:0] src_request = '0;
    logic req_valid;
    logic [REQUEST_W-1:0] req_request;
    logic [SOURCE_W-1:0] req_source;

    control_loop #(.SOURCES(SOURCES), .REQUEST_W(REQUEST_W)) dut (.*);

    integer accepted = 0, delivered = 0, cancelled = 0;
    integer per_source [0:SOURCES-1];
    logic expected_valid = 0;
    logic [REQUEST_W-1:0] expected_request;
    integer expected_source;
    logic was_stalled = 0;
    logic [REQUEST_W+SOURCE_W-1:0] held_output;
    logic [SOURCES-1:0] last_accept = '0;
    logic [SOURCES-1:0] all_sources = '1;
    logic [SOURCES-1:0] mask;
    integer before_count, before_delivered, chosen, seed = 1;
    logic [31:0] random_state;

    function automatic logic [31:0] next_random(input logic [31:0] value);
        logic [31:0] x;
        begin
            x = value ^ (value << 13);
            x = x ^ (x >> 17);
            next_random = x ^ (x << 5);
        end
    endfunction

    // Payload bits span multiple machine words, including the wide test cases.
    task automatic fresh_payload(input integer source);
        logic [REQUEST_W-1:0] payload;
        for (integer bit_index = 0; bit_index < REQUEST_W; bit_index++) begin
            random_state = next_random(random_state);
            payload[bit_index] = random_state[0];
        end
        src_request[source] = payload;
    endtask

    // Scoreboard observes only handshakes and externally visible properties.
    always @(posedge clk) begin : scoreboard
        integer grants;
        last_accept = '0;
        if (!rst_n) begin
            if (src_ready !== '0) $fatal(1, "ready asserted during reset");
            if (expected_valid) cancelled++;
            expected_valid = 0;
            was_stalled = 0;
        end else begin
            if ((^src_ready === 1'bx) || (req_valid !== 1'b0 && req_valid !== 1'b1))
                $fatal(1, "unknown handshake signal ready=%b valid=%b", src_ready, req_valid);
            if (was_stalled && (!req_valid || {req_source, req_request} !== held_output))
                $fatal(1, "output changed while stalled");
            was_stalled = req_valid && !req_ready;
            held_output = {req_source, req_request};

            if (req_valid) begin
                if (!expected_valid || int'(req_source) != expected_source ||
                    req_request !== expected_request)
                    $fatal(1, "unsolicited, duplicated or corrupted output");
            end
            if (req_valid && req_ready) begin
                delivered++;
                expected_valid = 0;
            end

            grants = 0;
            for (integer i = 0; i < SOURCES; i++) begin
                if (src_ready[i]) begin
                    grants++;
                    if (!poll_tick || req_valid || !src_valid[i])
                        $fatal(1, "source accepted outside an idle polling edge");
                    if (expected_valid) $fatal(1, "pending request overwritten");
                    expected_valid = 1;
                    expected_source = i;
                    expected_request = src_request[i];
                    last_accept[i] = 1;
                    accepted++;
                    per_source[i]++;
                end
            end
            if (grants > 1) $fatal(1, "multiple simultaneous source grants");
            if (accepted != delivered + cancelled + int'(expected_valid))
                $fatal(1, "request conservation failure");
        end
    end

    task automatic step(input logic poll, input logic ready,
                        input logic [SOURCES-1:0] valid_mask);
        @(negedge clk);
        poll_tick = poll;
        req_ready = ready;
        src_valid = valid_mask;
        @(posedge clk);
        #1;
    endtask

    task automatic reset_dut;
        @(negedge clk);
        rst_n = 0;
        poll_tick = 1;
        req_ready = 1;
        src_valid = '1;
        #1;
        if (req_valid !== 0 || src_ready !== '0 || req_request !== '0 || req_source !== '0)
            $fatal(1, "asynchronous reset failed");
        repeat (2) @(posedge clk);
        @(negedge clk);
        poll_tick = 0;
        req_ready = 0;
        src_valid = '0;
        rst_n = 1;
    endtask

    initial begin
        if ($value$plusargs("seed=%d", seed)) begin end
        random_state = (seed == 0) ? 32'h12345678 : 32'(seed);
        for (integer i = 0; i < SOURCES; i++) begin
            per_source[i] = 0;
            fresh_payload(i);
        end
        reset_dut();

        // Requests must not be read between polls; empty polls produce nothing.
        before_count = accepted;
        repeat (5) step(0, 1, all_sources);
        repeat (3) step(1, 1, '0);
        if (accepted != before_count || req_valid) $fatal(1, "unpolled/empty input accepted");

        // With all sources waiting, every source wins once per round in order.
        for (integer n = 0; n < 3*SOURCES; n++) begin
            step(1, 0, all_sources);
            if (!req_valid || int'(req_source) != n % SOURCES)
                $fatal(1, "round-robin order/fairness failure n=%0d source=%0d", n, req_source);
            before_count = accepted;
            repeat (3) step(1, 0, all_sources);
            if (accepted != before_count) $fatal(1, "full slot accepted another request");
            step(1, 1, all_sources);
            if (req_valid || last_accept != '0)
                $fatal(1, "consumption edge must not refill the slot");
        end

        // Skip idle sources, wrap correctly, and do not move priority on empty polls.
        reset_dut();
        chosen = (SOURCES > 1) ? 1 : 0;
        mask = '0;
        mask[chosen] = 1;
        step(1, 0, mask);
        if (!req_valid || int'(req_source) != chosen) $fatal(1, "sparse selection failure");
        step(0, 1, '0);  // queued output drains even without a poll.
        repeat (3) step(1, 1, '0);
        step(1, 0, all_sources);
        if (!req_valid || int'(req_source) != (chosen+1) % SOURCES)
            $fatal(1, "empty polls changed priority or non-power-of-two wrap failed");

        // Inputs may change after acceptance; the queued copy must stay unchanged.
        @(negedge clk);
        src_valid = '0;
        for (integer i = 0; i < SOURCES; i++) fresh_payload(i);
        repeat (4) step(0, 0, '0);
        before_delivered = delivered;
        step(0, 1, '0);
        if (delivered != before_delivered+1 || req_valid)
            $fatal(1, "poll-free output delivery failed");

        // Reset cancels a stalled output, resets priority, and produces no ghost.
        step(1, 0, all_sources);
        reset_dut();
        before_delivered = delivered;
        repeat (4) step(0, 1, '0);
        if (delivered != before_delivered || req_valid) $fatal(1, "stale output after reset");
        step(1, 0, all_sources);
        if (!req_valid || req_source != 0) $fatal(1, "reset did not restore priority");
        step(0, 1, '0);

        // Random producers keep each unaccepted request stable, while polling and
        // downstream readiness vary independently. Exercise reset with traffic.
        for (integer cycle = 0; cycle < 5000; cycle++) begin
            @(negedge clk);
            random_state = next_random(random_state);
            poll_tick = random_state[0] | random_state[2];
            req_ready = random_state[1] & random_state[3];
            for (integer i = 0; i < SOURCES; i++) begin
                if (!src_valid[i] || last_accept[i]) begin
                    random_state = next_random(random_state);
                    src_valid[i] = random_state[0] | random_state[1];
                    if (src_valid[i]) fresh_payload(i);
                end
            end
            @(posedge clk);
            #1;
            if (cycle == 1700 || cycle == 3300) reset_dut();
        end

        // Retire remaining source requests legally, then drain the final output.
        for (integer cycle = 0; cycle < 2*SOURCES+5; cycle++) begin
            @(negedge clk);
            src_valid = src_valid & ~last_accept;
            poll_tick = 1;
            req_ready = 1;
            @(posedge clk);
            #1;
        end
        step(0, 1, '0);
        if (expected_valid || req_valid || accepted != delivered+cancelled)
            $fatal(1, "failed to drain/conserve requests");
        for (integer i = 0; i < SOURCES; i++)
            if (per_source[i] < 3) $fatal(1, "source not exercised");
        $display("PASS tb_control_loop sources=%0d width=%0d seed=%0d accepted=%0d delivered=%0d cancelled=%0d",
                 SOURCES, REQUEST_W, seed, accepted, delivered, cancelled);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "control_loop timeout");
    end
endmodule
