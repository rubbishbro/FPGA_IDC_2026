module lcd_trail_spectrum (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        lcd_valid,
    input  logic [9:0]  pix_x,
    input  logic [9:0]  pix_y,
    input  logic [9:0]  q_y,
    input  logic [29:0] trail_data,
    input  logic        theme,

    output logic        hit,
    output logic [5:0]  r,
    output logic [5:0]  g,
    output logic [5:0]  b
);

    reg [9:0]  pxx, pxy;
    reg [9:0]  q_y_d;
    reg [29:0] trail_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pxx     <= 10'd0;
            pxy     <= 10'd0;
            q_y_d   <= 10'd0;
            trail_d <= 30'd0;
        end
        else begin
            pxx     <= pix_x;
            pxy     <= pix_y;
            q_y_d   <= q_y;
            trail_d <= trail_data;
        end
    end

    wire [9:0] cur_h    = q_y_d;
    wire [9:0] recent_h = trail_d[9:0];
    wire [9:0] mid_h    = trail_d[19:10];
    wire [9:0] old_h    = trail_d[29:20];

    wire [9:0] y_cur    = 10'd479 - cur_h;
    wire [9:0] y_recent = 10'd479 - recent_h;
    wire [9:0] y_mid    = 10'd479 - mid_h;
    wire [9:0] y_old    = 10'd479 - old_h;

    wire in_x = (pxx < 10'd768);
    wire in_cur = (pxy >= y_cur);
    wire in_recent = (pxy >= y_recent);
    wire in_mid = (pxy >= y_mid);
    wire in_old = (pxy >= y_old);

    assign hit = lcd_valid && in_x && in_old;

    logic [5:0] col_r, col_g, col_b;
    always_comb begin
        if (theme) begin
            col_r = cur_h[9:4];
            col_g = cur_h[9:4];
            col_b = cur_h[9:4];
        end
        else if (cur_h < 10'd80) begin
            col_r = 6'h00; col_g = 6'h00; col_b = 6'h14;
        end
        else if (cur_h < 10'd160) begin
            col_r = 6'h00; col_g = 6'h08; col_b = 6'h30;
        end
        else if (cur_h < 10'd240) begin
            col_r = 6'h00; col_g = 6'h20; col_b = 6'h30;
        end
        else if (cur_h < 10'd320) begin
            col_r = 6'h00; col_g = 6'h38; col_b = 6'h18;
        end
        else if (cur_h < 10'd400) begin
            col_r = 6'h30; col_g = 6'h30; col_b = 6'h00;
        end
        else begin
            col_r = 6'h3F; col_g = 6'h10; col_b = 6'h00;
        end
    end

    wire [5:0] old_r = (col_r >> 3);
    wire [5:0] old_g = (col_g >> 3);
    wire [5:0] old_b = (col_b >> 3);
    wire [5:0] mid_r = (col_r >> 2);
    wire [5:0] mid_g = (col_g >> 2);
    wire [5:0] mid_b = (col_b >> 2);
    wire [5:0] recent_r = (col_r >> 1);
    wire [5:0] recent_g = (col_g >> 1);
    wire [5:0] recent_b = (col_b >> 1);

    wire top_hit = hit && ((pxy == y_cur) || (pxy == (y_cur + 10'd1)));

    assign r = top_hit    ? 6'h3F :
               in_cur     ? col_r :
               in_recent  ? recent_r :
               in_mid     ? mid_r : old_r;
    assign g = top_hit    ? 6'h3F :
               in_cur     ? col_g :
               in_recent  ? recent_g :
               in_mid     ? mid_g : old_g;
    assign b = top_hit    ? 6'h3F :
               in_cur     ? col_b :
               in_recent  ? recent_b :
               in_mid     ? mid_b : old_b;

endmodule
