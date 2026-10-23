module top(
    // 板载 50 MHz 晶振输入
    input           clk,

    // 板载低有效复位按钮
    input           rst_n,

    // 板载按键：用于循环切换显示页面
    input           key0,

    // LCD 像素时钟输出（33.333 MHz PLL）
    output          lcd_clk,

    // LCD 数据有效（DE）
    output          lcd_en,

    // LCD RGB666 数据
    output  [5:0]   lcd_r,
    output  [5:0]   lcd_b,
    output  [5:0]   lcd_g
);

    wire            pix_clk;
    wire            core_clk;
    wire            pix_lock;
    wire            core_lock;
    wire            locked;

    wire            lcd_en_w;
    wire            frame_pulse;
    wire    [9:0]   pix_x;
    wire    [9:0]   pix_y;

    wire            key_pulse;
    reg     [1:0]   page_sel;
    wire    [9:0]   q_y;
    wire    [9:0]   q_ov;
    wire    [5:0]   wf_base_row;
    wire    [5:0]   wf_rd_row;
    wire    [6:0]   wf_rd_col;
    wire    [9:0]   wf_rd_data;
    wire    [5:0]   lcd_r_w, lcd_g_w, lcd_b_w;

    // ------------------------------------------------------------------
    // Clocks: 50 MHz board clock -> 33.333 MHz PLL
    //         33.333 MHz = compute + display domain
    //
    // FFT / Hann / spectrum / frame buffer all run on pix_clk here.
    // When the main engine is attached, only its 100 MHz PCM tap crosses
    // into this domain through a small async FIFO.
    // ------------------------------------------------------------------
    Gowin_PLL Gowin_PLL_inst(
        .clkout0(pix_clk),
        .clkin  (clk),
        .lock   (pix_lock)
    );

    assign core_clk = pix_clk;
    assign locked   = pix_lock;

    // Async assert, sync release in each domain.
    wire rst_sys_n = rst_n & locked;

    reg [2:0] rst_pix_sync;
    always @(posedge pix_clk or negedge rst_sys_n) begin
        if (!rst_sys_n) rst_pix_sync <= 3'b000;
        else            rst_pix_sync <= {rst_pix_sync[1:0], 1'b1};
    end
    wire rst_pix_n = rst_pix_sync[2];

    reg [2:0] rst_core_sync;
    always @(posedge core_clk or negedge rst_sys_n) begin
        if (!rst_sys_n) rst_core_sync <= 3'b000;
        else            rst_core_sync <= {rst_core_sync[1:0], 1'b1};
    end
    wire rst_core_n = rst_core_sync[2];

    assign lcd_clk = pix_clk;

    // ------------------------------------------------------------------
    // Pixel-domain scan / input
    // ------------------------------------------------------------------
    lcd_timing lcd_timing_inst(
        .lcd_clk      ( pix_clk      ),
        .rst_n        ( rst_pix_n    ),
        .lcd_en       ( lcd_en_w     ),
        .frame_pulse  ( frame_pulse  ),
        .pix_x        ( pix_x        ),
        .pix_y        ( pix_y        )
    );

    assign lcd_en = lcd_en_w;

    key_debounce key_debounce_inst(
        .clk        ( pix_clk    ),
        .rst_n      ( rst_pix_n  ),
        .key_in     ( key0       ),
        .key_pulse  ( key_pulse  )
    );

    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n)
            page_sel <= 2'b00;
        else if (key_pulse)
            page_sel <= (page_sel == 2'd2) ? 2'd0 : page_sel + 1'b1;
    end

    // ------------------------------------------------------------------
    // Pixel-domain 48k sample tick for the demo ROM (33.333 MHz / 694)
    // ------------------------------------------------------------------
    reg [15:0] div48k;
    reg        samp_en;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            div48k  <= 16'd0;
            samp_en <= 1'b0;
        end
        else begin
            samp_en <= 1'b0;
            if (div48k >= 16'd693) begin
                div48k  <= 16'd0;
                samp_en <= 1'b1;
            end
            else begin
                div48k <= div48k + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Compute: audio -> FFT -> spectrum -> central frame buffer
    // Pixel: bar readout
    // ------------------------------------------------------------------
    // bar index counter: floor(pix_x/6), no divider on the frame-buffer read path.
    reg [2:0] xmod_d;
    reg [6:0] bar_idx_disp_r;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            xmod_d         <= 3'd0;
            bar_idx_disp_r <= 7'd0;
        end
        else if (pix_x == 10'd0) begin
            xmod_d         <= 3'd0;
            bar_idx_disp_r <= 7'd0;
        end
        else if (xmod_d == 3'd5) begin
            xmod_d <= 3'd0;
            if (bar_idx_disp_r < 7'd127)
                bar_idx_disp_r <= bar_idx_disp_r + 1'b1;
        end
        else begin
            xmod_d <= xmod_d + 1'b1;
        end
    end

    wire [6:0] bar_idx_disp = bar_idx_disp_r;
    wire       rd_valid     = (pix_x < 10'd768);

    real_audio_chain real_audio_chain_inst(
        .clk_core    ( core_clk      ),
        .rst_core_n  ( rst_core_n    ),
        .clk_pix     ( pix_clk       ),
        .rst_pix_n   ( rst_pix_n     ),
        .samp_en     ( samp_en       ),
        .frame_pulse ( frame_pulse   ),
        .rd_bar_idx  ( bar_idx_disp  ),
        .rd_valid    ( rd_valid      ),
        .rd_q_y      ( q_y           ),
        .rd_q_ov     ( q_ov          ),
        .wf_base_row ( wf_base_row   ),
        .wf_rd_row   ( wf_rd_row     ),
        .wf_rd_col   ( wf_rd_col     ),
        .wf_rd_data  ( wf_rd_data    )
    );

    lcd_draw lcd_draw_inst(
        .clk          ( pix_clk      ),
        .rst_n        ( rst_pix_n    ),
        .frame_pulse  ( frame_pulse  ),
        .lcd_valid    ( lcd_en_w     ),
        .pix_x        ( pix_x        ),
        .pix_y        ( pix_y        ),
        .page_sel     ( page_sel     ),
        .q_y          ( q_y          ),
        .q_ov         ( q_ov         ),
        .wf_base_row  ( wf_base_row  ),
        .wf_rd_data   ( wf_rd_data   ),
        .wf_rd_row    ( wf_rd_row    ),
        .wf_rd_col    ( wf_rd_col    ),
        .lcd_r        ( lcd_r_w      ),
        .lcd_g        ( lcd_g_w      ),
        .lcd_b        ( lcd_b_w      )
    );

    // Register RGB outputs so the LCD samples settled data.
    reg [5:0] lcd_r_r, lcd_g_r, lcd_b_r;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
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
