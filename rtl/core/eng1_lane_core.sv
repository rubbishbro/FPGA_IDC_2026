// -----------------------------------------------------------------------------
// eng1_lane_core.sv -- ENG1 的纯计算 lane（内存中心版）
//
// 与 poly_modal_lane 的区别：
//   * 不再持有 RAM / state_valid / a1 shadow / clear / seed；
//   * 每次 mode 从 modal_ram 读一条 9×32 记录，算完把 y1/y2 写回；
//   * 4 个 lane 各处理 mode % LANES == LANE 的局部 mode。
//
// 算术与 poly_modal_lane 对齐：
//   G  = Q2.24 (26-bit) sign-extended 到 32
//   a1 = Q2.20 (22-bit) sign-extended，<<4 到 Q2.24
//   a2 = UQ0.24 (24-bit)，零扩展
//   y1/y2 = Q2.30 signed 32
//   ynew = clamp((G*x - a1*y1 - a2*y2 + 2^23) >>> 24)
//
// 每 mode 的时序（单乘法器）：
//   S_REQ  : 发读地址
//   S_CAP  : 捕获记录（下一拍数据）
//   S_M1   : prod <= G*x
//   S_M2   : acc  <= prod(G*x)；prod <= a1*y1
//   S_M3   : acc  <= acc - prod(a1*y1)；prod <= a2*y2
//   S_FIN  : acc  <= acc - prod(a2*y2)；算 ynew、写状态、累计 ps
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module eng1_lane_core #(
    parameter int NUM_SLOTS      = 16,
    parameter int N_MODES        = 48,
    parameter int LANES          = 4,
    parameter int LANE           = 0,
    parameter int LOCAL          = (N_MODES + LANES - 1) / LANES,
    parameter int VW             = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW             = (N_MODES < 2) ? 1 : $clog2(N_MODES),
    parameter int AW             = (NUM_SLOTS * LOCAL < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL),
    parameter int IW             = (LOCAL < 2) ? 1 : $clog2(LOCAL + 1),
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int REC_W          = 288
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // 单 voice 作业
    input  logic                  start,
    input  logic [MW-1:0]         n_modes,
    input  logic signed [31:0]    x_in,
    input  logic [VW-1:0]         voice,

    // RAM 读口（同步读，1 拍）
    output logic                  rd_re,
    output logic [AW-1:0]         rd_addr,
    input  logic [REC_W-1:0]      rd_data,

    // RAM 状态写口
    output logic                  st_we,
    output logic [AW-1:0]         st_addr,
    output logic [63:0]           st_data,     // {y2_new, y1_new}

    output logic                  done,
    output logic                  busy,

    output logic                  commit_valid,
    output logic [VW-1:0]         commit_voice,
    output logic [MW-1:0]         commit_mode,
    output logic signed [31:0]    commit_y1,
    output logic signed [31:0]    commit_y2,
    output logic                  commit_sat,

    output logic signed [63:0]    partial_sum,
    output logic [5:0]            sat_count
);

    localparam logic [3:0] S_IDLE  = 4'd0,
                           S_REQ   = 4'd1,
                           S_CAP   = 4'd2,
                           S_M1    = 4'd3,
                           S_M2    = 4'd4,
                           S_M3    = 4'd5,
                           S_FIN1  = 4'd6,
                           S_FIN2A = 4'd7,
                           S_FIN2B = 4'd8,
                           S_FIN3  = 4'd9,
                           S_DONE  = 4'd10;

    localparam logic signed [63:0] YMIN = -64'sd2147483648;
    localparam logic signed [63:0] YMAX =  64'sd2147483647;
    localparam logic signed [63:0] ROUND = 64'sd8388608;

    logic [3:0]  st;
    logic [MW-1:0] lc;
    logic [AW-1:0] mi;
    logic [AW-1:0] addr_r, voice_base_r;
    logic [VW-1:0] voice_r;
    logic signed [31:0] x_r;

    // 记录字段（S_CAP 捕获）
    logic signed [31:0] g_c, a1_c, a2_c, y1_c, y2_c;

    // 单乘法器操作数
    logic signed [31:0] csel, osel;
    logic signed [63:0] prod_r;
    logic signed [63:0] acc;
    logic signed [63:0] ps;
    logic [5:0]         sat;

    logic signed [63:0] diff;
    logic signed [63:0] shifted;
    logic               sat_now;
    logic signed [31:0] ynew;
    logic signed [31:0] ynew_r;
    logic               sat_r;

    // 局部 mode 数量：n_modes 内满足 k%LANES==LANE 的个数
    function automatic [MW-1:0] count_for(input [MW-1:0] nm);
        int v;
        begin
            if (nm > LANE) v = (nm - LANE + LANES - 1) / LANES;
            else           v = 0;
            count_for = v[MW-1:0];
        end
    endfunction

    // 记录字段取法（字段 0..4）
    wire signed [31:0] rec_g   = $signed(rd_data[31:0]);
    wire signed [31:0] rec_a1  = $signed(rd_data[63:32]) <<< 4;
    wire signed [31:0] rec_a2  = $signed({8'b0, rd_data[87:64]});
    wire signed [31:0] rec_y1  = $signed(rd_data[127:96]);
    wire signed [31:0] rec_y2  = $signed(rd_data[159:128]);

    assign rd_re   = (st == S_REQ);
    assign rd_addr = voice_r * LOCAL + mi[AW-1:0];
    assign st_we   = (st == S_FIN3);
    assign st_addr = voice_r * LOCAL + mi[AW-1:0];
    assign st_data = {y1_c, ynew_r};          // {y2_new, y1_new}

    assign done   = (st == S_DONE);
    assign busy   = (st != S_IDLE) && (st != S_DONE);

    logic [VW-1:0] commit_voice_r;
    logic [MW-1:0] commit_mode_r;
    logic signed [31:0] commit_y1_r, commit_y2_r;
    logic commit_sat_r;

    assign commit_voice = commit_voice_r;
    assign commit_mode  = commit_mode_r;
    assign commit_y1    = commit_y1_r;
    assign commit_y2    = commit_y2_r;
    assign commit_sat   = commit_sat_r;

    assign partial_sum = ps;
    assign sat_count   = sat;

    // 单乘法器：按状态选操作数
    always_comb begin
        csel = 32'sd0;
        osel = 32'sd0;
        case (st)
            S_M1: begin csel = g_c;  osel = x_r;  end
            S_M2: begin csel = a1_c; osel = y1_c; end
            S_M3: begin csel = a2_c; osel = y2_c; end
            default: begin csel = 32'sd0; osel = 32'sd0; end
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n)
            prod_r <= 64'sd0;
        else if ((st == S_M1) && (SKIP_ZERO_INPUT != 0) && (x_r == 32'sd0))
            prod_r <= 64'sd0;
        else if ((st == S_M1) || (st == S_M2) || (st == S_M3))
            prod_r <= csel * osel;
    end

    // S_FIN2A: 只做 diff + ROUND；S_FIN2B: 移位/比较/饱和。
    logic signed [63:0] rounded;
    always_comb begin
        shifted   = rounded >>> 24;
        sat_now   = (shifted > YMAX) || (shifted < YMIN);
        if (shifted > YMAX)       ynew = 32'sh7FFFFFFF;
        else if (shifted < YMIN)  ynew = 32'sh80000000;
        else                      ynew = shifted[31:0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st           <= S_IDLE;
            lc           <= {MW{1'b0}};
            mi           <= {AW{1'b0}};
            addr_r       <= {AW{1'b0}};
            voice_base_r <= {AW{1'b0}};
            voice_r      <= {VW{1'b0}};
            x_r          <= 32'sd0;
            g_c          <= 32'sd0;
            a1_c         <= 32'sd0;
            a2_c         <= 32'sd0;
            y1_c         <= 32'sd0;
            y2_c         <= 32'sd0;
            acc          <= 64'sd0;
            ps           <= 64'sd0;
            diff         <= 64'sd0;
            ynew_r       <= 32'sd0;
            sat_r        <= 1'b0;
            sat          <= 6'd0;
            commit_valid <= 1'b0;
            commit_voice_r <= {VW{1'b0}};
            commit_mode_r  <= {MW{1'b0}};
            commit_y1_r    <= 32'sd0;
            commit_y2_r    <= 32'sd0;
            commit_sat_r   <= 1'b0;
        end else begin
            commit_valid <= 1'b0;

            case (st)
                S_IDLE, S_DONE: begin
                    if (start) begin
                        lc      <= count_for(n_modes);
                        mi      <= {AW{1'b0}};
                        voice_base_r <= voice * LOCAL;
                        addr_r       <= voice * LOCAL;
                        commit_mode_r <= LANE[MW-1:0];
                        voice_r <= voice;
                        x_r     <= x_in;
                        ps      <= 64'sd0;
                        sat     <= 6'd0;
                        acc     <= 64'sd0;
                        st      <= (count_for(n_modes) == {MW{1'b0}}) ? S_DONE : S_REQ;
                    end
                end

                S_REQ: begin
                    // 第一个 mode 的提交值已在 start 设为 LANE；
                    // 从第二个 mode 起，每进一次 S_REQ 前进 LANES。
                    if (mi != {AW{1'b0}})
                        commit_mode_r <= commit_mode_r + LANES[MW-1:0];
                    st <= S_CAP;
                end

                S_CAP: begin
                    g_c  <= rec_g;
                    a1_c <= rec_a1;
                    a2_c <= rec_a2;
                    y1_c <= rec_y1;
                    y2_c <= rec_y2;
                    st   <= S_M1;
                end

                S_M1: begin
                    st <= S_M2;
                end

                S_M2: begin
                    acc <= prod_r;          // G*x
                    st  <= S_M3;
                end

                S_M3: begin
                    acc <= acc - prod_r;    // -a1*y1
                    st  <= S_FIN1;
                end

                S_FIN1: begin
                    diff <= acc - prod_r;   // 最终 64-bit 减法
                    st   <= S_FIN2A;
                end

                S_FIN2A: begin
                    rounded <= diff + ROUND; // 只做 64-bit 舍入加法
                    st      <= S_FIN2B;
                end

                S_FIN2B: begin
                    ynew_r <= ynew;         // 移位/比较/饱和
                    sat_r  <= sat_now;
                    st     <= S_FIN3;
                end

                S_FIN3: begin
                    ps <= ps + {{32{ynew_r[31]}}, ynew_r};
                    if (sat_r) sat <= sat + 6'd1;

                    commit_valid   <= 1'b1;
                    commit_voice_r <= voice_r;
                    commit_y1_r    <= ynew_r;
                    commit_y2_r    <= y1_c;
                    commit_sat_r   <= sat_r;

                    if ((mi + 1'b1) >= lc) begin
                        st <= S_DONE;
                    end else begin
                        mi <= mi + 1'b1;
                        addr_r <= addr_r + 1'b1;
                        st <= S_REQ;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
