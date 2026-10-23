// -----------------------------------------------------------------------------
// c_seed_loader.sv -- 从 seed_rom 顺序读出 n_modes 个 seed，写 C 引擎
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module c_seed_loader #(
    parameter int NUM_SLOTS  = 16,
    parameter int N_MODES    = 48,
    parameter int SEED_DEPTH = 1152,
    parameter     SEED_FILE  = "",
    parameter int VW         = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW         = (N_MODES < 2) ? 1 : $clog2(N_MODES + 1),
    parameter int AW         = (SEED_DEPTH < 2) ? 1 : $clog2(SEED_DEPTH)
) (
    input  logic          clk,
    input  logic          rst_n,

    input  logic          start,
    input  logic [VW-1:0] voice,
    input  logic [MW-1:0] n_modes,
    input  logic [15:0]   seed_base,

    output logic          seed_we,
    output logic [VW-1:0] seed_voice,
    output logic [MW-1:0] seed_mode,
    output logic [63:0]   seed_data,

    output logic          busy,
    output logic          done
);

    typedef enum logic [1:0] { S_IDLE, S_RD, S_WR, S_DONE } state_t;
    state_t state;

    logic [VW-1:0] voice_r;
    logic [MW-1:0] cnt, n_r;
    logic [15:0]   base_r;
    logic          done_r;

    logic [AW-1:0] rom_addr;
    logic [63:0]   rom_data;
    assign rom_addr = base_r[AW-1:0] + AW'(cnt);

    seed_rom #(.DEPTH(SEED_DEPTH), .AW(AW), .FILE(SEED_FILE)) u_rom (
        .clk(clk), .addr(rom_addr), .data(rom_data)
    );

    assign seed_we    = (state == S_WR);
    assign seed_voice = voice_r;
    assign seed_mode  = cnt;
    assign seed_data  = rom_data;
    assign busy       = (state != S_IDLE);
    assign done       = done_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            voice_r <= {VW{1'b0}};
            base_r  <= 16'd0;
            cnt     <= {MW{1'b0}};
            n_r     <= {MW{1'b0}};
            done_r  <= 1'b0;
        end else begin
            done_r <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        voice_r <= voice;
                        base_r  <= seed_base;
                        n_r     <= n_modes;
                        cnt     <= {MW{1'b0}};
                        if (n_modes == {MW{1'b0}}) begin
                            done_r <= 1'b1;
                            state  <= S_IDLE;
                        end else begin
                            state <= S_RD;
                        end
                    end
                end

                S_RD: begin
                    state <= S_WR;
                end

                S_WR: begin
                    if ((cnt + 1'b1) >= n_r) begin
                        done_r <= 1'b1;
                        state  <= S_IDLE;
                    end else begin
                        cnt   <= cnt + 1'b1;
                        state <= S_RD;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
