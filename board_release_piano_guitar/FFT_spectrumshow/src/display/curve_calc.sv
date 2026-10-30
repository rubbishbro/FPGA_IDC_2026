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

    localparam logic [2:0] S_IDLE      = 3'd0;
    localparam logic [2:0] S_LOAD      = 3'd1;
    localparam logic [2:0] S_LOAD_WAIT = 3'd2;
    localparam logic [2:0] S_EDGE      = 3'd3;
    localparam logic [2:0] S_GEN       = 3'd4;
    localparam logic [2:0] S_TAIL      = 3'd5;

    logic [2:0]  state;
    logic [6:0]  bar;
    logic [2:0]  xm;
    logic [39:0] bars [0:127];

    assign scan_addr = bar;

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

    wire [39:0] p0 = bars[(bar == 7'd0) ? 7'd0 : (bar - 7'd1)];
    wire [39:0] p1 = bars[bar];
    wire [39:0] p2 = bars[(bar == 7'd127) ? 7'd127 : (bar + 7'd1)];
    wire [39:0] p3 = bars[(bar >= 7'd126) ? 7'd127 : (bar + 7'd2)];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            bar        <= 7'd0;
            xm         <= 3'd0;
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
                        bar   <= 7'd0;
                        xm    <= 3'd0;
                        state <= S_LOAD;
                    end
                end

                S_LOAD: begin
                    state <= S_LOAD_WAIT;
                end

                S_LOAD_WAIT: begin
                    bars[bar] <= scan_data;
                    if (bar == 7'd127) begin
                        bar   <= 7'd0;
                        xm    <= 3'd0;
                        state <= S_EDGE;
                    end
                    else begin
                        bar   <= bar + 7'd1;
                        state <= S_LOAD;
                    end
                end

                S_EDGE: begin
                    wr_en   <= 1'b1;
                    wr_addr <= {7'b0, xm};
                    wr_data <= bars[0];

                    if (xm == 3'd2) begin
                        xm    <= 3'd0;
                        bar   <= 7'd0;
                        state <= S_GEN;
                    end
                    else begin
                        xm <= xm + 3'd1;
                    end
                end

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
                            state <= S_TAIL;
                        end
                        else begin
                            bar <= bar + 7'd1;
                            xm  <= 3'd0;
                        end
                    end
                    else begin
                        xm <= xm + 3'd1;
                    end
                end

                S_TAIL: begin
                    wr_en   <= 1'b1;
                    wr_addr <= 10'd765 + {7'b0, xm};
                    wr_data <= bars[127];

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
