`timescale 1ns/1ps

module sweep_source_tb;

    logic        clk;
    logic        rst_n;
    logic        samp_en;
    logic [7:0]  phase_idx;
    logic [31:0] phase;
    logic [31:0] freq_inc;
    logic        sweep_done;

    logic        fast_samp_en;
    logic [7:0]  fast_phase_idx;
    logic [31:0] fast_phase;
    logic [31:0] fast_freq_inc;
    logic        fast_sweep_done;

    integer errors;

    sweep_source u_dut (
        .clk(clk), .rst_n(rst_n), .samp_en(samp_en),
        .phase_idx(phase_idx), .phase(phase),
        .freq_inc(freq_inc), .sweep_done(sweep_done)
    );

    sweep_source #(
        .F_MIN(32'd100),
        .F_MAX(32'd500),
        .F_STEP(32'd100)
    ) u_fast (
        .clk(clk), .rst_n(rst_n), .samp_en(fast_samp_en),
        .phase_idx(fast_phase_idx), .phase(fast_phase),
        .freq_inc(fast_freq_inc), .sweep_done(fast_sweep_done)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic tick_default;
        begin
            samp_en = 1'b1;
            @(posedge clk); #1;
            samp_en = 1'b0;
        end
    endtask

    task automatic tick_fast;
        begin
            fast_samp_en = 1'b1;
            @(posedge clk); #1;
            fast_samp_en = 1'b0;
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        samp_en = 1'b0;
        fast_samp_en = 1'b0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        if (freq_inc !== 32'd89_478_485) begin
            $error("default F_MIN mismatch: %0d", freq_inc);
            errors = errors + 1;
        end
        if (phase !== 32'd0 || phase_idx !== 8'd0) begin
            $error("default phase reset mismatch");
            errors = errors + 1;
        end

        tick_default();
        if (phase !== 32'd89_478_485) begin
            $error("default phase step mismatch: %0d", phase);
            errors = errors + 1;
        end
        if (freq_inc !== 32'd89_480_163) begin
            $error("default F_STEP mismatch: %0d", freq_inc);
            errors = errors + 1;
        end
        if (phase_idx !== phase[31:24]) begin
            $error("default phase_idx mismatch");
            errors = errors + 1;
        end

        // Small-range instance exercises the 10 kHz wrap.
        tick_fast();
        if (fast_phase !== 32'd100 || fast_freq_inc !== 32'd200) begin
            $error("fast tick0 mismatch");
            errors = errors + 1;
        end

        tick_fast();
        if (fast_phase !== 32'd300 || fast_freq_inc !== 32'd300) begin
            $error("fast tick1 mismatch");
            errors = errors + 1;
        end

        tick_fast();
        if (fast_phase !== 32'd600 || fast_freq_inc !== 32'd400) begin
            $error("fast tick2 mismatch");
            errors = errors + 1;
        end

        tick_fast();
        if (fast_phase !== 32'd1000 || fast_freq_inc !== 32'd500) begin
            $error("fast tick3 mismatch");
            errors = errors + 1;
        end

        tick_fast();
        if (fast_phase !== 32'd1500 || fast_freq_inc !== 32'd100 || !fast_sweep_done) begin
            $error("fast sweep wrap mismatch");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== SWEEP SOURCE TEST PASSED ===");
        else
            $display("=== SWEEP SOURCE TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
