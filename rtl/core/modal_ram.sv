// -----------------------------------------------------------------------------
// modal_ram.sv -- 9×32 记录的内存中心 RAM 层（ENG1/ENG2 共用物理格式）
//
// 每个 mode 一条 288-bit 记录，按 lane 分成 LANES 个 1R1W bank：
//   rd_re/rd_addr/rd_data   同步读（1 拍）
//   st_we/st_addr/st_data   只写状态字段（core 写回）
//   cfg_we/cfg_voice/mode   写整条记录（router 装载）
//   seed_we/...             只写状态字段（C 的初值）
//   clr_we/...              只写状态字段为 0（clear，不清系数）
//   aux_re/aux_data         控制路径只读口（a1 刷新等）
//   co_we/co_field/co_wdata 单字段写口（B 的 a1 刷新）
//
// 记录语义由上层决定：
//   ENG1: G/a1/a2/y1/y2，状态字段 3/4
//   ENG2: a11..wo/q/qdot，状态字段 7/8
// 本模块只按 STATE_FIRST 写两个状态字段，不理解系数含义。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_ram #(
    parameter int SLOTS       = 16,
    parameter int MODES       = 48,
    parameter int LANES       = 4,
    parameter int STATE_FIRST = 3,       // 两个状态字段的起始索引
    parameter int REC_W       = 288,     // 9 * 32
    parameter int FLD_W       = 32,
    parameter int LOCAL       = (MODES + LANES - 1) / LANES,
    parameter int VW          = (SLOTS < 2) ? 1 : $clog2(SLOTS),
    parameter int MW          = (MODES < 2) ? 1 : $clog2(MODES),
    parameter int AW          = (SLOTS * LOCAL < 2) ? 1 : $clog2(SLOTS * LOCAL)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // ---- router 装载：整条记录 ----
    input  logic                         cfg_we,
    input  logic [VW-1:0]                cfg_voice,
    input  logic [MW-1:0]                cfg_mode,
    input  logic [REC_W-1:0]             cfg_data,

    // ---- core 状态写回：每 lane 一个口 ----
    input  logic [LANES-1:0]             st_we,
    input  logic [LANES*AW-1:0]          st_addr,
    input  logic [LANES*64-1:0]          st_data,     // {second, first}

    // ---- core 读：每 lane 一个口，同步读 ----
    input  logic [LANES-1:0]             rd_re,
    input  logic [LANES*AW-1:0]          rd_addr,
    output logic [LANES*REC_W-1:0]       rd_data,

    // ---- clear：只把状态字段写 0，系数保留 ----
    input  logic                         clr_we,
    input  logic [VW-1:0]                clr_voice,
    input  logic [MW-1:0]                clr_mode,

    // ---- seed：只把状态字段写初值 ----
    input  logic                         seed_we,
    input  logic [VW-1:0]                seed_voice,
    input  logic [MW-1:0]                seed_mode,
    input  logic [63:0]                  seed_data,   // {second, first}

    // ---- aux 读口：a1 刷新等控制路径用 ----
    input  logic                         aux_re,
    input  logic [VW-1:0]                aux_voice,
    input  logic [MW-1:0]                aux_mode,
    output logic [REC_W-1:0]             aux_data,
    output logic                         aux_valid,

    // ---- 单字段写口：B 的 a1 刷新 ----
    input  logic                         co_we,
    input  logic [VW-1:0]                co_voice,
    input  logic [MW-1:0]                co_mode,
    input  logic [3:0]                   co_field,
    input  logic [31:0]                  co_wdata
);

    localparam int DEPTH = SLOTS * LOCAL;

    wire [MW-1:0] cfg_lane  = cfg_mode % LANES;
    wire [MW-1:0] clr_lane  = clr_mode % LANES;
    wire [MW-1:0] seed_lane = seed_mode % LANES;

    wire [MW-1:0] cfg_local  = cfg_mode / LANES;
    wire [MW-1:0] clr_local  = clr_mode / LANES;
    wire [MW-1:0] seed_local = seed_mode / LANES;

    wire [AW-1:0] cfg_idx  = cfg_voice * LOCAL + cfg_local;
    wire [AW-1:0] clr_idx  = clr_voice * LOCAL + clr_local;
    wire [AW-1:0] seed_idx = seed_voice * LOCAL + seed_local;

    wire [MW-1:0] aux_lane  = aux_mode % LANES;
    wire [MW-1:0] aux_local = aux_mode / LANES;
    wire [AW-1:0] aux_idx   = aux_voice * LOCAL + aux_local;
    wire [MW-1:0] co_lane   = co_mode % LANES;
    wire [MW-1:0] co_local  = co_mode / LANES;
    wire [AW-1:0] co_idx    = co_voice * LOCAL + co_local;

    logic [LANES*REC_W-1:0] aux_q_flat;
    logic [MW-1:0]          aux_lane_r;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_lane
            logic [REC_W-1:0] mem [0:DEPTH-1];
            logic [REC_W-1:0] rd_q;
            logic [REC_W-1:0] aux_q;

            always_ff @(posedge clk) begin
                if (!rst_n)
                    rd_q <= {REC_W{1'b0}};
                else if (rd_re[g])
                    rd_q <= mem[rd_addr[g*AW +: AW]];

                if (aux_re && (aux_lane == g) &&
                    (aux_voice < SLOTS) && (aux_mode < MODES))
                    aux_q <= mem[aux_idx];
            end

            assign rd_data[g*REC_W +: REC_W] = rd_q;
            assign aux_q_flat[g*REC_W +: REC_W] = aux_q;

            always_ff @(posedge clk) begin
                if (cfg_we && (cfg_lane == g) && (cfg_voice < SLOTS) && (cfg_mode < MODES)) begin
                    mem[cfg_idx] <= cfg_data;
                end else if (co_we && (co_lane == g) &&
                             (co_voice < SLOTS) && (co_mode < MODES)) begin
                    mem[co_idx][co_field*FLD_W +: FLD_W] <= co_wdata;
                end else if (seed_we && (seed_lane == g) &&
                             (seed_voice < SLOTS) && (seed_mode < MODES)) begin
                    mem[seed_idx][STATE_FIRST*FLD_W +: FLD_W]     <= seed_data[31:0];
                    mem[seed_idx][(STATE_FIRST+1)*FLD_W +: FLD_W] <= seed_data[63:32];
                end else if (clr_we && (clr_lane == g) &&
                             (clr_voice < SLOTS) && (clr_mode < MODES)) begin
                    mem[clr_idx][STATE_FIRST*FLD_W +: FLD_W]     <= {FLD_W{1'b0}};
                    mem[clr_idx][(STATE_FIRST+1)*FLD_W +: FLD_W] <= {FLD_W{1'b0}};
                end else if (st_we[g]) begin
                    mem[st_addr[g*AW +: AW]][STATE_FIRST*FLD_W +: FLD_W]     <= st_data[g*64 +: 32];
                    mem[st_addr[g*AW +: AW]][(STATE_FIRST+1)*FLD_W +: FLD_W] <= st_data[g*64+32 +: 32];
                end
            end
        end
    endgenerate

    assign aux_data = aux_q_flat[aux_lane_r*REC_W +: REC_W];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            aux_lane_r <= {MW{1'b0}};
            aux_valid  <= 1'b0;
        end else begin
            if (aux_re) aux_lane_r <= aux_lane;
            aux_valid <= aux_re;
        end
    end

endmodule
