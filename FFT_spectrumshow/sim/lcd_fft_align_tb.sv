`timescale 1ns/1ps

module lcd_fft_align_tb;

    logic        clk;
    logic        rst_n;
    logic        frame_pulse;
    logic        dot_en;
    logic [9:0]  q_y;
    logic [9:0]  q_ov;
    logic [9:0]  pix_x;
    logic [9:0]  pix_y;
    logic        fft_hit;
    logic [5:0]  fft_r, fft_g, fft_b;

    integer errors;
    integer x;
    integer y;
    integer b;
    integer bar_of_x;

    lcd_fft dut (
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .dot_en(dot_en), .peak_en(1'b1), .theme(1'b0), .smooth_en(1'b0), .q_y(q_y), .q_ov(q_ov),
        .pix_x(pix_x), .pix_y(pix_y),
        .fft_hit(fft_hit), .fft_r(fft_r), .fft_g(fft_g), .fft_b(fft_b)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always @(posedge clk) begin
        bar_of_x = pix_x / 6;
        if (bar_of_x > 127) bar_of_x = 127;
        q_y  <= 100 + bar_of_x * 2;
        q_ov <= 100 + bar_of_x * 2;
    end

    initial begin
        errors = 0;
        rst_n = 1'b0;
        frame_pulse = 1'b0;
        dot_en = 1'b1;
        q_y = 10'd0;
        q_ov = 10'd0;
        pix_x = 10'd0;
        pix_y = 10'd0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (y = 0; y < 480; y = y + 1) begin
            for (x = 0; x < 800; x = x + 1) begin
                pix_x = x[9:0];
                pix_y = y[9:0];
                @(posedge clk);
            end
        end

        for (b = 0; b < 128; b = b + 1) begin
            if (dut.dot_ram[b] !== (100 + b * 2)) begin
                $error("dot_ram[%0d]=%0d expected %0d", b, dut.dot_ram[b], 100 + b * 2);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("=== LCD FFT ALIGN TEST PASSED ===");
        else
            $display("=== LCD FFT ALIGN TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
