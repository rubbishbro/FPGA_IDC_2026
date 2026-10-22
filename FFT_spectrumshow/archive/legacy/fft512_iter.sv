// -----------------------------------------------------------------------------
// fft512_iter.sv -- 512-point radix-2 DIF FFT, single butterfly, clock enable
//
// - Natural-order input, natural-order output (bit-reversed RAM read).
// - One complex butterfly at a time; 4 cycles per butterfly.
// - Intended for spectrum visualization, not precision measurement.
// - All sequential logic advances only when ce == 1.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module fft512_iter #(
    parameter int N     = 512,
    parameter int LOGN  = 9,
    parameter int IN_W  = 16,
    parameter int IW    = 26,
    parameter int TW_W  = 16
)(
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 ce,

    input  logic                 start,
    input  logic signed [IN_W-1:0] x_re,
    input  logic                 x_valid,
    output logic                 ready,

    output logic signed [IW-1:0] y_re,
    output logic signed [IW-1:0] y_im,
    output logic [LOGN-1:0]      y_idx,
    output logic                 y_valid,

    output logic                 busy,
    output logic                 done
);

    localparam int AW  = LOGN;
    localparam int DW  = 2 * IW;
    localparam int TWD = 2 * TW_W;

    // ------------------------------------------------------------------
    // Data RAM: 512 complex words, one read port + one write port.
    // ------------------------------------------------------------------
    logic [DW-1:0] mem [0:N-1];
    logic [DW-1:0] rd_data;
    logic [AW-1:0] raddr;
    logic [AW-1:0] waddr;
    logic [DW-1:0] wdata;
    logic          we;

    always_ff @(posedge clk) begin
        if (ce) begin
            if (we)
                mem[waddr] <= wdata;
            rd_data <= mem[raddr];
        end
    end

    // ------------------------------------------------------------------
    // Twiddle ROM: W_N^k for k = 0 .. N/2-1, packed {re[15:0], im[15:0]}.
    // ------------------------------------------------------------------
    logic [TWD-1:0] tw_rom [0:N/2-1];
    logic [TWD-1:0] tw_word;
    logic [AW-1:0]  tw_addr;

    initial begin
        $readmemh("twiddle512.mem", tw_rom);
    end

    always_ff @(posedge clk) begin
        if (ce)
            tw_word <= tw_rom[tw_addr];
    end

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,
        S_LOAD,
        S_RD_A,
        S_RD_B,
        S_RD_B2,
        S_MUL,
        S_WR,
        S_GAP,
        S_OUT,
        S_OUT_WAIT,
        S_OUT_WAIT2,
        S_DONE
    } state_t;

    state_t state;

    logic [3:0]  stage;
    logic [AW-1:0] group;
    logic [AW-1:0] k;
    logic [AW-1:0] load_cnt;
    logic [AW-1:0] out_cnt;
    logic [AW-1:0] i_r;
    logic [AW-1:0] j_r;
    logic [AW-1:0] m_r;
    logic [AW-1:0] y_idx_r;
    logic          to_out;

    logic [9:0] m10;
    logic [9:0] base10;
    logic [9:0] i10;
    logic [9:0] j10;
    logic [AW-1:0] tw9;
    logic [9:0] groups_m1;

    always_comb begin
        m10       = 10'd512 >> (stage + 1);
        base10    = group * (10'd512 >> stage);
        i10       = base10 + k;
        j10       = i10 + m10;
        tw9       = k << stage;
        groups_m1 = (10'd1 << stage) - 10'd1;
    end

    logic signed [IW-1:0] x_re_ext;
    assign x_re_ext = {{(IW-IN_W){x_re[IN_W-1]}}, x_re};

    // ------------------------------------------------------------------
    // Butterfly datapath
    // ------------------------------------------------------------------
    logic signed [IW-1:0] a_r;
    logic signed [IW-1:0] a_im_r;
    logic signed [IW-1:0] a_re;
    logic signed [IW-1:0] a_im;
    logic signed [IW-1:0] b_re;
    logic signed [IW-1:0] b_im;

    assign a_re = a_r;
    assign a_im = a_im_r;
    assign b_re = rd_data[2*IW-1:IW];
    assign b_im = rd_data[IW-1:0];

    logic signed [TW_W-1:0] tw_re;
    logic signed [TW_W-1:0] tw_im;
    assign tw_re = tw_word[2*TW_W-1:TW_W];
    assign tw_im = tw_word[TW_W-1:0];

    logic signed [IW:0] sum_re;
    logic signed [IW:0] sum_im;
    logic signed [IW:0] diff_re;
    logic signed [IW:0] diff_im;

    always_comb begin
        sum_re  = a_re + b_re;
        sum_im  = a_im + b_im;
        diff_re = a_re - b_re;
        diff_im = a_im - b_im;
    end

    logic signed [47:0] p_rr;
    logic signed [47:0] p_ii;
    logic signed [47:0] p_ri;
    logic signed [47:0] p_ir;

    logic signed [IW-1:0] sum_sat_re;
    logic signed [IW-1:0] sum_sat_im;

    function automatic logic signed [IW-1:0] sat(input logic signed [47:0] v);
        if (v > 48'sd33554431)       // 2^25 - 1
            sat = 26'sh1FFFFFF;
        else if (v < -48'sd33554432) // -2^25
            sat = 26'sh2000000;
        else
            sat = v[IW-1:0];
    endfunction

    assign sum_sat_re = sat({{21{sum_re[IW]}}, sum_re});
    assign sum_sat_im = sat({{21{sum_im[IW]}}, sum_im});

    logic signed [47:0] prod_re_c;
    logic signed [47:0] prod_im_c;

    always_comb begin
        prod_re_c = (p_rr - p_ii + 48'sd16384) >>> 15;
        prod_im_c = (p_ri + p_ir + 48'sd16384) >>> 15;
    end

    function automatic logic [AW-1:0] bitrev(input logic [AW-1:0] v);
        integer idx;
        begin
            for (idx = 0; idx < AW; idx = idx + 1)
                bitrev[idx] = v[AW-1-idx];
        end
    endfunction

    // ------------------------------------------------------------------
    // Main sequential FSM
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            stage     <= 4'd0;
            group     <= '0;
            k         <= '0;
            load_cnt  <= '0;
            out_cnt   <= '0;
            i_r       <= '0;
            j_r       <= '0;
            m_r       <= '0;
            y_idx_r   <= '0;
            to_out    <= 1'b0;
            raddr     <= '0;
            waddr     <= '0;
            wdata     <= '0;
            we        <= 1'b0;
            tw_addr   <= '0;
            y_re      <= '0;
            y_im      <= '0;
            y_idx     <= '0;
            y_valid   <= 1'b0;
            done      <= 1'b0;
            a_r       <= '0;
            a_im_r    <= '0;
            p_rr      <= '0;
            p_ii      <= '0;
            p_ri      <= '0;
            p_ir      <= '0;
        end
        else if (ce) begin
            done    <= 1'b0;
            y_valid <= 1'b0;
            we      <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state    <= S_LOAD;
                        load_cnt <= '0;
                        stage    <= 4'd0;
                        group    <= '0;
                        k        <= '0;
                        to_out   <= 1'b0;
                    end
                end

                S_LOAD: begin
                    if (x_valid) begin
                        we      <= 1'b1;
                        waddr   <= load_cnt;
                        wdata   <= {x_re_ext, {IW{1'b0}}};
                        if (load_cnt == N-1) begin
                            load_cnt <= '0;
                            stage    <= 4'd0;
                            group    <= '0;
                            k        <= '0;
                            to_out   <= 1'b0;
                            state    <= S_RD_A;
                        end
                        else begin
                            load_cnt <= load_cnt + 1'b1;
                        end
                    end
                end

                S_RD_A: begin
                    i_r     <= i10[AW-1:0];
                    j_r     <= j10[AW-1:0];
                    m_r     <= m10[AW-1:0];
                    raddr   <= i10[AW-1:0];
                    tw_addr <= tw9;
                    state   <= S_RD_B;
                end

                S_RD_B: begin
                    raddr <= j_r;
                    state <= S_RD_B2;
                end

                S_RD_B2: begin
                    // mem[i] is now valid on rd_data; twiddle is valid too.
                    a_r    <= rd_data[2*IW-1:IW];
                    a_im_r <= rd_data[IW-1:0];
                    state  <= S_MUL;
                end

                S_MUL: begin
                    // a_r/a_im_r hold mem[i]; rd_data now holds mem[j].
                    p_rr  <= diff_re * tw_re;
                    p_ii  <= diff_im * tw_im;
                    p_ri  <= diff_re * tw_im;
                    p_ir  <= diff_im * tw_re;

                    waddr <= i_r;
                    wdata <= {sum_sat_re, sum_sat_im};
                    we    <= 1'b1;
                    state <= S_WR;
                end

                S_WR: begin
                    waddr <= j_r;
                    wdata <= {sat(prod_re_c), sat(prod_im_c)};
                    we    <= 1'b1;

                    if (k == m_r - 1'b1) begin
                        k <= '0;
                        if (group == groups_m1[AW-1:0]) begin
                            group <= '0;
                            if (stage == LOGN-1) begin
                                to_out <= 1'b1;
                                state  <= S_GAP;
                            end
                            else begin
                                stage <= stage + 1'b1;
                                state <= S_GAP;
                            end
                        end
                        else begin
                            group <= group + 1'b1;
                            state <= S_RD_A;
                        end
                    end
                    else begin
                        k     <= k + 1'b1;
                        state <= S_RD_A;
                    end
                end

                S_GAP: begin
                    if (to_out) begin
                        to_out  <= 1'b0;
                        out_cnt <= '0;
                        state   <= S_OUT;
                    end
                    else begin
                        state <= S_RD_A;
                    end
                end

                S_OUT: begin
                    raddr   <= bitrev(out_cnt);
                    y_idx_r <= out_cnt;
                    state   <= S_OUT_WAIT;
                end

                S_OUT_WAIT: begin
                    state <= S_OUT_WAIT2;
                end

                S_OUT_WAIT2: begin
                    y_re    <= rd_data[2*IW-1:IW];
                    y_im    <= rd_data[IW-1:0];
                    y_idx   <= y_idx_r;
                    y_valid <= 1'b1;
                    if (out_cnt == N-1) begin
                        out_cnt <= '0;
                        state   <= S_DONE;
                    end
                    else begin
                        out_cnt <= out_cnt + 1'b1;
                        state   <= S_OUT;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign ready = (state == S_IDLE) || (state == S_LOAD);
    assign busy  = (state != S_IDLE);

endmodule
