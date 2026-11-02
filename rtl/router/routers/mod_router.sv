// mod_router -- 共用调制子路由：ENG0 矩阵调制 / ENG1 音高调制。
// 两条路径保留各自的作业协议；voice_router 管理 RAM 和帧边界提交许可。
// 参数读数据共用；两条路径按乐器互斥，不能将 ENG0 矩阵写入 ENG1 记录。
module mod_router #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 64,
    parameter int FS      = 48000,
    parameter logic [7:0] PAD_NOTE_ON_TH = 8'd102
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        start,        // 本声部更新（router 给一拍）
    input  logic [7:0]                  fmap_i,       // 本声部压力
    input  logic [15:0]                 n_modes,
    input  router_pkg::instrument_e     inst,
    output logic                        busy,
    output logic                        done,

    output logic                        p_re,
    output logic [$clog2(N_MODES)-1:0]  p_mode,
    input  logic signed [31:0]          p_a11,
    input  logic signed [31:0]          p_a12,
    input  logic signed [31:0]          p_a22,
    input  logic signed [31:0]          p_wo,
    input  logic signed [31:0]          p_s11,
    input  logic signed [31:0]          p_s12,
    input  logic signed [31:0]          p_s22,
    input  logic signed [31:0]          p_swo,

    output logic [4:0]                  co_we,
    output logic [$clog2(N_MODES)-1:0]  co_mode,
    output modal_step_pkg::coeff_t      co_wdata,

    // ENG1 后台音高调制；独立 busy/提交握手，不阻塞 ENG0 单声部作业口。
    input  logic                        pitch_clear,
    input  logic                        pressure_enable,
    input  logic [SLOTS-1:0]            pressure_gate,
    input  logic [SLOTS*8-1:0]          pressure_level,
    input  logic                        sample_tick,
    input  logic                        pitch_commit_ok,
    input  logic                        table_we,
    input  logic [9:0]                  table_addr,
    input  logic [31:0]                 table_data,
    input  logic [1:0]                  pitch_cleanup,
    input  logic [SLOTS-1:0]            pitch_slot_source,
    input  logic                        pitch_control_valid,
    input  logic                        pitch_control_cancel,
    input  logic                        pitch_control_source,
    input  logic [31:0]                 pitch_control_data,
    output logic                        pitch_control_ready,
    output logic                        pitch_control_rejected,
    output logic                        pitch_bank,
    output logic                        pitch_busy,
    output logic                        pitch_commit,
    output logic [SLOTS*24-1:0]         pitch_delta,
    output logic                        pitch_sources_ready,
    output logic                        pitch_p_re,
    output logic [$clog2(SLOTS)+$clog2(N_MODES)-1:0] pitch_p_addr,
    output logic                        pitch_co_we,
    output logic [$clog2(SLOTS)+$clog2(N_MODES)-1:0] pitch_co_addr,
    output logic signed [31:0]          pitch_a1
);
    logic en, mod_done_i, start_d1;

    // 没有揉弦的乐器：直接把 start 延一拍变成 done（避免上层死等）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_d1 <= 1'b0;
        else        start_d1 <= start && !en;
    end
    assign done = en ? mod_done_i : start_d1;

    always_comb case (inst)
        // ENG0 吉他启用一阶矩阵调制，目前只更新前四个模态。
        router_pkg::INST_GUITAR: en = !router_pkg::eng_sel(inst);
        default:                 en = 1'b0;
    endcase

    modulation0 #(.SLOTS(SLOTS), .N_MODES(N_MODES), .FS(FS),
                  .PAD_NOTE_ON_TH(PAD_NOTE_ON_TH)) u_mod0 (
        .clk(clk), .rst_n(rst_n),
        .start(start && en), .n_modes(n_modes), .fmap_i(fmap_i),
        .busy(busy), .done(mod_done_i),
        .p_re(p_re), .p_mode(p_mode),
        .p_a11(p_a11), .p_a12(p_a12), .p_a22(p_a22), .p_wo(p_wo),
        .p_s11(p_s11), .p_s12(p_s12), .p_s22(p_s22), .p_swo(p_swo),
        .co_we(co_we), .co_mode(co_mode), .co_wdata(co_wdata)
    );

    modulation1 #(.SLOTS(SLOTS),.N_MODES(N_MODES),.PAD_NOTE_ON_TH(PAD_NOTE_ON_TH)) u_pitch(
        .clk(clk),.rst_n(rst_n),.clear(pitch_clear || !router_pkg::is_sustain(inst)),
        .pressure_enable(pressure_enable),.pressure_gate(pressure_gate),.pressure_level(pressure_level),
        .table_we(table_we),.table_addr(table_addr),.table_data(table_data),
        .sample_tick(sample_tick),.commit_ok(pitch_commit_ok),.cleanup(pitch_cleanup),.n_modes(($clog2(N_MODES+1))'(n_modes)),
        .slot_source(pitch_slot_source),.control_valid(pitch_control_valid),.control_cancel(pitch_control_cancel),
        .control_source(pitch_control_source),.control_data(pitch_control_data),
        .control_ready(pitch_control_ready),.control_rejected(pitch_control_rejected),
        .active_bank(pitch_bank),.busy(pitch_busy),.commit_pulse(pitch_commit),.active_delta(pitch_delta),
        .sources_ready(pitch_sources_ready),
        .p_re(pitch_p_re),.p_addr(pitch_p_addr),.p_lower(p_a11),.p_base(p_a12),
        .p_upper(p_a22),.p_slope(p_s12),.p_tag(p_swo),
        .co_we(pitch_co_we),.co_addr(pitch_co_addr),.co_a1(pitch_a1));

endmodule
