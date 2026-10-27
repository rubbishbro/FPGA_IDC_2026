`timescale 1ns/1ps
// =============================================================================
// tb_comm_uart : self-checking UART RX/TX tests.
//
// RX cases:
//   16x oversampling, 115200 baud @ 3.6864 MHz
//   16x oversampling,   9600 baud @ 2.0 MHz
//    8x oversampling, 230400 baud @ 4.0 MHz
//   - nominal 8N1, back-to-back bytes, ±3/4% bit-period deviations,
//     false start, bad stop, held break with one-shot break_detect,
//     break recovery, and reset while held low.
//
// TX cases:
//   115200 baud @ 3.6864 MHz and 9600 baud @ 2.0 MHz
//   - 8N1 frame decode, busy/ready protocol, preloaded/stalled source data,
//     and checking that an accepted byte is transmitted completely.
// =============================================================================
module tb_comm_uart;

    logic done_rx_115, done_rx_9600, done_rx_230, done_tx_115, done_tx_9600;
    logic fail_rx_115, fail_rx_9600, fail_rx_230, fail_tx_115, fail_tx_9600;

    wire [4:0] done_vec = {done_rx_115, done_rx_9600, done_rx_230,
                           done_tx_115, done_tx_9600};
    wire [4:0] fail_vec = {fail_rx_115, fail_rx_9600, fail_rx_230,
                           fail_tx_115, fail_tx_9600};
    wire all_done = &done_vec;
    wire any_fail = |fail_vec;

    uart_rx_case #(
        .CLK_HZ(3_686_400), .BAUD(115_200), .OVERSAMPLE(16),
        .TAG("RX16_115200")
    ) rx_115 (
        .done(done_rx_115), .fail(fail_rx_115)
    );

    uart_rx_case #(
        .CLK_HZ(2_000_000), .BAUD(9_600), .OVERSAMPLE(16),
        .TAG("RX16_9600")
    ) rx_9600 (
        .done(done_rx_9600), .fail(fail_rx_9600)
    );

    uart_rx_case #(
        .CLK_HZ(4_000_000), .BAUD(230_400), .OVERSAMPLE(8),
        .TAG("RX8_230400")
    ) rx_230 (
        .done(done_rx_230), .fail(fail_rx_230)
    );

    uart_tx_case #(
        .CLK_HZ(3_686_400), .BAUD(115_200), .TAG("TX_115200")
    ) tx_115 (
        .done(done_tx_115), .fail(fail_tx_115)
    );

    uart_tx_case #(
        .CLK_HZ(2_000_000), .BAUD(9_600), .TAG("TX_9600")
    ) tx_9600 (
        .done(done_tx_9600), .fail(fail_tx_9600)
    );

    initial begin
        wait (all_done);
        #200;
        if (any_fail) begin
            $display("FAIL tb_comm_uart");
            $fatal(1);
        end
        $display("PASS tb_comm_uart (RX: 16x/115200, 16x/9600, 8x/230400; TX: 115200, 9600)");
        $finish;
    end

endmodule


// =============================================================================
// RX case
// =============================================================================
module uart_rx_case #(
    parameter int CLK_HZ     = 3_686_400,
    parameter int BAUD       = 115_200,
    parameter int OVERSAMPLE = 16,
    parameter string TAG     = "RX"
) (
    output logic done,
    output logic fail
);

    localparam real CLK_NS = 1.0e9 / CLK_HZ;
    localparam real BIT_NS = 1.0e9 / BAUD;
    localparam int  CLKS_PER_BIT = (CLK_HZ + BAUD - 1) / BAUD;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic       rx_i = 1'b1;
    logic       rx_stb;
    logic [7:0] rx_data;
    logic       framing_err;
    logic       break_detect;
    logic       false_start;

    comm_uart_rx #(
        .CLK_HZ(CLK_HZ), .BAUD(BAUD), .OVERSAMPLE(OVERSAMPLE)
    ) dut (
        .clk(clk), .rst_n(rst_n), .rx_i(rx_i),
        .rx_stb(rx_stb), .rx_data(rx_data),
        .framing_err(framing_err),
        .break_detect(break_detect),
        .false_start(false_start)
    );

    always #(CLK_NS / 2.0) clk = ~clk;

    logic [7:0] rx_bytes [0:63];
    integer     rx_count;
    integer     fe_count;
    integer     brk_count;
    integer     fs_count;
    integer     errors;

    logic prev_stb, prev_fe, prev_brk, prev_fs;

    task automatic fail_msg(input string msg);
        begin
            $display("FAIL %s: %s (t=%0t)", TAG, msg, $time);
            errors = errors + 1;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n) begin
            if (rx_stb) begin
                if (prev_stb) fail_msg("rx_stb wider than one clock");
                if (rx_count < 64)
                    rx_bytes[rx_count] = rx_data;
                rx_count = rx_count + 1;
            end
            if (framing_err) begin
                if (prev_fe) fail_msg("framing_err wider than one clock");
                fe_count = fe_count + 1;
            end
            if (break_detect) begin
                if (prev_brk) fail_msg("break_detect wider than one clock");
                brk_count = brk_count + 1;
            end
            if (false_start) begin
                if (prev_fs) fail_msg("false_start wider than one clock");
                fs_count = fs_count + 1;
            end
            prev_stb <= rx_stb;
            prev_fe  <= framing_err;
            prev_brk <= break_detect;
            prev_fs  <= false_start;
        end else begin
            prev_stb <= 1'b0;
            prev_fe  <= 1'b0;
            prev_brk <= 1'b0;
            prev_fs  <= 1'b0;
        end
    end

    task automatic send_byte(input [7:0] data, input real bit_ns,
                             input bit good_stop, input real gap_bits);
        integer k;
        begin
            rx_i = 1'b0;                    // start
            #(bit_ns);
            for (k = 0; k < 8; k = k + 1) begin
                rx_i = data[k];             // LSB first
                #(bit_ns);
            end
            rx_i = good_stop ? 1'b1 : 1'b0; // stop
            #(bit_ns);
            if (gap_bits > 0.0) begin
                rx_i = 1'b1;
                #(bit_ns * gap_bits);
            end
        end
    endtask

    task automatic wait_and_check(input int prev, input [7:0] exp,
                                  input string tag);
        integer c;
        begin
            c = 0;
            while ((rx_count == prev) && (c < (CLKS_PER_BIT * 16 + 400))) begin
                @(negedge clk);
                c = c + 1;
            end
            if (rx_count != (prev + 1)) begin
                fail_msg($sformatf("%s: strobe delta=%0d (expected 1)",
                                   tag, rx_count - prev));
            end else if (rx_bytes[prev] !== exp) begin
                fail_msg($sformatf("%s: data=%02h expected=%02h",
                                   tag, rx_bytes[prev], exp));
            end
        end
    endtask

    integer k;
    integer prev;
    integer fe_prev;
    integer brk_prev;
    integer fs_prev;
    integer rc_prev;
    integer cyc;

    initial begin
        done       = 1'b0;
        fail       = 1'b0;
        rx_count   = 0;
        fe_count   = 0;
        brk_count  = 0;
        fs_count   = 0;
        errors     = 0;
        prev_stb   = 1'b0;
        prev_fe    = 1'b0;
        prev_brk   = 1'b0;
        prev_fs    = 1'b0;
        for (k = 0; k < 64; k = k + 1)
            rx_bytes[k] = 8'h00;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // -----------------------------------------------------------------
        // Nominal 8N1, one idle bit between bytes.
        // -----------------------------------------------------------------
        begin : nominal_block
            logic [7:0] pat [0:7];
            integer n;
            pat[0] = 8'h55; pat[1] = 8'hAA;
            pat[2] = 8'h00; pat[3] = 8'hFF;
            pat[4] = 8'h81; pat[5] = 8'h7E;
            pat[6] = 8'hDB; pat[7] = 8'hC0;
            for (n = 0; n < 8; n = n + 1) begin
                prev = rx_count;
                send_byte(pat[n], BIT_NS, 1'b1, 1.0);
                wait_and_check(prev, pat[n], "nominal");
            end
        end

        // -----------------------------------------------------------------
        // Back-to-back bytes: stop bit high, next start immediately.
        // -----------------------------------------------------------------
        prev = rx_count;
        send_byte(8'hC3, BIT_NS, 1'b1, 0.0);
        send_byte(8'h3C, BIT_NS, 1'b1, 0.0);
        send_byte(8'h96, BIT_NS, 1'b1, 0.0);
        cyc = 0;
        while ((rx_count < (prev + 3)) && (cyc < (CLKS_PER_BIT * 40 + 500))) begin
            @(negedge clk);
            cyc = cyc + 1;
        end
        if (rx_count != (prev + 3)) begin
            fail_msg($sformatf("back-to-back strobe delta=%0d (expected 3)",
                               rx_count - prev));
        end else begin
            if (rx_bytes[prev + 0] !== 8'hC3) fail_msg("back-to-back byte 0");
            if (rx_bytes[prev + 1] !== 8'h3C) fail_msg("back-to-back byte 1");
            if (rx_bytes[prev + 2] !== 8'h96) fail_msg("back-to-back byte 2");
        end
        #(BIT_NS * 2.0);
        if (rx_count != (prev + 3))
            fail_msg("back-to-back produced extra strobe");

        // -----------------------------------------------------------------
        // Bit-period deviations (few percent).
        // -----------------------------------------------------------------
        prev = rx_count;
        send_byte(8'h5A, BIT_NS * 1.03, 1'b1, 2.0);
        wait_and_check(prev, 8'h5A, "dev +3%");

        prev = rx_count;
        send_byte(8'hC3, BIT_NS * 0.97, 1'b1, 2.0);
        wait_and_check(prev, 8'hC3, "dev -3%");

        prev = rx_count;
        send_byte(8'h3C, BIT_NS * 1.04, 1'b1, 2.0);
        wait_and_check(prev, 8'h3C, "dev +4%");

        prev = rx_count;
        send_byte(8'hA5, BIT_NS * 0.96, 1'b1, 2.0);
        wait_and_check(prev, 8'hA5, "dev -4%");

        // -----------------------------------------------------------------
        // False start: short low glitch is not a byte.
        // -----------------------------------------------------------------
        fs_prev = fs_count;
        rc_prev = rx_count;
        fe_prev = fe_count;
        rx_i = 1'b0;
        #(BIT_NS * 0.3);
        rx_i = 1'b1;
        #(BIT_NS * 3.0);
        if (fs_count != (fs_prev + 1))
            fail_msg($sformatf("false_start count=%0d expected=%0d",
                               fs_count, fs_prev + 1));
        if (rx_count != rc_prev)
            fail_msg("false start produced rx_stb");
        if (fe_count != fe_prev)
            fail_msg("false start produced framing_err");

        // -----------------------------------------------------------------
        // Bad stop: framing_err, no rx_stb, no break.
        // -----------------------------------------------------------------
        fe_prev  = fe_count;
        brk_prev = brk_count;
        rc_prev  = rx_count;
        send_byte(8'hA6, BIT_NS, 1'b0, 3.0);
        if (fe_count != (fe_prev + 1))
            fail_msg($sformatf("bad stop framing count=%0d expected=%0d",
                               fe_count, fe_prev + 1));
        if (rx_count != rc_prev)
            fail_msg("bad stop produced rx_stb");
        if (brk_count != brk_prev)
            fail_msg("one-bit bad stop falsely reported as break");
        #(BIT_NS * 2.0);

        // -----------------------------------------------------------------
        // Held break: exactly one break_detect; no rx_stb; then recover.
        // -----------------------------------------------------------------
        brk_prev = brk_count;
        fe_prev  = fe_count;
        rc_prev  = rx_count;
        rx_i = 1'b0;
        #(BIT_NS * 14.0);
        rx_i = 1'b1;
        #(BIT_NS * 3.0);
        if (brk_count != (brk_prev + 1))
            fail_msg($sformatf("break count=%0d expected=%0d",
                               brk_count, brk_prev + 1));
        if (fe_count != (fe_prev + 1))
            fail_msg($sformatf("break framing count=%0d expected=%0d",
                               fe_count, fe_prev + 1));
        if (rx_count != rc_prev)
            fail_msg("held break produced rx_stb");
        #(BIT_NS * 4.0);
        if (brk_count != (brk_prev + 1))
            fail_msg("held break repeated break_detect");

        prev = rx_count;
        send_byte(8'h42, BIT_NS, 1'b1, 1.0);
        wait_and_check(prev, 8'h42, "after break");

        // -----------------------------------------------------------------
        // Reset while the line is held low; release, then recover.
        // -----------------------------------------------------------------
        rc_prev = rx_count;
        rx_i = 1'b0;
        #(BIT_NS * 4.0);
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        if (rx_stb || framing_err || break_detect || false_start)
            fail_msg("event output high during reset");
        #(BIT_NS * 2.0);
        rst_n = 1'b1;
        #(BIT_NS * 2.0);
        #(BIT_NS * 10.0);
        rx_i = 1'b1;
        #(BIT_NS * 3.0);
        if (rx_count != rc_prev)
            fail_msg("break/reset sequence produced rx_stb");

        prev = rx_count;
        send_byte(8'h5C, BIT_NS, 1'b1, 1.0);
        wait_and_check(prev, 8'h5C, "after break+reset");

        // Final idle check.
        #(BIT_NS * 3.0);
        if (rx_count != (prev + 1))
            fail_msg("extra rx_stb after final byte");

        if (errors == 0)
            $display("PASS %s", TAG);
        else
            $display("FAIL %s errors=%0d", TAG, errors);

        fail = (errors != 0);
        done = 1'b1;
    end

endmodule


// =============================================================================
// TX case
// =============================================================================
module uart_tx_case #(
    parameter int CLK_HZ = 3_686_400,
    parameter int BAUD   = 115_200,
    parameter string TAG = "TX"
) (
    output logic done,
    output logic fail
);

    localparam real CLK_NS = 1.0e9 / CLK_HZ;
    localparam real BIT_NS = 1.0e9 / BAUD;
    localparam int  CLKS_PER_BIT = (CLK_HZ + BAUD - 1) / BAUD;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic       s_valid = 1'b0;
    logic       s_ready;
    logic [7:0] s_data = 8'h00;
    logic       tx_o;
    logic       busy;

    comm_uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .tx_o(tx_o), .busy(busy)
    );

    always #(CLK_NS / 2.0) clk = ~clk;

    logic [7:0] exp_bytes [0:63];
    integer     exp_wr;
    integer     dec_count;
    integer     errors;

    task automatic fail_msg(input string msg);
        begin
            $display("FAIL %s: %s (t=%0t)", TAG, msg, $time);
            errors = errors + 1;
        end
    endtask

    // Protocol / line-level monitor.
    always @(posedge clk) begin
        if (rst_n) begin
            if (busy && s_ready)
                fail_msg("s_ready asserted while busy");
            if (!busy && tx_o !== 1'b1)
                fail_msg("tx_o not idle-high while not busy");
        end
    end

    // Independent 8N1 decoder.  It aligns to each start edge, so source
    // stalls or back-to-back bytes cannot shift the sampling point.
    initial begin : tx_decoder
        logic [7:0] d;
        integer k;
        forever begin
            @(negedge tx_o);
            #(BIT_NS * 1.5);
            for (k = 0; k < 8; k = k + 1) begin
                d[k] = tx_o;
                #(BIT_NS);
            end
            // At 9.5 bit times after the start edge.
            if (tx_o !== 1'b1)
                fail_msg("decoded stop bit is low");
            if (dec_count >= exp_wr)
                fail_msg("decoded a byte with no expected entry");
            else if (d !== exp_bytes[dec_count])
                fail_msg($sformatf("decoded=%02h expected=%02h",
                                   d, exp_bytes[dec_count]));
            dec_count = dec_count + 1;
        end
    end

    task automatic offer_byte(input [7:0] d, input integer min_stall_clk);
        integer stalls;
        begin
            @(negedge clk);
            s_data  = d;
            s_valid = 1'b1;
            stalls  = 0;
            while (!s_ready) begin
                if (busy)
                    stalls = stalls + 1;
                @(negedge clk);
            end
            if (stalls < min_stall_clk)
                fail_msg($sformatf("busy stall only %0d cycles (min %0d)",
                                   stalls, min_stall_clk));
            @(posedge clk);             // accepted here
            if (exp_wr < 64) begin
                exp_bytes[exp_wr] = d;
                exp_wr = exp_wr + 1;
            end
            #1;
        end
    endtask

    task automatic source_idle;
        begin
            @(negedge clk);
            s_valid = 1'b0;
            #1;
        end
    endtask

    integer n;
    integer gap;
    integer cyc;
    logic [7:0] pat [0:7];

    initial begin
        done     = 1'b0;
        fail     = 1'b0;
        exp_wr   = 0;
        dec_count = 0;
        errors   = 0;
        pat[0] = 8'h55; pat[1] = 8'hAA;
        pat[2] = 8'h00; pat[3] = 8'hFF;
        pat[4] = 8'h81; pat[5] = 8'h7E;
        pat[6] = 8'hDB; pat[7] = 8'hC0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);
        if (tx_o !== 1'b1 || busy)
            fail_msg("TX not idle after reset");

        // Normal bytes with random idle gaps.
        for (n = 0; n < 8; n = n + 1) begin
            offer_byte(pat[n], 0);
            source_idle();
            gap = $urandom_range(1, 20);
            repeat (gap) @(negedge clk);
        end

        // Preloaded source while busy: second byte is held valid and stable
        // throughout the first byte's transmission.
        offer_byte(8'h3C, 0);
        offer_byte(8'hA5, CLKS_PER_BIT * 8);
        source_idle();
        repeat (3) @(negedge clk);

        offer_byte(8'h0F, 0);
        offer_byte(8'hF0, CLKS_PER_BIT * 8);
        source_idle();

        // Wait for the decoder to finish all expected frames.
        cyc = 0;
        while (((dec_count < exp_wr) || busy) &&
               (cyc < (CLKS_PER_BIT * 80 + 1000))) begin
            @(negedge clk);
            cyc = cyc + 1;
        end
        if (dec_count != exp_wr)
            fail_msg($sformatf("decoder count=%0d expected=%0d",
                               dec_count, exp_wr));
        if (busy)
            fail_msg("TX still busy after all frames");
        #(BIT_NS * 2.0);
        if (dec_count != exp_wr)
            fail_msg("TX produced extra frame");
        if (tx_o !== 1'b1)
            fail_msg("tx_o not idle-high at end");

        if (errors == 0)
            $display("PASS %s", TAG);
        else
            $display("FAIL %s errors=%0d", TAG, errors);

        fail = (errors != 0);
        done = 1'b1;
    end

endmodule
