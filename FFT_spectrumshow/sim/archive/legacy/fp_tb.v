`timescale 1ns/1ps

module fp_tb;

    reg clk, rst_ni;
    reg [6:0] wr_addr, rd_addr;
    reg [9:0] wr_bar, wr_ov;
    reg wr_we;
    wire [9:0] rd_bar, rd_ov;

    freq_pingpong #(.N_BARS(128), .WIDTH(10)) u_dut(
        .clk_i(clk), .rst_ni(rst_ni),
        .wr_addr_i(wr_addr), .wr_bar_i(wr_bar), .wr_ov_i(wr_ov), .wr_we_i(wr_we),
        .rd_addr_i(rd_addr), .rd_bar_o(rd_bar), .rd_ov_o(rd_ov)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        clk=0; rst_ni=0; wr_addr=0; wr_bar=0; wr_ov=0; wr_we=0; rd_addr=0;
        #20 rst_ni=1;
        #10;

        // write frame0 to block0 (addr 0..127)
        for (i=0;i<128;i=i+1) begin
            @(posedge clk);
            wr_addr = i; wr_bar = i; wr_ov = i*2; wr_we = 1;
        end
        @(posedge clk); wr_we=0;
        $display("after frame0: wr_sel=%0d rd_sel=%0d", u_dut.wr_sel, u_dut.rd_sel);
        // rd_sel should now be 0 (read just-finished block0)

        // read block0: addr 5 -> should be bar=5, ov=10
        rd_addr = 5; @(posedge clk); #1;
        $display("rd addr5: bar=%0d ov=%0d (expect 5,10)", rd_bar, rd_ov);

        // write frame1 to block1
        for (i=0;i<128;i=i+1) begin
            @(posedge clk);
            wr_addr = i; wr_bar = 100+i; wr_ov = 200+i; wr_we = 1;
        end
        @(posedge clk); wr_we=0;
        $display("after frame1: wr_sel=%0d rd_sel=%0d", u_dut.wr_sel, u_dut.rd_sel);
        // rd_sel should now be 1 (block1)

        // read block1: addr 5 -> bar=105, ov=205
        rd_addr = 5; @(posedge clk); #1;
        $display("rd addr5: bar=%0d ov=%0d (expect 105,205)", rd_bar, rd_ov);

        $display("=== FP TEST DONE ===");
        $finish;
    end

endmodule