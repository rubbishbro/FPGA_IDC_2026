`timescale 1ns/1ps
module tb_a1_engine;
    localparam int NV = 2, NM = 4;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [NV*2-1:0] class_vec = 4'b0101; // 两个 B
    logic [NV*16-1:0] theta_base_vec = '0;
    logic [15:0] ratio = 16'h80E6;        // ~1.007
    logic enable = 1;
    logic rd_en, rd_valid, bank_ready = 1, a1_we, a1_ready = 1;
    logic [0:0] rd_voice;
    logic [2:0] rd_mode;
    logic [71:0] rd_data;
    logic [0:0] a1_voice;
    logic [2:0] a1_mode;
    logic [21:0] a1_data;
    logic active, done;

    logic [71:0] core_mem [0:NV*NM-1];
    logic [21:0] nominal [0:NV*NM-1];
    logic [21:0] got [0:NV*NM-1];
    integer nwrite = 0;

    assign rd_data = core_mem[rd_voice*NM + rd_mode];
    always_ff @(posedge clk) rd_valid <= rd_en;
    always_ff @(posedge clk) begin
        if (done) enable <= 1'b0;
        if (a1_we) begin
            got[a1_voice*NM + a1_mode] <= a1_data;
            nwrite <= nwrite + 1;
        end
    end

    b_a1_engine #(
        .NUM_VOICES(NV), .N_MODES(NM), .COEFF_DEPTH(8),
        .THETA_DEPTH(4), .THETA_FILE("sim/unit/core/tb_theta.mem")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .class_vec(class_vec), .theta_base_vec(theta_base_vec),
        .ratio(ratio), .enable(enable),
        .rd_en(rd_en), .rd_voice(rd_voice), .rd_mode(rd_mode),
        .rd_data(rd_data), .rd_valid(rd_valid), .bank_ready(bank_ready),
        .a1_we(a1_we), .a1_voice(a1_voice), .a1_mode(a1_mode),
        .a1_data(a1_data), .a1_ready(a1_ready),
        .active(active), .done(done)
    );

    integer i, v, m, a1v;
    initial begin
        for (v = 0; v < NV; v = v + 1)
            for (m = 0; m < NM; m = m + 1) begin
                a1v = -300000 - (v*4+m)*1000;
                core_mem[v*NM+m] = {26'd0, 24'h0E0000, (a1v & 22'h3FFFFF)};
                nominal[v*NM+m] = core_mem[v*NM+m][21:0];
            end
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (200) @(posedge clk);
        if (nwrite < NV*NM) $fatal(1, "nwrite=%0d", nwrite);
        for (i = 0; i < NV*NM; i = i + 1) begin
            if (got[i] === 22'hx) $fatal(1, "mode %0d not written", i);
            if (got[i] == core_mem[i][21:0]) $fatal(1, "mode %0d a1 unchanged", i);
        end
        $display("tb_a1_engine PASS: %0d writes", nwrite);
        $finish;
    end
endmodule
