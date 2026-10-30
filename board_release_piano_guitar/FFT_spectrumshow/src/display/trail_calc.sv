module trail_calc #(
    parameter int N_BARS = 128,
    parameter int N_ROWS = 16,
    parameter int W      = 10
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [5:0]  base_row,

    output logic [5:0]  scan_row,
    output logic [6:0]  scan_col,
    input  logic [W-1:0] scan_data,

    output logic        wr_en,
    output logic [6:0]  wr_addr,
    output logic [39:0] wr_data,
    output logic        frame_done
);

    localparam logic [2:0] S_IDLE  = 3'd0;
    localparam logic [2:0] S_START = 3'd1;
    localparam logic [2:0] S_READ  = 3'd2;
    localparam logic [2:0] S_WAIT  = 3'd3;
    localparam logic [2:0] S_FLUSH = 3'd4;

    logic [2:0]  state;
    logic [5:0]  base_lat;
    logic [6:0]  bar;
    logic [3:0]  age;
    logic [W-1:0] recent, mid, old, current;
    logic [39:0] shift1, shift2;

    assign scan_row = base_lat - age;
    assign scan_col = bar;

    wire [39:0] new_raw = {current, scan_data, mid, recent};

    function automatic [9:0] avg3(input [9:0] a, input [9:0] b, input [9:0] c);
        logic [11:0] s;
        begin
            s = a + (b << 1) + c;
            avg3 = s[11:2];
        end
    endfunction

    function automatic [39:0] smooth3(input [39:0] a, input [39:0] b, input [39:0] c);
        begin
            smooth3 = {
                avg3(a[39:30], b[39:30], c[39:30]),
                avg3(a[29:20], b[29:20], c[29:20]),
                avg3(a[19:10], b[19:10], c[19:10]),
                avg3(a[9:0],   b[9:0],   c[9:0])
            };
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            base_lat   <= 6'd0;
            bar        <= 7'd0;
            age        <= 4'd0;
            recent     <= '0;
            mid        <= '0;
            old        <= '0;
            current    <= '0;
            shift1     <= 40'd0;
            shift2     <= 40'd0;
            wr_en      <= 1'b0;
            wr_addr    <= 7'd0;
            wr_data    <= 40'd0;
            frame_done <= 1'b0;
        end
        else begin
            wr_en      <= 1'b0;
            frame_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start)
                        state <= S_START;
                end

                S_START: begin
                    base_lat <= base_row;
                    bar      <= 7'd0;
                    age      <= 4'd0;
                    recent   <= '0;
                    mid      <= '0;
                    old      <= '0;
                    current  <= '0;
                    shift1   <= 40'd0;
                    shift2   <= 40'd0;
                    state    <= S_READ;
                end

                S_READ: begin
                    state <= S_WAIT;
                end

                S_WAIT: begin
                    if (age == N_ROWS - 1) begin
                        if (bar == 7'd0) begin
                            shift2 <= new_raw;
                            shift1 <= new_raw;
                            bar    <= 7'd1;
                            age    <= 4'd0;
                            recent <= '0;
                            mid    <= '0;
                            old    <= '0;
                            current <= '0;
                            state  <= S_READ;
                        end
                        else begin
                            wr_en   <= 1'b1;
                            wr_addr <= bar - 7'd1;
                            wr_data <= smooth3(shift2, shift1, new_raw);
                            shift2  <= shift1;
                            shift1  <= new_raw;

                            if (bar == N_BARS - 1)
                                state <= S_FLUSH;
                            else begin
                                bar    <= bar + 7'd1;
                                age    <= 4'd0;
                                recent <= '0;
                                mid    <= '0;
                                old    <= '0;
                                current <= '0;
                                state  <= S_READ;
                            end
                        end
                    end
                    else begin
                        case (age)
                            4'd0: current <= scan_data;
                            4'd3: recent  <= scan_data;
                            4'd7: mid     <= scan_data;
                            default: ;
                        endcase
                        age   <= age + 4'd1;
                        state <= S_READ;
                    end
                end

                S_FLUSH: begin
                    wr_en      <= 1'b1;
                    wr_addr    <= N_BARS - 1;
                    wr_data    <= smooth3(shift2, shift1, shift1);
                    frame_done <= 1'b1;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule