// -----------------------------------------------------------------------------
// b_a1_engine.sv -- B 的 a1 刷新引擎
//
// θ 是固定 ROM（b_theta.mem，与 core 同布局）；每 voice 一个 theta_base 寄存器。
// 引擎只在 bank idle 时工作：
//   READ  : 读 bank 的 72-bit 系数字（a1_nom/a2）
//   WAIT  : θ ROM[theta_base+mode] -> b_a1_refresh
//   WRITE : 写 bank 的 a1 shadow（a1_we）
// 全量 32×48 个 mode，1 mode/2~3 拍；sample 来则 a1_ready=0，引擎暂停。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module b_a1_engine #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES = 48,
    parameter int COEFF_DEPTH = 5483,
    parameter int THETA_DEPTH = COEFF_DEPTH,
    parameter THETA_FILE = "",
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1)
) (
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic [NUM_VOICES*2-1:0] class_vec,
    input  logic [NUM_VOICES*16-1:0] theta_base_vec,
    input  logic [15:0]            ratio,
    input  logic                   enable,

    // bank 系数只读
    output logic                   rd_en,
    output logic [VW-1:0]          rd_voice,
    output logic [MW-1:0]          rd_mode,
    input  logic [71:0]            rd_data,
    input  logic                   rd_valid,
    input  logic                   bank_ready,

    // bank a1 shadow 写
    output logic                   a1_we,
    output logic [VW-1:0]          a1_voice,
    output logic [MW-1:0]          a1_mode,
    output logic [21:0]            a1_data,
    input  logic                   a1_ready,

    output logic                   active,
    output logic                   done
);

    logic done_r;

    logic [15:0] theta_rom [0:THETA_DEPTH-1];
    initial if (THETA_FILE != "") $readmemh(THETA_FILE, theta_rom);

    localparam logic [1:0] S_IDLE = 2'd0, S_READ = 2'd1, S_WAIT = 2'd2, S_WRITE = 2'd3;

    logic [1:0]    st;
    logic [VW-1:0] voice;
    logic [MW-1:0] mode;
    logic          a1_new_r;
    logic signed [21:0] a1_new;

    wire [1:0] cls = class_vec[voice*2 +: 2];
    wire [15:0] theta_base = theta_base_vec[voice*16 +: 16];
    wire [15:0] theta_q = (theta_base + 16'(mode) < THETA_DEPTH) ?
                          theta_rom[theta_base + 16'(mode)] : 16'd0;
    wire signed [21:0] a1_nom = $signed(rd_data[21:0]);
    wire [23:0] a2 = rd_data[45:22];

    b_a1_refresh u_ref (
        .a1_nom(a1_nom), .a2(a2), .theta(theta_q), .ratio(ratio), .a1_new(a1_new)
    );

    assign rd_en    = (st == S_READ) && bank_ready;
    assign rd_voice = voice;
    assign rd_mode  = mode;
    assign a1_we    = (st == S_WRITE);
    assign a1_voice = voice;
    assign a1_mode  = mode;
    assign a1_data  = a1_new_r;
    assign active   = (st != S_IDLE);
    assign done     = done_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            voice    <= {VW{1'b0}};
            mode     <= {MW{1'b0}};
            a1_new_r <= 22'sd0;
            done_r   <= 1'b0;
        end else begin
            done_r <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (enable) begin
                        voice <= {VW{1'b0}};
                        mode  <= {MW{1'b0}};
                        st    <= S_READ;
                    end
                end

                S_READ: begin
                    if (cls != 2'd1) begin
                        // 非 B 声部不刷新，直接跳过
                        if (mode == (N_MODES - 1)) begin
                            mode <= {MW{1'b0}};
                            if (voice == (NUM_VOICES - 1)) begin
                                voice <= {VW{1'b0}};
                                st    <= S_IDLE;
                                done_r <= 1'b1;
                            end else begin
                                voice <= voice + VW'(1);
                            end
                        end else begin
                            mode <= mode + MW'(1);
                        end
                    end else if (bank_ready) begin
                        st <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (rd_valid) begin
                        a1_new_r <= a1_new;
                        st       <= S_WRITE;
                    end
                end

                default: begin // S_WRITE
                    if (a1_ready) begin
                        if (mode == (N_MODES - 1)) begin
                            mode <= {MW{1'b0}};
                            if (voice == (NUM_VOICES - 1)) begin
                                voice <= {VW{1'b0}};
                                st    <= S_IDLE;
                                done_r <= 1'b1;
                            end else begin
                                voice <= voice + VW'(1);
                                st    <= S_READ;
                            end
                        end else begin
                            mode <= mode + MW'(1);
                            st   <= S_READ;
                        end
                    end
                end
            endcase
        end
    end

endmodule
