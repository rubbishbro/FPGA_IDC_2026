import clk_rst_pkg::*;
import pad_driver_pkg::*;

module keyboard_board_top #(
    parameter bit FIXED_CENTER4 = 1'b0,
    parameter bit FORCE_ADC_ZERO = 1'b0
)(
    input  logic       clk,
    output logic [3:0] row_s,
    output logic [2:0] mux_sel,
    output logic       led_dat
);

    localparam int CLK_EN_DIV = 20;
    localparam int FILL_LEN   = 64;
    localparam int FRAME_GAP  = 6000;
    localparam int P_THRESH   = 16;
    localparam int BRIGHT_SHIFT = 2;

    logic [19:0] por_cnt = '0;
    logic        rst_n;
    logic [4:0]  clk_div;
    logic        clk_en;
    logic [7:0]  fill_idx;
    logic [15:0] gap_cnt;
    logic        fill_active;

    clk_rst     cr;
    led_param   led_p;
    input_param input_p;

    always_ff @(posedge clk) begin
        if (!por_cnt[19])
            por_cnt <= por_cnt + 1'b1;
    end

    assign rst_n = por_cnt[19];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_div <= 5'd0;
            clk_en  <= 1'b0;
        end
        else begin
            clk_en <= 1'b0;
            if (clk_div == CLK_EN_DIV - 1) begin
                clk_div <= 5'd0;
                clk_en  <= 1'b1;
            end
            else begin
                clk_div <= clk_div + 5'd1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_idx    <= 8'd0;
            gap_cnt     <= 16'd0;
            fill_active <= 1'b1;
        end
        else if (clk_en) begin
            if (fill_active) begin
                if (fill_idx == FILL_LEN - 1) begin
                    fill_idx    <= 8'd0;
                    fill_active <= 1'b0;
                    gap_cnt     <= 16'd0;
                end
                else begin
                    fill_idx <= fill_idx + 8'd1;
                end
            end
            else if (gap_cnt == FRAME_GAP - 1) begin
                gap_cnt     <= 16'd0;
                fill_idx    <= 8'd0;
                fill_active <= 1'b1;
            end
            else begin
                gap_cnt <= gap_cnt + 16'd1;
            end
        end
    end

    wire [2:0] led_x = fill_idx[2:0];
    wire [2:0] led_y = fill_idx[5:3];
    wire       center4 = ((led_x == 3) || (led_x == 4)) &&
                         ((led_y == 3) || (led_y == 4));

    wire [3:0] cell_idx = {led_y[2:1], led_x[2:1]};
    wire [7:0] cell_raw = FORCE_ADC_ZERO ? 8'd0 : input_p.fmap.flat_d[cell_idx].val;
    wire [7:0] cell_p   = (cell_raw > P_THRESH) ? (cell_raw >> BRIGHT_SHIFT) : 8'd0;
    wire [7:0] cell_r   = cell_p;
    wire [7:0] cell_g   = cell_p;
    wire [7:0] cell_b   = cell_p;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            led_p <= '0;
        end
        else if (clk_en) begin
            led_p.x   <= led_x;
            led_p.y   <= led_y;
            led_p.pix <= FIXED_CENTER4
                       ? (center4 ? {8'h3F, 8'h3F, 8'h3F} : 24'd0)
                       : {cell_g, cell_r, cell_b};
            led_p.wr  <= fill_active;
        end
    end

    assign cr.clk    = clk;
    assign cr.clk_en = clk_en;
    assign cr.rst_n  = rst_n;

    pad_driver u_pad (
        .cr      (cr),
        .led_p   (led_p),
        .dat     (led_dat),
        .input_p (input_p)
    );

    assign row_s   = input_p.row_s;
    assign mux_sel = input_p.ch_s;

endmodule
