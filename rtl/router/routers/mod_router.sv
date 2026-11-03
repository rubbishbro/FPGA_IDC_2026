// mod_router -- 共用调制子路由：ENG0 矩阵调制 / ENG1 音高调制。
// 两条路径共用逐声部 start/busy/done；voice_router 管理 RAM 与安全更新窗口。
// 参数读数据共用；两条路径按乐器互斥，不能将 ENG0 矩阵写入 ENG1 记录。
module mod_router #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 64,
    parameter int FS      = 48000,
    parameter int MOD1_MODES_PER_JOB = 6, // TODO: 听感还需要验证
    parameter bit SPLIT_RESET=0,
    parameter logic [7:0] PAD_NOTE_ON_TH = 8'd102
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input logic rst_mod0_n=1'b1,rst_pitch_n=1'b1,
    input  logic                        start,        // 本声部更新（router 给一拍）
    input logic [$clog2(SLOTS)-1:0] job_slot,
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

    // ENG1 逐声部音高调制；仅所选引擎响应共享作业口。
    input  logic                        pitch_clear,
    input  logic                        pressure_enable,
    input  logic [SLOTS-1:0]            pressure_gate,
    input  logic [SLOTS*8-1:0]          pressure_level,
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
    output logic                        pitch_commit,
    output logic [SLOTS*24-1:0]         pitch_delta,
    output logic                        pitch_sources_ready
);
    logic en, mod_done_i, start_d1, mod0_busy, mod1_busy, mod1_done;
    localparam int IW=$clog2(N_MODES),AW=$clog2(SLOTS)+IW;
    logic mod0_p_re,mod1_p_re,mod1_co_we;
    logic [IW-1:0] mod0_p_mode,mod0_co_mode;
    logic [AW-1:0] mod1_p_addr,mod1_co_addr;
    logic [4:0] mod0_co_we;
    modal_step_pkg::coeff_t mod0_co_wdata;
    logic signed [31:0] mod1_a1;
    wire en1=router_pkg::uses_mod1(inst);

    // 没有揉弦的乐器：直接把 start 延一拍变成 done（避免上层死等）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_d1 <= 1'b0;
        else        start_d1 <= start && !en;
    end
    assign done = en1 ? mod1_done : (en ? mod_done_i : start_d1);
    assign busy = en1 ? mod1_busy : (en ? mod0_busy : 1'b0);

    // Both kernels retain their own arithmetic and cycle counts. Only the
    // selected instrument owns the shared parameter/coefficient channels.
    // voice_router holds job_slot from start until done (including cancellation).
    always_comb begin
        p_re=1'b0;p_mode='0;co_we='0;co_mode='0;co_wdata='0;
        if(en1)begin
            p_re=mod1_p_re;p_mode=mod1_p_addr[IW-1:0];
            co_we=mod1_co_we ? 5'b00010 : 5'b00000;
            co_mode=mod1_co_addr[IW-1:0];co_wdata.a12=mod1_a1;
        end else if(en)begin
            p_re=mod0_p_re;p_mode=mod0_p_mode;
            co_we=mod0_co_we;co_mode=mod0_co_mode;co_wdata=mod0_co_wdata;
        end
    end

    always_comb case (inst)
        // ENG0 吉他启用一阶矩阵调制，目前只更新前四个模态。
        router_pkg::INST_GUITAR: en = !router_pkg::eng_sel(inst);
        default:                 en = 1'b0;
    endcase

    modulation0 #(.SLOTS(SLOTS), .N_MODES(N_MODES), .FS(FS),
                  .PAD_NOTE_ON_TH(PAD_NOTE_ON_TH)) u_mod0 (
        .clk(clk), .rst_n(SPLIT_RESET ? rst_mod0_n : rst_n),
        .start(start && en), .n_modes(n_modes), .fmap_i(fmap_i),
        .busy(mod0_busy), .done(mod_done_i),
        .p_re(mod0_p_re), .p_mode(mod0_p_mode),
        .p_a11(p_a11), .p_a12(p_a12), .p_a22(p_a22), .p_wo(p_wo),
        .p_s11(p_s11), .p_s12(p_s12), .p_s22(p_s22), .p_swo(p_swo),
        .co_we(mod0_co_we), .co_mode(mod0_co_mode), .co_wdata(mod0_co_wdata)
    );

    modulation1 #(.SLOTS(SLOTS),.N_MODES(N_MODES),.MODES_PER_JOB(MOD1_MODES_PER_JOB),.PAD_NOTE_ON_TH(PAD_NOTE_ON_TH)) u_pitch(
        .clk(clk),.rst_n(SPLIT_RESET ? rst_pitch_n : rst_n),.clear(pitch_clear || !router_pkg::uses_mod1(inst)),
        .pressure_enable(pressure_enable),.pressure_gate(pressure_gate),.pressure_level(pressure_level),
        .table_we(table_we),.table_addr(table_addr),.table_data(table_data),
        .start(start && en1),.job_slot(job_slot),.done(mod1_done),.cleanup(pitch_cleanup),.n_modes(($clog2(N_MODES+1))'(n_modes)),
        .slot_source(pitch_slot_source),.control_valid(pitch_control_valid),.control_cancel(pitch_control_cancel),
        .control_source(pitch_control_source),.control_data(pitch_control_data),
        .control_ready(pitch_control_ready),.control_rejected(pitch_control_rejected),
        .active_bank(pitch_bank),.busy(mod1_busy),.commit_pulse(pitch_commit),.active_delta(pitch_delta),
        .sources_ready(pitch_sources_ready),
        .p_re(mod1_p_re),.p_addr(mod1_p_addr),.p_lower(p_a11),.p_base(p_a12),
        .p_upper(p_a22),.p_slope(p_s12),.p_tag(p_swo),
        .co_we(mod1_co_we),.co_addr(mod1_co_addr),.co_a1(mod1_a1));

endmodule
