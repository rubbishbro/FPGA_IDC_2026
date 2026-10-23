// -----------------------------------------------------------------------------
// fltr_router.sv -- 乐器绑定的腔体滤波器系数选择（5 段 biquad）
//
// 系数不来自 flash、也不是 ROM：按乐器号直接选**常量 LUT**（综合成 LUT/寄存器）。
// 不足 5 段的乐器**末尾保持直通段**（b0=1.0，其余 0），所以默认值就是直通。
//
// 排布：coef[s*NTAP + t]，s = section 0..4，t = 0..4 依次为 b0,b1,b2,a1,a2。
// 符号约定：y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2（a1/a2 给正值）。
// 定点：Q2.30（1.0 = 1<<30）。
// -----------------------------------------------------------------------------
module fltr_router #(
    parameter int NSEC = 5,
    parameter int NTAP = 5
) (
    input  router_pkg::instrument_e       inst,
    output logic signed [31:0]            coef [0:NSEC*NTAP-1]   // Q2.30
);

    localparam logic signed [31:0] ONE = 32'sd1 <<< 30;

    always_comb begin
        // 默认：5 段全直通（段数少的乐器不用额外逻辑补齐）
        for (int s = 0; s < NSEC; s++) begin
            coef[s*NTAP + 0] = ONE;      // b0
            coef[s*NTAP + 1] = '0;       // b1
            coef[s*NTAP + 2] = '0;       // b2
            coef[s*NTAP + 3] = '0;       // a1
            coef[s*NTAP + 4] = '0;       // a2
        end

        case (inst)
            router_pkg::INST_GUITAR: begin
                // TODO: 5 段实系数（等 Python 侧给出 Q2.30 数值后填入）
                // 例：coef[0*NTAP+0] = 32'sd...;
            end
            router_pkg::INST_BASS: begin
                // 2 段实系数，第 3..5 段保持直通
            end
            router_pkg::INST_PIANO: begin
                // 3 段实系数，第 4..5 段保持直通
            end
            default: ;                    // 全直通
        endcase
    end

endmodule
