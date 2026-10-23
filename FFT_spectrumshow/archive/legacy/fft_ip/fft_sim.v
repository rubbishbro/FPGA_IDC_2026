// fft_sim.v - Behavioural "FFT-like" engine (replaces encrypted FFT IP for bring-up)
// 2026-09-29
//  Does NOT compute a real FFT. Instead it mimics the IP's I/O behaviour so the
//  rest of the chain (spectrum_map -> freq_pingpong -> display) can be verified:
//    - start -> captures 1024 xn_re samples (like the real IP)
//    - bins are computed as per-2-sample running |x| sum (rough energy spectrum)
//    - then streams out 512 bins with soud/idx/xk_re (natural order)
//  Ports match FFT_Top so it drops in with no other changes.
module fft_sim (
    output [9:0]  idx,
    output [15:0] xk_re,
    output [15:0] xk_im,
    output        sod,
    output        ipd,
    output        eod,
    output        busy,
    output        soud,
    output        opd,
    output        eoud,
    input  [15:0] xn_re,
    input  [15:0] xn_im,
    input         start,
    input         clk,
    input         rst
);

    localparam S_IDLE   = 2'd0;
    localparam S_LOAD   = 2'd1;
    localparam S_OUTPUT = 2'd2;

    reg [1:0]  state;
    reg [9:0]  cnt;        // load counter 0..1023
    reg [9:0]  o_cnt;      // output counter 0..511
    reg        busy_r, eod_r, soud_r, eoud_r;
    reg [15:0] idx_r, xk_re_r, xk_im_r;

    // bin accumulator: 512 bins, each sums |xn| of 2 consecutive samples
    reg [15:0] acc [0:511];
    integer ai;

    // absolute value of xn
    wire [15:0] xabs = xn_re[15] ? (~xn_re + 16'd1) : xn_re;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            cnt <= 10'd0; o_cnt <= 10'd0;
            busy_r <= 1'b0; eod_r <= 1'b0; soud_r <= 1'b0; eoud_r <= 1'b0;
            idx_r <= 10'd0; xk_re_r <= 16'd0; xk_im_r <= 16'd0;
            for (ai = 0; ai < 512; ai = ai + 1) acc[ai] <= 16'd0;
        end
        else begin
            eod_r <= 1'b0; soud_r <= 1'b0; eoud_r <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_LOAD;
                        busy_r <= 1'b1;
                        cnt <= 10'd0;
                        for (ai = 0; ai < 512; ai = ai + 1) acc[ai] <= 16'd0;
                    end
                end

                S_LOAD: begin
                    // accumulate |xn| every clock (samples arrive 1/clock)
                    // bin = cnt>>1; simple running sum per bin
                    acc[cnt[9:1]] <= acc[cnt[9:1]] + xabs;
                    if (cnt == 10'd1023) begin
                        eod_r <= 1'b1;          // input done
                        state <= S_OUTPUT;
                        o_cnt <= 10'd0;
                    end
                    cnt <= cnt + 1'b1;
                end

                S_OUTPUT: begin
                    // stream 512 bins, one per clock
                    if (o_cnt < 10'd512) begin
                        soud_r <= 1'b1;
                        idx_r   <= o_cnt;
                        xk_re_r <= acc[o_cnt];       // registered read
                        xk_im_r <= 16'd0;
                        if (o_cnt == 10'd511) begin
                            eoud_r <= 1'b1;
                            busy_r <= 1'b0;
                            state  <= S_IDLE;
                        end
                        o_cnt <= o_cnt + 1'b1;
                    end
                end
            endcase
        end
    end

    assign idx    = idx_r;
    assign xk_re  = xk_re_r;
    assign xk_im  = xk_im_r;
    assign sod    = 1'b0;
    assign ipd    = 1'b0;
    assign eod    = eod_r;
    assign busy   = busy_r;
    assign soud   = soud_r;
    assign opd    = 1'b0;
    assign eoud   = eoud_r;

endmodule