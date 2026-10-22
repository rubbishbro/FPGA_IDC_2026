// -----------------------------------------------------------------------------
// 激励生成：整张 fmap -> 整张 xmap
//   * 不需要声部号（router 按槽位分配）
//   * 采样节拍由 router 统一给（smp_tick）
//   * Q28 定标（与 modal_step_pkg::XF 一致），SHIFT 待定
// -----------------------------------------------------------------------------
module excitation_pulse_single #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SR_HZ   = 48_000,
    parameter int SLOTS   = 16,
    parameter int SHIFT   = 20,
    parameter int unsigned GATE_TH = 1
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        smp_tick,
    input  pad_driver_pkg::mat4x4       fmap,
    output logic signed [31:0]          xmap [0:15],
    output logic                        xmap_valid
);

    logic [SLOTS-1:0] prev;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev <= '0;
            for (int i = 0; i < SLOTS; i++) xmap[i] <= '0;
        end else if (smp_tick) begin
            for (int i = 0; i < SLOTS; i++) begin
                // 只在"越过阈值的那一拍"给一个脉冲（拨弦）
                if (fmap.flat_d[i].val > GATE_TH[7:0] && !prev[i])
                    xmap[i] <= signed'(32'(fmap.flat_d[i].val) <<< SHIFT);
                else
                    xmap[i] <= '0;
                prev[i] <= (fmap.flat_d[i].val > GATE_TH[7:0]);
            end
        end
    end
    assign xmap_valid = smp_tick;

endmodule


// 持续力：按住期间一直给力（用于持续激励的乐器）
module excitation_pulse_train #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SR_HZ   = 48_000,
    parameter int SLOTS   = 16,
    parameter int SHIFT   = 20,
    parameter int unsigned GATE_TH = 1
)(
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        smp_tick,
    input  pad_driver_pkg::mat4x4       fmap,
    output logic signed [31:0]          xmap [0:15],
    output logic                        xmap_valid
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < SLOTS; i++) xmap[i] <= '0;
        end else if (smp_tick) begin
            for (int i = 0; i < SLOTS; i++)
                xmap[i] <= (fmap.flat_d[i].val > GATE_TH[7:0])
                         ? signed'(32'(fmap.flat_d[i].val) <<< SHIFT) : '0;
        end
    end
    assign xmap_valid = smp_tick;

endmodule
