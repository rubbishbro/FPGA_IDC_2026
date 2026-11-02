module lcd_timing (
    input               lcd_clk,
    input               rst_n,

    output              lcd_en,
    output              frame_pulse,
    output      [9:0]   pix_x,
    output      [9:0]   pix_y
);

    parameter   H_Pixel_Valid   = 16'd800;
    parameter   ROTATE_180      = 1'b0;
    parameter   H_FrontPorch    = 16'd210;
    parameter   H_BackPorch     = 16'd182;
    parameter   PixelForHS      = H_Pixel_Valid + H_FrontPorch + H_BackPorch;

    parameter   V_Pixel_Valid   = 16'd480;
    parameter   V_FrontPorch    = 16'd45;
    parameter   V_BackPorch     = 16'd8;
    parameter   PixelForVS      = V_Pixel_Valid + V_FrontPorch + V_BackPorch;

    reg [15:0]  H_PixelCount;
    reg [15:0]  V_PixelCount;

    always @(posedge lcd_clk or negedge rst_n) begin
        if (!rst_n) begin
            V_PixelCount <= 16'b0;
            H_PixelCount <= 16'b0;
        end
        else if (H_PixelCount == PixelForHS-1) begin
            V_PixelCount <= V_PixelCount == PixelForVS-1 ? 16'd0 : V_PixelCount + 1'b1;
            H_PixelCount <= 16'b0;
        end
        else begin
            H_PixelCount <= H_PixelCount + 1'b1;
        end
    end

    // DE: active region only
    assign lcd_en = (H_PixelCount >= H_BackPorch) && (H_PixelCount < H_Pixel_Valid + H_BackPorch) &&
                    (V_PixelCount >= V_BackPorch) && (V_PixelCount < V_Pixel_Valid + V_BackPorch);

    // one-cycle pulse at the very end of a frame
    assign frame_pulse = (V_PixelCount == PixelForVS-1) && (H_PixelCount == PixelForHS-1);

    // clean pixel coordinate in active area: pix_x 0..799, pix_y 0..479
    wire [9:0] scan_x = (H_PixelCount >= H_BackPorch) ? (H_PixelCount - H_BackPorch) : 10'd0;
    wire [9:0] scan_y = (V_PixelCount >= V_BackPorch) ? (V_PixelCount - V_BackPorch) : 10'd0;
    // Rotate logical coordinates, leaving panel clocks, DE and frame cadence
    // unchanged. Clamp blanking to avoid unsigned underflow in renderers.
    assign pix_x = ROTATE_180 ? ((scan_x < H_Pixel_Valid) ? H_Pixel_Valid-1-scan_x : H_Pixel_Valid-1) : scan_x;
    assign pix_y = ROTATE_180 ? ((scan_y < V_Pixel_Valid) ? V_Pixel_Valid-1-scan_y : V_Pixel_Valid-1) : scan_y;

endmodule
