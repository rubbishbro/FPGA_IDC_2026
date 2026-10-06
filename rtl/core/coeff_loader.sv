// -----------------------------------------------------------------------------
// coeff_loader.sv -- module 2B: index/coefficient ROM loader.
//
// Looks up the dense 1024-entry index ROM for one (instrument, MIDI, dynamic)
// key, validates the entry, clears the target voice's state, then streams the
// entry's coefficients into the modal bank through the cfg handshake.  Only the
// final cfg handshake produces load_done.
//
// Contract (rtl/module2BC_design.md sections 3 and 5):
//   * load inputs are latched only on the load handshake; load_ready=0 while busy
//   * the whole entry is looked up and range-checked before any clear/cfg
//   * a missing entry or illegal ROM metadata emits an error pulse and returns
//     to idle without clear, cfg or load_done
//   * cfg/clear fields stay stable until the downstream handshake
//   * arbitrary downstream backpressure never loses or duplicates a word
//   * reset cancels the transaction and every valid token
//
// The ROMs are synchronous-read, initialised with $readmemh and never parsed at
// run time.  A 72-bit logical read port is not a physical BSRAM mapping promise.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module coeff_loader #(
    parameter int NUM_VOICES  = 32,
    parameter int N_MODES     = 48,
    parameter int COEFF_DEPTH = 5483,
    parameter int INDEX_DEPTH = 1024,
    parameter int COEFF_BITS  = 72,
    parameter int INDEX_BITS  = 20,
    parameter int OFFSET_BITS = 13,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem"
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // load request
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [VW-1:0]          load_voice,
    input  logic [1:0]             load_instrument,
    input  logic [6:0]             load_midi,
    input  logic                   load_dyn,

    output logic                   busy,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,

    output logic                   error_valid,
    output logic [1:0]             error_code,

    // downstream state clear
    output logic                   clear_valid,
    input  logic                   clear_ready,
    output logic [VW-1:0]          clear_voice,

    // downstream coefficient write
    output logic                   cfg_valid,
    input  logic                   cfg_ready,
    output logic [VW-1:0]          cfg_voice,
    output logic [MW-1:0]          cfg_mode,
    output logic [COEFF_BITS-1:0]  cfg_word
);

    localparam logic [2:0] S_IDLE  = 3'd0,
                           S_IDX   = 3'd1,
                           S_CHK   = 3'd2,
                           S_CLEAR = 3'd3,
                           S_CRD   = 3'd4,
                           S_CFG   = 3'd5,
                           S_DONE  = 3'd6;

    // ------------------------------------------------------------------
    // ROM arrays (synchronous read), initialised from the generated images
    // ------------------------------------------------------------------
    logic [COEFF_BITS-1:0] coeff_rom [0:COEFF_DEPTH-1];
    logic [INDEX_BITS-1:0] index_rom [0:INDEX_DEPTH-1];
    initial begin
        $readmemh(COEFF_FILE, coeff_rom);
        $readmemh(INDEX_FILE, index_rom);
    end

    logic [OFFSET_BITS-1:0]           coeff_raddr;
    logic [9:0]                       idx_raddr;
    logic [COEFF_BITS-1:0]            coeff_rdata;
    logic [INDEX_BITS-1:0]            idx_rdata;

    always_ff @(posedge clk) begin
        coeff_rdata <= coeff_rom[coeff_raddr];
        idx_rdata   <= index_rom[idx_raddr];
    end

    // ------------------------------------------------------------------
    // transaction state
    // ------------------------------------------------------------------
    logic [2:0]          st;
    logic [VW-1:0]       voice_r;
    logic [1:0]          inst_r;
    logic [6:0]          midi_r;
    logic                dyn_r;
    logic [OFFSET_BITS-1:0] offset_r;
    logic [MW-1:0]       n_r;          // full entry mode count
    logic [MW-1:0]       cnt;          // mode being written

    wire [9:0] req_addr = {inst_r, midi_r, dyn_r};

    // index word fields
    localparam int N_FIELD_W = INDEX_BITS - 1 - OFFSET_BITS;   // 6
    wire [N_FIELD_W-1:0]   n_field = idx_rdata[INDEX_BITS-2 -: N_FIELD_W];
    wire [OFFSET_BITS-1:0] off_field = idx_rdata[OFFSET_BITS-1:0];
    wire [OFFSET_BITS:0]   entry_end = {1'b0, off_field} + {1'b0, n_field};
    wire n_illegal = (n_field == {N_FIELD_W{1'b0}}) || (n_field > N_MODES);

    // fields presented to the downstream bank; stable while waiting for ready
    assign load_ready    = (st == S_IDLE);
    assign busy          = (st != S_IDLE);
    assign clear_valid   = (st == S_CLEAR);
    assign clear_voice   = voice_r;
    assign cfg_valid     = (st == S_CFG);
    assign cfg_voice     = voice_r;
    assign cfg_mode      = cnt;
    assign cfg_word      = coeff_rdata;
    assign done_voice    = voice_r;
    assign loaded_n_modes= n_r;

    // coefficient read address: offset + cnt (extra headroom, then truncated)
    wire [OFFSET_BITS+MW:0] coff_sum = {1'b0, offset_r} + {{(OFFSET_BITS+1){1'b0}},
                                                           cnt};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st           <= S_IDLE;
            voice_r      <= {VW{1'b0}};
            inst_r       <= 2'd0;
            midi_r       <= 7'd0;
            dyn_r        <= 1'b0;
            offset_r     <= {OFFSET_BITS{1'b0}};
            n_r          <= {MW{1'b0}};
            cnt          <= {MW{1'b0}};
            idx_raddr    <= 10'd0;
            coeff_raddr  <= {OFFSET_BITS{1'b0}};
            load_done    <= 1'b0;
            error_valid  <= 1'b0;
            error_code   <= 2'd0;
        end else begin
            load_done   <= 1'b0;
            error_valid <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (load_valid) begin
                        // latch the request
                        voice_r <= load_voice;
                        inst_r  <= load_instrument;
                        midi_r  <= load_midi;
                        dyn_r   <= load_dyn;
                        if (load_voice >= NUM_VOICES) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd1;        // voice out of range
                        end else begin
                            idx_raddr <= {load_instrument, load_midi, load_dyn};
                            st        <= S_IDX;
                        end
                    end
                end

                S_IDX: begin
                    // index_rom[req_addr] is on idx_rdata after this edge
                    idx_raddr <= req_addr;
                    st        <= S_CHK;
                end

                S_CHK: begin
                    if (!idx_rdata[INDEX_BITS-1]) begin
                        error_valid <= 1'b1;
                        error_code  <= 2'd2;            // missing entry
                        st          <= S_IDLE;
                    end else if (n_illegal ||
                                 (entry_end > (OFFSET_BITS+1)'(COEFF_DEPTH))) begin
                        error_valid <= 1'b1;
                        error_code  <= 2'd3;            // metadata illegal / > ROM
                        st          <= S_IDLE;
                    end else begin
                        offset_r <= off_field;
                        n_r      <= idx_rdata[INDEX_BITS-2 -: N_FIELD_W];
                        cnt      <= {MW{1'b0}};
                        st       <= S_CLEAR;
                    end
                end

                S_CLEAR: begin
                    if (clear_ready) begin
                        coeff_raddr <= offset_r;
                        st          <= S_CRD;
                    end
                end

                S_CRD: begin
                    coeff_raddr <= coff_sum[OFFSET_BITS-1:0];
                    st          <= S_CFG;
                end

                S_CFG: begin
                    if (cfg_ready) begin
                        if (cnt == (n_r - MW'(1))) begin
                            st <= S_DONE;
                        end else begin
                            cnt         <= cnt + MW'(1);
                            coeff_raddr <= offset_r + cnt + MW'(1);
                            st          <= S_CRD;
                        end
                    end
                end

                default: begin // S_DONE
                    load_done <= 1'b1;
                    st        <= S_IDLE;
                end
            endcase
        end
    end

endmodule
