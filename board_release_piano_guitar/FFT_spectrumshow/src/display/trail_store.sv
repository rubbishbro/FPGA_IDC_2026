module trail_store #(
    parameter int N_BARS = 128
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        wr_en,
    input  logic [6:0]  wr_addr,
    input  logic [39:0] wr_data,
    input  logic [6:0]  rd_addr,
    output logic [39:0] rd_data
);

    logic [39:0] mem [0:N_BARS-1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_data <= 40'd0;
        end
        else begin
            if (wr_en)
                mem[wr_addr] <= wr_data;
            rd_data <= mem[rd_addr];
        end
    end

endmodule
