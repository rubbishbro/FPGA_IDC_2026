// tb_eng1：用队友的 abc_lane_core 逐位核对我们的 eng1
//   同一组 (G, a1, a2, x) 喂两边，比较每个模态的 y1/y2 与总和。
`timescale 1ns/1ps
module tb_eng1;
    localparam int SLOTS = 1;
    localparam int N     = 8;          // 模态数（LOCAL = N/1 = 8）
    localparam int REC_W = 288;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- 激励 ----
    logic              start = 0;
    logic [15:0]       n_modes = N;
    logic signed [31:0] x_in = 0;

    // 系数/状态存储（两边共用同一份初值）
    logic signed [31:0] G_m, a1_m, a2_m, y1_m, y2_m;

    // ---------------- 被测：我们的 eng1 ----------------
    logic        e1_co_re, e1_st_re, e1_st_we, e1_x_re, e1_yv;
    logic [3:0]  e1_co_addr, e1_st_addr, e1_st_wa, e1_x_addr;
    logic signed [63:0] e1_yd;
    modal_step_pkg::coeff_t e1_cd;
    logic signed [31:0] e1_q, e1_qd, e1_qw, e1_qdw;

    // 本 TB 里 router 阵列的模型：eng1 读哪就回哪
    logic [3:0] e1_rd_mode;
    assign e1_rd_mode = e1_co_addr;
    always_comb begin
        e1_cd = '0;
        e1_cd.a11 = G_m;   e1_cd.a12 = a1_m;   e1_cd.a21 = a2_m;
    end
    // eng1 的状态模型：写回就存，读就从同一个模态取
    logic signed [31:0] q_mem [0:N-1];
    logic signed [31:0] v_mem [0:N-1];
    assign e1_q  = q_mem[e1_st_addr];
    assign e1_qd = v_mem[e1_st_addr];
    always @(posedge clk) if (e1_st_we) begin
        q_mem[e1_st_wa] <= e1_qw;
        v_mem[e1_st_wa] <= e1_qdw;
    end

    eng1 #(.N_MODES(N), .X_DEPTH(4)) u_eng1 (
        .clk(clk), .rst_n(rst_n), .start(start), .st_zero(1'b1), .n_modes(n_modes),
        .co_re(e1_co_re), .co_addr(e1_co_addr), .co_data(e1_cd),
        .st_re(e1_st_re), .st_addr(e1_st_addr), .st_q(e1_q), .st_qdot(e1_qd),
        .st_we(e1_st_we), .st_waddr(e1_st_wa), .st_q_wdata(e1_qw), .st_qdot_wdata(e1_qdw),
        .x_re(e1_x_re), .x_addr(e1_x_addr), .x_data(x_in),
        .y_valid(e1_yv), .y_data(e1_yd)
    );

    // ---------------- 参考：队友 abc_lane_core ----------------
    logic        r_rd_re, r_st_we, r_done, r_busy, r_cv;
    logic [7:0]  r_rd_addr, r_st_addr;
    logic [REC_W-1:0] r_rd_data;
    logic [63:0] r_st_data;
    logic signed [63:0] r_sum;
    logic signed [31:0] r_cy1, r_cy2;
    logic [5:0]  r_sat;

    abc_lane_core #(
        .NUM_SLOTS(SLOTS), .N_MODES(N), .LANES(1), .LANE(0)
    ) u_ref (
        .clk(clk), .rst_n(rst_n), .start(start), .n_modes(n_modes[7:0]),
        .x_in(x_in), .voice(1'b0),
        .rd_re(r_rd_re), .rd_addr(r_rd_addr), .rd_data(r_rd_data),
        .st_we(r_st_we), .st_addr(r_st_addr), .st_data(r_st_data),
        .done(r_done), .busy(r_busy),
        .commit_valid(r_cv), .commit_voice(), .commit_mode(),
        .commit_y1(r_cy1), .commit_y2(r_cy2), .commit_sat(),
        .partial_sum(r_sum), .sat_count(r_sat)
    );

    // ---------------- 两边共享的参考模型（同步 RAM）----------------
    // 每模态一条 288-bit 记录：字段 0..4 = G,a1,a2,y1,y2（按 modal_record_pkg）
    logic [REC_W-1:0] mem [0:N-1];
    logic [REC_W-1:0] ref_rd_q;
    logic [31:0]      g_i, a1_i, a2_i;
    logic signed [31:0] y1_i, y2_i;

    integer i;
    longint c_g, c_a1, c_a2, c_y1, c_y2, xr;
    longint acc, yexp, y1n, y2n;

    // 我们的 eng1 用同一个初值（它只读一个模态一条记录）
    initial begin
        y1_m = '0; y2_m = '0; G_m = '0; a1_m = '0; a2_m = '0;
    end

    // 参考核的 RAM
    always @(posedge clk) begin
        if (r_rd_re) ref_rd_q <= mem[r_rd_addr[7:0] % N];
    end
    assign r_rd_data = ref_rd_q;

    // 参考核的状态写回更新 mem
    always @(posedge clk) begin
        if (r_st_we) begin
            mem[r_st_addr[7:0] % N][127:96]  <= r_st_data[31:0];    // y1
            mem[r_st_addr[7:0] % N][159:128] <= r_st_data[63:32];   // y2
        end
    end

    // ---- 期望值（按 abc 契约，用 64 位整数算）----
    function automatic longint exp_y(input longint g, input longint a1, input longint a2,
                                     input longint x, input longint y1, input longint y2);
        longint acc;
        acc = g*x - ((a1 << 4)*y1) - (a2*y2);
        acc = (acc + (64'sd1 <<< 23)) >>> 24;
        if (acc >  64'sd2147483647) acc =  64'sd2147483647;
        if (acc < -64'sd2147483648) acc = -64'sd2147483648;
        exp_y = acc;
    endfunction

    // ---------------- 测试流程 ----------------
    localparam int NCASE = 6;
    initial begin
        if ($test$plusargs("seed")) ;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        for (int c = 0; c < NCASE; c++) begin
            // 造系数：G 小、a1/a2 使极点接近单位圆
            // 真实量纲：G~Q2.24(0.1..0.9)、a1~Q2.20(-0.9..0.9)、a2~UQ0.24(0..0.9)
            c_g  = (($urandom % 800) + 100) * 16777;          // 0.1..0.9 * 2^24
            c_a1 = (($urandom % 1800) - 900) * 582;           // -0.9..0.9 * 2^20
            c_a2 = ($urandom % 900) * 18641;                  // 0..0.9 * 2^24
            xr   = 0;
            for (i = 0; i < N; i++) begin
                mem[i] = '0;
                mem[i][31:0]   = G_m_rt(c_g);        // 字段 0 = G
                mem[i][63:32]  = a1_rt(c_a1);        // 字段 1 = a1
                mem[i][95:64]  = a2_rt(c_a2);        // 字段 2 = a2
                mem[i][127:96] = 0;                  // 字段 3 = y1
                mem[i][159:128]= 0;                  // 字段 4 = y2
            end
            G_m  = G_m_rt(c_g);  a1_m = a1_rt(c_a1); a2_m = a2_rt(c_a2);
            y1_m = 0; y2_m = 0;
            for (i = 0; i < N; i++) begin q_mem[i] = 0; v_mem[i] = 0; end
            x_in = 32'(((($urandom % 800) + 100) * 1342177) * (($urandom % 2) ? 1 : -1));  // 0.1..0.9 * 2^30

            @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
            wait (e1_yv);
            wait (r_done);
            @(posedge clk);

            // 参考：用同一组系数按契约逐模态算
            y1n = 0; y2n = 0; acc = 0;
            for (i = 0; i < N; i++) begin
                yexp = exp_y(64'(G_m), 64'(a1_m), 64'(a2_m), 64'(x_in), y1n, y2n);
                acc  = acc + yexp;
                y2n  = y1n;  y1n = yexp;
            end
            if (64'(e1_yd) === r_sum)
                $display("case %0d: OK  eng1=%0d ref=%0d", c, e1_yd, r_sum);
            else
                $display("case %0d: FAIL eng1=%0d ref=%0d exp=%0d", c, e1_yd, r_sum, acc);
        end
        $finish;
    end

    // 把整数塞进 32 位字段
    function automatic logic [31:0] G_m_rt(input longint v);  G_m_rt  = 32'(v); endfunction
    function automatic logic [31:0] a1_rt(input longint v);   a1_rt   = 32'(v); endfunction
    function automatic logic [31:0] a2_rt(input longint v);   a2_rt   = 32'(v); endfunction
endmodule
