`timescale 1ns/1ps
module tb_c_seed_loader;
    logic clk=0, rst_n=0;
    logic start;
    logic [3:0] voice;
    logic [2:0] n_modes;
    logic [15:0] seed_base;
    logic seed_we;
    logic [3:0] seed_voice;
    logic [2:0] seed_mode;
    logic [63:0] seed_data;
    logic busy, done;
    int errors=0;
    int nw=0;
    logic [63:0] got [0:7];
    logic [2:0]  gm [0:7];

    c_seed_loader #(.NUM_SLOTS(16), .N_MODES(4), .SEED_DEPTH(4),
                    .SEED_FILE("sim/unit/core/tb_seed.mem")) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .voice(voice),
        .n_modes(n_modes), .seed_base(seed_base),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode),
        .seed_data(seed_data), .busy(busy), .done(done)
    );

    always #5 clk=~clk;

    always_ff @(posedge clk) begin
        if (seed_we) begin
            got[nw] <= seed_data;
            gm[nw] <= seed_mode;
            nw <= nw + 1;
        end
    end

    initial begin
        start=0; voice=0; n_modes=0; seed_base=0;
        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        @(negedge clk); start=1; voice=0; n_modes=3'd4; seed_base=0;
        @(posedge clk); @(negedge clk); start=0;
        wait (done); @(posedge clk); #1;

        if (nw != 4) begin $display("FAIL nw=%0d", nw); errors++; end
        for (int i=0;i<4;i++) begin
            if (got[i] !== 64'(i+1)) begin $display("FAIL data[%0d]=%h",i,got[i]); errors++; end
            if (gm[i] !== i[2:0]) begin $display("FAIL mode[%0d]=%0d",i,gm[i]); errors++; end
        end

        if (errors==0) $display("PASS tb_c_seed_loader");
        else $display("FAIL tb_c_seed_loader errors=%0d", errors);
        $finish;
    end
endmodule
