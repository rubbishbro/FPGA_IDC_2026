`timescale 1ns/1ps

module scan_tb;

    reg         clk, rst_n, frame_pulse, lcd_valid;
    reg  [1:0]  page_sel;
    reg  [9:0]  pix_x, pix_y;
    wire [9:0]  q_y, q_ov;
    wire [5:0]  lcd_r, lcd_g, lcd_b;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(pix_x), .q_y(q_y), .q_ov(q_ov)
    );

    lcd_draw u_draw(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .lcd_valid(lcd_valid), .pix_x(pix_x), .pix_y(pix_y),
        .page_sel(page_sel), .q_y(q_y), .q_ov(q_ov),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b)
    );

    always #5 clk = ~clk;

    integer x, y, i;
    reg [9:0] qy_at[0:127];
    reg [9:0] peak_at[0:127];

    task clockpixel(input [9:0] xx, input [9:0] yy);
        begin
            pix_x = xx; pix_y = yy;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; lcd_valid = 0;
        pix_x = 0; pix_y = 0; page_sel = 0;
        #20 rst_n = 1;
        #10;
        frame_pulse = 1; @(posedge clk); frame_pulse = 0;
        repeat (140) @(posedge clk);
        lcd_valid = 1;

        // dump dot_ram values (the light-dot peak-hold array)
        $display("=== dot_ram ===");
        for (x = 0; x < 128; x = x + 1) begin
            if (u_draw.u_fft.dot_ram[x] != 10'd0)
                $display("dot[%0d]=%0d", x, u_draw.u_fft.dot_ram[x]);
        end
        $finish;
    end

endmodule