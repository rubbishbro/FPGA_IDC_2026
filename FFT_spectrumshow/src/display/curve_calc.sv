// =============================================================================
// curve_calc.sv - Catmull-Rom interpolation for the FALL pages
//
// Converts the 128 smoothed bars (trail_store) into 768 curve columns:
//   x = 0..2      : edge, bars[0]
//   x = 6b+3..8   : six Catmull columns for bar b (b = 0..126)
//   x = 765..767  : tail, bars[127]
// The four 10-bit age heights are interpolated with fixed-point weights.
//
// The four neighbours of a bar are CONSTANT for its six columns, so they are
// fetched from trail_store one per clock instead of being copied into a
// register array.  The old version cached all 128 bars (5,120 FF) so that
// four neighbours were available in one clock, which also cost a 128:1 mux
// tree (~5k LUT).  Fetching takes four extra clocks per bar; the whole frame
// is about 1.4 k clocks = 42 us at 33.333 MHz, i.e. 0.2 % of the 21 ms
// spectrum frame, so the extra clocks are free.
//
// Timing per bar (11 clocks):
//   clock 0: address p0
//   clock 1: p0 <= data, address p1
//   clock 2: p1 <= data, address p2
//   clock 3: p2 <= data, address p3
//   clock 4: p3 <= data
//   clock 5..10: xm = 0..5, write column 6*bar + 3 + xm
//
// trail_store has a one-clock registered read.  Its write side (trail_calc)
// runs once per 21 ms spectrum frame, while this module only needs about
// 42 us, so the data cannot change underneath the computation.
//
// clk = clk_pix = 33.333 MHz, async active-low reset rst_n.
// =============================================================================
module curve_calc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,

    output logic [6:0]  scan_addr,
    input  logic [39:0] scan_data,

    output logic        wr_en,
    output logic [9:0]  wr_addr,
    output logic [39:0] wr_data,
    output logic        frame_done
);

    localparam logic [3:0] S_IDLE     = 4'd0;
    localparam logic [3:0] S_EDGE_RD  = 4'd1;
    localparam logic [3:0] S_EDGE     = 4'd2;
    localparam logic [3:0] S_RD       = 4'd3;
    localparam logic [3:0] S_GEN      = 4'd4;
    localparam logic [3:0] S_TAIL_RD  = 4'd5;
    localparam logic [3:0] S_TAIL     = 4'd6;

    logic [3:0]  state;
    logic [6:0]  bar;
    logic [2:0]  rd_step;
    logic [2:0]  xm;
    logic [39:0] p0, p1, p2, p3;
    logic [39:0] edge_data;

    // ------------------------------------------------------------------
    // trail_store address: four neighbours for the current bar
    //   p0 = bars[max(bar-1, 0)]
    //   p1 = bars[bar]
    //   p2 = bars[min(bar+1, 127)]
    //   p3 = bars[min(bar+2, 127)]
    // ------------------------------------------------------------------
    always_comb begin
        scan_addr = 7'd0;
        case (state)
            S_EDGE_RD: scan_addr = 7'd0;
            S_RD: begin
                case (rd_step)
                    3'd0: scan_addr = (bar == 7'd0) ? 7'd0 : (bar - 7'd1);
                    3'd1: scan_addr = bar;
                    3'd2: scan_addr = (bar >= 7'd127) ? 7'd127 : (bar + 7'd1);
                    default: scan_addr = (bar >= 7'd126) ? 7'd127 : (bar + 7'd2);
                endcase
            end
            S_TAIL_RD, S_TAIL: scan_addr = 7'd127;
            default: scan_addr = 7'd0;
        endcase
    end

    // ------------------------------------------------------------------
    // Catmull-Rom weights, fixed point 1/256 (unchanged from the old core)
    // ------------------------------------------------------------------
    function automatic signed [9:0] w0(input [2:0] f);
        case (f)
            3'd0: w0 = 10'sd0;
            3'd1: w0 = -10'sd15;
            3'd2: w0 = -10'sd19;
            3'd3: w0 = -10'sd16;
            3'd4: w0 = -10'sd9;
            default: w0 = -10'sd3;
        endcase
    endfunction

    function automatic signed [9:0] w1(input [2:0] f);
        case (f)
            3'd0: w1 = 10'sd256;
            3'd1: w1 = 10'sd240;
            3'd2: w1 = 10'sd199;
            3'd3: w1 = 10'sd144;
            3'd4: w1 = 10'sd85;
            default: w1 = 10'sd34;
        endcase
    endfunction

    function automatic signed [9:0] w2(input [2:0] f);
        case (f)
            3'd0: w2 = 10'sd0;
            3'd1: w2 = 10'sd34;
            3'd2: w2 = 10'sd85;
            3'd3: w2 = 10'sd144;
            3'd4: w2 = 10'sd199;
            default: w2 = 10'sd240;
        endcase
    endfunction

    function automatic signed [9:0] w3(input [2:0] f);
        case (f)
            3'd0: w3 = 10'sd0;
            3'd1: w3 = -10'sd3;
            3'd2: w3 = -10'sd9;
            3'd3: w3 = -10'sd16;
            3'd4: w3 = -10'sd19;
            default: w3 = -10'sd15;
        endcase
    endfunction

    function automatic [9:0] catmull(input [9:0] p0, p1, p2, p3, input [2:0] f);
        logic signed [23:0] s;
        begin
            s = $signed({14'b0, p0}) * w0(f) +
                $signed({14'b0, p1}) * w1(f) +
                $signed({14'b0, p2}) * w2(f) +
                $signed({14'b0, p3}) * w3(f);
            s = s >>> 8;
            if (s < 0)
                catmull = 10'd0;
            else if (s > 24'sd479)
                catmull = 10'd479;
            else
                catmull = s[9:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            bar        <= 7'd0;
            rd_step    <= 3'd0;
            xm         <= 3'd0;
            p0         <= 40'd0;
            p1         <= 40'd0;
            p2         <= 40'd0;
            p3         <= 40'd0;
            edge_data  <= 40'd0;
            wr_en      <= 1'b0;
            wr_addr    <= 10'd0;
            wr_data    <= 40'd0;
            frame_done <= 1'b0;
        end
        else begin
            wr_en      <= 1'b0;
            frame_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        bar     <= 7'd0;
                        rd_step <= 3'd0;
                        xm      <= 3'd0;
                        state   <= S_EDGE_RD;
                    end
                end

                // read bars[0] for the three edge columns
                S_EDGE_RD: begin
                    edge_data <= scan_data;
                    state     <= S_EDGE;
                end

                S_EDGE: begin
                    wr_en   <= 1'b1;
                    wr_addr <= {7'b0, xm};
                    wr_data <= edge_data;

                    if (xm == 3'd2) begin
                        xm      <= 3'd0;
                        bar     <= 7'd0;
                        rd_step <= 3'd0;
                        state   <= S_RD;
                    end
                    else begin
                        xm <= xm + 3'd1;
                    end
                end

                // four neighbour reads, one per clock
                S_RD: begin
                    case (rd_step)
                        3'd0: rd_step <= 3'd1;
                        3'd1: begin p0 <= scan_data; rd_step <= 3'd2; end
                        3'd2: begin p1 <= scan_data; rd_step <= 3'd3; end
                        3'd3: begin p2 <= scan_data; rd_step <= 3'd4; end
                        default: begin
                            p3    <= scan_data;
                            rd_step <= 3'd0;
                            xm    <= 3'd0;
                            state <= S_GEN;
                        end
                    endcase
                end

                // six Catmull columns for this bar
                S_GEN: begin
                    wr_en   <= 1'b1;
                    wr_addr <= (bar * 10'd6) + 10'd3 + {7'b0, xm};
                    wr_data <= {
                        catmull(p0[39:30], p1[39:30], p2[39:30], p3[39:30], xm),
                        catmull(p0[29:20], p1[29:20], p2[29:20], p3[29:20], xm),
                        catmull(p0[19:10], p1[19:10], p2[19:10], p3[19:10], xm),
                        catmull(p0[9:0],   p1[9:0],   p2[9:0],   p3[9:0],   xm)
                    };

                    if (xm == 3'd5) begin
                        if (bar == 7'd126) begin
                            xm    <= 3'd0;
                            state <= S_TAIL_RD;
                        end
                        else begin
                            bar     <= bar + 7'd1;
                            xm      <= 3'd0;
                            rd_step <= 3'd0;
                            state   <= S_RD;
                        end
                    end
                    else begin
                        xm <= xm + 3'd1;
                    end
                end

                // read bars[127] for the three tail columns
                S_TAIL_RD: begin
                    state <= S_TAIL;
                end

                S_TAIL: begin
                    wr_en   <= 1'b1;
                    wr_addr <= 10'd765 + {7'b0, xm};
                    wr_data <= scan_data;

                    if (xm == 3'd2) begin
                        frame_done <= 1'b1;
                        state      <= S_IDLE;
                    end
                    else begin
                        xm <= xm + 3'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
