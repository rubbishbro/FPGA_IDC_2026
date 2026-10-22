// -----------------------------------------------------------------------------
// tb_a_router_loader.sv -- A 的 index/coeff ROM -> 9×32 记录
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_a_router_loader;
    import modal_record_pkg::*;

    localparam int SLOTS=2, MODES=4, VW=1, MW=3;
    logic clk=0, rst_n=0;
    logic load_valid, load_ready;
    logic [VW-1:0] load_voice;
    logic [1:0] load_instrument;
    logic [6:0] load_midi;
    logic load_dyn;
    logic [7:0] load_vel;
    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [VW-1:0] clr_voice;
    logic load_done; logic [VW-1:0] done_voice; logic [MW-1:0] nmodes;
    logic error_valid; logic [2:0] error_code;

    int errors=0;
    int cfg_cnt=0, clr_cnt=0;
    logic [REC_W-1:0] cfgs [0:7];
    logic [MW-1:0]    cfgm [0:7];

    a_router_loader #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES),
        .COEFF_DEPTH(2), .INDEX_DEPTH(128),
        .COEFF_FILE("sim/unit/core/router_a_coeff.mem"),
        .INDEX_FILE("sim/unit/core/router_a_index.mem"), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready),
        .load_voice(load_voice), .load_instrument(load_instrument),
        .load_midi(load_midi), .load_dyn(load_dyn), .load_vel(load_vel),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice),
        .load_done(load_done), .done_voice(done_voice), .loaded_n_modes(nmodes),
        .error_valid(error_valid), .error_code(error_code)
    );

    always #5 clk=~clk;

    always_ff @(posedge clk) begin
        if (cfg_we) begin cfgs[cfg_cnt] <= cfg_data; cfgm[cfg_cnt] <= cfg_mode; cfg_cnt <= cfg_cnt+1; end
        if (clr_we) clr_cnt <= clr_cnt+1;
    end

    initial begin
        load_valid=0; load_voice='0; load_instrument='0; load_midi='0; load_dyn=0; load_vel=255;
        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        @(negedge clk); load_valid=1; load_voice=0; load_instrument=0; load_midi=7'd60;
        load_dyn=1; load_vel=8'd255;
        @(posedge clk); @(negedge clk); load_valid=0;
        wait (load_done); @(posedge clk); #1;

        if (error_valid) begin $display("FAIL error=%0d",error_code); errors++; end
        if (cfg_cnt != 2) begin $display("FAIL cfg_cnt=%0d",cfg_cnt); errors++; end
        if (clr_cnt != 1) begin $display("FAIL clr_cnt=%0d",clr_cnt); errors++; end
        if (nmodes != 3'd2) begin $display("FAIL nmodes=%0d",nmodes); errors++; end
        for (int i=0;i<2;i++) begin
            if (cfgm[i] !== i[MW-1:0]) begin $display("FAIL mode%0d=%0d",i,cfgm[i]); errors++; end
            if (rec_get(cfgs[i],E1_G) !== 32'h01000000) begin $display("FAIL G%0d=%h",i,rec_get(cfgs[i],E1_G)); errors++; end
            if (rec_get(cfgs[i],E1_A1) !== 0) begin $display("FAIL a1%0d",i); errors++; end
            if (rec_get(cfgs[i],E1_A2) !== 0) begin $display("FAIL a2%0d",i); errors++; end
        end

        if (errors==0) $display("PASS tb_a_router_loader");
        else $display("FAIL tb_a_router_loader errors=%0d",errors);
        $finish;
    end
endmodule
