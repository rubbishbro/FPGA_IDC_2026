module top(
    input           rst_n,
    input           key0,
    input           clk,

    output          lcd_clk,
    output          lcd_en,
    output  [5:0]   lcd_r,
    output  [5:0]   lcd_b,
    output  [5:0]   lcd_g
);

    wire            pix_clk;
    wire            lcd_en_w;
    wire            frame_pulse;
    wire    [9:0]   pix_x;
    wire    [9:0]   pix_y;

    wire            key_pulse;
    reg     [1:0]   page_sel;
    wire    [9:0]   q_y;
    wire    [9:0]   q_ov;
    wire    [5:0]   lcd_r_w, lcd_g_w, lcd_b_w;

    Gowin_PLL Gowin_PLL_inst(
        .clkout0(pix_clk),  //33.33M
        .clkin(clk)         //50M
    );

    assign lcd_clk = pix_clk;

    lcd_timing lcd_timing_inst(
        .lcd_clk      ( pix_clk      ),
        .rst_n        ( rst_n        ),
        .lcd_en       ( lcd_en_w     ),
        .frame_pulse  ( frame_pulse  ),
        .pix_x        ( pix_x        ),
        .pix_y        ( pix_y        )
    );

    assign lcd_en = lcd_en_w;

    // key debounce -> page select
    key_debounce key_debounce_inst(
        .clk        ( pix_clk    ),
        .rst_n      ( rst_n      ),
        .key_in     ( key0       ),
        .key_pulse  ( key_pulse  )
    );

    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n)
            page_sel <= 2'b00;
        else if (key_pulse)
            page_sel <= page_sel + 1'b1;
    end

    // data source: real audio -> FFT -> spectrum (board bring-up)
    // 48kHz sample strobe from pix_clk (33.33M/48k ~ 694)
    reg [15:0] div48k;
    reg        samp_en;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin div48k <= 16'd0; samp_en <= 1'b0; end
        else begin
            samp_en <= 1'b0;
            if (div48k >= 16'd693) begin div48k <= 16'd0; samp_en <= 1'b1; end
            else div48k <= div48k + 16'd1;
        end
    end

    wire [9:0] bar_raw_disp = pix_x / 10'd6;
    // index only 0..127; right edge (>127) forced to 0 output via rd_valid
    wire [6:0] bar_idx_disp = (bar_raw_disp > 7'd127) ? 7'd0 : bar_raw_disp[6:0];
    wire        rd_valid     = (bar_raw_disp <= 7'd127);

    real_audio_chain real_audio_chain_inst(
        .clk         ( pix_clk       ),
        .rst_n       ( rst_n         ),
        .samp_en     ( samp_en       ),
        .rd_bar_idx  ( bar_idx_disp  ),
        .rd_valid    ( rd_valid      ),
        .rd_q_y      ( q_y           ),
        .rd_q_ov     ( q_ov          )
    );

    lcd_draw lcd_draw_inst(
        .clk          ( pix_clk      ),
        .rst_n        ( rst_n        ),
        .frame_pulse  ( frame_pulse  ),
        .lcd_valid    ( lcd_en_w     ),
        .pix_x        ( pix_x        ),
        .pix_y        ( pix_y        ),
        .page_sel     ( page_sel     ),
        .q_y          ( q_y          ),
        .q_ov         ( q_ov         ),
        .lcd_r        ( lcd_r_w      ),
        .lcd_g        ( lcd_g_w      ),
        .lcd_b        ( lcd_b_w      )
    );

    // 2026-09-28 stage 4: register RGB outputs so the LCD samples settled data
    // (was a 60-80ns combinational path straight to the pins -> edge tearing)
    reg [5:0] lcd_r_r, lcd_g_r, lcd_b_r;
    always @(posedge pix_clk or negedge rst_n) begin
        if (!rst_n) begin
            lcd_r_r <= 6'd0; lcd_g_r <= 6'd0; lcd_b_r <= 6'd0;
        end
        else begin
            lcd_r_r <= lcd_r_w;
            lcd_g_r <= lcd_g_w;
            lcd_b_r <= lcd_b_w;
        end
    end

    assign lcd_r = lcd_r_r;
    assign lcd_g = lcd_g_r;
    assign lcd_b = lcd_b_r;

endmodule