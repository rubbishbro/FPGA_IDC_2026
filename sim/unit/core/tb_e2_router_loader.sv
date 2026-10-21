`timescale 1ns/1ps
module tb_e2_router_loader;
    import modal_record_pkg::*;
    localparam int SLOTS=2, MODES=4, VW=1, MW=3;
    logic clk=0, rst_n=0;
    logic load_valid, load_ready;
    logic [1:0] ev_class, ev_layer; logic [3:0] ev_inst; logic [6:0] ev_note;
    logic [7:0] ev_vel; logic [11:0] ev_nid; logic [VW-1:0] load_voice;
    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [VW-1:0] clr_voice; logic [MW-1:0] clr_mode;
    logic seed_valid; logic [VW-1:0] seed_voice; logic [MW-1:0] seed_mode; logic [63:0] seed_word;
    logic load_done; logic [VW-1:0] done_voice; logic [MW-1:0] nmodes; logic [15:0] theta;
    logic err; logic [2:0] ec;
    int errors=0, cfg_cnt=0, seed_cnt=0;
    logic [REC_W-1:0] cfgs[0:3]; logic [63:0] seeds[0:3];

    e2_router_loader #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .REC_W(REC_W),
        .COEFF_DEPTH(2), .INDEX_DEPTH(8192), .CTRL_DEPTH(2), .SEED_DEPTH(8),
        .COEFF_FILE("sim/unit/core/router_e2_coeff.mem"),
        .INDEX_FILE("sim/unit/core/router_e2_index.mem"),
        .CTRL_FILE("sim/unit/core/router_e2_ctrl.mem"),
        .L72_FILE("sim/unit/core/router_e2_l72.mem"),
        .SEED_FILE("sim/unit/core/router_e2_seed.mem")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready),
        .ev_class(ev_class), .ev_layer(ev_layer), .ev_instrument(ev_inst),
        .ev_note(ev_note), .ev_velocity(ev_vel), .ev_note_id(ev_nid),
        .load_voice(load_voice),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_valid(seed_valid), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_word(seed_word),
        .load_done(load_done), .done_voice(done_voice), .loaded_n_modes(nmodes), .theta_base(theta),
        .error_valid(err), .error_code(ec)
    );
    always #5 clk=~clk;
    always_ff @(posedge clk) begin
        if (cfg_we) begin cfgs[cfg_cnt] <= cfg_data; cfg_cnt <= cfg_cnt+1; end
        if (seed_valid) begin seeds[seed_cnt] <= seed_word; seed_cnt <= seed_cnt+1; end
    end
    initial begin
        load_valid=0; ev_class=0; ev_layer=0; ev_inst=0; ev_note=0; ev_vel=0; ev_nid=0; load_voice=0;
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        @(negedge clk); load_valid=1; ev_class=3; ev_note=7'd36; ev_vel=8'd0; ev_nid=0; load_voice=0;
        @(posedge clk); @(negedge clk); load_valid=0;
        wait(load_done); @(posedge clk); #1;
        if (err) begin $display("FAIL err=%0d",ec); errors++; end
        if (cfg_cnt != 2) begin $display("FAIL cfg=%0d",cfg_cnt); errors++; end
        if (nmodes != 3'd2) begin $display("FAIL n=%0d",nmodes); errors++; end
        if (theta != 16'd0) begin $display("FAIL theta=%0d",theta); errors++; end
        if (seed_cnt != 2) begin $display("FAIL seed=%0d",seed_cnt); errors++; end
        if (seeds[0] !== 64'hffffe00000001000) begin $display("FAIL seed0=%h",seeds[0]); errors++; end
        for (int i=0;i<2;i++) begin
            if (rec_get(cfgs[i],E2_A11) !== (32'h1000+i)) begin $display("FAIL a11[%0d]=%h",i,rec_get(cfgs[i],E2_A11)); errors++; end
            if (rec_get(cfgs[i],E2_WO) !== (32'h7000+i)) begin $display("FAIL wo[%0d]=%h",i,rec_get(cfgs[i],E2_WO)); errors++; end
        end
        if (errors==0) $display("PASS tb_e2_router_loader");
        else $display("FAIL tb_e2_router_loader errors=%0d",errors);
        $finish;
    end
endmodule
