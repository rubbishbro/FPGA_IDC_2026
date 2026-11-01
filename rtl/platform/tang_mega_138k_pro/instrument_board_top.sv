`timescale 1ns/1ps
module instrument_board_top #(
    parameter int BAUD=115200,KEY_DEBOUNCE=1_000_000,KEY_LONG=40_000_000,
    parameter bit NOTE_BANKS=0,BT_HAS_STATE=0,BT_PROTOCOL_V2=0,
    parameter int PCM_HEADROOM_BITS=4,
    parameter bit LCD_ROTATE_180=1'b1,
    parameter logic [9:0] RESOURCE_MASK=10'b0000101011,
    parameter logic [31:0] FLASH_BASE=32'h0080_0000,
    parameter int FLASH_BYTES=16_777_216,
    parameter bit STEREO_ENABLE=1'b1,STEREO_AUTO_SWEEP=1'b0,STEREO_ITD_ENABLE=1'b1,
    parameter logic [5:0] STEREO_PAN=6'd16,
    parameter int SWEEP_HOLD_FRAMES=3072,
    parameter logic [6:0] FIRST_MIDI=48
)(
    input wire clk,rst_n,key0,key1,
    input wire [1:0] uart_rx,
    output wire [1:0] uart_tx,
    input wire bt_state,
    output wire [3:0] pad_row,
    output wire [2:0] pad_ch,
    output wire led_dat,
    output wire flash_cs_n,flash_sck,
    inout wire [3:0] flash_dq,
    output wire amp_bclk,amp_ws,amp_din,amp_sd,
    output wire dac_bck,dac_ws,dac_din,dac_pa_en,
    output wire lcd_clk,lcd_en,
    output wire [5:0] lcd_r,lcd_g,lcd_b
);
    wire clk_core,clk_audio,clk_pix,reset_request_n,locked;
    board_clock_reset u_clocks(.clk_50m(clk),.rst_n(rst_n),.clk_core(clk_core),.clk_audio(clk_audio),
        .clk_pix(clk_pix),.reset_request_n(reset_request_n),.locked(locked));
    instrument_system #(.FLASH_BASE(FLASH_BASE),.FLASH_BYTES(FLASH_BYTES),.BAUD(BAUD),.KEY_DEBOUNCE(KEY_DEBOUNCE),.KEY_LONG(KEY_LONG),
        .NOTE_BANKS(NOTE_BANKS),.BT_HAS_STATE(BT_HAS_STATE),.BT_PROTOCOL_V2(BT_PROTOCOL_V2),.RESOURCE_MASK(RESOURCE_MASK),.FIRST_MIDI(FIRST_MIDI),
        .PCM_HEADROOM_BITS(PCM_HEADROOM_BITS),.LCD_ROTATE_180(LCD_ROTATE_180),
        .STEREO_ENABLE(STEREO_ENABLE),.STEREO_AUTO_SWEEP(STEREO_AUTO_SWEEP),.SWEEP_HOLD_FRAMES(SWEEP_HOLD_FRAMES)) u_system(
        .clk_core(clk_core),.clk_audio(clk_audio),.clk_pix(clk_pix),.rst_n(reset_request_n),.key0(key0),.key1(key1),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.bt_state(bt_state),.session_restart(2'b0),
        .pan_position(STEREO_PAN),.itd_enable(STEREO_ITD_ENABLE),
        .pad_row(pad_row),.pad_ch(pad_ch),.led_dat(led_dat),.flash_cs_n(flash_cs_n),.flash_sck(flash_sck),.flash_dq(flash_dq),
        .amp_bclk(amp_bclk),.amp_ws(amp_ws),.amp_din(amp_din),.amp_sd(amp_sd),
        .dac_bck(dac_bck),.dac_ws(dac_ws),.dac_din(dac_din),.dac_pa_en(dac_pa_en),
        .lcd_clk(lcd_clk),.lcd_en(lcd_en),.lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b),
        .sample_valid(),.sample_value(),.audio_diagnostics());
endmodule
