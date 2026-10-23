// -----------------------------------------------------------------------------
// synth_top.sv -- 共享 BUF + ENG1/ENG2 的顶层壳（迁移第一步）
//
// 本版只接 ENG1（A 路径），ENG2 先 tie-off；BUF 的读口暂时不接 loader，
// 等 class_loader 改成读 BUF 后再接。作业口/结果口对齐 modal_voice_top。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module synth_top #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES = 48,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int COEFF_DEPTH = 5483,
    parameter int INDEX_DEPTH = 1024,
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter bit USE_BC = 1'b0,
    parameter bit USE_BUF = 1'b0,
    parameter int BC_COEFF_DEPTH = 5483,
    parameter int BC_INDEX_DEPTH = 8192,
    parameter int BC_CTRL_DEPTH = 1024,
    parameter int BC_SEED_DEPTH = 1152,
    parameter BC_COEFF_FILE = "rtl/rom/b_coeff.mem",
    parameter BC_INDEX_FILE = "rtl/rom/b_index.mem",
    parameter BC_CTRL_FILE = "rtl/rom/b_ctrl.mem",
    parameter BC_SEED_FILE = "rtl/rom/c_seed.mem",
    parameter int A1_THETA_DEPTH = 5483,
    parameter A1_THETA_FILE = "",
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter int SW = $clog2(NUM_VOICES * N_MODES + 1)
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // BUF 写（router / loader）
    input  logic                     buf_wr_en,
    input  logic                     buf_wr_engine,
    input  logic [15:0]              buf_wr_addr,
    input  logic [255:0]             buf_wr_data,

    // BUF 结果写
    input  logic                     res_we,
    input  logic                     res_engine,
    input  logic                     res_bank,
    input  logic [63:0]              res_data,

    // 结果读口（对齐 modal_voice_top；rd_addr[0] 选 ping-pong bank）
    input  logic                     rd_en,
    input  logic [7:0]               rd_addr,
    output logic [63:0]              rd_data,
    output logic                     rd_valid,

    // ENG1 load
    input  logic                     load_valid,
    output logic                     load_ready,
    input  logic [VW-1:0]            load_voice,
    input  logic [1:0]               load_instrument,
    input  logic [6:0]               load_midi,
    input  logic                     load_dyn,
    input  logic [7:0]               load_vel,
    input  logic [1:0]               load_class,
    input  logic [11:0]              load_note_id,
    output logic [255:0]             commit_ctrl,
    input  logic [VW-1:0]            ctrl_rd_voice,
    output logic [255:0]             ctrl_rd_data,
    input  logic [NUM_VOICES*2-1:0]  b_class_vec,
    input  logic [NUM_VOICES*16-1:0] b_vel_vec,
    input  logic [NUM_VOICES-1:0]    b_start_mask,
    input  logic [NUM_VOICES-1:0]    b_gate_mask,
    input  logic [15:0]              b_ratio,
    input  logic                     a1_enable,
    output logic                     a1_active,
    output logic                     a1_done,
    input  logic [NUM_VOICES*20-1:0] c_length_vec,
    input  logic [NUM_VOICES-1:0]    c_choke_mask,
    output logic [NUM_VOICES-1:0]    c_active,
    output logic [NUM_VOICES-1:0]    c_done,
    output logic                     load_done,
    output logic [VW-1:0]            done_voice,
    output logic [MW-1:0]            loaded_n_modes,

    // ENG1 作业口
    input  logic                     start,
    input  logic [NUM_VOICES-1:0]    active_mask,
    input  logic [NUM_VOICES*32-1:0] x_vec,
    output logic                     sample_ready,
    output logic                     done,
    output logic                     busy,

    // 结果
    output logic                     out_valid,
    output logic signed [63:0]       mix_sum,
    output logic [SW-1:0]            sat_count,
    output logic                     voice_valid,
    output logic [VW-1:0]            voice_id,
    output logic signed [63:0]       voice_sum,
    output logic                     error_valid,
    output logic [2:0]               error_code
);

    // 共享 BUF：系数 region + 结果 ping-pong
    logic [255:0] buf_rd1_data, buf_rd2_data;
    logic [63:0]  res1_b0, res1_b1, res2_b0, res2_b1;
    logic         res_bank_r, rd_valid_r;
    logic         res_we_w, res_engine_w, res_bank_w;
    logic [63:0]  res_data_w;
    logic         buf_rd_en;
    logic [15:0]  buf_rd_addr;
    logic [71:0]  buf_rd_data;

    synth_buf #(
        .ENG1_DEPTH(COEFF_DEPTH),
        .ENG2_DEPTH(16 * 48),
        .WIDTH(256)
    ) u_buf (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (buf_wr_en),
        .wr_engine  (buf_wr_engine),
        .wr_addr    (buf_wr_addr),
        .wr_data    (buf_wr_data),
        .rd1_en     (buf_rd_en),
        .rd1_addr   (buf_rd_addr),
        .rd1_data   (buf_rd1_data),
        .rd2_en     (1'b0),          // TODO: 接 eng2_voice_top
        .rd2_addr   (16'd0),
        .rd2_data   (buf_rd2_data),
        .res_we     (res_we_w),
        .res_engine (res_engine_w),
        .res_bank   (res_bank_w),
        .res_data   (res_data_w),
        .res1_b0    (res1_b0),
        .res1_b1    (res1_b1),
        .res2_b0    (res2_b0),
        .res2_b1    (res2_b1)
    );

    // ENG1 结果自动写 BUF（engine 0，ping-pong bank）
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            res_bank_r <= 1'b0;
            rd_valid_r <= 1'b0;
        end else begin
            if (out_valid) res_bank_r <= ~res_bank_r;
            rd_valid_r <= rd_en;
        end
    end

    assign res_we_w     = out_valid | res_we;
    assign res_engine_w = out_valid ? 1'b0 : res_engine;
    assign res_bank_w   = out_valid ? res_bank_r : res_bank;
    assign res_data_w   = out_valid ? mix_sum : res_data;

    assign rd_data  = rd_addr[1] ? (rd_addr[0] ? res2_b1 : res2_b0)
                                 : (rd_addr[0] ? res1_b1 : res1_b0);
    assign rd_valid = rd_valid_r;

    // ENG1
    eng1_voice_top #(
        .NUM_VOICES(NUM_VOICES),
        .N_MODES(N_MODES),
        .SKIP_ZERO_INPUT(SKIP_ZERO_INPUT),
        .COEFF_DEPTH(COEFF_DEPTH),
        .INDEX_DEPTH(INDEX_DEPTH),
        .COEFF_FILE(COEFF_FILE),
        .INDEX_FILE(INDEX_FILE),
        .USE_BC(USE_BC),
        .USE_BUF(USE_BUF),
        .BC_COEFF_DEPTH(BC_COEFF_DEPTH),
        .BC_INDEX_DEPTH(BC_INDEX_DEPTH),
        .BC_CTRL_DEPTH(BC_CTRL_DEPTH),
        .BC_SEED_DEPTH(BC_SEED_DEPTH),
        .BC_COEFF_FILE(BC_COEFF_FILE),
        .BC_INDEX_FILE(BC_INDEX_FILE),
        .BC_CTRL_FILE(BC_CTRL_FILE),
        .BC_SEED_FILE(BC_SEED_FILE),
        .A1_THETA_DEPTH(A1_THETA_DEPTH),
        .A1_THETA_FILE(A1_THETA_FILE)
    ) u_eng1 (
        .clk(clk),
        .rst_n(rst_n),
        .load_valid(load_valid),
        .load_ready(load_ready),
        .load_voice(load_voice),
        .load_instrument(load_instrument),
        .load_midi(load_midi),
        .load_dyn(load_dyn),
        .load_vel(load_vel),
        .load_class(load_class),
        .load_note_id(load_note_id),
        .commit_ctrl(commit_ctrl),
        .ctrl_rd_voice(ctrl_rd_voice),
        .ctrl_rd_data(ctrl_rd_data),
        .buf_rd_en(buf_rd_en),
        .buf_rd_addr(buf_rd_addr),
        .buf_rd_data(buf_rd1_data[71:0]),
        .b_class_vec(b_class_vec),
        .b_vel_vec(b_vel_vec),
        .b_start_mask(b_start_mask),
        .b_gate_mask(b_gate_mask),
        .b_ratio(b_ratio),
        .a1_enable(a1_enable),
        .a1_active(a1_active),
        .a1_done(a1_done),
        .c_length_vec(c_length_vec),
        .c_choke_mask(c_choke_mask),
        .c_active(c_active),
        .c_done(c_done),
        .load_done(load_done),
        .done_voice(done_voice),
        .loaded_n_modes(loaded_n_modes),
        .start(start),
        .active_mask(active_mask),
        .x_vec(x_vec),
        .sample_ready(sample_ready),
        .done(done),
        .busy(busy),
        .out_valid(out_valid),
        .mix_sum(mix_sum),
        .sat_count(sat_count),
        .voice_valid(voice_valid),
        .voice_id(voice_id),
        .voice_sum(voice_sum),
        .error_valid(error_valid),
        .error_code(error_code)
    );

    // ENG2：复用 modal_voice_top，先 tie-off，等 BUF 读口接通
    import modal_step_pkg::*;
    eng2_voice_top #(
        .N_MODES(48),
        .X_DEPTH(256),
        .SLOTS(16),
        .DEBUG_PORT(1'b0)
    ) u_eng2 (
        .clk(clk),
        .rst_n(rst_n),
        .co_we(1'b0),
        .co_addr('0),
        .co_data('0),
        .x_we(1'b0),
        .x_addr('0),
        .x_data('0),
        .start(1'b0),
        .n_voices('0),
        .n_samples('0),
        .n_modes('0),
        .st_zero_mask('0),
        .done(),
        .busy(),
        .rd_en(1'b0),
        .rd_addr('0),
        .rd_data(),
        .rd_valid(),
        .ns_rd_en(1'b0),
        .ns_rd_addr('0),
        .ns_rd_sel(1'b0),
        .ns_rd_data(),
        .ns_rd_valid()
    );

endmodule
