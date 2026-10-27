// sweep_source.sv -- 1 kHz -> 10 kHz linear sweep phase accumulator
//
// 48.03 kHz sample tick. The 32-bit phase accumulator is read as
// phase[31:24] by the sine ROM in ui_demo_top.
module sweep_source #(
    parameter logic [31:0] F_MIN  = 32'd89_478_485,   // 1 kHz  @ 48.03 kHz
    parameter logic [31:0] F_MAX  = 32'd894_784_853,  // 10 kHz @ 48.03 kHz
    parameter logic [31:0] F_STEP = 32'd1_678         // ~10 s 1k -> 10k
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        samp_en,
    output logic [7:0]  phase_idx,
    output logic [31:0] phase,
    output logic [31:0] freq_inc,
    output logic        sweep_done
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase      <= 32'd0;
            freq_inc   <= F_MIN;
            sweep_done <= 1'b0;
        end
        else if (samp_en) begin
            phase <= phase + freq_inc;

            if (freq_inc >= F_MAX) begin
                freq_inc   <= F_MIN;
                sweep_done <= 1'b1;
            end
            else begin
                freq_inc   <= freq_inc + F_STEP;
                sweep_done <= 1'b0;
            end
        end
        else begin
            sweep_done <= 1'b0;
        end
    end

    assign phase_idx = phase[31:24];

endmodule
