// -----------------------------------------------------------------------------
// router_loader.sv -- 统一 loader 顶层（直接使用 class_loader / class_loader64）
//
// A: class_loader（20-bit index）
// B/C: class_loader64（64-bit index/control/seed）
// E2: class_loader64 + 224-bit coefficient ROM
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module router_loader #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2 = 80,
    parameter int REC_W = 288,
    parameter int A_COEFF_DEPTH = 5483, A_INDEX_DEPTH = 1024,
    parameter A_COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter A_INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter int BC_COEFF_DEPTH = 5483, BC_INDEX_DEPTH = 8192,
    parameter int BC_CTRL_DEPTH = 1024, BC_SEED_DEPTH = 1152,
    parameter BC_COEFF_FILE = "rtl/rom/b_coeff.mem",
    parameter BC_INDEX_FILE = "rtl/rom/b_index.mem",
    parameter BC_CTRL_FILE = "rtl/rom/b_ctrl.mem",
    parameter BC_SEED_FILE = "rtl/rom/c_seed.mem",
    parameter int E2_COEFF_DEPTH = 8192, E2_INDEX_DEPTH = 8192,
    parameter int E2_CTRL_DEPTH = 1024, E2_SEED_DEPTH = 1152,
    parameter E2_COEFF_FILE = "rtl/rom/e2_coeff.mem",
    parameter E2_INDEX_FILE = "rtl/rom/e2_index.mem",
    parameter E2_CTRL_FILE = "rtl/rom/e2_ctrl.mem",
    parameter E2_SEED_FILE = "rtl/rom/e2_seed.mem",
    parameter E2_L72_FILE = "rtl/rom/modal_coeff.mem",
    parameter int VW = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_ABC = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2 = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1)
) (
    input  logic clk, rst_n,
    input  logic load_valid,
    output logic load_ready,
    input  logic [1:0] load_class,
    input  logic [VW-1:0] load_voice,
    input  logic [1:0] load_inst,
    input  logic [6:0] load_note,
    input  logic [7:0] load_vel,
    input  logic load_dyn,
    input  logic [11:0] load_note_id,

    output logic a_cfg_we, output logic [VW-1:0] a_cfg_voice, output logic [MW_ABC-1:0] a_cfg_mode,
    output logic [REC_W-1:0] a_cfg_data, output logic a_clr_we, output logic [VW-1:0] a_clr_voice,
    output logic a_ready, a_done, a_err, output logic [VW-1:0] a_done_voice,
    output logic [MW_ABC-1:0] a_n, output logic [2:0] a_ecode,

    output logic bc_cfg_we, output logic [VW-1:0] bc_cfg_voice, output logic [MW_ABC-1:0] bc_cfg_mode,
    output logic [REC_W-1:0] bc_cfg_data, output logic bc_clr_we, output logic [VW-1:0] bc_clr_voice,
    output logic bc_seed_valid, output logic [VW-1:0] bc_seed_voice,
    output logic [MW_ABC-1:0] bc_seed_mode, output logic [63:0] bc_seed_word,
    output logic [255:0] bc_ctrl, output logic [15:0] bc_theta, output logic [1:0] bc_class,
    output logic bc_ready, bc_done, bc_err, output logic [VW-1:0] bc_done_voice,
    output logic [MW_ABC-1:0] bc_n, output logic [2:0] bc_ecode,

    output logic e2_cfg_we, output logic [VW-1:0] e2_cfg_voice, output logic [MW_E2-1:0] e2_cfg_mode,
    output logic [REC_W-1:0] e2_cfg_data, output logic e2_clr_we, output logic [VW-1:0] e2_clr_voice,
    output logic e2_seed_valid, output logic [VW-1:0] e2_seed_voice,
    output logic [MW_E2-1:0] e2_seed_mode, output logic [63:0] e2_seed_word,
    output logic e2_ready, e2_done, e2_err, output logic [VW-1:0] e2_done_voice,
    output logic [MW_E2-1:0] e2_n, output logic [15:0] e2_theta, output logic [2:0] e2_ecode
);
    // ---------------- A ----------------
    logic a_cfg_valid, a_clear_valid, a_busy;
    logic [VW-1:0] a_cv, a_clv, a_dv;
    logic [MW_ABC-1:0] a_cm, a_nm;
    logic [71:0] a_word; logic [1:0] a_ec2;
    class_loader #(.NUM_VOICES(NUM_SLOTS),.N_MODES(N_MODES_ABC),.COEFF_DEPTH(A_COEFF_DEPTH),
      .INDEX_DEPTH(A_INDEX_DEPTH),.COEFF_FILE(A_COEFF_FILE),.INDEX_FILE(A_INDEX_FILE),.USE_BUF(1'b0)) u_a (
      .clk(clk),.rst_n(rst_n),.load_valid(load_valid && load_class==2'd0),.load_ready(a_ready),
      .ev_class(2'd0),.ev_layer({1'b0,load_dyn}),.ev_instrument({2'b0,load_inst}),.ev_note(load_note),
      .ev_velocity(load_vel),.ev_note_id(12'd0),.ev_gate(1'b1),.ev_event_type(2'd0),.load_voice(load_voice),
      .busy(a_busy),.load_done(a_done),.done_voice(a_dv),.loaded_n_modes(a_nm),.theta_base(),
      .error_valid(a_err),.error_code(a_ec2),.clear_valid(a_clear_valid),.clear_ready(1'b1),
      .clear_voice(a_clv),.cfg_valid(a_cfg_valid),.cfg_ready(1'b1),.cfg_voice(a_cv),.cfg_mode(a_cm),
      .cfg_word(a_word),.buf_rd_en(),.buf_rd_addr(),.buf_rd_data(72'd0),
      .seed_valid(),.seed_ready(1'b1),.seed_voice(),.seed_mode(),.seed_word(),
      .commit_valid(),.commit_class(),.commit_layer(),.commit_instrument(),.commit_note(),
      .commit_velocity(),.commit_note_id(),.commit_n_modes());
    always_comb begin
        a_cfg_data='0;
        a_cfg_data[0*32 +: 32]={{6{a_word[71]}},a_word[71:46]};
        a_cfg_data[1*32 +: 32]={{10{a_word[21]}},a_word[21:0]};
        a_cfg_data[2*32 +: 32]={8'b0,a_word[45:22]};
    end
    assign a_cfg_we=a_cfg_valid; assign a_cfg_voice=a_cv; assign a_cfg_mode=a_cm;
    assign a_clr_we=a_clear_valid; assign a_clr_voice=a_clv;
    assign a_done_voice=a_dv; assign a_n=a_nm; assign a_ecode={1'b0,a_ec2};

    // ---------------- B/C ----------------
    logic bc_cfg_valid, bc_clear_valid;
    logic [VW-1:0] bc_cv, bc_clv, bc_dv;
    logic [MW_ABC-1:0] bc_cm, bc_nm;
    logic [71:0] bc_word;
    class_loader64 #(.NUM_VOICES(NUM_SLOTS),.N_MODES(N_MODES_ABC),.COEFF_DEPTH(BC_COEFF_DEPTH),
      .INDEX_DEPTH(BC_INDEX_DEPTH),.CTRL_DEPTH(BC_CTRL_DEPTH),.SEED_DEPTH(BC_SEED_DEPTH),
      .COEFF_FILE(BC_COEFF_FILE),.INDEX_FILE(BC_INDEX_FILE),.CTRL_FILE(BC_CTRL_FILE),
      .SEED_FILE(BC_SEED_FILE),.USE_BUF(1'b0),.MW(MW_ABC)) u_bc (
      .clk(clk),.rst_n(rst_n),.load_valid(load_valid && (load_class==2'd1||load_class==2'd2)),.load_ready(bc_ready),
      .ev_class(load_class),.ev_layer({1'b0,load_dyn}),.ev_instrument({2'b0,load_inst}),.ev_note(load_note),
      .ev_velocity(load_vel),.ev_note_id(load_note_id),.ev_gate(1'b1),.ev_event_type(2'd0),.load_voice(load_voice),
      .busy(),.load_done(bc_done),.done_voice(bc_dv),.loaded_n_modes(bc_nm),.theta_base(bc_theta),
      .error_valid(bc_err),.error_code(bc_ecode),.clear_valid(bc_clear_valid),.clear_ready(1'b1),
      .clear_voice(bc_clv),.cfg_valid(bc_cfg_valid),.cfg_ready(1'b1),.cfg_voice(bc_cv),.cfg_mode(bc_cm),
      .cfg_word(bc_word),.buf_rd_en(),.buf_rd_addr(),.buf_rd_data(72'd0),
      .seed_valid(bc_seed_valid),.seed_ready(1'b1),.seed_voice(bc_seed_voice),.seed_mode(bc_seed_mode),
      .seed_word(bc_seed_word),.commit_valid(),.commit_class(bc_class),.commit_layer(),
      .commit_instrument(),.commit_note(),.commit_velocity(),.commit_note_id(),.commit_n_modes(),
      .commit_ctrl(bc_ctrl));
    always_comb begin
        bc_cfg_data='0;
        bc_cfg_data[0*32 +: 32]={{6{bc_word[71]}},bc_word[71:46]};
        bc_cfg_data[1*32 +: 32]={{10{bc_word[21]}},bc_word[21:0]};
        bc_cfg_data[2*32 +: 32]={8'b0,bc_word[45:22]};
    end
    assign bc_cfg_we=bc_cfg_valid; assign bc_cfg_voice=bc_cv; assign bc_cfg_mode=bc_cm;
    assign bc_clr_we=bc_clear_valid; assign bc_clr_voice=bc_clv;
    assign bc_done_voice=bc_dv; assign bc_n=bc_nm;

    // ---------------- E2 ----------------
    logic e2_cfg_valid, e2_clear_valid;
    logic [VW-1:0] e2_cv, e2_clv, e2_dv;
    logic [MW_E2-1:0] e2_cm, e2_nm;
    logic [71:0] e2_word;
    logic [223:0] e2_rom [0:E2_COEFF_DEPTH-1];
    logic [15:0] e2_addr;
    initial if (E2_COEFF_FILE != "") $readmemh(E2_COEFF_FILE, e2_rom);
    assign e2_addr = e2_theta + e2_cm;
    class_loader64 #(.NUM_VOICES(NUM_SLOTS),.N_MODES(N_MODES_E2),.COEFF_DEPTH(E2_COEFF_DEPTH),
      .INDEX_DEPTH(E2_INDEX_DEPTH),.CTRL_DEPTH(E2_CTRL_DEPTH),.SEED_DEPTH(E2_SEED_DEPTH),
      .COEFF_FILE(E2_L72_FILE),.INDEX_FILE(E2_INDEX_FILE),.CTRL_FILE(E2_CTRL_FILE),
      .SEED_FILE(E2_SEED_FILE),.USE_BUF(1'b0),.MW(MW_E2)) u_e2 (
      .clk(clk),.rst_n(rst_n),.load_valid(load_valid && load_class==2'd3),.load_ready(e2_ready),
      .ev_class(load_class),.ev_layer({1'b0,load_dyn}),.ev_instrument({2'b0,load_inst}),.ev_note(load_note),
      .ev_velocity(load_vel),.ev_note_id(load_note_id),.ev_gate(1'b1),.ev_event_type(2'd0),.load_voice(load_voice),
      .busy(),.load_done(e2_done),.done_voice(e2_dv),.loaded_n_modes(e2_nm),.theta_base(e2_theta),
      .error_valid(e2_err),.error_code(e2_ecode),.clear_valid(e2_clear_valid),.clear_ready(1'b1),
      .clear_voice(e2_clv),.cfg_valid(e2_cfg_valid),.cfg_ready(1'b1),.cfg_voice(e2_cv),.cfg_mode(e2_cm),
      .cfg_word(e2_word),.buf_rd_en(),.buf_rd_addr(),.buf_rd_data(72'd0),
      .seed_valid(e2_seed_valid),.seed_ready(1'b1),.seed_voice(e2_seed_voice),.seed_mode(e2_seed_mode),
      .seed_word(e2_seed_word),.commit_valid(),.commit_class(),.commit_layer(),.commit_instrument(),
      .commit_note(),.commit_velocity(),.commit_note_id(),.commit_n_modes(),.commit_ctrl());
    always_comb begin
        e2_cfg_data='0;
        e2_cfg_data[0*32 +: 32]=e2_rom[e2_addr][0*32 +: 32];
        e2_cfg_data[1*32 +: 32]=e2_rom[e2_addr][1*32 +: 32];
        e2_cfg_data[2*32 +: 32]=e2_rom[e2_addr][2*32 +: 32];
        e2_cfg_data[3*32 +: 32]=e2_rom[e2_addr][3*32 +: 32];
        e2_cfg_data[4*32 +: 32]=e2_rom[e2_addr][4*32 +: 32];
        e2_cfg_data[5*32 +: 32]=e2_rom[e2_addr][5*32 +: 32];
        e2_cfg_data[6*32 +: 32]=e2_rom[e2_addr][6*32 +: 32];
    end
    assign e2_cfg_we=e2_cfg_valid; assign e2_cfg_voice=e2_cv; assign e2_cfg_mode=e2_cm;
    assign e2_clr_we=e2_clear_valid; assign e2_clr_voice=e2_clv;
    assign e2_done_voice=e2_dv; assign e2_n=e2_nm;

    always_comb begin
        if (load_class==2'd0) load_ready=a_ready;
        else if (load_class==2'd3) load_ready=e2_ready;
        else load_ready=bc_ready;
    end
endmodule
