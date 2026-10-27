`timescale 1ns/1ps

// =============================================================================
// curve_calc_equiv_tb.sv - equivalence check for the curve_calc refactor
//
// Feeds the same 128x40 input frame to the reference (register-array) version
// and to the new (trail_store on demand) version, then compares all 768
// written columns word for word.  Four random frames cover the edge cases
// (bar 0 clamp, bar 126/127 clamp, tail).
// =============================================================================
module curve_calc_equiv_tb;

    logic        clk;
    logic        rst_n;
    logic        start;

    wire  [6:0]  sa_ref,  sa_new;
    logic [39:0] sd_ref,  sd_new;
    wire         we_ref,  we_new;
    wire  [9:0]  wa_ref,  wa_new;
    wire  [39:0] wd_ref,  wd_new;
    wire         done_ref, done_new;

    logic [39:0] mem     [0:127];
    logic [39:0] img_ref [0:767];
    logic [39:0] img_new [0:767];

    integer errors;
    integer frame;
    integer i;
    integer writes_ref;
    integer writes_new;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always_ff @(posedge clk) sd_ref <= mem[sa_ref];
    always_ff @(posedge clk) sd_new <= mem[sa_new];

    always @(posedge clk) begin
        if (we_ref) begin
            img_ref[wa_ref] <= wd_ref;
            writes_ref <= writes_ref + 1;
        end
        if (we_new) begin
            img_new[wa_new] <= wd_new;
            writes_new <= writes_new + 1;
        end
    end

    curve_calc_ref u_ref (
        .clk(clk), .rst_n(rst_n), .start(start),
        .scan_addr(sa_ref), .scan_data(sd_ref),
        .wr_en(we_ref), .wr_addr(wa_ref), .wr_data(wd_ref),
        .frame_done(done_ref)
    );

    curve_calc u_new (
        .clk(clk), .rst_n(rst_n), .start(start),
        .scan_addr(sa_new), .scan_data(sd_new),
        .wr_en(we_new), .wr_addr(wa_new), .wr_data(wd_new),
        .frame_done(done_new)
    );

    task automatic wait_done(output bit ok);
        integer n;
        bit d_ref, d_new;
        begin
            ok    = 1'b0;
            d_ref = 1'b0;
            d_new = 1'b0;
            for (n = 0; n < 4000; n = n + 1) begin
                @(posedge clk);
                #1;
                if (done_ref) d_ref = 1'b1;
                if (done_new) d_new = 1'b1;
                if (d_ref && d_new) begin
                    ok = 1'b1;
                    n  = 4000;
                end
            end
        end
    endtask

    initial begin
        errors     = 0;
        rst_n      = 1'b0;
        start      = 1'b0;
        writes_ref = 0;
        writes_new = 0;

        for (i = 0; i < 128; i = i + 1)
            mem[i] = 40'd0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (frame = 0; frame < 4; frame = frame + 1) begin
            for (i = 0; i < 128; i = i + 1)
                mem[i] = {10'($urandom_range(0, 479)), 10'($urandom_range(0, 479)),
                          10'($urandom_range(0, 479)), 10'($urandom_range(0, 479))};

            for (i = 0; i < 768; i = i + 1) begin
                img_ref[i] = 40'hxx;
                img_new[i] = 40'hxx;
            end
            writes_ref = 0;
            writes_new = 0;

            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            begin : wait_block
                bit ok;
                wait_done(ok);
                if (!ok) begin
                    $error("frame %0d: timeout waiting for frame_done", frame);
                    errors = errors + 1;
                end
            end

            repeat (3) @(posedge clk);
            #1;

            if (writes_ref != 768) begin
                $error("frame %0d: ref wrote %0d columns", frame, writes_ref);
                errors = errors + 1;
            end
            if (writes_new != 768) begin
                $error("frame %0d: new wrote %0d columns", frame, writes_new);
                errors = errors + 1;
            end

            for (i = 0; i < 768; i = i + 1) begin
                if (img_ref[i] !== img_new[i]) begin
                    $error("frame %0d col %0d: ref %h new %h",
                           frame, i, img_ref[i], img_new[i]);
                    errors = errors + 1;
                    i = 768;
                end
            end
        end

        if (errors == 0)
            $display("=== CURVE CALC EQUIV TEST PASSED ===");
        else
            $display("=== CURVE CALC EQUIV TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
