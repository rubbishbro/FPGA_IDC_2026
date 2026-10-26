`timescale 1ns/1ps

module time_pingpong_tb;

    // Small blocks keep the simulation fast; the CDC/handshake logic is
    // identical to the 1024-sample production configuration.
    localparam integer N_SAMPLES = 16;
    localparam integer N_BLOCKS  = 2;
    localparam integer TOTAL     = N_SAMPLES * N_BLOCKS;

    reg clk_wr, clk_rd;
    reg rst_wr_n, rst_rd_n;

    reg  [23:0] wr_data;
    reg         wr_valid;
    wire        wr_ready;

    reg  [3:0]  rd_addr;
    reg         rd_req;
    wire [23:0] rd_data;
    wire        rd_valid;
    reg         rd_done;

    wire [23:0] wf_data;

    integer wcount;
    integer errors;
    integer b;
    integer a;

    time_pingpong #(
        .N_SAMPLES (N_SAMPLES),
        .WIDTH     (24)
    ) dut (
        .wr_rst_ni  (rst_wr_n),
        .wr_clk_i   (clk_wr),
        .wr_data_i  (wr_data),
        .wr_valid_i (wr_valid),
        .wr_ready_o (wr_ready),
        .rd_rst_ni  (rst_rd_n),
        .rd_clk_i   (clk_rd),
        .rd_req_i   (rd_req),
        .rd_addr_i  (rd_addr),
        .rd_data_o  (rd_data),
        .rd_valid_o (rd_valid),
        .rd_done_i  (rd_done),
        .wf_clk_i   (clk_rd),
        .wf_addr_i  (4'd0),
        .wf_data_o  (wf_data)
    );

    always #5  clk_wr = ~clk_wr;   // 100 MHz
    always #15 clk_rd = ~clk_rd;   // 33.333 MHz

    // 48 kHz sample tick in the 100 MHz write domain.
    reg [31:0] acc48k;
    reg        samp_en;

    always @(posedge clk_wr or negedge rst_wr_n) begin
        if (!rst_wr_n) begin
            acc48k  <= 32'd0;
            samp_en <= 1'b0;
        end
        else if (acc48k + 32'd48000 >= 32'd100_000_000) begin
            acc48k  <= acc48k + 32'd48000 - 32'd100_000_000;
            samp_en <= 1'b1;
        end
        else begin
            acc48k  <= acc48k + 32'd48000;
            samp_en <= 1'b0;
        end
    end

    // Write samples 0..TOTAL-1 at 48 kHz. Hold valid if the destination
    // bank is not ready, matching continuous audio input behavior.
    always @(posedge clk_wr or negedge rst_wr_n) begin
        if (!rst_wr_n) begin
            wr_data  <= 24'd0;
            wr_valid <= 1'b0;
            wcount   <= 0;
        end
        else if (wr_valid && wr_ready) begin
            wcount   <= wcount + 1;
            wr_valid <= 1'b0;
        end
        else if (!wr_valid && samp_en && wcount < TOTAL) begin
            wr_data  <= wcount;
            wr_valid <= 1'b1;
        end
    end

    // Read both full blocks and compare every sample with the write sequence.
    initial begin
        clk_wr   = 1'b0;
        clk_rd   = 1'b0;
        rst_wr_n = 1'b0;
        rst_rd_n = 1'b0;
        wr_data  = 24'd0;
        wr_valid = 1'b0;
        rd_addr  = 4'd0;
        rd_req   = 1'b0;
        rd_done  = 1'b0;
        wcount   = 0;
        errors   = 0;

        #40;
        rst_wr_n = 1'b1;
        rst_rd_n = 1'b1;

        for (b = 0; b < N_BLOCKS; b = b + 1) begin
            while (!rd_valid) @(posedge clk_rd);
            $display("block %0d ready", b);

            for (a = 0; a < N_SAMPLES; a = a + 1) begin
                @(negedge clk_rd);
                rd_req  = 1'b1;
                rd_addr = a[3:0];

                @(posedge clk_rd);
                #1;
                if (rd_data !== (b * N_SAMPLES + a)) begin
                    if (errors < 10)
                        $display("MISMATCH block=%0d a=%0d got=%0d exp=%0d",
                                 b, a, rd_data, b * N_SAMPLES + a);
                    errors = errors + 1;
                end

                @(negedge clk_rd);
                rd_req = 1'b0;
            end

            @(negedge clk_rd);
            rd_done = 1'b1;
            @(negedge clk_rd);
            rd_done = 1'b0;

            // Let the write side observe the toggle before waiting for the
            // next block. The next block may already be FULL by then.
            repeat (4) @(posedge clk_rd);
        end

        if (errors == 0)
            $display("=== TIME PINGPONG TEST PASSED ===");
        else
            $display("=== TIME PINGPONG TEST FAILED: %0d mismatch(es) ===", errors);

        $finish;
    end

endmodule
