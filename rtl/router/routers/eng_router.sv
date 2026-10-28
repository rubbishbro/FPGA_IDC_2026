// -----------------------------------------------------------------------------
// eng_router -- 双引擎薄封装：按乐器在 eng0 / eng1 之间二选一
//
//   * 两个引擎**互斥**：同一个作业只有选中的那个在跑，没选中的 start 不响应。
//   * 端口只有一套：系数读、状态读写、激励读、结果流。
//   * 上层想并行跑两个引擎，就实例化两个 eng_router（各自接自己的存储 bank），
//     两个实例的 inst 接同一个乐器号 -> 用的是同一种引擎，时序也完全一致。
// -----------------------------------------------------------------------------
module eng_router #(
    parameter int N_MODES = 64
)(
    input  logic                                     clk,
    input  logic                                     rst_n,
    input  router_pkg::instrument_e                  inst,
    // ---- 作业口 ----
    input  logic                                     start,
    input  logic                                     st_zero,      // 1 = 本作业先把状态清零（note-on）
    input  logic [$clog2(N_MODES+1)-1:0]             n_modes,

    // ---- 系数读口（同步读：地址这拍给，数据下一拍有效）----
    output logic                                     co_re,
    output logic [$clog2(N_MODES)-1:0]               co_addr,
    input  modal_step_pkg::coeff_t                   co_data,

    // ---- 状态读口 ----
    output logic                                     st_re,
    output logic [$clog2(N_MODES)-1:0]               st_addr,
    input  logic signed [modal_step_pkg::QW-1:0]     st_q,
    input  logic signed [modal_step_pkg::VW-1:0]     st_qdot,

    // ---- 状态写回口（计算侧；已饱和）----
    output logic                                     st_we,
    output logic [$clog2(N_MODES)-1:0]               st_waddr,
    output logic signed [modal_step_pkg::QW-1:0]     st_q_wdata,
    output logic signed [modal_step_pkg::VW-1:0]     st_qdot_wdata,

    // ---- 激励读口 ----
    output logic                                     x_re,
    input  logic signed [modal_step_pkg::XW-1:0]     x_data,

    // ---- 结果流口 ----
    output logic                                     y_valid,
    output logic signed [modal_step_pkg::YW-1:0]     y_data
);

    import modal_step_pkg::*;
    import router_pkg::*;

    localparam int IW = $clog2(N_MODES);

    // =========================================================================
    // 两套引擎（互斥）+ 口 mux
    // =========================================================================
    logic                 e0_start, e0_zero, e0_yv;
    logic [IW-1:0]        e0_co_addr;
    logic                 e0_co_re, e0_st_re, e0_st_we;
    logic [IW-1:0]        e0_st_addr, e0_st_waddr;
    logic                 e0_x_re;
    logic signed [63:0]   e0_y;

    logic                 e1_start, e1_zero, e1_yv;
    logic [IW-1:0]        e1_co_addr;
    logic                 e1_co_re, e1_st_re, e1_st_we;
    logic [IW-1:0]        e1_st_addr, e1_st_waddr;
    logic                 e1_x_re;
    logic signed [63:0]   e1_y;

    logic                 sel_alt;
    // 两个引擎各写一份，再按乐器号 mux —— 不能直接把两个实例的输出接到同一个端口
    logic signed [modal_step_pkg::QW-1:0] e0_qwd, e1_qwd;
    logic signed [modal_step_pkg::VW-1:0] e0_vwd, e1_vwd;

    assign st_q_wdata    = sel_alt ? e1_qwd : e0_qwd;
    assign st_qdot_wdata = sel_alt ? e1_vwd : e0_vwd;
    assign sel_alt = eng_sel(inst);

    assign e0_start = start    && !sel_alt;
    assign e1_start = start    &&  sel_alt;
    assign e0_zero  = st_zero  && !sel_alt;
    assign e1_zero  = st_zero  &&  sel_alt;

    assign co_re    = sel_alt ? e1_co_re    : e0_co_re;
    assign co_addr  = sel_alt ? e1_co_addr  : e0_co_addr;
    assign st_re    = sel_alt ? e1_st_re    : e0_st_re;
    assign st_addr  = sel_alt ? e1_st_addr  : e0_st_addr;
    assign st_we    = sel_alt ? e1_st_we    : e0_st_we;
    assign st_waddr = sel_alt ? e1_st_waddr : e0_st_waddr;
    assign x_re     = sel_alt ? e1_x_re     : e0_x_re;
    assign y_valid  = sel_alt ? e1_yv       : e0_yv;
    assign y_data   = sel_alt ? e1_y        : e0_y;

    eng0 #(.N_MODES(N_MODES)) u_eng0 (
        .clk(clk), .rst_n(rst_n),
        .start(e0_start), .st_zero(e0_zero), .n_modes(n_modes),
        .y_valid(e0_yv), .y_data(e0_y),
        .co_re(e0_co_re), .co_addr(e0_co_addr), .co_data(co_data),
        .st_re(e0_st_re), .st_addr(e0_st_addr),
        .st_q(st_q), .st_qdot(st_qdot),
        .st_we(e0_st_we), .st_waddr(e0_st_waddr),
        .st_q_wdata(e0_qwd), .st_qdot_wdata(e0_vwd),
        .x_re(e0_x_re), .x_data(x_data)
    );

    eng1 #(.N_MODES(N_MODES)) u_eng1 (
        .clk(clk), .rst_n(rst_n),
        .start(e1_start), .st_zero(e1_zero), .n_modes(n_modes),
        .y_valid(e1_yv), .y_data(e1_y),
        .co_re(e1_co_re), .co_addr(e1_co_addr), .co_data(co_data),
        .st_re(e1_st_re), .st_addr(e1_st_addr),
        .st_q(st_q), .st_qdot(st_qdot),
        .st_we(e1_st_we), .st_waddr(e1_st_waddr),
        .st_q_wdata(e1_qwd), .st_qdot_wdata(e1_vwd),
        .x_re(e1_x_re), .x_data(x_data)
    );

endmodule
