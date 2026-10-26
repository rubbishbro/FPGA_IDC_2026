`timescale 1ns/1ps
// =============================================================================
// tb_comm_fifo : self-checking randomized testbench for comm_fifo.
//
// Covers DEPTH = 1, 3, 16 with:
// - directed fill/drain and full/empty flags,
// - simultaneous push/pop while not full,
// - randomized valid/ready stalls and random flushes,
// - a circular scoreboard that checks ordering, duplicates and skips,
// - output stability while m_valid && !m_ready,
// - level equal to the scoreboard occupancy (including held output).
// =============================================================================
module tb_comm_fifo;

    logic clk   = 1'b0;
    logic rst_n = 1'b0;

    logic done_1, done_3, done_16;
    logic fail_1, fail_3, fail_16;

    always #5 clk = ~clk;

    fifo_case #(.WIDTH(8), .DEPTH(1))  c1  (
        .clk(clk), .rst_n(rst_n), .done(done_1),  .fail(fail_1)
    );
    fifo_case #(.WIDTH(8), .DEPTH(3))  c3  (
        .clk(clk), .rst_n(rst_n), .done(done_3),  .fail(fail_3)
    );
    fifo_case #(.WIDTH(8), .DEPTH(16)) c16 (
        .clk(clk), .rst_n(rst_n), .done(done_16), .fail(fail_16)
    );

    initial begin
        repeat (6) @(posedge clk);
        rst_n = 1'b1;

        wait (done_1 && done_3 && done_16);
        #50;

        if (fail_1 || fail_3 || fail_16) begin
            $display("FAIL tb_comm_fifo");
            $fatal(1);
        end
        $display("PASS tb_comm_fifo (DEPTH=1,3,16)");
        $finish;
    end

endmodule


module fifo_case #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic clk,
    input  logic rst_n,
    output logic done,
    output logic fail
);

    logic                   flush;
    logic                   s_valid;
    logic                   s_ready;
    logic [WIDTH-1:0]       s_data;
    logic                   m_valid;
    logic                   m_ready;
    logic [WIDTH-1:0]       m_data;
    logic [$clog2(DEPTH+1)-1:0] level;

    comm_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data),
        .level(level)
    );

    // Circular scoreboard.
    logic [WIDTH-1:0] model [0:DEPTH-1];
    integer head;
    integer tail;
    integer model_count;
    integer errors;

    logic             src_hold;
    logic [WIDTH-1:0] src_data;

    logic             prev_stall;
    logic             flush_prev;
    logic [WIDTH-1:0] stall_data;

    integer i;
    integer cyc;
    integer randv;

    task automatic fail_msg(input string msg);
        begin
            $display("FAIL DEPTH=%0d: %s (t=%0t)", DEPTH, msg, $time);
            errors = errors + 1;
        end
    endtask

    task automatic check_level(input string where);
        begin
            if (level != model_count)
                fail_msg($sformatf("level=%0d expected=%0d at %s",
                                   level, model_count, where));
        end
    endtask

    initial begin
        done      = 1'b0;
        fail      = 1'b0;
        errors    = 0;
        head      = 0;
        tail      = 0;
        model_count = 0;
        flush     = 1'b0;
        s_valid   = 1'b0;
        s_data    = '0;
        m_ready   = 1'b0;
        src_hold  = 1'b0;
        src_data  = '0;
        prev_stall = 1'b0;
        flush_prev = 1'b0;
        stall_data = '0;

        wait (rst_n === 1'b1);
        repeat (2) @(negedge clk);

        // -----------------------------------------------------------------
        // Directed: flush, fill to full, check flags, drain in order.
        // -----------------------------------------------------------------
        @(negedge clk);
        flush = 1'b1; s_valid = 1'b0; m_ready = 1'b0;
        #1;
        @(negedge clk);
        flush = 1'b0;
        if (level != 0) fail_msg("flush did not clear level");
        if (m_valid)    fail_msg("flush left m_valid high");

        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge clk);
            s_valid = 1'b1;
            s_data  = WIDTH'(8'h80 + i);
            m_ready = 1'b0;
            flush   = 1'b0;
            #1;
            if (!s_ready)
                fail_msg($sformatf("s_ready low during fill i=%0d", i));
            model[tail] = s_data;
            tail = (tail + 1) % DEPTH;
            model_count = model_count + 1;
        end

        @(negedge clk);
        s_valid = 1'b0;
        #1;
        if (s_ready) fail_msg("s_ready high when full");
        check_level("after fill");

        // Drain, allowing the synchronous-read prefetch bubbles.
        m_ready = 1'b0;
        cyc = 0;
        while ((model_count > 0) && (cyc < (DEPTH * 8 + 20))) begin
            @(negedge clk);
            m_ready = 1'b1;
            s_valid = 1'b0;
            #1;
            if (m_valid && m_ready) begin
                if (m_data !== model[head])
                    fail_msg($sformatf("drain data got=%02h exp=%02h",
                                       m_data, model[head]));
                head = (head + 1) % DEPTH;
                model_count = model_count - 1;
            end
            cyc = cyc + 1;
        end
        if (model_count != 0) fail_msg("drain timeout");
        @(negedge clk);
        #1;
        if (m_valid) fail_msg("m_valid high after drain");
        if (!s_ready) fail_msg("s_ready low after drain");
        m_ready = 1'b0;

        // -----------------------------------------------------------------
        // Directed: simultaneous push and pop over several cycles.
        // -----------------------------------------------------------------
        @(negedge clk);
        m_ready = 1'b0;
        s_valid = 1'b0;
        #1;
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge clk);
            s_valid = 1'b1;
            s_data  = WIDTH'(8'h10 + i);
            m_ready = 1'b0;
            flush   = 1'b0;
            #1;
            if (s_ready) begin
                model[tail] = s_data;
                tail = (tail + 1) % DEPTH;
                model_count = model_count + 1;
            end
        end

        for (i = 0; i < 24; i = i + 1) begin
            @(negedge clk);
            s_valid = 1'b1;
            s_data  = WIDTH'(8'h40 + i);
            m_ready = 1'b1;
            flush   = 1'b0;
            #1;
            if (m_valid && m_ready) begin
                if (model_count == 0)
                    fail_msg("pop with empty scoreboard");
                else begin
                    if (m_data !== model[head])
                        fail_msg($sformatf("simul data got=%02h exp=%02h",
                                           m_data, model[head]));
                    head = (head + 1) % DEPTH;
                    model_count = model_count - 1;
                end
            end
            if (s_valid && s_ready) begin
                if (model_count >= DEPTH)
                    fail_msg("push accepted while scoreboard full");
                model[tail] = s_data;
                tail = (tail + 1) % DEPTH;
                model_count = model_count + 1;
            end
        end

        // Drain remainder.  Wait for the posedge of the last simultaneous
        // step before changing the source inputs.
        @(negedge clk);
        s_valid = 1'b0;
        m_ready = 1'b0;
        #1;
        cyc = 0;
        while ((model_count > 0) && (cyc < (DEPTH * 8 + 40))) begin
            @(negedge clk);
            m_ready = 1'b1;
            s_valid = 1'b0;
            #1;
            if (m_valid && m_ready) begin
                if (m_data !== model[head])
                    fail_msg("tail drain data mismatch");
                head = (head + 1) % DEPTH;
                model_count = model_count - 1;
            end
            cyc = cyc + 1;
        end
        if (model_count != 0) fail_msg("tail drain timeout");

        // -----------------------------------------------------------------
        // Randomized stalls / flushes.
        // -----------------------------------------------------------------
        for (cyc = 0; cyc < 5000; cyc = cyc + 1) begin
            @(negedge clk);

            check_level("random pre-check");
            if (prev_stall && !flush_prev) begin
                if (!m_valid)
                    fail_msg("valid dropped during stall");
                else if (m_data !== stall_data)
                    fail_msg("data changed during stall");
            end

            randv = $urandom_range(0, 999);
            if (randv < 4) begin
                // ~0.4% flushes; a flush overrides any pending source word.
                flush   = 1'b1;
                s_valid = 1'b0;
                m_ready = 1'b0;
                src_hold = 1'b0;
            end else begin
                flush = 1'b0;
                if (src_hold) begin
                    s_valid = 1'b1;
                    s_data  = src_data;
                end else begin
                    s_valid = ($urandom_range(0, 99) < 55);
                    s_data  = WIDTH'($urandom);
                end
                m_ready = ($urandom_range(0, 99) < 70);
            end

            #1;

            if (flush) begin
                model_count = 0;
                head = 0;
                tail = 0;
                prev_stall = 1'b0;
            end else begin
                if (m_valid && m_ready) begin
                    if (model_count == 0)
                        fail_msg("random pop with empty scoreboard");
                    else begin
                        if (m_data !== model[head])
                            fail_msg($sformatf("random data got=%02h exp=%02h",
                                               m_data, model[head]));
                        head = (head + 1) % DEPTH;
                        model_count = model_count - 1;
                    end
                end

                if (s_valid && s_ready) begin
                    if (model_count >= DEPTH)
                        fail_msg("random push while scoreboard full");
                    model[tail] = s_data;
                    tail = (tail + 1) % DEPTH;
                    model_count = model_count + 1;
                    src_hold = 1'b0;
                end else if (s_valid) begin
                    src_hold = 1'b1;
                    src_data = s_data;
                end

                prev_stall = m_valid && !m_ready;
                stall_data = m_data;
            end

            flush_prev = flush;
        end

        @(negedge clk);
        check_level("final");

        if (errors == 0)
            $display("PASS comm_fifo DEPTH=%0d (random 5000 cycles)", DEPTH);
        else
            $display("FAIL comm_fifo DEPTH=%0d errors=%0d", DEPTH, errors);

        fail = (errors != 0);
        done = 1'b1;
    end

endmodule
