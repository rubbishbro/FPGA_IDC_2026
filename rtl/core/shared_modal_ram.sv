// =============================================================================
// 文件 : shared_modal_ram.sv
// 模块 : shared_modal_ram
// 功能 : 9×32 共享模态 RAM
// 说明 : 深度 320；4 lane 读写；装载字段与计算写回字段分开选择。
// =============================================================================
`timescale 1ns/1ps

module shared_modal_ram #(
    parameter int SLOTS       = 16,
    parameter int MODES       = 48,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter int FLD_W       = 32,
    parameter int LOCAL       = (MODES + LANES - 1) / LANES,
    parameter int VW          = (SLOTS < 2) ? 1 : $clog2(SLOTS),
    parameter int MW          = (MODES < 2) ? 1 : $clog2(MODES),
    parameter int AW          = (SLOTS * LOCAL < 2) ? 1 : $clog2(SLOTS * LOCAL)
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // 3 = A/B/C (y1/y2), 7 = E2 (q/qdot)
    input  logic [3:0]                   cfg_first,
    input  logic [3:0]                   st_first,

    input  logic                         cfg_we,
    input  logic [VW-1:0]                cfg_voice,
    input  logic [MW-1:0]                cfg_mode,
    input  logic [REC_W-1:0]             cfg_data,

    input  logic [LANES-1:0]             st_we,
    input  logic [LANES*AW-1:0]          st_addr,
    input  logic [LANES*64-1:0]          st_data,

    input  logic [LANES-1:0]             rd_re,
    input  logic [LANES*AW-1:0]          rd_addr,
    output logic [LANES*REC_W-1:0]       rd_data,

    input  logic                         clr_we,
    input  logic [VW-1:0]                clr_voice,
    input  logic [MW-1:0]                clr_mode,

    input  logic                         seed_we,
    input  logic [VW-1:0]                seed_voice,
    input  logic [MW-1:0]                seed_mode,
    input  logic [63:0]                  seed_data,

    input  logic                         aux_re,
    input  logic [VW-1:0]                aux_voice,
    input  logic [MW-1:0]                aux_mode,
    output logic [REC_W-1:0]             aux_data,
    output logic                         aux_valid,

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
    wire [MW-1:0] cfg_local = cfg_mode / LANES;
    wire [MW-1:0] clr_local = clr_mode / LANES;
    wire [MW-1:0] seed_local= seed_mode / LANES;

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
            (* syn_ramstyle = "block_ram" *) logic [31:0] f0 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f1 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f2 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f3 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f4 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f5 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f6 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f7 [0:DEPTH-1];
            (* syn_ramstyle = "block_ram" *) logic [31:0] f8 [0:DEPTH-1];

            logic [REC_W-1:0] rd_q;
            logic [REC_W-1:0] aux_q;

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    rd_q  <= {REC_W{1'b0}};
                    aux_q <= {REC_W{1'b0}};
                end else begin
                    if (rd_re[g]) begin
                        rd_q[0*32 +: 32] <= f0[rd_addr[g*AW +: AW]];
                        rd_q[1*32 +: 32] <= f1[rd_addr[g*AW +: AW]];
                        rd_q[2*32 +: 32] <= f2[rd_addr[g*AW +: AW]];
                        rd_q[3*32 +: 32] <= f3[rd_addr[g*AW +: AW]];
                        rd_q[4*32 +: 32] <= f4[rd_addr[g*AW +: AW]];
                        rd_q[5*32 +: 32] <= f5[rd_addr[g*AW +: AW]];
                        rd_q[6*32 +: 32] <= f6[rd_addr[g*AW +: AW]];
                        rd_q[7*32 +: 32] <= f7[rd_addr[g*AW +: AW]];
                        rd_q[8*32 +: 32] <= f8[rd_addr[g*AW +: AW]];
                    end
                    if (aux_re && (aux_lane == g) &&
                        (aux_voice < SLOTS) && (aux_mode < MODES)) begin
                        aux_q[0*32 +: 32] <= f0[aux_idx];
                        aux_q[1*32 +: 32] <= f1[aux_idx];
                        aux_q[2*32 +: 32] <= f2[aux_idx];
                        aux_q[3*32 +: 32] <= f3[aux_idx];
                        aux_q[4*32 +: 32] <= f4[aux_idx];
                        aux_q[5*32 +: 32] <= f5[aux_idx];
                        aux_q[6*32 +: 32] <= f6[aux_idx];
                        aux_q[7*32 +: 32] <= f7[aux_idx];
                        aux_q[8*32 +: 32] <= f8[aux_idx];
                    end
                end
            end

            assign rd_data[g*REC_W +: REC_W] = rd_q;
            assign aux_q_flat[g*REC_W +: REC_W] = aux_q;

            always_ff @(posedge clk) begin
                if (cfg_we && (cfg_lane == g) &&
                    (cfg_voice < SLOTS) && (cfg_mode < MODES)) begin
                    f0[cfg_idx] <= cfg_data[0*32 +: 32];
                    f1[cfg_idx] <= cfg_data[1*32 +: 32];
                    f2[cfg_idx] <= cfg_data[2*32 +: 32];
                    f3[cfg_idx] <= cfg_data[3*32 +: 32];
                    f4[cfg_idx] <= cfg_data[4*32 +: 32];
                    f5[cfg_idx] <= cfg_data[5*32 +: 32];
                    f6[cfg_idx] <= cfg_data[6*32 +: 32];
                    f7[cfg_idx] <= cfg_data[7*32 +: 32];
                    f8[cfg_idx] <= cfg_data[8*32 +: 32];
                end else if (co_we && (co_lane == g) &&
                             (co_voice < SLOTS) && (co_mode < MODES)) begin
                    case (co_field)
                        4'd0: f0[co_idx] <= co_wdata;
                        4'd1: f1[co_idx] <= co_wdata;
                        4'd2: f2[co_idx] <= co_wdata;
                        4'd3: f3[co_idx] <= co_wdata;
                        4'd4: f4[co_idx] <= co_wdata;
                        4'd5: f5[co_idx] <= co_wdata;
                        4'd6: f6[co_idx] <= co_wdata;
                        4'd7: f7[co_idx] <= co_wdata;
                        4'd8: f8[co_idx] <= co_wdata;
                        default: ;
                    endcase
                end else if (seed_we && (seed_lane == g) &&
                             (seed_voice < SLOTS) && (seed_mode < MODES)) begin
                    if (cfg_first == 4'd3) begin
                        f3[seed_idx] <= seed_data[31:0];
                        f4[seed_idx] <= seed_data[63:32];
                    end else begin
                        f7[seed_idx] <= seed_data[31:0];
                        f8[seed_idx] <= seed_data[63:32];
                    end
                end else if (clr_we && (clr_lane == g) &&
                             (clr_voice < SLOTS) && (clr_mode < MODES)) begin
                    if (cfg_first == 4'd3) begin
                        f3[clr_idx] <= 32'd0;
                        f4[clr_idx] <= 32'd0;
                    end else begin
                        f7[clr_idx] <= 32'd0;
                        f8[clr_idx] <= 32'd0;
                    end
                end else if (st_we[g]) begin
                    if (st_first == 4'd3) begin
                        f3[st_addr[g*AW +: AW]] <= st_data[g*64 +: 32];
                        f4[st_addr[g*AW +: AW]] <= st_data[g*64+32 +: 32];
                    end else begin
                        f7[st_addr[g*AW +: AW]] <= st_data[g*64 +: 32];
                        f8[st_addr[g*AW +: AW]] <= st_data[g*64+32 +: 32];
                    end
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
