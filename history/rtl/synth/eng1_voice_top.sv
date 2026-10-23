// -----------------------------------------------------------------------------
// eng1_voice_top.sv -- ENG1（A/B/C）的 voice_top 薄壳
//
// 对外的作业口对齐 rtl/simsynth/modal_voice_top：
//   start / active / n_modes / x -> done / busy / out_valid / mix_sum
// 内部仍是 modal_engine（class_loader + modal_poly_bank），A 路径逐位不变。
//
// 注意：本版还没有把 synth_buf 接到 class_loader 的 ROM 读口；BUF 读口在
// synth_top 里先 tie-off，等 loader 改成读 BUF 后再接。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module eng1_voice_top #(
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
    input  logic                   clk,
    input  logic                   rst_n,

    // 兼容旧 load 口（后续可换成 BUF 直写）
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [VW-1:0]          load_voice,
    input  logic [1:0]             load_instrument,
    input  logic [6:0]             load_midi,
    input  logic                   load_dyn,
    input  logic [7:0]             load_vel,
    input  logic [1:0]             load_class,
    input  logic [11:0]            load_note_id,
    output logic [255:0]           commit_ctrl,
    input  logic [VW-1:0]          ctrl_rd_voice,
    output logic [255:0]           ctrl_rd_data,
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
    output logic                   buf_rd_en,
    output logic [15:0]            buf_rd_addr,
    input  logic [71:0]            buf_rd_data,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,

    // 作业口（对齐 modal_voice_top 的 start/done/busy）
    input  logic                   start,
    input  logic [NUM_VOICES-1:0]  active_mask,
    input  logic [NUM_VOICES*32-1:0] x_vec,
    output logic                   sample_ready,
    output logic                   done,
    output logic                   busy,

    output logic                   out_valid,
    output logic signed [63:0]     mix_sum,
    output logic [SW-1:0]          sat_count,
    output logic                   voice_valid,
    output logic [VW-1:0]          voice_id,
    output logic signed [63:0]     voice_sum,
    output logic                   error_valid,
    output logic [2:0]             error_code
);

    logic [NUM_VOICES*256-1:0] ctrl_flat;
    logic [NUM_VOICES*32-1:0]  b_x;
    logic [NUM_VOICES*32-1:0]  x_mux;

    b_x_pool #(.NUM_VOICES(NUM_VOICES)) u_bx (
        .clk(clk),
        .rst_n(rst_n),
        .ctrl_vec(ctrl_flat),
        .class_vec(b_class_vec),
        .vel_vec(b_vel_vec),
        .start_mask(b_start_mask),
        .gate_mask(b_gate_mask),
        .ratio(b_ratio),
        .x_vec(b_x)
    );

    genvar gv;
    generate
        for (gv = 0; gv < NUM_VOICES; gv = gv + 1) begin : g_xmux
            wire [1:0] cls = b_class_vec[gv*2 +: 2];
            assign x_mux[gv*32 +: 32] =
                (cls == 2'd1) ? b_x[gv*32 +: 32] :
                (cls == 2'd2) ? 32'sd0 : x_vec[gv*32 +: 32];
        end
    endgenerate

    modal_engine #(
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
    ) u_engine (
        .clk          (clk),
        .rst_n        (rst_n),
        .load_valid   (load_valid),
        .load_ready   (load_ready),
        .load_voice   (load_voice),
        .load_instrument(load_instrument),
        .load_midi    (load_midi),
        .load_dyn     (load_dyn),
        .load_vel     (load_vel),
        .load_class   (load_class),
        .load_note_id (load_note_id),
        .busy         (busy),
        .load_done    (load_done),
        .done_voice   (done_voice),
        .loaded_n_modes(loaded_n_modes),
        .sample_valid (start),
        .sample_ready (sample_ready),
        .active_mask  (active_mask),
        .x_vec        (x_mux),
        .out_valid    (out_valid),
        .mix_sum      (mix_sum),
        .sat_count    (sat_count),
        .voice_valid  (voice_valid),
        .voice_id     (voice_id),
        .voice_sum    (voice_sum),
        .commit_valid (),
        .commit_voice (),
        .commit_mode  (),
        .commit_y1    (),
        .commit_y2    (),
        .commit_sat   (),
        .commit_ctrl  (commit_ctrl),
        .ctrl_rd_voice(ctrl_rd_voice),
        .ctrl_rd_data (ctrl_rd_data),
        .ctrl_flat    (ctrl_flat),
        .b_ratio      (b_ratio),
        .a1_enable    (a1_enable),
        .a1_active    (a1_active),
        .a1_done      (a1_done),
        .buf_rd_en    (buf_rd_en),
        .buf_rd_addr  (buf_rd_addr),
        .buf_rd_data  (buf_rd_data),
        .error_valid  (error_valid),
        .error_code   (error_code)
    );

    // C 的每声部生命周期：load_done 且 class=2 时启动对应声部
    logic [NUM_VOICES-1:0] c_start;
    always_ff @(posedge clk) begin
        if (!rst_n) c_start <= '0;
        else begin
            c_start <= '0;
            if (load_done && (load_class == 2'd2)) c_start[done_voice] <= 1'b1;
        end
    end

    genvar gc;
    generate
        for (gc = 0; gc < NUM_VOICES; gc = gc + 1) begin : g_ctimer
            wire [19:0] clen = c_length_vec[gc*20 +: 20];
            c_voice_timer u_timer (
                .clk(clk), .rst_n(rst_n),
                .start(c_start[gc]), .length(clen),
                .choke(c_choke_mask[gc]),
                .active(c_active[gc]), .done(c_done[gc])
            );
        end
    endgenerate

    assign done = out_valid;

endmodule
