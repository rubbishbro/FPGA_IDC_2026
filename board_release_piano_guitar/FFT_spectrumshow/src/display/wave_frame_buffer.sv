module wave_frame_buffer #(
    parameter int N_POINTS = 768
) (
    input  logic        wr_clk,
    input  logic        wr_rst_n,
    input  logic        wr_en,
    input  logic [9:0]  wr_addr,
    input  logic [9:0]  wr_data,
    input  logic        wr_frame_done,

    input  logic        rd_clk,
    input  logic        rd_rst_n,
    input  logic [9:0]  rd_addr,
    output logic [9:0]  rd_data,
    input  logic        rd_frame_pulse
);

    logic [9:0] mem [0:2*N_POINTS-1];

    logic wr_bank;
    logic frame_toggle;
    logic rd_bank;
    logic [1:0] ft_sync;
    logic [1:0] wb_sync;
    logic ft_seen;
    logic frame_seen;
    logic [9:0] rd_data_r;

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bank      <= 1'b0;
            frame_toggle <= 1'b0;
        end
        else begin
            if (wr_en)
                mem[(wr_bank ? N_POINTS : 0) + wr_addr] <= wr_data;

            if (wr_frame_done) begin
                wr_bank      <= ~wr_bank;
                frame_toggle <= ~frame_toggle;
            end
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            ft_sync    <= 2'b00;
            wb_sync    <= 2'b00;
            ft_seen    <= 1'b0;
            frame_seen <= 1'b0;
            rd_bank    <= 1'b0;
            rd_data_r  <= 10'd240;
        end
        else begin
            ft_sync <= {ft_sync[0], frame_toggle};
            wb_sync <= {wb_sync[0], wr_bank};

            if (rd_frame_pulse && (ft_sync[1] != ft_seen)) begin
                ft_seen    <= ft_sync[1];
                frame_seen <= 1'b1;
                rd_bank    <= ~wb_sync[1];
            end

            rd_data_r <= mem[(rd_bank ? N_POINTS : 0) + rd_addr];
        end
    end

    assign rd_data = frame_seen ? rd_data_r : 10'd240;

endmodule
