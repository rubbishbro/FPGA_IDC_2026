`timescale 1ns/1ps

module fft512_verify_tb;

    logic clk = 0;
    logic rst_n = 0;
    logic ce;
    logic start = 0;
    logic signed [15:0] x_re = 0;
    logic x_valid = 0;

    wire signed [25:0] y_re;
    wire signed [25:0] y_im;
    wire [8:0] y_idx;
    wire y_valid;
    wire ready;
    wire busy;
    wire done;

    integer ce_div = 1;
    integer ce_cnt = 0;
    integer i;
    integer count = 0;
    integer errors = 0;
    integer fd;
    reg [15:0] sample_mem [0:511];
    reg seen [0:511];

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (ce_cnt >= ce_div - 1) begin
            ce_cnt <= 0;
            ce <= 1'b1;
        end
        else begin
            ce_cnt <= ce_cnt + 1;
            ce <= 1'b0;
        end
    end

    fft512_iter dut (
        .clk(clk), .rst_n(rst_n), .ce(ce),
        .start(start), .x_re(x_re), .x_valid(x_valid), .ready(ready),
        .y_re(y_re), .y_im(y_im), .y_idx(y_idx), .y_valid(y_valid),
        .busy(busy), .done(done)
    );

    initial begin
        if (!$value$plusargs("CE_DIV=%d", ce_div))
            ce_div = 1;

        $readmemh("fft_in.mem", sample_mem);
        for (i = 0; i < 512; i = i + 1)
            seen[i] = 1'b0;

        if (ce_div == 1)
            fd = $fopen("fft_out_ce1.txt", "w");
        else
            fd = $fopen("fft_out_ce3.txt", "w");

        ce = 0; ce_cnt = 0;
        rst_n = 0; start = 0; x_valid = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        start = 1;
        @(posedge clk);
        while (!ce) @(posedge clk);
        start = 0;

        for (i = 0; i < 512; i = i + 1) begin
            x_re = sample_mem[i];
            x_valid = 1;
            @(posedge clk);
            while (!ce) @(posedge clk);
        end
        x_valid = 0;

        while (!done) begin
            @(posedge clk);
            if (ce && y_valid) begin
                $fwrite(fd, "%0d %0d %0d\n", y_idx, $signed(y_re), $signed(y_im));
                seen[y_idx] = 1'b1;
                count = count + 1;
            end
        end

        $fclose(fd);

        if (count != 512) begin
            $error("output count = %0d, expected 512", count);
            errors = errors + 1;
        end
        for (i = 0; i < 512; i = i + 1) begin
            if (!seen[i]) begin
                $error("missing y_idx=%0d", i);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("=== FFT DUMP PASSED (CE_DIV=%0d, outputs=%0d) ===", ce_div, count);
        else
            $display("=== FFT DUMP FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
