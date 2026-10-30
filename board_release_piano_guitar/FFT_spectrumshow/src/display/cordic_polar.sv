// cordic_polar.sv - pipelined vectoring CORDIC for the polar FALL page
//
// Vectoring mode: (x_in, y_in) -> (r_out, ang_out).  One pixel per clock.
//
// ang_out is in binary-angle units (2*pi = 65536), so a sector index is just
// the top bits of ang_out - no atan2 table, no divide, no multiplier in the
// stages.  Each stage's shift is a compile-time constant, so it is wiring,
// not a barrel shifter.
//
// Latency: N+1 clocks (stage 0 pre-rotation + N stages).
// r_out = K * sqrt(x^2+y^2) * 2^FRAC, K = 1.6467602581 (CORDIC gain).
// The caller folds K into its radius thresholds.
//
// Area (N = 14, W = 20, GW5AST-138): about 750 FF and 830 LUT/ALU, no BSRAM
// and no DSP.  One register stage per iteration keeps every stage short.
`timescale 1ns/1ps

module cordic_polar #(
    parameter int N    = 14,   // CORDIC stages
    parameter int IN_W = 11,   // signed input width
    parameter int FRAC = 7,    // fractional bits added at the input
    parameter int W    = 20    // datapath width
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic signed [IN_W-1:0]  x_in,
    input  logic signed [IN_W-1:0]  y_in,
    input  logic                    in_valid,
    output logic [W-1:0]            r_out,
    output logic [15:0]             ang_out,
    output logic                    out_valid
);

    localparam logic [15:0] PI_BAM = 16'd32768;

    // atan(2^-i) in BAM units
    function automatic [15:0] atan_bam(input integer i);
        case (i)
            0:  atan_bam = 16'd8192;
            1:  atan_bam = 16'd4836;
            2:  atan_bam = 16'd2556;
            3:  atan_bam = 16'd1297;
            4:  atan_bam = 16'd651;
            5:  atan_bam = 16'd326;
            6:  atan_bam = 16'd163;
            7:  atan_bam = 16'd82;
            8:  atan_bam = 16'd41;
            9:  atan_bam = 16'd20;
            10: atan_bam = 16'd10;
            11: atan_bam = 16'd5;
            12: atan_bam = 16'd3;
            13: atan_bam = 16'd1;
            default: atan_bam = 16'd0;
        endcase
    endfunction

    logic signed [W-1:0] px [0:N];
    logic signed [W-1:0] py [0:N];
    logic        [15:0]  pa [0:N];
    logic                pv [0:N];

    wire signed [W-1:0] x_ext = {{(W-IN_W){x_in[IN_W-1]}}, x_in};
    wire signed [W-1:0] y_ext = {{(W-IN_W){y_in[IN_W-1]}}, y_in};
    wire signed [W-1:0] x_fx  = x_ext <<< FRAC;
    wire signed [W-1:0] y_fx  = y_ext <<< FRAC;

    // stage 0: move into the right half plane so vectoring converges
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px[0] <= '0;
            py[0] <= '0;
            pa[0] <= '0;
            pv[0] <= 1'b0;
        end
        else begin
            pv[0] <= in_valid;
            if (x_in < 0) begin
                px[0] <= -x_fx;
                py[0] <= -y_fx;
                pa[0] <= PI_BAM;
            end
            else begin
                px[0] <= x_fx;
                py[0] <= y_fx;
                pa[0] <= 16'd0;
            end
        end
    end

    generate
        for (genvar gi = 0; gi < N; gi = gi + 1) begin : g_stage
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    px[gi+1] <= '0;
                    py[gi+1] <= '0;
                    pa[gi+1] <= '0;
                    pv[gi+1] <= 1'b0;
                end
                else begin
                    pv[gi+1] <= pv[gi];
                    if (py[gi] < 0) begin
                        px[gi+1] <= px[gi] - (py[gi] >>> gi);
                        py[gi+1] <= py[gi] + (px[gi] >>> gi);
                        pa[gi+1] <= pa[gi] - atan_bam(gi);
                    end
                    else begin
                        px[gi+1] <= px[gi] + (py[gi] >>> gi);
                        py[gi+1] <= py[gi] - (px[gi] >>> gi);
                        pa[gi+1] <= pa[gi] + atan_bam(gi);
                    end
                end
            end
        end
    endgenerate

    assign r_out     = px[N];
    assign ang_out   = pa[N];
    assign out_valid = pv[N];

endmodule
