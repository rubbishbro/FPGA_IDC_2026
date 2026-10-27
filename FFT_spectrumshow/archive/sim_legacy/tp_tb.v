`timescale 1ns/1ps

module tp_tb;

    reg  rst_ni;
    reg  wr_clk, rd_clk, wf_clk;
    reg  [15:0] wr_data;
    reg  wr_valid;
    wire wr_ready;
    reg  rd_req;
    reg  [9:0] rd_addr;
    wire [15:0] rd_data;
    wire rd_valid;
    reg  rd_done;
    reg  [9:0] wf_addr;
    wire [15:0] wf_data;

    time_pingpong #(.N_SAMPLES(1024), .WIDTH(16)) u_dut(
        .rst_ni(rst_ni),
        .wr_clk_i(wr_clk), .wr_data_i(wr_data), .wr_valid_i(wr_valid), .wr_ready_o(wr_ready),
        .rd_clk_i(rd_clk), .rd_req_i(rd_req), .rd_addr_i(rd_addr),
        .rd_data_o(rd_data), .rd_valid_o(rd_valid), .rd_done_i(rd_done),
        .wf_clk_i(wf_clk), .wf_addr_i(wf_addr), .wf_data_o(wf_data)
    );

    always #5 wr_clk = ~wr_clk;   // 48k-ish fast for test
    always #3 rd_clk = ~rd_clk;   // pix_clk fast
    always #3 wf_clk = ~wf_clk;

    integer i;
    reg [15:0] wbuf [0:1023];

    initial begin
        wr_clk=0; rd_clk=0; wf_clk=0; rst_ni=0;
        wr_data=0; wr_valid=0; rd_req=0; rd_addr=0; rd_done=0; wf_addr=0;
        #20 rst_ni=1;
        #10;

        // ===== write 1024 samples to block0 =====
        for (i=0;i<1024;i=i+1) begin
            @(posedge wr_clk);
            wr_data = i; wr_valid = 1;
            wbuf[i] = i;
        end
        @(posedge wr_clk); wr_valid = 0;
        @(posedge wr_clk);   // let full_exists/full_ptr register
        $display("after write: full_exists=%0d full_ptr=%0d wr_ready=%0d", u_dut.full_exists, u_dut.full_ptr, wr_ready);

        // wait for rd side to sync full
        repeat(10) @(posedge rd_clk);
        $display("rd side: rd_valid=%0d", rd_valid);

        // ===== read 1024 samples from block0 =====
        for (i=0;i<1024;i=i+1) begin
            @(posedge rd_clk);
            rd_req = 1; rd_addr = i;
        end
        @(posedge rd_clk); rd_req = 0;
        rd_done = 1;                  // FFT signals done AFTER reading all
        @(posedge rd_clk);
        rd_done = 0;

        // wait for wr side to sync done + clear
        repeat(10) @(posedge wr_clk);
        $display("after read done: full_exists=%0d block0=%0d block1=%0d", u_dut.full_exists, u_dut.block_state[0], u_dut.block_state[1]);

        // ===== verify wave read =====
        wf_addr = 100; @(posedge wf_clk); #1;
        $display("wf_data=%0d (expect 100)", wf_data);

        $display("=== TP TEST DONE ===");
        $finish;
    end

endmodule