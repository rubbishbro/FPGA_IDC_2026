module spectrum_map #(
    parameter N_BARS = 128,
    parameter BIN_W  = 10
) (
    input               clk_i,
    input               rst_ni,

    input       [15:0]  xk_re_i,
    input       [15:0]  xk_im_i,
    input       [9:0]   bin_idx_i,
    input               bin_valid_i,
    input               eoud_i,

    output reg  [6:0]       bar_addr_o,
    output reg  [BIN_W-1:0] bar_w_o,
    output reg  [BIN_W-1:0] ov_w_o,
    output reg              bar_we_o,
    output reg              frame_done_o
);

    localparam logic [2:0] S_ACCUM = 3'd0;
    localparam logic [2:0] S_RANGE = 3'd1;
    localparam logic [2:0] S_SCAN  = 3'd2;
    localparam logic [2:0] S_CMP   = 3'd3;
    localparam logic [2:0] S_WRITE = 3'd4;
    localparam logic [2:0] S_DONE  = 3'd5;

    localparam logic [9:0] SMOOTH_DECAY = 10'd6;

    reg [2:0]  phase;
    reg [6:0]  bar_idx;
    reg [9:0]  scan_bin;
    reg [9:0]  range_end;
    reg [17:0] bar_acc;
    reg [17:0] mag_q;
    reg [9:0]  smooth_val;
    reg [4:0]  peak_msb;
    reg [17:0] frame_peak;
    reg        eoud_r;

    // 512x18 的 bin_mag 和 128x20 的 bar_range 是顺序扫描表，读地址已经
    // 是寄存器输出（S_RANGE/S_SCAN 各等一拍），显式映射到 BSRAM，避免综合
    // 退化成 512:1/128:1 的大选择树。
    (* syn_ramstyle="block_ram" *) reg [17:0] bin_mag [0:511];
    (* syn_ramstyle="block_ram" *) reg [19:0] bar_range [0:N_BARS-1];
    // 小型平滑表固定用寄存器，避免当前 Gowin 将互斥读/写映射成该器件
    // 不支持 WRITE_MODE=2'b10 的单口 BSRAM。保留原有读写时序/数值。
    (* syn_ramstyle="registers" *) reg [9:0] smooth_ram [0:N_BARS-1];

    integer i;
    initial begin
        for (i = 0; i < 512; i = i + 1)
            bin_mag[i] = 18'd0;
        for (i = 0; i < N_BARS; i = i + 1)
            smooth_ram[i] = 10'd0;
        $readmemh("bar2bin.mem", bar_range);
    end

    wire [15:0] re_abs = xk_re_i[15] ? (~xk_re_i + 16'd1) : xk_re_i;
    wire [15:0] im_abs = xk_im_i[15] ? (~xk_im_i + 16'd1) : xk_im_i;
    wire [15:0] mag_big = (re_abs > im_abs) ? re_abs : im_abs;
    wire [15:0] mag_sml = (re_abs > im_abs) ? im_abs : re_abs;
    wire [17:0] mag_in  = {2'b0, mag_big} + {2'b0, mag_sml[15:2]};

    localparam logic [4:0] SPECTRUM_SPAN = 5'd8;
    wire [4:0] bar_msb = msb_of(bar_acc);
    wire [4:0] floor_msb = (peak_msb > SPECTRUM_SPAN) ? (peak_msb - SPECTRUM_SPAN) : 5'd0;
    wire [4:0] level = (bar_msb > floor_msb) ? (bar_msb - floor_msb) : 5'd0;
    wire [10:0] raw_h = level * 6'd60;
    wire [9:0] raw_lim = (raw_h > 11'd479) ? 10'd479 : raw_h[9:0];
    wire [9:0] release_h = (smooth_val > SMOOTH_DECAY) ? (smooth_val - SMOOTH_DECAY) : 10'd0;
    wire [9:0] sm_new = (raw_lim > smooth_val) ? raw_lim : release_h;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            phase        <= S_ACCUM;
            bar_idx      <= 7'd0;
            scan_bin     <= 10'd0;
            range_end    <= 10'd0;
            bar_acc      <= 18'd0;
            mag_q        <= 18'd0;
            smooth_val   <= 10'd0;
            peak_msb     <= 5'd0;
            frame_peak   <= 18'd0;
            eoud_r       <= 1'b0;
            bar_addr_o   <= 7'd0;
            bar_w_o      <= 10'd0;
            ov_w_o       <= 10'd0;
            bar_we_o     <= 1'b0;
            frame_done_o <= 1'b0;
        end
        else begin
            bar_we_o     <= 1'b0;
            frame_done_o <= 1'b0;

            if (eoud_i)
                eoud_r <= 1'b1;
            else
                eoud_r <= 1'b0;

            case (phase)
                S_ACCUM: begin
                    if (bin_valid_i && !bin_idx_i[9]) begin
                        bin_mag[bin_idx_i[8:0]] <= mag_in;
                        if (mag_in > frame_peak)
                            frame_peak <= mag_in;
                    end

                    if (eoud_r) begin
                        peak_msb  <= msb_of(frame_peak);
                        frame_peak <= 18'd0;
                        bar_idx   <= 7'd0;
                        phase     <= S_RANGE;
                    end
                end

                S_RANGE: begin
                    scan_bin   <= bar_range[bar_idx][9:0];
                    range_end  <= bar_range[bar_idx][19:10];
                    bar_acc    <= 18'd0;
                    smooth_val <= smooth_ram[bar_idx];
                    phase      <= S_SCAN;
                end

                S_SCAN: begin
                    mag_q <= bin_mag[scan_bin];
                    phase <= S_CMP;
                end

                S_CMP: begin
                    if (mag_q > bar_acc)
                        bar_acc <= mag_q;

                    if (scan_bin == range_end)
                        phase <= S_WRITE;
                    else begin
                        scan_bin <= scan_bin + 10'd1;
                        phase    <= S_SCAN;
                    end
                end

                S_WRITE: begin
                    bar_addr_o <= bar_idx;
                    bar_w_o    <= sm_new;
                    ov_w_o     <= ov_target(sm_new);
                    bar_we_o   <= 1'b1;
                    smooth_ram[bar_idx] <= sm_new;

                    if (bar_idx == N_BARS - 1)
                        phase <= S_DONE;
                    else begin
                        bar_idx <= bar_idx + 7'd1;
                        phase   <= S_RANGE;
                    end
                end

                S_DONE: begin
                    frame_done_o <= 1'b1;
                    phase        <= S_ACCUM;
                end

                default: phase <= S_ACCUM;
            endcase
        end
    end

    function [4:0] msb_of(input [17:0] x);
        begin
            if (x[17:16])      msb_of = 5'd17;
            else if (x[15])    msb_of = 5'd15;
            else if (x[14])    msb_of = 5'd14;
            else if (x[13])    msb_of = 5'd13;
            else if (x[12])    msb_of = 5'd12;
            else if (x[11])    msb_of = 5'd11;
            else if (x[10])    msb_of = 5'd10;
            else if (x[9])     msb_of = 5'd9;
            else if (x[8])     msb_of = 5'd8;
            else if (x[7])     msb_of = 5'd7;
            else if (x[6])     msb_of = 5'd6;
            else if (x[5])     msb_of = 5'd5;
            else if (x[4])     msb_of = 5'd4;
            else if (x[3])     msb_of = 5'd3;
            else if (x[2])     msb_of = 5'd2;
            else if (x[1])     msb_of = 5'd1;
            else               msb_of = 5'd0;
        end
    endfunction

    function [9:0] ov_target(input [9:0] h);
        reg [11:0] t;
        begin
            t = h + (h >> 2) - (h >> 5);
            ov_target = (t > 12'd479) ? 10'd479 : t[9:0];
        end
    endfunction

endmodule
