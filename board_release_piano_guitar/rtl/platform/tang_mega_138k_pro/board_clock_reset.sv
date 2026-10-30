`timescale 1ns/1ps
// One 800MHz vendor PLL: /8 core100M, /64 audio12M5, /24 pixel33M333.
// Functional domains and their CDC protocols remain separate.
module board_clock_reset(
    input wire clk_50m,rst_n,
    output wire clk_core,clk_audio,clk_pix,reset_request_n,locked
);
    wire core_lock;
    Gowin_PLL_core_100M u_core(.clkin(clk_50m),.init_clk(clk_50m),
        .clkout0(clk_core),.clkout_audio(clk_audio),.clkout_pix(clk_pix),.lock(core_lock));
    assign locked=core_lock;
    // Async assert on PLL loss; every consumer still releases its reset locally.
    assign reset_request_n=rst_n && locked;
endmodule
