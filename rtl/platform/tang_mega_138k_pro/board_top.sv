// -----------------------------------------------------------------------------
// board_top.sv -- Gowin-synthesis build wrapper around top.sv.
//
// The Gowin synthesizer resolves $readmemh relative paths against its own
// working directory, not the repository root, which silently failed to load the
// coefficient/index ROMs (WARN EX3988) and let the engine array constant-fold
// away.  This wrapper overrides COEFF_FILE/INDEX_FILE with ABSOLUTE paths so the
// real ROM images are always found, independent of the tool's CWD.
//
// It is a synthesis/build convenience only: it instantiates the SAME top.sv used
// in simulation, changing nothing but the ROM file paths.  It is NOT used by the
// board simulation (which runs from the repo root and uses top.sv directly), and
// it does not modify any core/audio file.
//
// The synthesizer has no command-line parameter override, so the absolute paths
// must be literals here.  Keep this file in sync if the tree moves.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module board_top (
    input  logic clk,
    input  logic reset,
    output logic amp_bclk,
    output logic amp_lrc,
    output logic amp_din,
    output logic amp_sd
);

    top #(
        .ENABLE_BODY(1),
        .BODY_INSTRUMENT(0),
        .COEFF_FILE("/home/rubbishbro/Desktop/FPGA_IDC_2026/rtl/rom/modal_coeff.mem"),
        .INDEX_FILE("/home/rubbishbro/Desktop/FPGA_IDC_2026/rtl/rom/modal_index.mem"),
        .BODY_FILE("/home/rubbishbro/Desktop/FPGA_IDC_2026/rtl/rom/body_coeff.mem")
    ) u_top (
        .clk     (clk),
        .reset   (reset),
        .amp_bclk(amp_bclk),
        .amp_lrc (amp_lrc),
        .amp_din (amp_din),
        .amp_sd  (amp_sd)
    );

endmodule
