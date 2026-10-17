// -----------------------------------------------------------------------------
// modal_lane.sv -- modal bank 的一个 TDM lane（module 2A）。
//
// 一个共享的 26x32 signed 逻辑乘法器，一个同步读单端口
// 72-bit 工作缓存，II = 3 modes。
//
// 算术契约（rtl/DECISIONS.md C，rtl/module2A_design.md 第 3 节）：
//   G   Q2.24 signed   26 bit
//   a1  Q2.20 signed   22 bit  -> 符号扩展，<<4 -> 26-bit Q2.24
//   a2  UQ0.24 unsigned 24 bit -> 零扩展 -> 26-bit
//   x / y1 / y2  Q2.30 signed 32 bit
//   乘积 signed 58 bit；累加器 64 bit
//   acc = G*x - (a1<<4)*y1 - a2*y2
//   ynew = clamp((acc + 2^23) >>> 24, -2^31, 2^31-1)
//
// 每个 lane 的存储：mem[2*j] = 72-bit 系数 word，mem[2*j+1] = 状态
// {8'b0, y2, y1}。每时钟一次访问：config 写、系数读、状态读、状态写
// 互斥。RAM 数组从不 reset；逐 lane 的 state_valid 位图用 (0,0) 屏蔽
// 未初始化的内容。
//
// 流水线（周期表见 delivery report）：
//   phase 0 : 读取 mode mi 的系数
//   phase 1 : 读取 mode mi 的状态，呈现 mode mi 的 G*x
//   phase 2 : 呈现 mode mi 的 a1*y1，finalise mode mi-1，写 mode mi-2
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module modal_lane #(
    parameter int N_MODES = 48,
    parameter int LANE = 0,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int MW = $clog2(N_MODES + 1),                       // 全局 mode id 宽度
    parameter int LOCAL_MODES = (N_MODES + 3) / 4,               // 每个 lane 的 slot 数
    parameter int ADDRW = ($clog2(2 * LOCAL_MODES) < 1) ? 1 : $clog2(2 * LOCAL_MODES),
    parameter int IDXW = (LOCAL_MODES > 1) ? $clog2(LOCAL_MODES) : 1
) (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               start,        // 单周期帧启动脉冲
    input  logic [MW-1:0]      n_modes,      // 帧的全局 mode 数量
    input  logic signed [31:0] x_in,         // 帧共享 excitation

    input  logic               clear,        // 清除逻辑状态（仅空闲时）

    input  logic               cfg_we,       // 对该 lane 的配置写入
    input  logic [ADDRW-1:0]   cfg_addr,
    input  logic [71:0]        cfg_wdata,

    output logic               done,
    output logic [MW-1:0]      commit_mode,
    output logic signed [31:0] commit_y1,
    output logic signed [31:0] commit_y2,
    output logic               commit_sat,
    output logic               commit_valid,
    output logic signed [63:0] partial_sum,
    output logic [5:0]         sat_count
);

    localparam logic signed [63:0] YMIN = -64'sd2147483648;
    localparam logic signed [63:0] YMAX =  64'sd2147483647;
    localparam logic signed [63:0] ROUND = 64'sd8388608;   // 2^23

    // ------------------------------------------------------------------
    // 逐 lane mode 数量：全局 mode k 映射到 lane k%4，local k/4
    // ------------------------------------------------------------------
    function automatic [MW-1:0] count_for(input [MW-1:0] nm);
        integer v;
        begin
            if (nm > LANE) v = (nm - LANE + 3) >> 2;
            else           v = 0;
            count_for = v[MW-1:0];
        end
    endfunction

    // ------------------------------------------------------------------
    // 单端口 72-bit 工作缓存（read-first），从不 reset。
    // 只分配该 lane 能拥有的 LOCAL_MODES 个 slot。
    // ------------------------------------------------------------------
    logic [71:0]           mem [0:2*LOCAL_MODES-1];
    logic [71:0]           rdata;
    logic [ADDRW-1:0]      addr;
    logic                  we;
    logic [71:0]           wdata;

    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        rdata <= mem[addr];
    end

    // ------------------------------------------------------------------
    // 状态
    // ------------------------------------------------------------------
    localparam logic [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;

    logic [1:0]          st;
    logic [1:0]          ph;
    logic [7:0]          mi;
    logic [MW-1:0]       lc;             // 锁存的逐 lane 数量
    logic signed [31:0]  x_r;

    logic [LOCAL_MODES-1:0] state_valid;   // 逐 lane local-mode 位图
    logic signed [63:0]  acc, ps;
    logic signed [57:0]  prod_r;
    logic [5:0]          sat;

    logic signed [25:0]  ctx_a1, ctx_a2;
    logic signed [31:0]  ctx_y2, ctx_oldy1;

    logic                pend_valid;
    logic [MW-1:0]       pend_local;
    logic signed [31:0]  pend_ynew, pend_oldy1;
    logic                pend_sat;

    // ------------------------------------------------------------------
    // 乘法器操作数选择（一个逻辑乘法器）
    // ------------------------------------------------------------------
    // 为位图钳位的 local-mode 索引（绝不越界选择）
    wire [IDXW-1:0] mi_idx   = (mi < LOCAL_MODES) ? mi[IDXW-1:0] : {IDXW{1'b0}};
    wire [IDXW-1:0] pend_idx = (pend_local < LOCAL_MODES) ? pend_local[IDXW-1:0]
                                                          : {IDXW{1'b0}};

    wire signed [31:0] y1_use = ((st == S_RUN) && (mi < lc) &&
                                 state_valid[mi_idx]) ? $signed(rdata[31:0])
                                                      : 32'sd0;
    wire signed [31:0] y2_use = ((st == S_RUN) && (mi < lc) &&
                                 state_valid[mi_idx]) ? $signed(rdata[63:32])
                                                      : 32'sd0;

    logic signed [25:0] csel;
    logic signed [31:0] osel;
    always_comb begin
        csel = 26'sd0;
        osel = 32'sd0;
        if (st == S_RUN) begin
            case (ph)
                2'd1: if (mi < lc) begin        // G * x  （rdata = 系数）
                    csel = $signed(rdata[71:46]);
                    osel = x_r;
                end
                2'd2: if (mi < lc) begin        // a1 * y1（rdata = 状态）
                    csel = ctx_a1;
                    osel = $signed(y1_use);
                end
                default: if ((mi >= 8'd1) && (mi <= lc)) begin
                    csel = ctx_a2;              // a2 * y2（mi-1 的上下文）
                    osel = ctx_y2;
                end
            endcase
        end
    end

    // SKIP_ZERO_INPUT：当帧输入为零时显式旁路 G*x 乘积寄存器。
    // 唯一的乘法点保持不变；只有该 slot 的结果被强制为零
    // （无操作数 hack，无时序变化）。
    wire skip_g_slot = (SKIP_ZERO_INPUT != 0) && (st == S_RUN) &&
                       (ph == 2'd1) && (mi < lc) && (x_r == 32'sd0);

    always_ff @(posedge clk) begin
        if (!rst_n)               prod_r <= 58'sd0;
        else if (skip_g_slot)     prod_r <= 58'sd0;
        else                      prod_r <= csel * osel;  // signed 58-bit 乘积
    end

    wire signed [63:0] prod64 = {{6{prod_r[57]}}, prod_r};

    // 为乘积刚完成的 mode 执行 finalise 算术
    wire signed [63:0] shifted = (acc + ROUND) >>> 24;
    wire               sat_now = (shifted > YMAX) || (shifted < YMIN);
    logic signed [31:0] ynew;
    always_comb begin
        if (shifted > YMAX)      ynew = 32'sh7FFFFFFF;
        else if (shifted < YMIN) ynew = 32'sh80000000;
        else                     ynew = shifted[31:0];
    end

    // ------------------------------------------------------------------
    // phase/mode 控制
    // ------------------------------------------------------------------
    wire finalize_en = (st == S_RUN) && (ph == 2'd2) && (mi >= 8'd1) && (mi <= lc);
    wire write_en    = (st == S_RUN) && (ph == 2'd2) && pend_valid;
    wire last_cycle  = (st == S_RUN) && (ph == 2'd2) && (mi == (lc + 8'd1));

    // run 端口访问。先形成全宽 2*local(+1)，然后取低 ADDRW 位；
    // 不对更窄的信号做 part-select。
    logic              run_we;
    logic [ADDRW-1:0]  run_addr;
    logic [71:0]       run_wdata;
    logic [MW:0]       run_addr_full;
    always_comb begin
        run_we        = 1'b0;
        run_addr      = {ADDRW{1'b0}};
        run_wdata     = 72'd0;
        run_addr_full = {(MW + 1){1'b0}};
        if (st == S_RUN) begin
            case (ph)
                2'd0: begin
                    run_addr_full = {mi[MW-1:0], 1'b0};        // 系数
                    if (mi < lc) run_addr = run_addr_full[ADDRW-1:0];
                end
                2'd1: begin
                    run_addr_full = {mi[MW-1:0], 1'b1};        // 状态
                    if (mi < lc) run_addr = run_addr_full[ADDRW-1:0];
                end
                default: begin
                    if (write_en) begin
                        run_we        = 1'b1;
                        run_addr_full = {pend_local, 1'b1};    // 要回写的状态
                        run_addr      = run_addr_full[ADDRW-1:0];
                        run_wdata     = {8'b0, pend_oldy1, pend_ynew};
                    end
                end
            endcase
        end
    end

    always_comb begin
        addr  = cfg_we ? cfg_addr : run_addr;
        we    = cfg_we | run_we;
        wdata = cfg_we ? cfg_wdata : run_wdata;
    end

    assign done        = (st == S_DONE);
    assign partial_sum = ps;
    assign sat_count   = sat;

    // ------------------------------------------------------------------
    // 主时序过程
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st           <= S_IDLE;
            ph           <= 2'd0;
            mi           <= 8'd0;
            lc           <= {MW{1'b0}};
            x_r          <= 32'sd0;
            state_valid  <= '0;
            acc          <= 64'sd0;
            ps           <= 64'sd0;
            sat          <= 6'd0;
            ctx_a1       <= 26'sd0;
            ctx_a2       <= 26'sd0;
            ctx_y2       <= 32'sd0;
            ctx_oldy1    <= 32'sd0;
            pend_valid   <= 1'b0;
            pend_local   <= {MW{1'b0}};
            pend_ynew    <= 32'sd0;
            pend_oldy1   <= 32'sd0;
            pend_sat     <= 1'b0;
            commit_valid <= 1'b0;
            commit_mode  <= {MW{1'b0}};
            commit_y1    <= 32'sd0;
            commit_y2    <= 32'sd0;
            commit_sat   <= 1'b0;
        end else begin
            commit_valid <= 1'b0;

            if (clear) begin
                state_valid <= '0;
                ps          <= 64'sd0;
                sat         <= 6'd0;
                pend_valid  <= 1'b0;
            end

            case (st)
                S_IDLE: begin
                    if (start) begin
                        lc  <= count_for(n_modes);
                        x_r <= x_in;
                        ph  <= 2'd0;
                        mi  <= 8'd0;
                        ps  <= 64'sd0;
                        sat <= 6'd0;
                        acc <= 64'sd0;
                        pend_valid <= 1'b0;
                        st  <= (count_for(n_modes) == {MW{1'b0}}) ? S_DONE : S_RUN;
                    end
                end

                S_RUN: begin
                    // 捕获当前 mode 的系数
                    if ((ph == 2'd1) && (mi < lc)) begin
                        ctx_a1 <= {rdata[21:0], 4'b0};        // a1 Q2.20 -> 26-bit
                        ctx_a2 <= {2'b0, rdata[45:22]};       // a2 UQ0.24 -> 26-bit
                    end
                    // 捕获当前 mode 的状态
                    if ((ph == 2'd2) && (mi < lc)) begin
                        ctx_y2    <= y2_use;
                        ctx_oldy1 <= y1_use;
                    end

                    // 累加器：本 phase 可用的乘积
                    if (ph == 2'd2)      acc <= prod64;             // G*x
                    else if (ph == 2'd0) acc <= acc - prod64;       // a1*y1
                    else                 acc <= acc - prod64;       // a2*y2

                    // finalise 前一个 mode
                    if (finalize_en) begin
                        pend_valid  <= 1'b1;
                        pend_local  <= mi - 8'd1;
                        pend_ynew   <= ynew;
                        pend_oldy1  <= ctx_oldy1;
                        pend_sat    <= sat_now;
                        ps          <= ps + {{32{ynew[31]}}, ynew};
                        if (sat_now) sat <= sat + 6'd1;
                    end

                    // 回写三个周期前完成的 mode
                    if (write_en) begin
                        state_valid[pend_idx] <= 1'b1;
                        commit_valid <= 1'b1;
                        commit_mode  <= (pend_local << 2) | LANE;
                        commit_y1    <= pend_ynew;
                        commit_y2    <= pend_oldy1;
                        commit_sat   <= pend_sat;
                    end

                    // 推进
                    if (last_cycle) begin
                        st <= S_DONE;
                    end else if (ph == 2'd2) begin
                        ph <= 2'd0;
                        mi <= mi + 8'd1;
                    end else begin
                        ph <= ph + 2'd1;
                    end
                end

                default: begin // S_DONE
                    if (start) begin
                        lc  <= count_for(n_modes);
                        x_r <= x_in;
                        ph  <= 2'd0;
                        mi  <= 8'd0;
                        ps  <= 64'sd0;
                        sat <= 6'd0;
                        acc <= 64'sd0;
                        pend_valid <= 1'b0;
                        st  <= (count_for(n_modes) == {MW{1'b0}}) ? S_DONE : S_RUN;
                    end
                end
            endcase
        end
    end

endmodule
