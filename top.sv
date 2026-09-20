module matrix_keyboard_4_8 #(
    parameter integer ROWS = 4,
    parameter integer COLS = 8,
    parameter integer CLK_FREQ = 100_000_000;
    parameter integer SCAN_FREQ = 1_000;
    parameter integer DEBOUNCE_MS = 5;
)(
    input logic clk,
    input logic rst_n,
    input logic [3:0] row,
    output logic [7:0] col,
    output logic [31:0] keycode
)

