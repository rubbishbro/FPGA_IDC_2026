module lcd_wave (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        lcd_valid,
    input  logic [9:0]  pix_x,
    input  logic [9:0]  pix_y,
    input  logic        theme,
    input  logic [9:0]  wave_rd_data,

    output logic [9:0]  wave_rd_addr,
    output logic        wave_hit,
    output logic [5:0]  wave_r,
    output logic [5:0]  wave_g,
    output logic [5:0]  wave_b
);

    reg [9:0] pxx1, pxx2;
    reg [9:0] pxy1, pxy2;
    reg [9:0] y_curr, y_prev;

    assign wave_rd_addr = (pix_x < 10'd768) ? pix_x : 10'd0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pxx1   <= 10'd0;
            pxx2   <= 10'd0;
            pxy1   <= 10'd0;
            pxy2   <= 10'd0;
            y_curr <= 10'd240;
            y_prev <= 10'd240;
        end
        else begin
            pxx1   <= pix_x;
            pxx2   <= pxx1;
            pxy1   <= pix_y;
            pxy2   <= pxy1;
            y_curr <= wave_rd_data;
            y_prev <= y_curr;
        end
    end

    wire [9:0] y_lo = (y_curr < y_prev) ? y_curr : y_prev;
    wire [9:0] y_hi = (y_curr < y_prev) ? y_prev : y_curr;
    wire in_wave_x = (pxx2 < 10'd768);
    wire in_line   = (pxy2 >= y_lo) && (pxy2 <= y_hi);

    assign wave_hit = lcd_valid && in_wave_x && in_line;

    always_comb begin
        wave_r = 6'h00;
        wave_g = 6'h00;
        wave_b = 6'h00;

        if (in_line) begin
            if (theme) begin
                wave_r = 6'h3F;
                wave_g = 6'h3F;
                wave_b = 6'h3F;
            end
            else begin
                wave_r = 6'h08;
                wave_g = 6'h38;
                wave_b = 6'h28;
            end
        end
    end

endmodule
