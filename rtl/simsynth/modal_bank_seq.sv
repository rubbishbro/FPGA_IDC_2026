// -----------------------------------------------------------------------------
// modal_bank_seq.sv -- 时分复用（TDM）的模态 bank：一条乘加数据通路跑 N 个模态
//
// 为什么要时分复用：单模态"并联一步"模块综合出来是 3603 LUT + 704 ALU、0 DSP，
// 80 个模态并联 ≈ 34 万逻辑单元，装不进 138K 器件（见 README 资源表）。
// 本模块用**一个乘法器**顺序完成每个模态的 7 个乘积；每帧（= 一个采样步）用
// (7 + 2) × N 个时钟周期：
//
//     S_REQ   1 拍：给系数 ROM 地址与状态 RAM 地址（都是同步读，下一拍数据有效）
//     S_MAC   7 拍：k = 0..6，把本拍的 (a, m, s) 送到唯一的乘法器，舍入后累加
//     S_WB    1 拍：状态写回 RAM，y 累加进 y_sum
//
// 一个模态的 7 个乘积（与 string_mode_step 逐位一致 —— 算术都在 modal_step_pkg 里）：
//     qn += (q·a11)>>s11   (v·a12)>>s12   (x·gq)>>sgq
//     vn += (q·a21)>>s21   (v·a22)>>s22   (x·gv)>>sgv
//     y  += (q·wo )>>swo
//
// 周期预算：100 MHz、48 kHz ⇒ 每帧 2083 拍；N = 48 时 9×48 = 432 拍，余量约 4.8 倍。
//
// 系数来自外部 ROM（`c_addr` → 下一拍 `c_data`）；状态在本模块内 RAM，另有独立的
// 初始化/读回端口（note-on 与测试用）。帧运行与初始化/读回互斥。
//
// 与队友 rtl/core/modal_lane.sv 的关系：他们那套是 (a1,a2,G) 三系数 DF-II 的 TDM lane；
// 本模块是我们 (q,q̇) 物理状态的 TDM bank。接口风格（clk/rst_n + 帧脉冲 + 系数 ROM 读 +
// 状态 RAM + 饱和）刻意与他们保持一致，便于日后接进同一套顶层。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module modal_bank_seq #(
    parameter int   N_MODES  = 32,
    parameter logic SATURATE = 1'b1
) (
    input  logic                                 clk,
    input  logic                                 rst_n,

    // 一帧 = 一个采样步
    input  logic                                 start,      // 单周期脉冲
    input  logic [$clog2(N_MODES+1)-1:0]         n_modes,    // 1..N_MODES
    input  logic signed [modal_step_pkg::XW-1:0] x_in,

    // 状态初始化 / 读回（与帧运行互斥）
    input  logic                                 st_we,
    input  logic [$clog2(N_MODES)-1:0]           st_addr,
    input  logic signed [modal_step_pkg::QW-1:0] st_q,
    input  logic signed [modal_step_pkg::VW-1:0] st_v,
    input  logic                                 rd_en,
    output logic signed [modal_step_pkg::QW-1:0] rd_q,
    output logic signed [modal_step_pkg::VW-1:0] rd_v,
    output logic                                 rd_valid,

    // 系数 ROM：同步读，1 拍延迟
    output logic [$clog2(N_MODES)-1:0]           c_addr,
    input  modal_step_pkg::coeff_t               c_data,

    // 一帧结果：Σ wo·q（由调用方统一移位/舍入到音频）
    output logic signed [modal_step_pkg::YW-1:0] y_sum,
    output logic                                 frame_done,
    output logic                                 busy
);

    import modal_step_pkg::*;

    localparam int IW = $clog2(N_MODES);

    // ---------------------------------------------------------------------
    // 状态 RAM：一个写口 + 一个读口，同步读（1 拍延迟）
    // ---------------------------------------------------------------------
    (* syn_ramstyle = "block_ram" *)
    logic signed [QW-1:0] q_ram [0:N_MODES-1];
    (* syn_ramstyle = "block_ram" *)
    logic signed [VW-1:0] v_ram [0:N_MODES-1];

    logic                 ram_we;
    logic [IW-1:0]        ram_waddr;
    logic signed [QW-1:0] ram_wq;
    logic signed [VW-1:0] ram_wv;
    logic                 ram_re;
    logic [IW-1:0]        ram_raddr;

    logic signed [QW-1:0] ram_rd_q;
    logic signed [VW-1:0] ram_rd_v;

    always_ff @(posedge clk) begin
        if (ram_we) begin
            q_ram[ram_waddr] <= ram_wq;
            v_ram[ram_waddr] <= ram_wv;
        end
        if (ram_re) begin
            ram_rd_q <= q_ram[ram_raddr];
            ram_rd_v <= v_ram[ram_raddr];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rd_valid <= 1'b0;
        else        rd_valid <= ram_re;
    end

    assign rd_q = ram_rd_q;
    assign rd_v = ram_rd_v;

    // ---------------------------------------------------------------------
    // 帧状态机
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] { S_IDLE, S_REQ, S_MAC, S_WB, S_DONE } state_t;
    state_t               state;
    logic [IW-1:0]        midx;
    logic [IW:0]          n_lat;
    logic signed [XW-1:0] x_lat;
    logic [3:0]           k;

    logic signed [AW-1:0] qn_acc, vn_acc, y_acc;

    // ---------------------------------------------------------------------
    // 唯一的乘法数据通路：三级流水（与 modal_bank_ram 完全同构，便于对比）
    //   S1 操作数选择 -> op_*_q
    //   S2 乘法 + 四舍五入 + 移位 -> term_q
    //   S3 累加进 qn/vn/y
    // 每个乘积先独立舍入再相加，所以晚两拍累加**逐位等价**。
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] { DST_QN, DST_VN, DST_Y } dst_t;
    logic signed [XW-1:0] op_a;
    logic signed [CW-1:0] op_m;
    logic        [5:0]    op_s;   // 6 位：移位量是编译期常量，窄一点综合出的移位器更小
    dst_t                 op_dst;

    logic signed [XW-1:0] op_a_q;
    logic signed [CW-1:0] op_m_q;
    logic        [5:0]    op_s_q;
    dst_t                 op_dst_q;
    logic signed [AW-1:0] term_q;
    dst_t                 dst_q;
    logic                 sel_en;
    logic                 mult_en;

    always_comb begin
        // 注意：这里直接用 c_data（不额外锁存）。同步 ROM 在 S_REQ 的边沿把 rom[midx] 打出来，
        // 所以 S_MAC 期间 c_data 正好是本模态的系数；若在 S_REQ 边沿再锁存一次就会晚一个模态
        // （这是本模块第一版被 bank 测试台抓到的真实 bug）。
        sel_en  = (state == S_MAC) && (k <= 4'd6);
        mult_en = (state == S_MAC) && (k >= 4'd1) && (k <= 4'd7);
        case (k)
            3'd0: begin op_a = ram_rd_q; op_m = c_data.a11; op_s = SH_A11; op_dst = DST_QN; end
            3'd1: begin op_a = ram_rd_v; op_m = c_data.a12; op_s = SH_A12; op_dst = DST_QN; end
            3'd2: begin op_a = x_lat;    op_m = c_data.gq;  op_s = SH_GQ; op_dst = DST_QN; end
            3'd3: begin op_a = ram_rd_q; op_m = c_data.a21; op_s = SH_A21; op_dst = DST_VN; end
            3'd4: begin op_a = ram_rd_v; op_m = c_data.a22; op_s = SH_A22; op_dst = DST_VN; end
            3'd5: begin op_a = x_lat;    op_m = c_data.gv;  op_s = SH_GV; op_dst = DST_VN; end
            default: begin op_a = ram_rd_q; op_m = c_data.wo; op_s = SH_WO; op_dst = DST_Y; end
        endcase
    end

    // S1 打拍
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_a_q   <= '0;
            op_m_q   <= '0;
            op_s_q   <= '0;
            op_dst_q <= DST_QN;
        end else if (sel_en) begin
            op_a_q   <= op_a;
            op_m_q   <= op_m;
            op_s_q   <= op_s;
            op_dst_q <= op_dst;
        end
    end

    // S2：乘法 + 舍入（唯一乘法器；term() 在包里）
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            term_q <= '0;
            dst_q  <= DST_QN;
        end else if (mult_en) begin
            term_q <= term(op_a_q, op_m_q, op_s_q);
            dst_q  <= op_dst_q;
        end
    end

    // ---------------------------------------------------------------------
    // RAM 端口接续与写数据（帧写回优先；其余给初始化/读回）
    // ---------------------------------------------------------------------
    always_comb begin
        if (state == S_WB) begin
            ram_we    = 1'b1;
            ram_waddr = midx;
            ram_wq    = SATURATE ? sat_q(qn_acc) : qn_acc[QW-1:0];
            ram_wv    = SATURATE ? sat_v(vn_acc) : vn_acc[VW-1:0];
        end else begin
            ram_we    = st_we;
            ram_waddr = st_addr;
            ram_wq    = st_q;
            ram_wv    = st_v;
        end

        if (state == S_REQ) begin
            ram_re    = 1'b1;
            ram_raddr = midx;
        end else begin
            ram_re    = rd_en;
            ram_raddr = st_addr;
        end
    end

    // ---------------------------------------------------------------------
    // 时序
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            midx       <= '0;
            n_lat      <= '0;
            x_lat      <= '0;
            k          <= '0;
            qn_acc     <= '0;
            vn_acc     <= '0;
            y_acc      <= '0;
            y_sum      <= '0;
            frame_done <= 1'b0;
            busy       <= 1'b0;
            c_addr     <= '0;

        end else begin
            frame_done <= 1'b0;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        n_lat  <= n_modes;
                        x_lat  <= x_in;
                        midx   <= '0;
                        k      <= '0;
                        y_sum  <= '0;
                        c_addr <= '0;          // ROM 在 S_REQ 期间给出 mode 0 的系数
                        state  <= S_REQ;
                        busy   <= 1'b1;
                    end
                end

                S_REQ: begin
                    // 系数在 S_MAC 期间由 c_data 直接使用（见上面数据通路的注释）
                    qn_acc <= '0;
                    vn_acc <= '0;
                    y_acc  <= '0;
                    k      <= '0;
                    state  <= S_MAC;
                end

                S_MAC: begin
                    // S3：把上一拍算好的项加进累加器（k=0/1 时流水线还没吐出有效项）
                    if (k >= 4'd2) begin
                        case (dst_q)
                            DST_QN:  qn_acc <= qn_acc + term_q;
                            DST_VN:  vn_acc <= vn_acc + term_q;
                            default: y_acc  <= y_acc + term_q;
                        endcase
                    end
                    if (k == 4'd8) state <= S_WB;
                    else           k     <= k + 1'b1;
                end

                S_WB: begin
                    y_sum <= y_sum + y_acc;
                    if (midx + 1'b1 >= n_lat[IW-1:0]) begin
                        state <= S_DONE;
                    end else begin
                        midx   <= midx + 1'b1;
                        c_addr <= midx + 1'b1; // 下一个模态的系数
                        state  <= S_REQ;
                    end
                end

                S_DONE: begin
                    frame_done <= 1'b1;
                    busy       <= 1'b0;
                    state      <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
