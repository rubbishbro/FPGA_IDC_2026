`timescale 1ns/1ps
// Label ID + character index -> glyph ID. Synchronous read, no reset mux on ROM.
// All 4096 bytes (including undefined labels) are supplied by the generated MEM.
module sidebar_label_rom #(
    parameter LABEL_FILE="sidebar_labels.mem"
)(
    input logic clk,
    input logic [7:0] label_id,
    input logic [3:0] character,
    output logic [7:0] glyph
);
    (* syn_romstyle="block_rom", syn_ramstyle="block_ram" *) logic [7:0] labels[0:4095];
    initial $readmemh(LABEL_FILE,labels);
    always_ff @(posedge clk) glyph<=labels[{label_id,character}];
endmodule
