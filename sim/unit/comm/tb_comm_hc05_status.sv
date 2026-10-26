`timescale 1ns/1ps
// =============================================================================
// tb_comm_hc05_status : self-checking synchronized/debounced STATE tests.
//
// HAS_STATE=1, DEBOUNCE_CYCLES=8:
//   - reset with state low, no events,
//   - high/low bounce shorter than the debounce window is ignored,
//   - stable high produces exactly one connect_event and link_up=1,
//   - stable low produces exactly one disconnect_event and link_up=0,
//   - reset while state is high clears link_up, then re-connects after release,
//   - event pulses are exactly one clock wide.
//
// HAS_STATE=0:
//   - link_up is tied high from reset, state_async toggles produce no events.
// =============================================================================
module tb_comm_hc05_status;

    logic clk = 1'b0;
    logic done_state, done_nostate;
    logic fail_state, fail_nostate;

    wire all_done = done_state & done_nostate;
    wire any_fail = fail_state | fail_nostate;

    always #5 clk = ~clk;

    hc05_state_case #(.DEBOUNCE_CYCLES(8)) c_state (
        .clk(clk), .done(done_state), .fail(fail_state)
    );
    hc05_nostate_case c_nostate (
        .clk(clk), .done(done_nostate), .fail(fail_nostate)
    );

    initial begin
        wait (all_done);
        #100;
        if (any_fail) begin
            $display("FAIL tb_comm_hc05_status");
            $fatal(1);
        end
        $display("PASS tb_comm_hc05_status");
        $finish;
    end

endmodule


module hc05_state_case #(
    parameter int DEBOUNCE_CYCLES = 8
) (
    input  logic clk,
    output logic done,
    output logic fail
);

    logic rst_n;
    logic state_async;
    logic link_up;
    logic disconnect_event;
    logic connect_event;

    comm_hc05_status #(
        .HAS_STATE(1'b1), .DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n), .state_async(state_async),
        .link_up(link_up),
        .disconnect_event(disconnect_event),
        .connect_event(connect_event)
    );

    integer errors;
    integer connect_count;
    integer disconnect_count;
    logic   prev_connect;
    logic   prev_disconnect;

    task automatic fail_msg(input string msg);
        begin
            $display("FAIL HC05_STATE: %s (t=%0t)", msg, $time);
            errors = errors + 1;
        end
    endtask

    task automatic wait_link(input bit value, input string tag);
        integer c;
        begin
            c = 0;
            while ((link_up !== value) && (c < 128)) begin
                @(negedge clk);
                c = c + 1;
            end
            if (link_up !== value)
                fail_msg($sformatf("%s: link_up=%b expected=%b",
                                   tag, link_up, value));
            else
                @(negedge clk); // allow the event monitor to observe the pulse
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if (connect_event) begin
                if (prev_connect) fail_msg("connect_event wider than one clock");
                connect_count = connect_count + 1;
            end
            if (disconnect_event) begin
                if (prev_disconnect) fail_msg("disconnect_event wider than one clock");
                disconnect_count = disconnect_count + 1;
            end
            prev_connect    <= connect_event;
            prev_disconnect <= disconnect_event;
        end else begin
            prev_connect    <= 1'b0;
            prev_disconnect <= 1'b0;
        end
    end

    integer i;
    integer c_prev;
    integer d_prev;

    initial begin
        done = 1'b0;
        fail = 1'b0;
        errors = 0;
        connect_count = 0;
        disconnect_count = 0;
        prev_connect = 1'b0;
        prev_disconnect = 1'b0;
        rst_n = 1'b0;
        state_async = 1'b0;

        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(negedge clk);

        if (link_up !== 1'b0) fail_msg("link_up not low after reset");
        if (connect_count != 0) fail_msg("connect event after low reset");

        // -----------------------------------------------------------------
        // High-side bounce shorter than DEBOUNCE_CYCLES must be ignored.
        // -----------------------------------------------------------------
        for (i = 0; i < 30; i = i + 1) begin
            @(negedge clk);
            state_async = (i % 3 == 0) ? 1'b1 : 1'b0;
        end
        @(negedge clk);
        state_async = 1'b0;
        repeat (12) @(negedge clk);
        if (link_up !== 1'b0) fail_msg("bounce falsely set link_up");
        if (connect_count != 0) fail_msg("bounce falsely produced connect");

        // -----------------------------------------------------------------
        // Stable high: exactly one connect event.
        // -----------------------------------------------------------------
        @(negedge clk);
        state_async = 1'b1;
        wait_link(1'b1, "connect");
        if (connect_count != 1)
            fail_msg($sformatf("connect count=%0d expected=1", connect_count));
        if (disconnect_count != 0) fail_msg("unexpected disconnect on connect");
        repeat (30) @(negedge clk);
        if (connect_count != 1) fail_msg("connect event repeated while high");

        // -----------------------------------------------------------------
        // Low-side bounce shorter than DEBOUNCE_CYCLES must be ignored.
        // -----------------------------------------------------------------
        c_prev = connect_count;
        d_prev = disconnect_count;
        for (i = 0; i < 24; i = i + 1) begin
            @(negedge clk);
            state_async = (i % 4 == 0) ? 1'b0 : 1'b1;
        end
        @(negedge clk);
        state_async = 1'b1;
        repeat (12) @(negedge clk);
        if (link_up !== 1'b1) fail_msg("low bounce falsely dropped link_up");
        if (disconnect_count != d_prev) fail_msg("low bounce produced disconnect");
        if (connect_count != c_prev) fail_msg("low bounce produced connect");

        // -----------------------------------------------------------------
        // Stable low: exactly one disconnect event.
        // -----------------------------------------------------------------
        @(negedge clk);
        state_async = 1'b0;
        wait_link(1'b0, "disconnect");
        if (disconnect_count != (d_prev + 1))
            fail_msg($sformatf("disconnect count=%0d expected=%0d",
                               disconnect_count, d_prev + 1));
        repeat (30) @(negedge clk);
        if (disconnect_count != (d_prev + 1))
            fail_msg("disconnect event repeated while low");

        // -----------------------------------------------------------------
        // Short high glitch while low: no connect.
        // -----------------------------------------------------------------
        c_prev = connect_count;
        for (i = 0; i < 6; i = i + 1) begin
            @(negedge clk);
            state_async = 1'b1;
            @(negedge clk);
            state_async = 1'b0;
            @(negedge clk);
            state_async = 1'b0;
        end
        repeat (12) @(negedge clk);
        if (link_up !== 1'b0) fail_msg("short high glitch set link_up");
        if (connect_count != c_prev) fail_msg("short high glitch produced connect");

        // -----------------------------------------------------------------
        // Reset while STATE is high.
        // -----------------------------------------------------------------
        @(negedge clk);
        state_async = 1'b1;
        wait_link(1'b1, "pre-reset connect");
        c_prev = connect_count;
        d_prev = disconnect_count;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        if (link_up !== 1'b0) fail_msg("link_up not cleared by reset");
        if (connect_event || disconnect_event)
            fail_msg("event high during reset");

        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        wait_link(1'b1, "post-reset connect");
        if (connect_count != (c_prev + 1))
            fail_msg($sformatf("post-reset connect count=%0d expected=%0d",
                               connect_count, c_prev + 1));
        if (disconnect_count != d_prev)
            fail_msg("post-reset disconnect count changed");

        // -----------------------------------------------------------------
        // Reset while STATE is low: no events, stays disconnected.
        // -----------------------------------------------------------------
        @(negedge clk);
        state_async = 1'b0;
        wait_link(1'b0, "pre-reset disconnect");
        c_prev = connect_count;
        d_prev = disconnect_count;

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        if (link_up !== 1'b0) fail_msg("link_up high during low reset");
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        repeat (12) @(negedge clk);
        if (link_up !== 1'b0) fail_msg("link_up high after low reset");
        if (connect_count != c_prev) fail_msg("low reset produced connect");
        if (disconnect_count != d_prev) fail_msg("low reset produced disconnect");

        if (errors == 0)
            $display("PASS HC05_STATE DEBOUNCE_CYCLES=%0d", DEBOUNCE_CYCLES);
        else
            $display("FAIL HC05_STATE errors=%0d", errors);

        fail = (errors != 0);
        done = 1'b1;
    end

endmodule


module hc05_nostate_case (
    input  logic clk,
    output logic done,
    output logic fail
);

    logic rst_n;
    logic state_async;
    logic link_up;
    logic disconnect_event;
    logic connect_event;

    comm_hc05_status #(
        .HAS_STATE(1'b0), .DEBOUNCE_CYCLES(8)
    ) dut (
        .clk(clk), .rst_n(rst_n), .state_async(state_async),
        .link_up(link_up),
        .disconnect_event(disconnect_event),
        .connect_event(connect_event)
    );

    integer errors;
    integer i;

    task automatic fail_msg(input string msg);
        begin
            $display("FAIL HC05_NOSTATE: %s (t=%0t)", msg, $time);
            errors = errors + 1;
        end
    endtask

    initial begin
        done = 1'b0;
        fail = 1'b0;
        errors = 0;
        rst_n = 1'b0;
        state_async = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        if (link_up !== 1'b1) fail_msg("link_up not tied high");
        if (connect_event || disconnect_event) fail_msg("event after reset");

        for (i = 0; i < 40; i = i + 1) begin
            @(negedge clk);
            state_async = $urandom_range(0, 1);
            #1;
            if (link_up !== 1'b1) fail_msg("link_up changed with no STATE");
            if (connect_event || disconnect_event)
                fail_msg("event with HAS_STATE=0");
        end

        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        if (link_up !== 1'b1) fail_msg("link_up not high during reset");
        if (connect_event || disconnect_event) fail_msg("event during reset");
        rst_n = 1'b1;
        repeat (10) @(negedge clk);
        if (link_up !== 1'b1) fail_msg("link_up not high after reset");
        if (connect_event || disconnect_event) fail_msg("event after second reset");

        if (errors == 0)
            $display("PASS HC05_NOSTATE");
        else
            $display("FAIL HC05_NOSTATE errors=%0d", errors);

        fail = (errors != 0);
        done = 1'b1;
    end

endmodule
