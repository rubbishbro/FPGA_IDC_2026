module wave_capture #(
    parameter int N_POINTS = 768,
    parameter int SCAN_MAX = 255
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    output logic [9:0]  wf_addr,
    input  logic [23:0] wf_data,
    output logic        wr_en,
    output logic [9:0]  wr_addr,
    output logic [9:0]  wr_data,
    output logic        frame_done
);

    localparam logic [1:0] S_IDLE = 2'd0;
    localparam logic [1:0] S_SCAN = 2'd1;
    localparam logic [1:0] S_WAIT = 2'd2;
    localparam logic [1:0] S_CAP  = 2'd3;
    localparam logic [9:0] SCAN_LAST = SCAN_MAX;

    logic [1:0]  state;
    logic [9:0]  scan_addr;
    logic [9:0]  start_addr;
    logic [9:0]  raddr;
    logic [9:0]  cnt;
    logic [23:0] prev_sample;

    assign wf_addr = (state == S_SCAN) ? scan_addr : raddr;

    function automatic [9:0] scale_y(input [23:0] d);
        logic signed [11:0] s;
        logic signed [12:0] y;
        begin
            s = d[23:12];
            y = 13'sd240 - (s >>> 1);
            if (y < 13'sd40)
                scale_y = 10'd40;
            else if (y > 13'sd440)
                scale_y = 10'd440;
            else
                scale_y = y[9:0];
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            scan_addr   <= 10'd0;
            start_addr  <= 10'd0;
            raddr       <= 10'd0;
            cnt         <= 10'd0;
            prev_sample <= 24'd0;
            wr_en       <= 1'b0;
            wr_addr     <= 10'd0;
            wr_data     <= 10'd240;
            frame_done  <= 1'b0;
        end
        else begin
            wr_en      <= 1'b0;
            frame_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        scan_addr   <= 10'd0;
                        start_addr  <= 10'd0;
                        prev_sample <= 24'd0;
                        state       <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (scan_addr != 10'd0 &&
                        prev_sample[23] && !wf_data[23]) begin
                        start_addr <= scan_addr - 10'd2;
                        raddr      <= scan_addr - 10'd2;
                        cnt        <= 10'd0;
                        state      <= S_WAIT;
                    end
                    else if (scan_addr == SCAN_LAST) begin
                        start_addr <= 10'd0;
                        raddr      <= 10'd0;
                        cnt        <= 10'd0;
                        state      <= S_WAIT;
                    end
                    else begin
                        prev_sample <= wf_data;
                        scan_addr   <= scan_addr + 10'd1;
                    end
                end

                S_WAIT: begin
                    state <= S_CAP;
                end

                S_CAP: begin
                    wr_en   <= 1'b1;
                    wr_addr <= cnt;
                    wr_data <= scale_y(wf_data);

                    if (cnt == N_POINTS - 1) begin
                        state      <= S_IDLE;
                        frame_done <= 1'b1;
                    end
                    else begin
                        cnt   <= cnt + 10'd1;
                        raddr <= raddr + 10'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
