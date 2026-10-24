`timescale 1ns/1ps

module waterfall_tb;

    logic       clk;
    logic       rst_n;
    logic       wr_en;
    logic [6:0] wr_col;
    logic [9:0] wr_data;
    logic       wr_frame_done;
    logic [5:0] rd_row;
    logic [6:0] rd_col;
    logic [9:0] rd_data;
    logic [5:0] base_row;

    integer errors;
    integer f;
    integer c;

    waterfall_store dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_col(wr_col), .wr_data(wr_data),
        .wr_frame_done(wr_frame_done),
        .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data),
        .base_row(base_row)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic write_frame(input integer frame_id);
        integer n;
        begin
            for (n = 0; n < 128; n = n + 1) begin
                wr_en   = 1'b1;
                wr_col  = n[6:0];
                wr_data = (frame_id * 100 + n) % 1024;
                @(posedge clk);
            end
            wr_en = 1'b0;
            wr_frame_done = 1'b1;
            @(posedge clk);
            wr_frame_done = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic check_cell(input integer row, input integer col, input integer want);
        begin
            rd_row = row[5:0];
            rd_col = col[6:0];
            @(posedge clk);
            #1;
            if (rd_data !== want[9:0]) begin
                $error("cell row=%0d col=%0d got %0d want %0d", row, col, rd_data, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        rst_n = 1'b0;
        wr_en = 1'b0;
        wr_col = 0;
        wr_data = 0;
        wr_frame_done = 1'b0;
        rd_row = 0;
        rd_col = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        write_frame(0);
        if (base_row !== 6'd0) begin
            $error("base_row after frame0 = %0d", base_row);
            errors = errors + 1;
        end

        write_frame(1);
        if (base_row !== 6'd1) begin
            $error("base_row after frame1 = %0d", base_row);
            errors = errors + 1;
        end

        check_cell(0, 0, 0);
        check_cell(0, 127, 127);
        check_cell(1, 0, 100);
        check_cell(1, 127, 227);

        for (f = 2; f < 70; f = f + 1)
            write_frame(f);

        if (base_row !== 6'd5) begin
            $error("base_row after 70 frames = %0d (expected 5)", base_row);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("=== WATERFALL TEST PASSED ===");
        else
            $display("=== WATERFALL TEST FAILED: %0d error(s) ===", errors);
        $finish;
    end

endmodule
