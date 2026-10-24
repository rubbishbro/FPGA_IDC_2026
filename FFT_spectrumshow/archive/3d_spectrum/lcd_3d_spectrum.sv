module lcd_3d_spectrum (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        lcd_valid,
    input  logic [9:0]  pix_x,
    input  logic [9:0]  pix_y,
    input  logic [5:0]  wf_base_row,
    input  logic [9:0]  wf_rd_data,
    input  logic        theme,

    output logic [5:0]  wf_rd_row,
    output logic [6:0]  wf_rd_col,
    output logic        hit,
    output logic [5:0]  r,
    output logic [5:0]  g,
    output logic [5:0]  b
);

    reg [7:0] bar_lut [0:16383];
    initial $readmemh("bar3d.mem", bar_lut);

    wire [3:0] depth = pix_y[8:5];

    reg [9:0] pxx1, pxy1, pxx2, pxy2;
    reg [3:0] depth1, depth2;
    reg [7:0] bar1, bar2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pxx1   <= 10'd0;
            pxy1   <= 10'd0;
            pxx2   <= 10'd0;
            pxy2   <= 10'd0;
            depth1 <= 4'd0;
            depth2 <= 4'd0;
            bar1   <= 8'd0;
            bar2   <= 8'd0;
        end
        else begin
            bar1   <= bar_lut[{depth, pix_x}];
            depth1 <= depth;
            pxx1   <= pix_x;
            pxy1   <= pix_y;
            pxx2   <= pxx1;
            pxy2   <= pxy1;
            depth2 <= depth1;
            bar2   <= bar1;
        end
    end

    assign wf_rd_row = wf_base_row - (4'd15 - depth1);
    assign wf_rd_col = bar1[6:0];

    wire [9:0] base_y   = {1'b0, depth2, 5'b11111};
    wire [9:0] band_top = base_y - 10'd31;
    wire [4:0] h_raw    = wf_rd_data[9:5];
    wire [9:0] h_prod   = h_raw * ({1'b0, depth2} + 5'd8);
    wire [4:0] h_scaled = (h_prod[9:4] > 5'd28) ? 5'd28 : h_prod[8:4];
    wire [9:0] raw_top  = base_y - {5'b0, h_scaled};
    wire [9:0] bar_top  = (raw_top < band_top) ? band_top : raw_top;

    wire bar_hit = lcd_valid && bar2[7] && (pxx2 < 10'd800) &&
                   (pxy2 <= base_y) && (pxy2 >= bar_top);
    wire floor_hit = lcd_valid && (pxy2 == base_y) && (pxx2 < 10'd800);
    assign hit = bar_hit || floor_hit;

    logic [5:0] col_r, col_g, col_b;
    always_comb begin
        if (theme) begin
            col_r = wf_rd_data[9:4];
            col_g = wf_rd_data[9:4];
            col_b = wf_rd_data[9:4];
        end
        else if (wf_rd_data < 10'd80) begin
            col_r = 6'h00; col_g = 6'h00; col_b = 6'h12;
        end
        else if (wf_rd_data < 10'd160) begin
            col_r = 6'h00; col_g = 6'h08; col_b = 6'h30;
        end
        else if (wf_rd_data < 10'd240) begin
            col_r = 6'h00; col_g = 6'h20; col_b = 6'h30;
        end
        else if (wf_rd_data < 10'd320) begin
            col_r = 6'h00; col_g = 6'h38; col_b = 6'h18;
        end
        else if (wf_rd_data < 10'd400) begin
            col_r = 6'h30; col_g = 6'h30; col_b = 6'h00;
        end
        else begin
            col_r = 6'h3F; col_g = 6'h10; col_b = 6'h00;
        end
    end

    wire [1:0] dim_sel = depth2[3:2];
    wire [5:0] dim_r = (dim_sel == 2'd0) ? (col_r >> 2) :
                       (dim_sel == 2'd1) ? (col_r >> 1) : col_r;
    wire [5:0] dim_g = (dim_sel == 2'd0) ? (col_g >> 2) :
                       (dim_sel == 2'd1) ? (col_g >> 1) : col_g;
    wire [5:0] dim_b = (dim_sel == 2'd0) ? (col_b >> 2) :
                       (dim_sel == 2'd1) ? (col_b >> 1) : col_b;

    wire top_hit = bar_hit && (pxy2 <= (bar_top + 10'd1));
    wire [5:0] floor_r = (depth2 < 4'd8) ? 6'h01 : 6'h03;

    assign r = (floor_hit && !bar_hit) ? floor_r : (top_hit ? 6'h3F : dim_r);
    assign g = (floor_hit && !bar_hit) ? floor_r : (top_hit ? 6'h3F : dim_g);
    assign b = (floor_hit && !bar_hit) ? 6'h10 : (top_hit ? 6'h3F : dim_b);

endmodule
