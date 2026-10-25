`timescale 1ns/1ps

module lcd_fft_tb;

    logic        clk;
    logic        rst_n;
    logic        frame_pulse;
    logic        dot_en;
    logic        peak_en;
    logic [9:0]  q_y;
    logic [9:0]  q_ov;
    logic [9:0]  pix_x;
    logic [9:0]  pix_y;
    logic        fft_hit;
    logic [5:0]  fft_r, fft_g, fft_b;

    integer errors;
    integer x;
    integer y;

    lcd_fft dut (
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .dot_en(dot_en), .peak_en(peak_en), .theme(1'b0), .smooth_en(1'b0), .q_y(q_y), .q_ov(q_ov),
        .pix_x(pix_x), .pix_y(pix_y),
        .fft_hit(fft_hit), .fft_r(fft_r), .fft_g(fft_g), .fft_b(fft_b)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic set_pixel(input integer px, input integer py);
        begin
            pix_x = px[9:0];
            pix_y = py[9:0];
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        frame_pulse = 1'b0;
        dot_en = 1'b1;
        peak_en = 1'b1;
        q_y = 10'd479;
        q_ov = 10'd479;
        pix_x = 10'd0;
        pix_y = 10'd0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (y = 0; y < 480; y = y + 1) begin
            for (x = 0; x < 800; x = x + 1)
                set_pixel(x, y);
        end

        set_pixel(1, 39);
        if (fft_hit) begin
            $error("bar extended above content top at y=39");
            errors = errors + 1;
        end

        set_pixel(1, 40);
        if (!fft_hit) begin
            $error("bar missing at y=40");
            errors = errors + 1;
        end

        set_pixel(0, 40);
        set_pixel(1, 40);
        set_pixel(2, 40);
        if (!fft_hit || fft_g !== 6'h34 || fft_b !== 6'h34) begin
            $error("peak dot missing or wrong color at (2,40)");
            errors = errors + 1;
        end

        peak_en = 1'b0;
        set_pixel(2, 40);
        if (fft_g === 6'h34 && fft_b === 6'h34) begin
            $error("peak disabled but dot color still present");
            errors = errors + 1;
        end

        set_pixel(0, 0);
        if (fft_hit) begin
            $error("bar extended above content top at y=0");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== LCD FFT TEST PASSED ===");
        else
            $display("=== LCD FFT TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
