// -----------------------------------------------------------------------------
// class_loader_mux.sv -- A（20-bit）与 B/C（64-bit）loader 的按 class 选择
//
// USE_BC=0：只实例化 A loader，ev_class 强制 0（兼容旧 A 测试/顶层）。
// USE_BC=1：A 与 B/C 两个 loader 都在，按 load 时刻的 ev_class 选；
//           另一个 loader 的 load_valid 被 gate 掉，不会启动。
// 两个 loader 共用同一组 clear/cfg/seed 下游端口，由 class_r 选。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module class_loader_mux #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES = 48,
    parameter bit USE_BC = 1'b0,
    parameter bit USE_BUF = 1'b0,
    parameter int COEFF_DEPTH = 5483,
    parameter int INDEX_DEPTH = 1024,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter int BC_COEFF_DEPTH = 5483,
    parameter int BC_INDEX_DEPTH = 8192,
    parameter int BC_CTRL_DEPTH = 1024,
    parameter int BC_SEED_DEPTH = 1152,
    parameter BC_COEFF_FILE = "rtl/rom/b_coeff.mem",
    parameter BC_INDEX_FILE = "rtl/rom/b_index.mem",
    parameter BC_CTRL_FILE = "rtl/rom/b_ctrl.mem",
    parameter BC_SEED_FILE = "rtl/rom/c_seed.mem",
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1)
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [VW-1:0]          load_voice,
    input  logic [1:0]             ev_class,
    input  logic [1:0]             ev_layer,
    input  logic [3:0]             ev_instrument,
    input  logic [6:0]             ev_note,
    input  logic [7:0]             ev_velocity,
    input  logic [11:0]            ev_note_id,
    input  logic                   ev_gate,
    input  logic [1:0]             ev_event_type,

    output logic                   busy,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,
    output logic [15:0]            theta_base,
    output logic                   error_valid,
    output logic [2:0]             error_code,

    output logic                   clear_valid,
    input  logic                   clear_ready,
    output logic [VW-1:0]          clear_voice,

    output logic                   cfg_valid,
    input  logic                   cfg_ready,
    output logic [VW-1:0]          cfg_voice,
    output logic [MW-1:0]          cfg_mode,
    output logic [71:0]            cfg_word,

    output logic                   buf_rd_en,
    output logic [15:0]            buf_rd_addr,
    input  logic [71:0]            buf_rd_data,

    output logic                   seed_valid,
    input  logic                   seed_ready,
    output logic [VW-1:0]          seed_voice,
    output logic [MW-1:0]          seed_mode,
    output logic [63:0]            seed_word,

    output logic                   commit_valid,
    output logic [1:0]             commit_class,
    output logic [1:0]             commit_layer,
    output logic [3:0]             commit_instrument,
    output logic [6:0]             commit_note,
    output logic [7:0]             commit_velocity,
    output logic [11:0]            commit_note_id,
    output logic [MW-1:0]          commit_n_modes,
    output logic [255:0]           commit_ctrl
);

    wire [1:0] cls = USE_BC ? ev_class : 2'd0;

    logic a_busy, a_done, a_err;
    logic [1:0] a_ecode2;
    logic [VW-1:0] a_dv;
    logic [MW-1:0] a_n;
    logic [15:0] a_theta;
    logic a_cv, a_cfg, a_sv;
    logic a_buf_en;
    logic [15:0] a_buf_addr;
    logic [VW-1:0] a_cvoice, a_cfgvoice, a_svoice;
    logic [MW-1:0] a_cfgmode, a_smode;
    logic [71:0] a_cfgword;
    logic [63:0] a_sword;

    class_loader #(
        .NUM_VOICES(NUM_VOICES), .N_MODES(N_MODES),
        .COEFF_DEPTH(COEFF_DEPTH), .INDEX_DEPTH(INDEX_DEPTH),
        .COEFF_FILE(COEFF_FILE), .INDEX_FILE(INDEX_FILE),
        .USE_BUF(USE_BUF)
    ) u_a (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid && (cls == 2'd0)),
        .load_ready(),
        .ev_class(2'd0),
        .ev_layer(ev_layer),
        .ev_instrument(ev_instrument),
        .ev_note(ev_note),
        .ev_velocity(ev_velocity),
        .ev_note_id(ev_note_id),
        .ev_gate(ev_gate),
        .ev_event_type(ev_event_type),
        .load_voice(load_voice),
        .busy(a_busy), .load_done(a_done), .done_voice(a_dv),
        .loaded_n_modes(a_n),
        .theta_base(a_theta),
        .error_valid(a_err), .error_code(a_ecode2),
        .clear_valid(a_cv), .clear_ready(clear_ready), .clear_voice(a_cvoice),
        .cfg_valid(a_cfg), .cfg_ready(cfg_ready), .cfg_voice(a_cfgvoice),
        .cfg_mode(a_cfgmode), .cfg_word(a_cfgword),
        .buf_rd_en(a_buf_en), .buf_rd_addr(a_buf_addr), .buf_rd_data(buf_rd_data),
        .seed_valid(a_sv), .seed_ready(seed_ready), .seed_voice(a_svoice),
        .seed_mode(a_smode), .seed_word(a_sword),
        .commit_valid(), .commit_class(), .commit_layer(),
        .commit_instrument(), .commit_note(), .commit_velocity(),
        .commit_note_id(), .commit_n_modes()
    );

    // B/C
    logic b_busy, b_done, b_err;
    logic [2:0] b_ecode;
    logic [VW-1:0] b_dv;
    logic [MW-1:0] b_n;
    logic [15:0] b_theta;
    logic b_cv, b_cfg, b_sv;
    logic b_buf_en;
    logic [15:0] b_buf_addr;
    logic [VW-1:0] b_cvoice, b_cfgvoice, b_svoice;
    logic [MW-1:0] b_cfgmode, b_smode;
    logic [71:0] b_cfgword;
    logic [63:0] b_sword;
    logic b_commit;
    logic [1:0] b_cc, b_cl;
    logic [3:0] b_ci;
    logic [6:0] b_cn;
    logic [7:0] b_cvel;
    logic [11:0] b_cnid;
    logic [MW-1:0] b_cnm;
    logic [255:0] b_ctrl;

    generate
        if (USE_BC) begin : g_bc
            class_loader64 #(
                .NUM_VOICES(NUM_VOICES), .N_MODES(N_MODES),
                .COEFF_DEPTH(BC_COEFF_DEPTH), .INDEX_DEPTH(BC_INDEX_DEPTH),
                .CTRL_DEPTH(BC_CTRL_DEPTH), .SEED_DEPTH(BC_SEED_DEPTH),
                .COEFF_FILE(BC_COEFF_FILE), .INDEX_FILE(BC_INDEX_FILE),
                .CTRL_FILE(BC_CTRL_FILE), .SEED_FILE(BC_SEED_FILE),
                .USE_BUF(USE_BUF)
            ) u_bc (
                .clk(clk), .rst_n(rst_n),
                .load_valid(load_valid && (cls != 2'd0)),
                .load_ready(),
                .ev_class(ev_class), .ev_layer(ev_layer),
                .ev_instrument(ev_instrument), .ev_note(ev_note),
                .ev_velocity(ev_velocity), .ev_note_id(ev_note_id),
                .ev_gate(ev_gate), .ev_event_type(ev_event_type),
                .load_voice(load_voice),
                .busy(b_busy), .load_done(b_done), .done_voice(b_dv),
                .loaded_n_modes(b_n),
                .theta_base(b_theta),
                .error_valid(b_err), .error_code(b_ecode),
                .clear_valid(b_cv), .clear_ready(clear_ready), .clear_voice(b_cvoice),
                .cfg_valid(b_cfg), .cfg_ready(cfg_ready), .cfg_voice(b_cfgvoice),
                .cfg_mode(b_cfgmode), .cfg_word(b_cfgword),
                .buf_rd_en(b_buf_en), .buf_rd_addr(b_buf_addr), .buf_rd_data(buf_rd_data),
                .seed_valid(b_sv), .seed_ready(seed_ready), .seed_voice(b_svoice),
                .seed_mode(b_smode), .seed_word(b_sword),
                .commit_valid(b_commit), .commit_class(b_cc), .commit_layer(b_cl),
                .commit_instrument(b_ci), .commit_note(b_cn),
                .commit_velocity(b_cvel), .commit_note_id(b_cnid),
                .commit_n_modes(b_cnm), .commit_ctrl(b_ctrl)
            );
        end else begin : g_nobc
            assign b_busy = 1'b0; assign b_done = 1'b0; assign b_err = 1'b0;
            assign b_ecode = 3'd0; assign b_dv = {VW{1'b0}}; assign b_n = {MW{1'b0}};
            assign b_cv = 1'b0; assign b_cfg = 1'b0; assign b_sv = 1'b0;
            assign b_cvoice = {VW{1'b0}}; assign b_cfgvoice = {VW{1'b0}};
            assign b_svoice = {VW{1'b0}};
            assign b_cfgmode = {MW{1'b0}}; assign b_smode = {MW{1'b0}};
            assign b_buf_en = 1'b0; assign b_buf_addr = 16'd0;
            assign b_cfgword = 72'd0; assign b_sword = 64'd0;
            assign b_theta = 16'd0;
            assign b_commit = 1'b0; assign b_cc = 2'd0; assign b_cl = 2'd0;
            assign b_ci = 4'd0; assign b_cn = 7'd0; assign b_cvel = 8'd0;
            assign b_cnid = 12'd0; assign b_cnm = {MW{1'b0}}; assign b_ctrl = 256'd0;
        end
    endgenerate

    // class 在 load 握手时锁存；之后下游 mux 不再看 ev_class。
    logic class_r;
    always_ff @(posedge clk) begin
        if (!rst_n) class_r <= 1'b0;
        else if (load_valid && load_ready) class_r <= (cls != 2'd0);
    end

    // 空闲时对应 loader 的 ready 为 1；用 busy 反推
    assign load_ready = (cls != 2'd0) ? (~b_busy) : (~a_busy);

    assign busy          = class_r ? b_busy : a_busy;
    assign load_done     = class_r ? b_done : a_done;
    assign done_voice    = class_r ? b_dv : a_dv;
    assign loaded_n_modes= class_r ? b_n : a_n;
    assign theta_base   = class_r ? b_theta : a_theta;
    assign error_valid   = class_r ? b_err : a_err;
    assign error_code    = class_r ? b_ecode : {1'b0, a_ecode2};

    assign clear_valid   = class_r ? b_cv : a_cv;
    assign clear_voice   = class_r ? b_cvoice : a_cvoice;
    assign cfg_valid     = class_r ? b_cfg : a_cfg;
    assign cfg_voice     = class_r ? b_cfgvoice : a_cfgvoice;
    assign cfg_mode      = class_r ? b_cfgmode : a_cfgmode;
    assign cfg_word      = class_r ? b_cfgword : a_cfgword;
    assign buf_rd_en     = class_r ? b_buf_en : a_buf_en;
    assign buf_rd_addr   = class_r ? b_buf_addr : a_buf_addr;
    assign seed_valid    = class_r ? b_sv : a_sv;
    assign seed_voice    = class_r ? b_svoice : a_svoice;
    assign seed_mode     = class_r ? b_smode : a_smode;
    assign seed_word     = class_r ? b_sword : a_sword;

    assign commit_valid  = class_r ? b_commit : a_done;
    assign commit_class  = class_r ? b_cc : 2'd0;
    assign commit_layer  = class_r ? b_cl : ev_layer;
    assign commit_instrument = class_r ? b_ci : ev_instrument;
    assign commit_note   = class_r ? b_cn : ev_note;
    assign commit_velocity = class_r ? b_cvel : ev_velocity;
    assign commit_note_id = class_r ? b_cnid : ev_note_id;
    assign commit_n_modes = class_r ? b_cnm : a_n;
    assign commit_ctrl   = class_r ? b_ctrl : 256'd0;

endmodule
