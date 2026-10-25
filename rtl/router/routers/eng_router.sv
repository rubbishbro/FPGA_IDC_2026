//双引擎分配薄封装
module eng_router #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 64,
    parameter int FS      = 48000
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
    output logic [$clog2(X_DEPTH)-1:0]               x_addr,
    input  logic signed [modal_step_pkg::XW-1:0]     x_data,

    // ---- 结果流口 ----
    output logic                                     y_valid,
    output logic signed [modal_step_pkg::YW-1:0]     y_data
);

// =========================================================================
// 两套引擎（互斥）+ 口 mux
// =========================================================================
// 引擎 0
logic                 e0_start, e0_zero, e0_yv;
logic [IW-1:0]        e0_co_addr;
logic                 e0_co_re, e0_st_re, e0_st_we;
logic [IW-1:0]        e0_st_addr, e0_st_waddr;
logic [0:0]           e0_x_addr;
logic                 e0_x_re;
logic signed [63:0]   e0_y;

// 引擎 1
logic                 e1_start, e1_zero, e1_yv;
logic [IW-1:0]        e1_co_addr;
logic                 e1_co_re, e1_st_re, e1_st_we;
logic [IW-1:0]        e1_st_addr, e1_st_waddr;
logic [0:0]           e1_x_addr;
logic                 e1_x_re;
logic signed [63:0]   e1_y;

// 存储读出的寄存器（声明必须在引擎实例之前）
// 选中的引擎（作业开始/装载时锁存，运行中不变）
logic                 sel_alt;
assign sel_alt = eng_sel(inst);

assign e0_start = start && !sel_alt;
assign e1_start = start &&  sel_alt;
assign e0_zero  = st_zero  && !sel_alt;
assign e1_zero  = st_zero  &&  sel_alt;

assign co_re        = sel_alt ? e1_co_re   : e0_co_re;
assign co_addr      = sel_alt ? e1_co_addr : e0_co_addr;
assign st_re        = sel_alt ? e1_st_re   : e0_st_re;
assign st_addr      = sel_alt ? e1_st_addr : e0_st_addr;
assign st_we        = sel_alt ? e1_st_we   : e0_st_we;
assign st_waddr     = sel_alt ? e1_st_waddr: e0_st_waddr;
assign x_re         = sel_alt ? e1_x_re    : e0_x_re;
assign x_addr       = sel_alt ? e1_x_addr  : e0_x_addr;
assign y_valid      = sel_alt ? e1_yv      : e0_yv;
assign y_data       = sel_alt ? e1_y       : e0_y;

eng0 #(.N_MODES(N_MODES)) u_eng0 (
    .clk(clk), .rst_n(rst_n),
    .start(e0_start), .st_zero(e0_zero), .n_modes(n_modes),
    .y_valid(e0_yv), .y_data(e0_y),
    .co_re(e0_co_re), .co_addr(e0_co_addr), .co_data(co_data),
    .st_re(e0_st_re), .st_addr(e0_st_addr),
    .st_q(st_q), .st_qdot(st_qdot),
    .st_we(e0_st_we), .st_waddr(e0_st_waddr),
    .st_q_wdata(st_q_wdata), .st_qdot_wdata(st_qdot_wdata),
    .x_re(e0_x_re), .x_addr(e0_x_addr), .x_data(x_data)
);

eng1 #(.N_MODES(N_MODES)) u_eng1 (
    .clk(clk), .rst_n(rst_n),
    .start(e1_start), .st_zero(e1_zero), .n_modes(n_modes),
    .y_valid(e1_yv), .y_data(e1_y),
    .co_re(e1_co_re), .co_addr(e1_co_addr), .co_data(co_data),
    .st_re(e1_st_re), .st_addr(e1_st_addr),
    .st_q(st_q), .st_qdot(st_qdot),
    .st_we(e1_st_we), .st_waddr(e1_st_waddr),
    .st_q_wdata(st_q_wdata), .st_qdot_wdata(st_qdot_wdata),
    .x_re(e1_x_re), .x_addr(e1_x_addr), .x_data(x_data)
);

endmodule