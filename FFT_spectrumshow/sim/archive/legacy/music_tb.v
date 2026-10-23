`timescale 1ns/1ps

module music_tb;

    reg         clk, rst_n, frame_pulse;
    reg  [1:0]  page_sel;
    reg  [9:0]  q_x;
    wire [9:0]  q_y;

    data_source u_ds(
        .clk(clk), .rst_n(rst_n), .frame_pulse(frame_pulse),
        .page_sel(page_sel), .q_x(q_x), .q_y(q_y)
    );

    always #5 clk = ~clk;

    integer i, b;

    task advance(input integer n);
        begin
            for (i = 0; i < n; i = i + 1) begin
                frame_pulse = 1; @(posedge clk); frame_pulse = 0;
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; frame_pulse = 0; page_sel = 0; q_x = 0;
        #20 rst_n = 1;
        #10;
        advance(10);   // note 0, env ~360, peak near bar 8
        $display("note=%0d env=%0d note_pos=%0d note_amp=%0d", u_ds.note_idx, u_ds.env, u_ds.note_pos, u_ds.note_amp);
        for (b = 0; b < 128; b = b + 4) begin
            q_x = b * 6; #1;
            $display("bar%0d: h=%0d n=%0d h0=%0d h2=%0d h3=%0d", b, q_y, u_ds.note_h, u_ds.h0, u_ds.h2, u_ds.h3);
        end
        $finish;
    end

endmodule