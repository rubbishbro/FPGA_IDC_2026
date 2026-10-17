// -----------------------------------------------------------------------------
// poly_modal_lane.sv -- 32 声部模态 bank 的一个 TDM lane（module 2C）。
//
// 在已验证的 module 2A lane（`modal_lane.sv`）基础上扩展 voice 维度：一个
// signed 26x32 乘法器、一个同步单端口 72-bit 工作缓存（保存
// NUM_VOICES*LOCAL_MODES 个 mode），以及逐 voice 的状态有效位图。一个状态 word
// 位于
//
//     mem[2*(voice*LOCAL_MODES + local) + 0] = 72-bit 系数 word
//     mem[2*(voice*LOCAL_MODES + local) + 1] = {8'b0, y2, y1}
//
// 所有 lane 使用相同的 voice slot；全局 mode k 映射到 lane k%4，local k/4。
// RAM 从不 reset；clear 只丢弃目标 voice 的 state_valid 切片，保留系数
// （以及所有其他 voice）不变。
//
// 算术契约与 module 2A 相同（rtl/module2A_design.md s.3）：
//   G Q2.24 signed 26，a1 Q2.20 signed 22（<<4），a2 UQ0.24 unsigned 24，
//   x/y Q2.30 signed 32，乘积 signed 58，累加器 64，
//   ynew = clamp((acc + 2^23) >>> 24, -2^31, 2^31-1)。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module poly_modal_lane #(
    parameter int NUM_VOICES = 32,
    parameter int N_MODES = 48,
    parameter int LANE = 0,
    parameter int SKIP_ZERO_INPUT = 0,
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter int LOCAL_MODES = (N_MODES + 3) / 4,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int SLOTS = NUM_VOICES * LOCAL_MODES,
    parameter int ADDRW = (2 * SLOTS < 2) ? 1 : $clog2(2 * SLOTS),
    parameter int SVW = (SLOTS < 2) ? 1 : $clog2(SLOTS),
    parameter int IDXW = (LOCAL_MODES < 2) ? 1 : $clog2(LOCAL_MODES)
) (
    input  logic               clk,
    input  logic               rst_n,

    // 单 voice 帧
    input  logic               start,
    input  logic [MW-1:0]      n_modes,
    input  logic signed [31:0] x_in,
    input  logic [VW-1:0]      voice,

    // 逐 voice 状态清除（仅空闲时）
    input  logic               clear,
    input  logic [VW-1:0]      clear_voice,

    // 系数写入
    input  logic               cfg_we,
    input  logic [VW-1:0]      cfg_voice,
    input  logic [IDXW-1:0]    cfg_local,
    input  logic [71:0]        cfg_wdata,

    output logic               done,
    output logic [VW-1:0]      commit_voice,
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
    // 工作缓存（no-change 同步单端口，从不 reset）
    //
    // 在写周期，读被抑制，`rdata` 保持其前一个
    // 值；在读周期，`rdata` 在时钟边沿
    // 捕获 mem[addr]。这避免了 Gowin SPX9 BSRAM 无法实现的 read-first
    // （WRITE_MODE=2'b10）推断。数据通路绝不依赖由写周期产生的 RAM
    // 输出：写边沿仍然消费前一个 ph1 读取的状态
    // （其 ctx_y2/y1 来自更早的那次读），新写入的值在接下来的
    // ph0 不需要，然后 ph0 读取下一个系数供 ph1 消费。
    // ph2 的写地址（奇状态 word）绝不等于紧随其后被消费的
    // ph0 系数 / ph1 状态读地址。逐周期证明见
    // sim/test_poly_lane_ram_write_mode.py 和父级的
    // sim/test_poly_lane_ram_equivalence_review.py。
    // ------------------------------------------------------------------
    logic [71:0]           mem [0:2*SLOTS-1];
    logic [71:0]           rdata;
    logic [ADDRW-1:0]      addr;
    logic                  we;
    logic [71:0]           wdata;

    always_ff @(posedge clk) begin
        if (we) mem[addr] <= wdata;
        else    rdata    <= mem[addr];
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
    logic [VW-1:0]       voice_r;

    logic [SLOTS-1:0]    state_valid;    // 逐 (voice,local) 位图
    logic signed [63:0]  acc, ps;
    logic signed [57:0]  prod_r;
    logic [5:0]          sat;

    logic signed [25:0]  ctx_a1, ctx_a2;
    logic signed [31:0]  ctx_y2, ctx_oldy1;

    logic                pend_valid;
    logic [MW-1:0]       pend_local;
    logic signed [31:0]  pend_ynew, pend_oldy1;
    logic                pend_sat;

    // 常数乘 v*LOCAL_MODES 的纯组合移位/加法：只用编译期常量位移与加法，
    // 不写 `*` 运算符，避免被综合器识别成 DSP 常数乘法（原
    // voice*LOCAL_MODES / cfg_voice*LOCAL_MODES 会在关键地址链上生成 DSP）。
    // 结果 mod 2^SVW，对所有可编码 voice（含可表达的非法 code）低位一致。
    localparam int LOC_BITS = (LOCAL_MODES < 2) ? 1 : $clog2(LOCAL_MODES + 1);
    function automatic [SVW-1:0] voice_base(input [VW-1:0] v);
        integer k;
        begin
            voice_base = {SVW{1'b0}};
            for (k = 0; k < LOC_BITS; k = k + 1)
                if ((LOCAL_MODES >> k) & 1)
                    voice_base = voice_base + (SVW'(v) << k);
        end
    endfunction

    // 寄存的 voice base = voice_r * LOCAL_MODES。voice_r 在 `start` 时锁存
    // 一次，整个帧期间保持不变，因此 base 在 start 时寄存，而不是
    // 每个 phase 组合地重新相乘（否则该常数乘法会映射到
    // OREG=BYPASS 的 DSP，馈入动态 operand/state_valid 选择，
    // 形成长地址链）。纯粹是寻址优化：索引相同，
    // 算术不变。
    logic [SVW-1:0]      vb_r;
    wire [SVW-1:0]       vb_next = voice_base(voice);

    // 钳位的 local 索引（绝不越界选择）
    wire [IDXW-1:0] mi_cl = (mi < LOCAL_MODES) ? mi[IDXW-1:0] : {IDXW{1'b0}};
    wire [IDXW-1:0] pd_cl = (pend_local < LOCAL_MODES) ? pend_local[IDXW-1:0]
                                                       : {IDXW{1'b0}};
    wire [SVW-1:0]  sv_run  = vb_r + mi_cl;
    wire [SVW-1:0]  sv_pend = vb_r + pd_cl;

    // ------------------------------------------------------------------
    // 将 "mode-index -> valid lookup -> DSP operand" 链拆分到
    // phase 流水线上（lane 已在 ph1 读取状态 word
    // 并在 ph2 消费它）：
    //   ph0 : 预取寄存 run 索引 sv_run_r = vb_r + mi_cl；
    //   ph1 : 捕获 ctx_valid <= (S_RUN & mi<lc & state_valid[sv_run_r]) ——
    //         查找现在使用 REGISTERED 索引，脱离 mi->lookup 关键路径，
    //         且 ph1 状态读就是 ph2 消费的数据；
    //   ph2 : 用 REGISTERED ctx_valid 对 rdata 的 y1/y2 做门控。
    // `mi` 在一个 mode 的 ph0..ph2 期间保持不变，且 `clear` 仅在
    // 空闲时被接受（绝不在 run 期间），因此寄存的有效位与 mode 保持对齐；
    // pending write/commit 路径不变。
    // ------------------------------------------------------------------
    logic [SVW-1:0] sv_run_r;
    logic           ctx_valid;
    wire            valid_now = (st == S_RUN) && (mi < lc) && state_valid[sv_run_r];

    // ------------------------------------------------------------------
    // 乘法器操作数选择（一个逻辑乘法器）
    // ------------------------------------------------------------------
    wire signed [31:0] y1_use = (ctx_valid) ? $signed(rdata[31:0]) : 32'sd0;
    wire signed [31:0] y2_use = (ctx_valid) ? $signed(rdata[63:32]) : 32'sd0;

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
    // 唯一的乘法点保持不变；只有该 slot 的结果
    // 被强制为零。
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

    // run 端口访问
    logic              run_we;
    logic [ADDRW-1:0]  run_addr;
    logic [71:0]       run_wdata;
    logic [31:0]       run_addr_w;
    always_comb begin
        run_we     = 1'b0;
        run_addr_w = 32'd0;
        run_wdata  = 72'd0;
        if (st == S_RUN) begin
            case (ph)
                2'd0: run_addr_w = 2 * (vb_r + mi_cl) + 0;
                2'd1: run_addr_w = 2 * (vb_r + mi_cl) + 1;
                default: if (write_en) begin
                    run_we     = 1'b1;
                    run_addr_w = 2 * (vb_r + pd_cl) + 1;
                    run_wdata  = {8'b0, pend_oldy1, pend_ynew};
                end
            endcase
        end
    end
    assign run_addr = run_addr_w[ADDRW-1:0];

    // cfg 地址同样是常数乘：复用 voice_base 的移位/加法，不用 `*`。
    // cfg_slot = cfg_voice*LOCAL_MODES + cfg_local（mod 2^SVW）；
    // cfg_addr_w 是 2*cfg_slot 的 32bit 零扩展（低 ADDRW 位等价于旧表达式，
    // 供旧观测与地址 mux 使用）。纯组合，不注册、不延迟 cfg 写。
    wire [SVW-1:0]   cfg_base    = voice_base(cfg_voice);
    wire [SVW-1:0]   cfg_slot    = cfg_base + SVW'(cfg_local);
    wire [31:0]      cfg_addr_w  = 32'(cfg_slot) << 1;

    always_comb begin
        addr  = cfg_we ? cfg_addr_w[ADDRW-1:0] : run_addr;
        we    = cfg_we | run_we;
        wdata = cfg_we ? cfg_wdata : run_wdata;
    end

    assign done        = (st == S_DONE);
    assign partial_sum = ps;
    assign sat_count   = sat;
    assign commit_voice= voice_r;

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
            voice_r      <= {VW{1'b0}};
            vb_r         <= {SVW{1'b0}};
            state_valid  <= '0;
            acc          <= 64'sd0;
            ps           <= 64'sd0;
            sat          <= 6'd0;
            ctx_a1       <= 26'sd0;
            ctx_a2       <= 26'sd0;
            ctx_y2       <= 32'sd0;
            ctx_oldy1    <= 32'sd0;
            sv_run_r     <= {SVW{1'b0}};
            ctx_valid    <= 1'b0;
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

            // 静态逐 voice clear 译码器：综合器为每个 voice 展开一个常数
            // 切片 `v*LOCAL_MODES`，因此不会生成 voice*LOCAL_MODES
            // 乘法/DSP，越界的 clear_voice 自然不会匹配任何切片。
            // 与 pending 写的优先级不变（clear 仅在空闲时被接受，
            // 绝不在 run 期间）。
            for (int v = 0; v < NUM_VOICES; v = v + 1)
                if (clear && (clear_voice == v[VW-1:0]))
                    state_valid[v*LOCAL_MODES +: LOCAL_MODES] <= '0;

            case (st)
                S_IDLE, S_DONE: begin
                    if (start) begin
                        lc         <= count_for(n_modes);
                        x_r        <= x_in;
                        voice_r    <= voice;
                        vb_r       <= vb_next;
                        ph         <= 2'd0;
                        mi         <= 8'd0;
                        ps         <= 64'sd0;
                        sat        <= 6'd0;
                        acc        <= 64'sd0;
                        pend_valid <= 1'b0;
                        st         <= (count_for(n_modes) == {MW{1'b0}}) ? S_DONE
                                                                         : S_RUN;
                    end
                end

                S_RUN: begin
                    // ph0：为 ph1 valid 查找预取 run 索引
                    if (ph == 2'd0) sv_run_r <= sv_run;
                    // ph1：为 ph2 捕获（寄存索引的）state-valid
                    if (ph == 2'd1) ctx_valid <= valid_now;

                    if ((ph == 2'd1) && (mi < lc)) begin
                        ctx_a1 <= {rdata[21:0], 4'b0};        // a1 Q2.20 -> 26-bit
                        ctx_a2 <= {2'b0, rdata[45:22]};       // a2 UQ0.24 -> 26-bit
                    end
                    if ((ph == 2'd2) && (mi < lc)) begin
                        ctx_y2    <= y2_use;
                        ctx_oldy1 <= y1_use;
                    end

                    if (ph == 2'd2)      acc <= prod64;             // G*x
                    else if (ph == 2'd0) acc <= acc - prod64;       // a1*y1
                    else                 acc <= acc - prod64;       // a2*y2

                    if (finalize_en) begin
                        // finalize 只填充 pending token（舍入/clamp 后的
                        // ynew 在这里是寄存边界）
                        pend_valid  <= 1'b1;
                        pend_local  <= mi - 8'd1;
                        pend_ynew   <= ynew;
                        pend_oldy1  <= ctx_oldy1;
                        pend_sat    <= sat_now;
                    end

                    if (write_en) begin
                        // 从已寄存（REGISTERED）的 pending token 累加部分和（partial sum）/
                        // saturation（不是来自实时的 acc->ynew
                        // clamp），因此 64-bit ps 加法器
                        // 脱离该链；累加值的集合和 done 时的 partial_sum
                        // 逐位相同。
                        ps                   <= ps + {{32{pend_ynew[31]}}, pend_ynew};
                        if (pend_sat) sat    <= sat + 6'd1;
                        state_valid[sv_pend] <= 1'b1;
                        commit_valid <= 1'b1;
                        commit_mode  <= (pend_local << 2) | LANE;
                        commit_y1    <= pend_ynew;
                        commit_y2    <= pend_oldy1;
                        commit_sat   <= pend_sat;
                    end

                    if (last_cycle) begin
                        st <= S_DONE;
                    end else if (ph == 2'd2) begin
                        ph <= 2'd0;
                        mi <= mi + 8'd1;
                    end else begin
                        ph <= ph + 2'd1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
