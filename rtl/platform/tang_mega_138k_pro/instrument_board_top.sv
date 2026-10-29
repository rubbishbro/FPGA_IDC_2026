`timescale 1ns/1ps
module instrument_board_top #(
    parameter int BAUD=115200,KEY_DEBOUNCE=2_000_000,KEY_LONG=80_000_000,
    parameter bit NOTE_BANKS=0,BT_HAS_STATE=0,
    parameter logic [9:0] RESOURCE_MASK=10'b0000000001,
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
    output wire lcd_clk,lcd_en,
    output wire [5:0] lcd_r,lcd_g,lcd_b
);
    wire clk_core,clk_audio,clk_pix,reset_request_n,locked;
    board_clock_reset u_clocks(.clk_50m(clk),.rst_n(rst_n),.clk_core(clk_core),.clk_audio(clk_audio),
        .clk_pix(clk_pix),.reset_request_n(reset_request_n),.locked(locked));
    instrument_system #(.BAUD(BAUD),.KEY_DEBOUNCE(KEY_DEBOUNCE),.KEY_LONG(KEY_LONG),
        .NOTE_BANKS(NOTE_BANKS),.BT_HAS_STATE(BT_HAS_STATE),.RESOURCE_MASK(RESOURCE_MASK),.FIRST_MIDI(FIRST_MIDI)) u_system(
        .clk_core(clk_core),.clk_audio(clk_audio),.clk_pix(clk_pix),.rst_n(reset_request_n),.key0(key0),.key1(key1),
        .uart_rx(uart_rx),.uart_tx(uart_tx),.bt_state(bt_state),.session_restart(2'b0),
        .pad_row(pad_row),.pad_ch(pad_ch),.led_dat(led_dat),.flash_cs_n(flash_cs_n),.flash_sck(flash_sck),.flash_dq(flash_dq),
        .amp_bclk(amp_bclk),.amp_ws(amp_ws),.amp_din(amp_din),.amp_sd(amp_sd),
        .lcd_clk(lcd_clk),.lcd_en(lcd_en),.lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b),
        .sample_valid(),.sample_value(),.audio_diagnostics());
endmodule
