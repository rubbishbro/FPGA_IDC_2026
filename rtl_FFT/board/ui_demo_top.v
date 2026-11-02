module ui_demo_top #(
    parameter       SWEEP_MODE = 1'b0
) (
    input           clk,
    input           rst_n,
    input           key0,
    input           key1,
    output          lcd_clk,
    output          lcd_en,
    output  [5:0]   lcd_r,
    output  [5:0]   lcd_g,
    output  [5:0]   lcd_b
);

    import ui_pkg::*;

    wire        pix_clk;
    wire        locked;
    wire        lcd_en_w;
    wire        frame_pulse;
    wire [9:0]  pix_x;
    wire [9:0]  pix_y;

    wire [9:0]  q_y;
    wire [9:0]  q_ov;
    wire [39:0] curve_rd_data;
    wire [9:0]  curve_rd_addr;
    wire [9:0]  wave_rd_addr;
    wire [9:0]  wave_rd_data;
    wire [5:0]  lcd_r_w;
    wire [5:0]  lcd_g_w;
    wire [5:0]  lcd_b_w;

    Gowin_PLL Gowin_PLL_inst (
        .clkout0 (pix_clk),
        .clkin   (clk),
        .lock    (locked)
    );

    wire rst_sys_n = rst_n & locked;

    reg [2:0] rst_sync;
    always @(posedge pix_clk or negedge rst_sys_n) begin
        if (!rst_sys_n)
            rst_sync <= 3'b000;
        else
            rst_sync <= {rst_sync[1:0], 1'b1};
    end
    wire rst_pix_n = rst_sync[2];

    assign lcd_clk = pix_clk;

    lcd_timing u_timing (
        .lcd_clk     (pix_clk),
        .rst_n       (rst_pix_n),
        .lcd_en      (lcd_en_w),
        .frame_pulse (frame_pulse),
        .pix_x       (pix_x),
        .pix_y       (pix_y)
    );

    wire sidebar_de;
    reg sidebar_de_q;
    always @(posedge pix_clk or negedge rst_pix_n)
        if(!rst_pix_n)sidebar_de_q<=1'b0;
        else sidebar_de_q<=sidebar_de;
    assign lcd_en = sidebar_de_q;

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

    logic [15:0] sine_rom [0:255];
    initial $readmemh("sine256.mem", sine_rom);

    wire [23:0] pcm_data;

    generate
        if (SWEEP_MODE) begin : g_sweep
            wire [7:0] sweep_idx;

            sweep_source u_sweep (
                .clk        (pix_clk),
                .rst_n      (rst_pix_n),
                .samp_en    (samp_en),
                .phase_idx  (sweep_idx),
                .phase      (),
                .freq_inc   (),
                .sweep_done ()
            );

            assign pcm_data = {sine_rom[sweep_idx], 8'b0};
        end
        else begin : g_three_tone
            reg [31:0] phase1, phase2, phase3;

            always @(posedge pix_clk or negedge rst_pix_n) begin
                if (!rst_pix_n) begin
                    phase1 <= 32'd0;
                    phase2 <= 32'd0;
                    phase3 <= 32'd0;
                end
                else if (samp_en) begin
                    phase1 <= phase1 + 32'd39370533;
                    phase2 <= phase2 + 32'd78741066;
                    phase3 <= phase3 + 32'd118111599;
                end
            end

            wire signed [15:0] s1 = sine_rom[phase1[31:24]];
            wire signed [15:0] s2 = sine_rom[phase2[31:24]];
            wire signed [15:0] s3 = sine_rom[phase3[31:24]];
            wire signed [17:0] mix = s1 + (s2 >>> 1) + (s3 >>> 2);

            assign pcm_data = {mix, 6'b0};
        end
    endgenerate

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

    real_audio_chain u_chain (
        .clk_core    (pix_clk),
        .rst_core_n  (rst_pix_n),
        .clk_pix     (pix_clk),
        .rst_pix_n   (rst_pix_n),
        .pcm_valid   (samp_en),
        .pcm_data    (pcm_data),
        .frame_pulse (frame_pulse),
        .rd_bar_idx  (bar_idx_disp),
        .rd_valid    (rd_valid),
        .rd_q_y      (q_y),
        .rd_q_ov     (q_ov),
        .curve_rd_addr(curve_rd_addr),
        .curve_rd_data(curve_rd_data),
        .wave_rd_addr(wave_rd_addr),
        .wave_rd_data(wave_rd_data)
    );

    // The Chinese sidebar is the only UI path.
    wire key0_valid_ctrl,key1_valid_ctrl;
    wire[2:0] key0_ctrl,key1_ctrl;
    reg[2:0] ctrl_reset;
    always @(posedge clk or negedge rst_sys_n)
        if(!rst_sys_n)ctrl_reset<=0;else ctrl_reset<={ctrl_reset[1:0],1'b1};
    key_ui_event #(.DEBOUNCE_CNT(1_000_000),.LONG_CNT(40_000_000),
                   .SHORT_EVENT(UI_EV_NEXT),.LONG_EVENT(UI_EV_OK)) u_ctrl_key0(
        .clk(clk),.rst_n(ctrl_reset[2]),.key_in(key0),.ev_valid(key0_valid_ctrl),.ev(key0_ctrl));
    key_ui_event #(.DEBOUNCE_CNT(1_000_000),.LONG_CNT(40_000_000),
                   .SHORT_EVENT(UI_EV_PREV),.LONG_EVENT(UI_EV_BACK)) u_ctrl_key1(
        .clk(clk),.rst_n(ctrl_reset[2]),.key_in(key1),.ev_valid(key1_valid_ctrl),.ev(key1_ctrl));
    // 独立 LCD demo 仍用测试音源/两按键。整机用 sidebar_system 原始坐标及后端口。
    sidebar_system #(.CTRL_HZ(50_000_000),.HAS_JOYSTICK(1'b0)) u_system(
        .rst_n(rst_sys_n),.ctrl_clk(clk),.pix_clk(pix_clk),
        .joy_sample_valid(1'b0),.joy_raw_x(14'd0),.joy_raw_y(14'd0),
        .key_valid(key0_valid_ctrl|key1_valid_ctrl),.key_event(key0_valid_ctrl?key0_ctrl:key1_ctrl),
        .ext_cfg_valid(1'b0),.ext_cfg_ready(),.ext_cfg_request(64'd0),
        .ext_rsp_valid(),.ext_rsp_ready(1'b1),.ext_cfg_response(),
        .backend_supported(20'd0),.backend_valid(),.backend_ready(1'b0),.backend_request(),
        .backend_source(),.backend_rsp_valid(1'b0),.backend_rsp_ready(),.backend_response(72'd0),
        .frame_pulse(frame_pulse),.lcd_valid(lcd_en_w),.pix_x(pix_x),.pix_y(pix_y),
        .q_y(q_y),.q_ov(q_ov),.wave_rd_data(wave_rd_data),.wave_rd_addr(wave_rd_addr),
        .curve_rd_data(curve_rd_data),.curve_rd_addr(curve_rd_addr),
        .lcd_r(lcd_r_w),.lcd_g(lcd_g_w),.lcd_b(lcd_b_w),.lcd_valid_out(sidebar_de),
        .active_values(),.ui_scene(),.sidebar_width());

    reg [5:0] lcd_r_r, lcd_g_r, lcd_b_r;
    always @(posedge pix_clk or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            lcd_r_r <= 6'd0;
            lcd_g_r <= 6'd0;
            lcd_b_r <= 6'd0;
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
