// mod_router -- 调制子路由：只有需要揉弦的乐器才启用 modulation0
module mod_router #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 48
)(
    input  logic                             clk,
    input  logic                             rst_n,
    input  logic                             start,
    input  logic [SLOTS-1:0]                 active,
    input  logic signed [31:0]               alpha_q,
    input  logic [15:0]                      n_modes,
    input  router_pkg::instrument_e          inst,
    output logic                             busy,
    output logic                             done,
    output logic                             co_re,
    output logic                             co_we,
    output logic [$clog2(SLOTS*N_MODES)-1:0] co_addr,
    input  modal_step_pkg::coeff_t           co_data,
    output modal_step_pkg::coeff_t           co_wdata,
    output logic                             p_re,
    output logic [$clog2(SLOTS*N_MODES)-1:0] p_addr,
    input  logic signed [31:0]               p_c0,
    input  logic signed [31:0]               p_s0,
    input  logic signed [31:0]               p_gam,
    input  logic signed [31:0]               p_theta0,
    input  logic signed [31:0]               p_g
);
    logic en;

    always_comb case (inst)
        router_pkg::INST_GUITAR, router_pkg::INST_BASS: en = 1'b1;
        default:                                        en = 1'b0;
    endcase

    modulation0 #(.SLOTS(SLOTS), .N_MODES(N_MODES)) u_mod0 (
        .clk(clk), .rst_n(rst_n), .start(start && en),
        .active(active), .alpha_q(alpha_q), .n_modes(n_modes),
        .busy(busy), .done(done),
        .p_re(p_re), .p_addr(p_addr),
        .p_c0(p_c0), .p_s0(p_s0), .p_gam(p_gam), .p_theta0(p_theta0), .p_g(p_g),
        .co_re(co_re), .co_we(co_we), .co_addr(co_addr),
        .co_data(co_data), .co_wdata(co_wdata));
endmodule
