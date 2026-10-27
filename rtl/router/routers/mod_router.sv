// mod_router -- 调制子路由：只有需要揉弦的乐器才启用 modulation0
module mod_router #(
    parameter int SLOTS   = 16,
    parameter int N_MODES = 64,
    parameter int FS      = 48000
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
    output modal_step_pkg::coeff_t      co_wdata
);
    logic en, mod_done_i, start_d1;

    // 没有揉弦的乐器：直接把 start 延一拍变成 done（避免上层死等）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) start_d1 <= 1'b0;
        else        start_d1 <= start && !en;
    end
    assign done = en ? mod_done_i : start_d1;

    always_comb case (inst)
        // TODO: 揉弦的一阶线性版本还在调（会写出 >1 的 a11 导致自激），
        // 先关掉出一版"无调制"的吉他音色；修好再打开。
        router_pkg::INST_GUITAR: en = 1'b0;
        default:                 en = 1'b0;
    endcase

    modulation0 #(.SLOTS(SLOTS), .N_MODES(N_MODES), .FS(FS)) u_mod0 (
        .clk(clk), .rst_n(rst_n),
        .start(start && en), .n_modes(n_modes), .fmap_i(fmap_i),
        .busy(busy), .done(mod_done_i),
        .p_re(p_re), .p_mode(p_mode),
        .p_a11(p_a11), .p_a12(p_a12), .p_a22(p_a22), .p_wo(p_wo),
        .p_s11(p_s11), .p_s12(p_s12), .p_s22(p_s22), .p_swo(p_swo),
        .co_we(co_we), .co_mode(co_mode), .co_wdata(co_wdata)
    );
endmodule
