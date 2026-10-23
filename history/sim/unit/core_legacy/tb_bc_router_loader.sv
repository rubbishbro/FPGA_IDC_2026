`timescale 1ns/1ps
module tb_bc_router_loader;
    import modal_record_pkg::*;
    localparam int SLOTS=2, MODES=4, VW=1, MW=2;
    logic clk=0, rst_n=0;
    logic load_valid, load_ready;
    logic [1:0] ev_class, ev_layer;
    logic [3:0] ev_inst;
    logic [6:0] ev_note;
    logic [7:0] ev_vel;
    logic [11:0] ev_nid;
    logic ev_gate;
    logic [1:0] ev_type;
    logic [VW-1:0] load_voice;
    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [VW-1:0] clr_voice;
    logic seed_valid; logic [VW-1:0] seed_voice; logic [MW-1:0] seed_mode; logic [63:0] seed_word;
    logic cvalid; logic [1:0] cclass; logic [3:0] cinst; logic [6:0] cnote; logic [7:0] cvel;
    logic [MW-1:0] cnm; logic [255:0] cctrl; logic [15:0] theta;
    logic load_done; logic [VW-1:0] done_voice; logic [MW-1:0] nmodes;
    logic err; logic [2:0] ecode;

    int errors=0;
    int cfg_cnt=0, seed_cnt=0;
    logic [REC_W-1:0] cfgs[0:7];
    logic [63:0] seeds[0:7];

    bc_router_loader #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES),
        .COEFF_DEPTH(8), .INDEX_DEPTH(8192), .CTRL_DEPTH(2), .SEED_DEPTH(24),
        .COEFF_FILE("sim/unit/core/router_bc_coeff.mem"),
        .INDEX_FILE("sim/unit/core/router_bc_index.mem"),
        .CTRL_FILE("sim/unit/core/router_bc_ctrl.mem"),
        .SEED_FILE("sim/unit/core/router_bc_seed.mem"), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready),
        .ev_class(ev_class), .ev_layer(ev_layer), .ev_instrument(ev_inst),
        .ev_note(ev_note), .ev_velocity(ev_vel), .ev_note_id(ev_nid),
        .ev_gate(ev_gate), .ev_event_type(ev_type), .load_voice(load_voice),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice),
        .seed_valid(seed_valid), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_word(seed_word),
        .commit_valid(cvalid), .commit_class(cclass), .commit_instrument(cinst),
        .commit_note(cnote), .commit_velocity(cvel), .commit_n_modes(cnm),
        .commit_ctrl(cctrl), .theta_base(theta),
        .load_done(load_done), .done_voice(done_voice), .loaded_n_modes(nmodes),
        .error_valid(err), .error_code(ecode)
    );

    always #5 clk=~clk;

    always_ff @(posedge clk) begin
        if (cfg_we) begin cfgs[cfg_cnt] <= cfg_data; cfg_cnt <= cfg_cnt+1; end
        if (seed_valid) begin seeds[seed_cnt] <= seed_word; seed_cnt <= seed_cnt+1; end
    end

    task automatic load(input int cls, input int note, input int nid);
        begin
            @(negedge clk); load_valid=1; load_voice=0;
            ev_class=cls[1:0]; ev_layer=0; ev_inst=0; ev_note=note[6:0];
            ev_vel=0; ev_nid=nid[11:0]; ev_gate=1; ev_type=0;
            @(posedge clk); @(negedge clk); load_valid=0;
            wait (load_done); @(posedge clk); #1;
        end
    endtask

    initial begin
        load_valid=0; ev_class='0; ev_layer='0; ev_inst='0; ev_note='0; ev_vel='0;
        ev_nid='0; ev_gate=0; ev_type='0; load_voice='0;
        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        // B
        load(1, 60, 0);
        if (err) begin $display("FAIL B err=%0d",ecode); errors++; end
        if (cfg_cnt != 2) begin $display("FAIL B cfg=%0d",cfg_cnt); errors++; end
        if (nmodes != 2'd2) begin $display("FAIL B n=%0d",nmodes); errors++; end
        if (cclass != 2'd1) begin $display("FAIL B class=%0d",cclass); errors++; end
        if (rec_get(cfgs[0],E1_G) == 0) begin $display("FAIL B G0"); errors++; end
        if (seed_cnt != 0) begin $display("FAIL B seed=%0d",seed_cnt); errors++; end

        // C
        cfg_cnt=0; seed_cnt=0;
        load(2, 36, 1);
        if (err) begin $display("FAIL C err=%0d",ecode); errors++; end
        if (cfg_cnt != 2) begin $display("FAIL C cfg=%0d",cfg_cnt); errors++; end
        if (seed_cnt != 2) begin $display("FAIL C seed=%0d",seed_cnt); errors++; end
        if (cclass != 2'd2) begin $display("FAIL C class=%0d",cclass); errors++; end
        if (seeds[0] !== 64'hffffe00000001000) begin $display("FAIL C seed0=%h",seeds[0]); errors++; end

        if (errors==0) $display("PASS tb_bc_router_loader");
        else $display("FAIL tb_bc_router_loader errors=%0d",errors);
        $finish;
    end
endmodule
