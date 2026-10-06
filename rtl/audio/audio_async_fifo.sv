// -----------------------------------------------------------------------------
// audio_async_fifo.sv -- dual-clock Gray-pointer asynchronous FIFO.
//
// One shared asynchronous-assert reset.  Each clock domain gets its own
// two-flop synchroniser, so the *release* is synchronous in that domain.  The
// data array is never directly synchronised: read/write pointers cross as Gray
// codes through two flops, and the array is single-clock on each side.
//
// Contract (rtl/audio_bringup_design.md section 3):
//   * DEPTH is a power of two, >= 4
//   * a write only commits when wvalid && wready (wready = !full); a read only
//     commits when rvalid && rready (rvalid = !empty)
//   * full never overwrites, empty never reads stale/unwritten data
//   * rdata is addressed by the read pointer and is only meaningful when rvalid
//
// The memory read is combinational (distributed-read model) so a consumer can
// use rvalid/rdata in the same cycle.  This is a generic simulation/synthesis
// model, not a physical BSRAM mapping promise.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module audio_async_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 16
) (
    input  logic             wclk,
    input  logic             rclk,
    input  logic             rst_n,      // async assert, per-domain sync release

    // write port (wclk domain)
    input  logic             wvalid,
    output logic             wready,
    input  logic [WIDTH-1:0] wdata,

    // read port (rclk domain)
    output logic             rvalid,
    input  logic             rready,
    output logic [WIDTH-1:0] rdata,

    // status
    output logic             wfull,
    output logic             rempty
);

    localparam int ADDRW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // DEPTH must be a power of two and at least 4 (structural contract).
    initial begin
        if ((DEPTH < 4) || ((DEPTH & (DEPTH - 1)) != 0))
            $error("%m: DEPTH=%0d must be a power of two and >= 4", DEPTH);
    end

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function automatic [ADDRW:0] bin2gray(input [ADDRW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // ------------------------------------------------------------------
    // per-domain synchronised reset release
    // ------------------------------------------------------------------
    logic [1:0] wrst_sync, rrst_sync;
    always_ff @(posedge wclk or negedge rst_n)
        if (!rst_n) wrst_sync <= 2'b00;
        else        wrst_sync <= {wrst_sync[0], 1'b1};

    always_ff @(posedge rclk or negedge rst_n)
        if (!rst_n) rrst_sync <= 2'b00;
        else        rrst_sync <= {rrst_sync[0], 1'b1};

    wire wrst_n = wrst_sync[1];
    wire rrst_n = rrst_sync[1];

    // ------------------------------------------------------------------
    // pointers (one extra bit distinguishes full from empty)
    // ------------------------------------------------------------------
    logic [ADDRW:0] wbin, wgray;
    logic [ADDRW:0] rbin, rgray;

    logic [ADDRW:0] wgray_s1, wgray_s2;   // write Gray -> read domain
    logic [ADDRW:0] rgray_s1, rgray_s2;   // read  Gray -> write domain

    logic           wfull_r, rempty_r;

    // ------------------------------------------------------------------
    // memory: written only in wclk, addressed only by the read pointer in rclk
    // ------------------------------------------------------------------
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    wire winc = wvalid & wready;
    wire rinc = rvalid & rready;

    // A write/read is only advertised as accepted once this domain's reset has
    // released; during reset the pointers do not advance, so an ungated wready
    // would falsely imply an accepted write.
    assign wready = wrst_n & ~wfull_r;
    assign rvalid = rrst_n & ~rempty_r;
    assign wfull  = wfull_r;
    assign rempty = rempty_r;

    always_ff @(posedge wclk) begin
        if (winc) mem[wbin[ADDRW-1:0]] <= wdata;
    end

    assign rdata = mem[rbin[ADDRW-1:0]];

    // ------------------------------------------------------------------
    // next-state pointers + flags (registered, no combinational loop through
    // wready: wready uses the registered wfull_r)
    // ------------------------------------------------------------------
    wire [ADDRW:0] wbin_nxt  = wbin + {{ADDRW{1'b0}}, winc};
    wire [ADDRW:0] rbin_nxt  = rbin + {{ADDRW{1'b0}}, rinc};
    wire [ADDRW:0] wgray_nxt = bin2gray(wbin_nxt);
    wire [ADDRW:0] rgray_nxt = bin2gray(rbin_nxt);

    wire [ADDRW:0] rfull_cmp = {~rgray_s2[ADDRW:ADDRW-1],
                                 rgray_s2[ADDRW-2:0]};

    always_ff @(posedge wclk or negedge wrst_n)
        if (!wrst_n) begin
            wbin    <= {ADDRW+1{1'b0}};
            wgray   <= {ADDRW+1{1'b0}};
            wfull_r <= 1'b0;
        end else begin
            wbin    <= wbin_nxt;
            wgray   <= wgray_nxt;
            wfull_r <= (wgray_nxt == rfull_cmp);
        end

    always_ff @(posedge rclk or negedge rrst_n)
        if (!rrst_n) begin
            rbin    <= {ADDRW+1{1'b0}};
            rgray   <= {ADDRW+1{1'b0}};
            rempty_r<= 1'b1;
        end else begin
            rbin    <= rbin_nxt;
            rgray   <= rgray_nxt;
            rempty_r<= (rgray_nxt == wgray_s2);
        end

    // ------------------------------------------------------------------
    // pointer synchronisers (2 FF, Gray, registered in the destination domain)
    // ------------------------------------------------------------------
    always_ff @(posedge rclk or negedge rrst_n)
        if (!rrst_n) {wgray_s2, wgray_s1} <= '0;
        else         {wgray_s2, wgray_s1} <= {wgray_s1, wgray};

    always_ff @(posedge wclk or negedge wrst_n)
        if (!wrst_n) {rgray_s2, rgray_s1} <= '0;
        else         {rgray_s2, rgray_s1} <= {rgray_s1, rgray};

endmodule
