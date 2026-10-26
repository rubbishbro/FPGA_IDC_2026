// time_pingpong.v - dual-clock time-domain ping-pong buffer
//
// Write side: PCM sample domain (clk_wr_i, e.g. 100 MHz).
// Read side : visualization domain (clk_rd_i, 33.333 MHz).
//
// The two 1024-sample banks are the CDC boundary. The cross-domain control
// signals are synchronized explicitly; tbuf_ram is a dual-clock RAM.
//
// Handshake:
//  - block_state/full_exists/full_ptr are owned by the write side.
//  - full_exists/full_ptr are synchronized into the read side with 2FF.
//  - rd_done is converted to a toggle in the read domain and edge-detected
//    in the write domain. A one-cycle pulse is not sent across directly.
//  - wr_ready_o is low if the target bank is still FULL, preventing overwrite.
module time_pingpong #(
    parameter N_SAMPLES = 1024,
    parameter WIDTH     = 16
) (
    // Write-side reset (active low, synchronous deassert recommended)
    input               wr_rst_ni,

    // ---------------- Write side: PCM sample domain ----------------
    input               wr_clk_i,
    input  [WIDTH-1:0]  wr_data_i,
    input               wr_valid_i,
    output              wr_ready_o,

    // ---------------- Read side: visualization domain ----------------
    input               rd_rst_ni,
    input               rd_clk_i,
    input               rd_req_i,
    input  [$clog2(N_SAMPLES)-1:0] rd_addr_i,
    output [WIDTH-1:0]  rd_data_o,
    output              rd_valid_o,
    input               rd_done_i,

    // ---------------- Waveform read side ----------------
    input               wf_clk_i,
    input  [$clog2(N_SAMPLES)-1:0] wf_addr_i,
    output [WIDTH-1:0]  wf_data_o
);

    // ============================================================
    //  Data path: two banks of dual-clock RAM
    // ============================================================
    reg [WIDTH-1:0] tbuf_ram [0:1][0:N_SAMPLES-1];

    // ============================================================
    //  Write-side controller (wr_clk_i domain)
    // ============================================================
    localparam EMPTY = 1'b0, FULL = 1'b1;

    reg block_state [0:1];
    reg wr_block;
    reg [$clog2(N_SAMPLES)-1:0] wr_addr;
    reg full_exists;
    reg full_ptr;

    // rd_done_i is a one-cycle pulse in the read domain. Convert it to a
    // toggle there, then synchronize and edge-detect in the write domain.
    reg rd_done_toggle;
    always @(posedge rd_clk_i or negedge rd_rst_ni) begin
        if (!rd_rst_ni)
            rd_done_toggle <= 1'b0;
        else if (rd_done_i)
            rd_done_toggle <= ~rd_done_toggle;
    end

    (* ASYNC_REG = "TRUE" *) reg done_tog_meta;
    (* ASYNC_REG = "TRUE" *) reg done_tog_sync;
    reg done_tog_prev;

    always @(posedge wr_clk_i or negedge wr_rst_ni) begin
        if (!wr_rst_ni) begin
            done_tog_meta <= 1'b0;
            done_tog_sync <= 1'b0;
            done_tog_prev <= 1'b0;
        end
        else begin
            done_tog_meta <= rd_done_toggle;
            done_tog_sync <= done_tog_meta;
            done_tog_prev <= done_tog_sync;
        end
    end

    wire done_pulse_wr = done_tog_sync ^ done_tog_prev;

    always @(posedge wr_clk_i or negedge wr_rst_ni) begin
        if (!wr_rst_ni) begin
            block_state[0] <= EMPTY;
            block_state[1] <= EMPTY;
            wr_block       <= 1'b0;
            wr_addr        <= 0;
            full_exists    <= 1'b0;
            full_ptr       <= 1'b0;
        end
        else begin
            // Read side finished the published bank: mark it EMPTY.
            if (done_pulse_wr) begin
                block_state[full_ptr] <= EMPTY;
                full_exists           <= 1'b0;
            end

            // Accept a sample only when the current write bank is EMPTY.
            if (wr_valid_i && (block_state[wr_block] == EMPTY)) begin
                tbuf_ram[wr_block][wr_addr] <= wr_data_i;
                if (wr_addr == N_SAMPLES-1) begin
                    block_state[wr_block] <= FULL;
                    full_exists           <= 1'b1;
                    full_ptr              <= wr_block;
                    wr_block              <= ~wr_block;
                    wr_addr               <= 0;
                end
                else begin
                    wr_addr <= wr_addr + 1'b1;
                end
            end
        end
    end

    assign wr_ready_o = (block_state[wr_block] == EMPTY);

    // ============================================================
    //  Read-side controller (rd_clk_i domain)
    //  Synchronize full_exists/full_ptr from the write domain.
    // ============================================================
    (* ASYNC_REG = "TRUE" *) reg full_ex_s1;
    (* ASYNC_REG = "TRUE" *) reg full_ex_s2;
    (* ASYNC_REG = "TRUE" *) reg full_ptr_s1;
    (* ASYNC_REG = "TRUE" *) reg full_ptr_s2;

    always @(posedge rd_clk_i or negedge rd_rst_ni) begin
        if (!rd_rst_ni) begin
            full_ex_s1  <= 1'b0;
            full_ex_s2  <= 1'b0;
            full_ptr_s1 <= 1'b0;
            full_ptr_s2 <= 1'b0;
        end
        else begin
            full_ex_s1  <= full_exists;
            full_ex_s2  <= full_ex_s1;
            full_ptr_s1 <= full_ptr;
            full_ptr_s2 <= full_ptr_s1;
        end
    end

    assign rd_valid_o = full_ex_s2;
    wire rd_block = full_ptr_s2;

    // ============================================================
    //  Data path: FFT read + waveform read
    // ============================================================
    reg [WIDTH-1:0] rd_data_r;
    always @(posedge rd_clk_i) begin
        if (rd_req_i)
            rd_data_r <= tbuf_ram[rd_block][rd_addr_i];
    end
    assign rd_data_o = rd_data_r;

    reg [WIDTH-1:0] wf_data_r;
    always @(posedge wf_clk_i) begin
        wf_data_r <= tbuf_ram[full_ptr_s2][wf_addr_i];
    end
    assign wf_data_o = wf_data_r;

endmodule
