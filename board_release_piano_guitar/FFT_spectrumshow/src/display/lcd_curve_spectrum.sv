module lcd_curve_spectrum (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        lcd_valid,
    input  logic [9:0]  pix_x,
    input  logic [9:0]  pix_y,
    input  logic [39:0] curve_data,
    input  logic        theme,

    output logic [9:0]  curve_rd_addr,
    output logic        hit,
    output logic [5:0]  r,
    output logic [5:0]  g,
    output logic [5:0]  b
);

    assign curve_rd_addr = pix_x;

    reg [9:0]  pxx, pxy;
    reg [39:0] curve_d;
    reg [9:0]  prev_cur_h, prev_rec_h, prev_mid_h, prev_old_h;
    reg        pline_cur_t, pline_cur_b, pline_rec, pline_mid, pline_old;
    reg        pline_rec_b, pline_mid_b, pline_old_b;
    reg [9:0]  pline_y;
    wire [9:0] cur_h    = curve_d[39:30];
    wire [9:0] old_h    = curve_d[29:20];
    wire [9:0] mid_h    = curve_d[19:10];
    wire [9:0] recent_h = curve_d[9:0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pxx     <= 10'd0;
            pxy     <= 10'd0;
            curve_d <= 40'd0;
            prev_cur_h <= 10'd0;
            prev_rec_h <= 10'd0;
            prev_mid_h <= 10'd0;
            prev_old_h <= 10'd0;
        end
        else begin
            pxx     <= pix_x;
            pxy     <= pix_y;
            curve_d <= curve_data;
            prev_cur_h <= cur_h;
            prev_rec_h <= recent_h;
            prev_mid_h <= mid_h;
            prev_old_h <= old_h;
        end
    end

    wire [9:0] y_cur    = 10'd479 - cur_h;
    wire [9:0] y_recent = 10'd479 - recent_h;
    wire [9:0] y_mid    = 10'd479 - mid_h;
    wire [9:0] y_old    = 10'd479 - old_h;

    wire in_x = (pxx < 10'd768);

    localparam logic [9:0] MID_Y = 10'd240;

    wire [9:0] cur_top  = MID_Y - (cur_h >> 1);
    wire [9:0] cur_bot  = MID_Y + (cur_h >> 1);
    wire [9:0] rec_bot  = MID_Y + (recent_h >> 1);
    wire [9:0] mid_bot  = MID_Y + (mid_h >> 1);
    wire [9:0] old_bot  = MID_Y + (old_h >> 1);
    wire [9:0] rec_top  = MID_Y - (recent_h >> 1);
    wire [9:0] mid_top  = MID_Y - (mid_h >> 1);
    wire [9:0] old_top  = MID_Y - (old_h >> 1);

    wire [9:0] cur_top_prev  = MID_Y - (prev_cur_h >> 1);
    wire [9:0] cur_bot_prev  = MID_Y + (prev_cur_h >> 1);
    wire [9:0] rec_bot_prev  = MID_Y + (prev_rec_h >> 1);
    wire [9:0] mid_bot_prev  = MID_Y + (prev_mid_h >> 1);
    wire [9:0] old_bot_prev  = MID_Y + (prev_old_h >> 1);
    wire [9:0] rec_top_prev  = MID_Y - (prev_rec_h >> 1);
    wire [9:0] mid_top_prev  = MID_Y - (prev_mid_h >> 1);
    wire [9:0] old_top_prev  = MID_Y - (prev_old_h >> 1);

    wire [9:0] cur_top_hi = (cur_top < cur_top_prev) ? cur_top : cur_top_prev;
    wire [9:0] cur_top_lo = (cur_top < cur_top_prev) ? cur_top_prev : cur_top;
    wire [9:0] cur_bot_hi = (cur_bot < cur_bot_prev) ? cur_bot : cur_bot_prev;
    wire [9:0] cur_bot_lo = (cur_bot < cur_bot_prev) ? cur_bot_prev : cur_bot;
    wire [9:0] rec_hi = (rec_top < rec_top_prev) ? rec_top : rec_top_prev;
    wire [9:0] mid_hi = (mid_top < mid_top_prev) ? mid_top : mid_top_prev;
    wire [9:0] old_hi = (old_top < old_top_prev) ? old_top : old_top_prev;
    wire [9:0] rec_bot_hi = (rec_bot < rec_bot_prev) ? rec_bot : rec_bot_prev;
    wire [9:0] rec_bot_lo = (rec_bot < rec_bot_prev) ? rec_bot_prev : rec_bot;
    wire [9:0] mid_bot_hi = (mid_bot < mid_bot_prev) ? mid_bot : mid_bot_prev;
    wire [9:0] mid_bot_lo = (mid_bot < mid_bot_prev) ? mid_bot_prev : mid_bot;
    wire [9:0] old_bot_hi = (old_bot < old_bot_prev) ? old_bot : old_bot_prev;
    wire [9:0] old_bot_lo = (old_bot < old_bot_prev) ? old_bot_prev : old_bot;

    wire [9:0] cur_top_hi_2 = (cur_top_hi > 10'd1) ? (cur_top_hi - 10'd1) : 10'd0;
    wire [9:0] cur_top_lo_2 = (cur_top_lo < 10'd478) ? (cur_top_lo + 10'd1) : 10'd479;
    wire [9:0] cur_bot_hi_2 = (cur_bot_hi > 10'd1) ? (cur_bot_hi - 10'd1) : 10'd0;
    wire [9:0] cur_bot_lo_2 = (cur_bot_lo < 10'd478) ? (cur_bot_lo + 10'd1) : 10'd479;
    wire [9:0] rec_hi_2 = (rec_hi > 10'd1) ? (rec_hi - 10'd1) : 10'd0;
    wire [9:0] rec_top_2 = (rec_top < 10'd478) ? (rec_top + 10'd1) : 10'd479;
    wire [9:0] mid_hi_2 = (mid_hi > 10'd1) ? (mid_hi - 10'd1) : 10'd0;
    wire [9:0] mid_top_2 = (mid_top < 10'd478) ? (mid_top + 10'd1) : 10'd479;
    wire [9:0] old_hi_2 = (old_hi > 10'd1) ? (old_hi - 10'd1) : 10'd0;
    wire [9:0] old_top_2 = (old_top < 10'd478) ? (old_top + 10'd1) : 10'd479;

    wire line_cur_top = in_x && (pxy >= cur_top_hi_2) && (pxy <= cur_top_lo_2);
    wire line_cur_bot = in_x && (pxy >= cur_bot_hi_2) && (pxy <= cur_bot_lo_2);
    wire [9:0] rec_bot_hi_2 = (rec_bot_hi > 10'd1) ? (rec_bot_hi - 10'd1) : 10'd0;
    wire [9:0] rec_bot_lo_2 = (rec_bot_lo < 10'd478) ? (rec_bot_lo + 10'd1) : 10'd479;
    wire [9:0] mid_bot_hi_2 = (mid_bot_hi > 10'd1) ? (mid_bot_hi - 10'd1) : 10'd0;
    wire [9:0] mid_bot_lo_2 = (mid_bot_lo < 10'd478) ? (mid_bot_lo + 10'd1) : 10'd479;
    wire [9:0] old_bot_hi_2 = (old_bot_hi > 10'd1) ? (old_bot_hi - 10'd1) : 10'd0;
    wire [9:0] old_bot_lo_2 = (old_bot_lo < 10'd478) ? (old_bot_lo + 10'd1) : 10'd479;
    wire line_rec_bot = in_x && (pxy >= rec_bot_hi_2) && (pxy <= rec_bot_lo_2);
    wire line_mid_bot = in_x && (pxy >= mid_bot_hi_2) && (pxy <= mid_bot_lo_2);
    wire line_old_bot = in_x && (pxy >= old_bot_hi_2) && (pxy <= old_bot_lo_2);
    wire line_rec = in_x && (pxy >= rec_hi_2) && (pxy <= rec_top_2);
    wire line_mid = in_x && (pxy >= mid_hi_2) && (pxy <= mid_top_2);
    wire line_old = in_x && (pxy >= old_hi_2) && (pxy <= old_top_2);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pline_cur_t <= 1'b0;
            pline_cur_b <= 1'b0;
            pline_rec <= 1'b0;
            pline_mid <= 1'b0;
            pline_old <= 1'b0;
            pline_rec_b <= 1'b0;
            pline_mid_b <= 1'b0;
            pline_old_b <= 1'b0;
            pline_y <= 10'd0;
        end
        else begin
            pline_cur_t <= line_cur_top;
            pline_cur_b <= line_cur_bot;
            pline_rec <= line_rec;
            pline_mid <= line_mid;
            pline_old <= line_old;
            pline_rec_b <= line_rec_bot;
            pline_mid_b <= line_mid_bot;
            pline_old_b <= line_old_bot;
            pline_y <= pxy;
        end
    end

    wire same_row = (pxy == pline_y);
    wire eline_cur_top = line_cur_top | (pline_cur_t & same_row);
    wire eline_cur_bot = line_cur_bot | (pline_cur_b & same_row);
    wire eline_rec = line_rec | (pline_rec & same_row);
    wire eline_mid = line_mid | (pline_mid & same_row);
    wire eline_old = line_old | (pline_old & same_row);
    wire eline_rec_b = line_rec_bot | (pline_rec_b & same_row);
    wire eline_mid_b = line_mid_bot | (pline_mid_b & same_row);
    wire eline_old_b = line_old_bot | (pline_old_b & same_row);

    wire fill_cur_top = in_x && (pxy >= cur_top_hi) && (pxy <= MID_Y);
    wire fill_cur_bot = in_x && (pxy >= MID_Y) && (pxy <= cur_bot_lo);
    wire fill_rec = in_x && (pxy >= rec_hi) && (pxy < cur_top_hi);
    wire fill_mid = in_x && (pxy >= mid_hi) && (pxy < rec_hi);
    wire fill_old = in_x && (pxy >= old_hi) && (pxy < mid_hi);
    wire center_line = in_x && (pxy == MID_Y);

    assign hit = lcd_valid && (fill_cur_top || fill_cur_bot ||
                               eline_cur_top || eline_cur_bot ||
                               eline_rec || eline_mid || eline_old ||
                               eline_rec_b || eline_mid_b || eline_old_b || center_line);

    wire [5:0] cur_r = theme ? 6'h3F : 6'h3F;
    wire [5:0] cur_g = theme ? 6'h3F : 6'h3F;
    wire [5:0] cur_b = theme ? 6'h3F : 6'h00;
    wire [5:0] rec_r = theme ? 6'h30 : 6'h00;
    wire [5:0] rec_g = theme ? 6'h30 : 6'h3F;
    wire [5:0] rec_b = theme ? 6'h30 : 6'h3F;
    wire [5:0] mid_r = theme ? 6'h18 : 6'h3F;
    wire [5:0] mid_g = theme ? 6'h18 : 6'h00;
    wire [5:0] mid_b = theme ? 6'h18 : 6'h3F;
    wire [5:0] old_r = theme ? 6'h08 : 6'h00;
    wire [5:0] old_g = theme ? 6'h08 : 6'h10;
    wire [5:0] old_b = theme ? 6'h08 : 6'h3F;

    assign r = eline_cur_top ? cur_r :
               eline_cur_bot ? {1'b0, cur_r[5:1]} :
               eline_rec ? rec_r :
               eline_mid ? mid_r :
               eline_old ? old_r :
               eline_rec_b ? {1'b0, rec_r[5:1]} :
               eline_mid_b ? {1'b0, mid_r[5:1]} :
               eline_old_b ? {1'b0, old_r[5:1]} :
               center_line ? 6'h02 :
               fill_cur_top ? {1'b0, cur_r[5:3]} :
               fill_cur_bot ? {2'b0, cur_r[5:4]} :
               fill_rec ? {1'b0, rec_r[5:2]} :
               fill_mid ? {1'b0, mid_r[5:2]} : {1'b0, old_r[5:2]};

    assign g = eline_cur_top ? cur_g :
               eline_cur_bot ? {1'b0, cur_g[5:1]} :
               eline_rec ? rec_g :
               eline_mid ? mid_g :
               eline_old ? old_g :
               eline_rec_b ? {1'b0, rec_g[5:1]} :
               eline_mid_b ? {1'b0, mid_g[5:1]} :
               eline_old_b ? {1'b0, old_g[5:1]} :
               center_line ? 6'h08 :
               fill_cur_top ? {1'b0, cur_g[5:3]} :
               fill_cur_bot ? {2'b0, cur_g[5:4]} :
               fill_rec ? {1'b0, rec_g[5:2]} :
               fill_mid ? {1'b0, mid_g[5:2]} : {1'b0, old_g[5:2]};

    assign b = eline_cur_top ? cur_b :
               eline_cur_bot ? {1'b0, cur_b[5:1]} :
               eline_rec ? rec_b :
               eline_mid ? mid_b :
               eline_old ? old_b :
               eline_rec_b ? {1'b0, rec_b[5:1]} :
               eline_mid_b ? {1'b0, mid_b[5:1]} :
               eline_old_b ? {1'b0, old_b[5:1]} :
               center_line ? 6'h10 :
               fill_cur_top ? {1'b0, cur_b[5:3]} :
               fill_cur_bot ? {2'b0, cur_b[5:4]} :
               fill_rec ? {1'b0, rec_b[5:2]} :
               fill_mid ? {1'b0, mid_b[5:2]} : {1'b0, old_b[5:2]};
endmodule
