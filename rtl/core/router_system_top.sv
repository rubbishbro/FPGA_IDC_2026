// -----------------------------------------------------------------------------
// router_system_top.sv -- A/B/C router loader + 事件/voice router + 四引擎
//
// load event -> A/B/C index/control/coeff ROM loader -> 9×32 cfg
// load_done -> voice_router note_on -> 四引擎
// ENG2 的 cfg/x 仍由外部给（R5 已有 9×32 适配）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module router_system_top #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter int A_COEFF_DEPTH = 5483,
    parameter int A_INDEX_DEPTH = 1024,
    parameter     A_COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter     A_INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter int BC_COEFF_DEPTH = 5483,
    parameter int BC_INDEX_DEPTH = 8192,
    parameter int BC_CTRL_DEPTH  = 1024,
    parameter int BC_SEED_DEPTH  = 1152,
    parameter     BC_COEFF_FILE = "rtl/rom/b_coeff.mem",
    parameter     BC_INDEX_FILE = "rtl/rom/b_index.mem",
    parameter     BC_CTRL_FILE  = "rtl/rom/b_ctrl.mem",
    parameter     BC_SEED_FILE  = "rtl/rom/c_seed.mem",
    parameter     C_SEED_FILE   = "rtl/rom/c_seed.mem",
    parameter int E2_COEFF_DEPTH = 8192,
    parameter int E2_INDEX_DEPTH = 8192,
    parameter int E2_CTRL_DEPTH  = 1024,
    parameter int E2_SEED_DEPTH  = 1152,
    parameter     E2_COEFF_FILE  = "rtl/rom/e2_coeff.mem",
    parameter     E2_INDEX_FILE  = "rtl/rom/e2_index.mem",
    parameter     E2_CTRL_FILE   = "rtl/rom/e2_ctrl.mem",
    parameter     E2_SEED_FILE   = "rtl/rom/e2_seed.mem",
    parameter     E2_L72_FILE    = "rtl/rom/modal_coeff.mem",
    parameter int VW = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_ABC = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2  = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1)
) (
    input  logic clk, rst_n,

    // load event
    input  logic load_valid,
    output logic load_ready,
    input  logic [1:0] load_class,
    input  logic [VW-1:0] load_voice,
    input  logic [1:0] load_inst,
    input  logic [6:0] load_note,
    input  logic [7:0] load_vel,
    input  logic load_dyn,
    input  logic [11:0] load_note_id,
    output logic load_done,
    output logic [VW-1:0] done_voice,
    output logic [MW_ABC-1:0] loaded_n_modes,
    output logic load_error,

    // new router frontend (config/fmap -> x)
    input  logic rcfg_valid,
    input  logic [3:0] rcfg_instrument,
    input  logic [3:0] rcfg_voice,
    input  logic [6:0] rcfg_note,
    input  logic [7:0] rcfg_velocity,
    input  logic [16*8-1:0] fmap,
    input  logic fmap_valid,

    // note off
    input  logic off_valid,
    input  logic [VW-1:0] off_voice,

    // A job
    input  logic [NUM_SLOTS*32-1:0] a_x,
    input  logic [NUM_SLOTS*16-1:0] a_x_vel,
    // B job
    input  logic [NUM_SLOTS*16-1:0] b_vel,
    input  logic [15:0] b_ratio,
    input  logic b_a1_enable,
    // C job
    input  logic [NUM_SLOTS*16-1:0] c_seed_vel,
    input  logic [15:0] c_seed_base,

    // ENG2 external
    input  logic e2_cfg_we,
    input  logic [VW-1:0] e2_cfg_voice,
    input  logic [MW_E2-1:0] e2_cfg_mode,
    input  logic [REC_W-1:0] e2_cfg_data,
    input  logic e2_clr_we,
    input  logic [VW-1:0] e2_clr_voice,
    input  logic [MW_E2-1:0] e2_clr_mode,
    input  logic e2_seed_we,
    input  logic [VW-1:0] e2_seed_voice,
    input  logic [MW_E2-1:0] e2_seed_mode,
    input  logic [63:0] e2_seed_data,
    input  logic [NUM_SLOTS*32-1:0] e2_x,
    input  logic [NUM_SLOTS*MW_E2-1:0] e2_nmodes,

    input  logic start,
    output logic sample_ready, busy, done, out_valid,
    output logic signed [63:0] mix_sum
);

    // loaders
    logic a_ready, bc_ready;
    logic a_cfg_we, bc_cfg_we;
    logic a_clr_we, bc_clr_we;
    logic [VW-1:0] a_cfg_voice, bc_cfg_voice, a_clr_voice, bc_clr_voice;
    logic [MW_ABC-1:0] a_cfg_mode, bc_cfg_mode;
    logic [REC_W-1:0] a_cfg_data, bc_cfg_data;
    logic [VW-1:0] a_done_voice, bc_done_voice;
    logic [MW_ABC-1:0] a_n, bc_n;
    logic a_done, bc_done;
    logic a_err, bc_err;
    logic [2:0] a_ecode, bc_ecode;

    logic bc_seed_valid;
    logic [VW-1:0] bc_seed_voice;
    logic [MW_ABC-1:0] bc_seed_mode;
    logic [63:0] bc_seed_word;
    logic [255:0] bc_ctrl;
    logic [15:0] bc_theta;
    logic [1:0] bc_class;

    logic [1:0] class_r;
    logic [VW-1:0] done_voice_r;

    logic [3:0] r_instrument_id;
    logic [1:0] r_engine_sel;
    logic signed [31:0] r_x;
    logic r_key_pressed;
    logic [15:0] r_velocity;
    logic [NUM_SLOTS*32-1:0] a_x_eff;
    logic [NUM_SLOTS*32-1:0] b_x_eff;
    logic [NUM_SLOTS*32-1:0] c_x_eff;
    logic [NUM_SLOTS*32-1:0] e2_x_eff;

    router_frontend u_rfront (
        .clk(clk), .rst_n(rst_n),
        .cfg_valid(rcfg_valid), .cfg_instrument(rcfg_instrument),
        .cfg_voice(rcfg_voice), .cfg_note(rcfg_note), .cfg_velocity(rcfg_velocity),
        .fmap(fmap), .fmap_valid(fmap_valid),
        .instrument_id(r_instrument_id), .engine_sel(r_engine_sel),
        .coeff_base(), .ram_base(), .load_req(), .load_voice(), .load_note(),
        .load_velocity(), .load_addr(), .key_pressed(r_key_pressed),
        .velocity(r_velocity), .x(r_x), .x_valid()
    );

    always_comb begin
        a_x_eff = a_x;
        b_x_eff = '0;
        c_x_eff = '0;
        e2_x_eff = e2_x;
        if (fmap_valid) begin
            a_x_eff[0*32 +: 32]  = r_x;
            b_x_eff[0*32 +: 32]  = r_x;
            c_x_eff[0*32 +: 32]  = r_x;
            e2_x_eff[0*32 +: 32] = r_x;
        end
    end

    // E2 loader
    logic e2_ready, e2_cfg_we_ld, e2_clr_we_ld;
    logic [VW-1:0] e2_cfg_voice_ld, e2_clr_voice_ld;
    logic [MW_E2-1:0] e2_cfg_mode_ld, e2_clr_mode_ld;
    logic [REC_W-1:0] e2_cfg_data_ld;
    logic e2_seed_valid_ld;
    logic [VW-1:0] e2_seed_voice_ld;
    logic [MW_E2-1:0] e2_seed_mode_ld;
    logic [63:0] e2_seed_word_ld;
    logic e2_done;
    logic [VW-1:0] e2_done_voice;
    logic [MW_E2-1:0] e2_n;
    logic [15:0] e2_theta;
    logic e2_err;
    logic [2:0] e2_ecode;
    logic [NUM_SLOTS*MW_E2-1:0] e2_nm;

    router_loader #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES_ABC(N_MODES_ABC), .N_MODES_E2(N_MODES_E2), .REC_W(REC_W),
        .A_COEFF_DEPTH(A_COEFF_DEPTH), .A_INDEX_DEPTH(A_INDEX_DEPTH),
        .A_COEFF_FILE(A_COEFF_FILE), .A_INDEX_FILE(A_INDEX_FILE),
        .BC_COEFF_DEPTH(BC_COEFF_DEPTH), .BC_INDEX_DEPTH(BC_INDEX_DEPTH),
        .BC_CTRL_DEPTH(BC_CTRL_DEPTH), .BC_SEED_DEPTH(BC_SEED_DEPTH),
        .BC_COEFF_FILE(BC_COEFF_FILE), .BC_INDEX_FILE(BC_INDEX_FILE),
        .BC_CTRL_FILE(BC_CTRL_FILE), .BC_SEED_FILE(BC_SEED_FILE),
        .E2_COEFF_DEPTH(E2_COEFF_DEPTH), .E2_INDEX_DEPTH(E2_INDEX_DEPTH),
        .E2_CTRL_DEPTH(E2_CTRL_DEPTH), .E2_SEED_DEPTH(E2_SEED_DEPTH),
        .E2_COEFF_FILE(E2_COEFF_FILE), .E2_INDEX_FILE(E2_INDEX_FILE),
        .E2_CTRL_FILE(E2_CTRL_FILE), .E2_SEED_FILE(E2_SEED_FILE), .E2_L72_FILE(E2_L72_FILE)
    ) u_ld (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(),
        .load_class(load_class), .load_voice(load_voice), .load_inst(load_inst),
        .load_note(load_note), .load_vel(load_vel), .load_dyn(load_dyn), .load_note_id(load_note_id),
        .a_cfg_we(a_cfg_we), .a_cfg_voice(a_cfg_voice), .a_cfg_mode(a_cfg_mode), .a_cfg_data(a_cfg_data),
        .a_clr_we(a_clr_we), .a_clr_voice(a_clr_voice),
        .a_ready(a_ready), .a_done(a_done), .a_err(a_err), .a_done_voice(a_done_voice), .a_n(a_n), .a_ecode(a_ecode),
        .bc_cfg_we(bc_cfg_we), .bc_cfg_voice(bc_cfg_voice), .bc_cfg_mode(bc_cfg_mode), .bc_cfg_data(bc_cfg_data),
        .bc_clr_we(bc_clr_we), .bc_clr_voice(bc_clr_voice),
        .bc_seed_valid(bc_seed_valid), .bc_seed_voice(bc_seed_voice), .bc_seed_mode(bc_seed_mode), .bc_seed_word(bc_seed_word),
        .bc_ctrl(bc_ctrl), .bc_theta(bc_theta), .bc_class(bc_class),
        .bc_ready(bc_ready), .bc_done(bc_done), .bc_err(bc_err), .bc_done_voice(bc_done_voice), .bc_n(bc_n), .bc_ecode(bc_ecode),
        .e2_cfg_we(e2_cfg_we_ld), .e2_cfg_voice(e2_cfg_voice_ld), .e2_cfg_mode(e2_cfg_mode_ld), .e2_cfg_data(e2_cfg_data_ld),
        .e2_clr_we(e2_clr_we_ld), .e2_clr_voice(e2_clr_voice_ld),
        .e2_seed_valid(e2_seed_valid_ld), .e2_seed_voice(e2_seed_voice_ld), .e2_seed_mode(e2_seed_mode_ld), .e2_seed_word(e2_seed_word_ld),
        .e2_ready(e2_ready), .e2_done(e2_done), .e2_err(e2_err), .e2_done_voice(e2_done_voice), .e2_n(e2_n),
        .e2_theta(e2_theta), .e2_ecode(e2_ecode)
    );

    always_comb begin
        if (load_class == 2'd0)       load_ready = a_ready;
        else if (load_class == 2'd3)  load_ready = e2_ready;
        else                          load_ready = bc_ready;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) class_r <= 2'd0;
        else if (load_valid && load_ready) class_r <= load_class;
    end

    // 元数据
    logic [NUM_SLOTS*MW_ABC-1:0] a_nm, b_nm, c_nm;
    logic [NUM_SLOTS*256-1:0]    ctrl_flat;
    logic [NUM_SLOTS*16-1:0]     theta_flat;
    logic [NUM_SLOTS*20-1:0]     c_len;
    logic [NUM_SLOTS*24-1:0]     c_atk, c_rel;

    wire [VW-1:0] dv_meta = (class_r == 2'd3) ? e2_done_voice :
                            class_r ? bc_done_voice : a_done_voice;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_nm <= '0; b_nm <= '0; c_nm <= '0; e2_nm <= '0;
            ctrl_flat <= '0; theta_flat <= '0;
        end else if ((class_r == 2'd3) ? e2_done : (class_r ? bc_done : a_done)) begin
            if (class_r == 2'd0) begin
                a_nm[dv_meta*MW_ABC +: MW_ABC] <= a_n;
            end else if (class_r == 2'd3) begin
                e2_nm[dv_meta*MW_E2 +: MW_E2] <= e2_n;
            end else begin
                ctrl_flat[dv_meta*256 +: 256] <= bc_ctrl;
                theta_flat[dv_meta*16 +: 16] <= bc_theta;
                if (bc_class == 2'd1)
                    b_nm[dv_meta*MW_ABC +: MW_ABC] <= bc_n;
                else
                    c_nm[dv_meta*MW_ABC +: MW_ABC] <= bc_n;
            end
        end
    end

    genvar g;
    generate
        for (g = 0; g < NUM_SLOTS; g = g + 1) begin : g_cfg
            assign c_len[g*20 +: 20] = ctrl_flat[g*256 + 39 +: 20];
            assign c_atk[g*24 +: 24] = ctrl_flat[g*256 + 16 +: 24];
            assign c_rel[g*24 +: 24] = ctrl_flat[g*256 + 40 +: 24];
        end
    endgenerate

    wire load_done_mux = (class_r == 2'd3) ? e2_done : (class_r ? bc_done : a_done);
    wire [VW-1:0] done_voice_mux = (class_r == 2'd3) ? e2_done_voice :
                                   class_r ? bc_done_voice : a_done_voice;
    wire [MW_ABC-1:0] n_mux = (class_r == 2'd3) ? e2_n[MW_ABC-1:0] :
                              class_r ? bc_n : a_n;

    assign load_done = load_done_mux;
    assign done_voice = done_voice_mux;
    assign loaded_n_modes = n_mux;
    assign load_error = a_err | bc_err | e2_err;

    // A/B/C 共享总线
    wire cfg_we_mux = class_r ? bc_cfg_we : a_cfg_we;
    wire clr_we_mux = class_r ? bc_clr_we : a_clr_we;
    wire [VW-1:0] cfg_voice_mux = class_r ? bc_cfg_voice : a_cfg_voice;
    wire [MW_ABC-1:0] cfg_mode_mux = class_r ? bc_cfg_mode : a_cfg_mode;
    wire [REC_W-1:0] cfg_data_mux = class_r ? bc_cfg_data : a_cfg_data;
    wire [VW-1:0] clr_voice_mux = class_r ? bc_clr_voice : a_clr_voice;
    wire seed_we_mux = (class_r == 2'd2) && bc_seed_valid;

    // E2 总线：class3 用 router loader；其他 class 保持外部手动口
    wire e2_cfg_we_use = (class_r == 2'd3) ? e2_cfg_we_ld : e2_cfg_we;
    wire e2_clr_we_use = (class_r == 2'd3) ? e2_clr_we_ld : e2_clr_we;
    wire e2_seed_we_use = (class_r == 2'd3) ? e2_seed_valid_ld : e2_seed_we;
    wire [VW-1:0] e2_cfg_voice_use = (class_r == 2'd3) ? e2_cfg_voice_ld : e2_cfg_voice;
    wire [MW_E2-1:0] e2_cfg_mode_use = (class_r == 2'd3) ? e2_cfg_mode_ld : e2_cfg_mode;
    wire [REC_W-1:0] e2_cfg_data_use = (class_r == 2'd3) ? e2_cfg_data_ld : e2_cfg_data;
    wire [VW-1:0] e2_clr_voice_use = (class_r == 2'd3) ? e2_clr_voice_ld : e2_clr_voice;
    wire [MW_E2-1:0] e2_clr_mode_use = (class_r == 2'd3) ? e2_cfg_mode_ld : e2_clr_mode;
    wire [VW-1:0] e2_seed_voice_use = (class_r == 2'd3) ? e2_seed_voice_ld : e2_seed_voice;
    wire [MW_E2-1:0] e2_seed_mode_use = (class_r == 2'd3) ? e2_seed_mode_ld : e2_seed_mode;
    wire [63:0] e2_seed_data_use = (class_r == 2'd3) ? e2_seed_word_ld : e2_seed_data;
    wire [NUM_SLOTS*MW_E2-1:0] e2_nmodes_use = (class_r == 2'd3) ? e2_nm : e2_nmodes;

    shared_engines_system_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES_ABC(N_MODES_ABC),
        .N_MODES_E2(N_MODES_E2), .LANES(LANES), .REC_W(REC_W),
        .C_SEED_FILE(C_SEED_FILE)
    ) u_sys (
        .clk(clk), .rst_n(rst_n),
        .note_on(load_done_mux), .note_off(off_valid),
        .note_voice(off_valid ? off_voice : done_voice_mux),
        .note_class((class_r == 2'd3) ? 2'd3 : (class_r ? bc_class : 2'd0)),
        .a_x(a_x_eff), .a_x_vel(a_x_vel), .a_nmodes(a_nm), .b_x(b_x_eff), .c_x(c_x_eff),
        .b_ctrl(ctrl_flat), .b_vel(b_vel), .b_theta(theta_flat),
        .b_a1_enable(b_a1_enable), .b_ratio(b_ratio), .b_nmodes(b_nm),
        .c_len(c_len), .c_seed_vel(c_seed_vel), .c_attack(c_atk), .c_release(c_rel),
        .c_nmodes(c_nm), .c_seed_base(c_seed_base),
        .cfg_we(cfg_we_mux), .cfg_engine((class_r == 2'd0) ? 2'd0 : (bc_class == 2'd1 ? 2'd1 : 2'd2)),
        .cfg_voice(cfg_voice_mux), .cfg_mode(cfg_mode_mux), .cfg_data(cfg_data_mux),
        .clr_we(clr_we_mux), .clr_engine((class_r == 2'd0) ? 2'd0 : (bc_class == 2'd1 ? 2'd1 : 2'd2)),
        .clr_voice(clr_voice_mux), .clr_mode(cfg_mode_mux),
        .seed_we(seed_we_mux), .seed_engine(2'd2),
        .seed_voice(bc_seed_voice), .seed_mode(bc_seed_mode), .seed_data(bc_seed_word),
        .e2_cfg_we(e2_cfg_we_use), .e2_cfg_voice(e2_cfg_voice_use), .e2_cfg_mode(e2_cfg_mode_use), .e2_cfg_data(e2_cfg_data_use),
        .e2_clr_we(e2_clr_we_use), .e2_clr_voice(e2_clr_voice_use), .e2_clr_mode(e2_clr_mode_use),
        .e2_seed_we(e2_seed_we_use), .e2_seed_voice(e2_seed_voice_use), .e2_seed_mode(e2_seed_mode_use), .e2_seed_data(e2_seed_data_use),
        .e2_x(e2_x_eff), .e2_nmodes(e2_nmodes_use),
        .start(start), .sample_ready(sample_ready), .busy(busy), .done(done),
        .out_valid(out_valid), .mix_sum(mix_sum)
    );

endmodule
