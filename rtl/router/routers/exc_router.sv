// exc_router -- 激励子路由：同一模块不同参数 = 不同乐器
module exc_router #(
    parameter int CLK_HZ = 100_000_000,
    parameter int SR_HZ  = 48_000,
    parameter int SLOTS  = 16
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    smp_tick,
    input  pad_driver_pkg::mat4x4   fmap,
    input  logic [SLOTS-1:0]        note_on,
    input  logic [SLOTS-1:0]        note_gate,
    input  router_pkg::instrument_e inst,
    output logic signed [31:0]      xmap [0:15],
    output logic                    xmap_valid
);
    logic [5:0] shift;
    logic [7:0] gate_th;
    logic       use_train;

    // 常量表：加乐器 = 加一行
    always_comb begin
        shift     = 6'd20;
        gate_th   = 8'd1;
        use_train = 1'b0;
        case (inst)
            router_pkg::INST_GUITAR: begin shift = 6'd18; gate_th = 8'd2; end
            router_pkg::INST_PAD:    use_train = 1'b1;
            router_pkg::INST_BASS:   use_train = 1'b1;
            default: ;
        endcase
    end

    logic signed [31:0] m_s [0:15], m_t [0:15];
    logic               v_s, v_t;

    excitation_pulse_single #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_single (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .SHIFT(shift), .GATE_TH(gate_th),
        .note_on(note_on), .note_gate(note_gate),
        .xmap(m_s), .xmap_valid(v_s)
    );
    excitation_pulse_train #(.CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_train (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap),
        .SHIFT(shift), .GATE_TH(gate_th),
        .note_on(note_on), .note_gate(note_gate),
        .xmap(m_t), .xmap_valid(v_t)
    );

    always_comb begin
        xmap_valid = use_train ? v_t : v_s;
        for (int i = 0; i < 16; i++) xmap[i] = use_train ? m_t[i] : m_s[i];
    end
endmodule
