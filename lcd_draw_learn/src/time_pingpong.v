// time_pingpong.v - Time-domain ping-pong buffer (audio in / FFT out / wave out)
// 2026-09-29 架构重构 v2：写侧唯一状态源 + 完整握手 + 控制/数据分离
//
//  FFT 读比音频写快 ~700 倍（30us vs 21ms），乒乓天然不冲突。
//
//  握手逻辑（已确认，重要）：
//  - 块状态 EMPTY/FULL 由【写侧】唯一维护（full_exists + full_ptr）
//  - 读侧只【同步 full_ptr/full_exists】（2-FF），读它指向的满块
//  - 读侧读完发 rd_done_i，写侧同步后清满块（同时只一块满 → 必对应满块）
//  - 写侧翻块若目标块仍 FULL（FFT 没读走）→ wr_ready=0 停写（防覆盖）
//  - 波形读也用同步的满块指针（与 FFT 同源，无跨时钟直接索引写侧信号）
module time_pingpong #(
    parameter N_SAMPLES = 1024,
    parameter WIDTH     = 16
) (
    // ===== 复位 =====
    input               rst_ni,

    // ===== 写侧（音频域 48k）=====
    input               wr_clk_i,
    input  [WIDTH-1:0]  wr_data_i,      // 采样数据
    input               wr_valid_i,     // 每采样 1 拍脉冲
    output              wr_ready_o,     // 电平：当前写块 EMPTY，可收

    // ===== FFT 读口（pix_clk 域）=====
    input               rd_clk_i,
    input               rd_req_i,       // 1拍脉冲：请求读当前拍
    input  [$clog2(N_SAMPLES)-1:0] rd_addr_i,  // 块内地址 0..N-1
    output [WIDTH-1:0]  rd_data_o,      // 读出采样（rd_req_i 时锁存）
    output              rd_valid_o,     // 电平：有满块可读
    input               rd_done_i,      // 1拍脉冲：FFT 读完一块

    // ===== 波形读口（显示域）=====
    input               wf_clk_i,
    input  [$clog2(N_SAMPLES)-1:0] wf_addr_i,  // 采样点
    output [WIDTH-1:0]  wf_data_o       // 波形值（锁存）
);

    // ============================================================
    //  数据通路：双块 RAM
    // ============================================================
    reg [WIDTH-1:0] tbuf_ram [0:1][0:N_SAMPLES-1];

    // ============================================================
    //  控制器（写侧 wr_clk 域）
    // ============================================================
    localparam EMPTY = 1'b0, FULL = 1'b1;

    reg block_state [0:1];          // 每块 EMPTY/FULL（写侧唯一维护）
    reg wr_block;                   // 当前写块
    reg [$clog2(N_SAMPLES)-1:0] wr_addr;  // 块内写地址
    reg full_exists;                // 是否有满块
    reg full_ptr;                   // 满的是哪块

    // rd_done 同步（读→写，2-FF）
    reg done_s1, done_s2;
    always @(posedge wr_clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            done_s1 <= 1'b0;
            done_s2 <= 1'b0;
        end
        else begin
            done_s1 <= rd_done_i;
            done_s2 <= done_s1;
        end
    end

    // 写侧控制 FSM
    always @(posedge wr_clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            block_state[0] <= EMPTY;
            block_state[1] <= EMPTY;
            wr_block <= 1'b0;
            wr_addr  <= 0;
            full_exists <= 1'b0;
            full_ptr <= 1'b0;
        end
        else begin
            // 读侧读完 → 清满块（同时只一块满 → 清 full_ptr 指向的块）
            if (done_s2) begin
                block_state[full_ptr] <= EMPTY;
                full_exists <= 1'b0;
            end

            // 写：当前写块 EMPTY 且来采样
            if (wr_valid_i && (block_state[wr_block] == EMPTY)) begin
                tbuf_ram[wr_block][wr_addr] <= wr_data_i;
                if (wr_addr == N_SAMPLES-1) begin
                    block_state[wr_block] <= FULL;   // 攒满
                    full_exists <= 1'b1;             // 有满块了
                    full_ptr <= wr_block;            // 记满块
                    wr_block <= ~wr_block;           // 翻块
                    wr_addr  <= 0;
                end
                else wr_addr <= wr_addr + 1'b1;
            end
        end
    end
    assign wr_ready_o = (block_state[wr_block] == EMPTY);

    // ============================================================
    //  控制器（读侧 rd_clk 域）：同步满块指针 + 满块存在标志
    // ============================================================
    reg full_ex_s1, full_ex_s2;     // full_exists 同步
    reg full_ptr_s1, full_ptr_s2;   // full_ptr 同步
    always @(posedge rd_clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            full_ex_s1 <= 1'b0;
            full_ex_s2 <= 1'b0;
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
    assign rd_valid_o = full_ex_s2;              // 有满块可读
    wire rd_block = full_ptr_s2;                 // 读满块

    // ============================================================
    //  数据通路：FFT 读 + 波形读
    // ============================================================
    reg [WIDTH-1:0] rd_data_r;
    always @(posedge rd_clk_i) begin
        if (rd_req_i) rd_data_r <= tbuf_ram[rd_block][rd_addr_i];
    end
    assign rd_data_o = rd_data_r;

    // 波形读：读同步的满块（与 FFT 同源，无跨时钟直接索引）
    reg [WIDTH-1:0] wf_data_r;
    always @(posedge wf_clk_i) begin
        wf_data_r <= tbuf_ram[full_ptr_s2][wf_addr_i];
    end
    assign wf_data_o = wf_data_r;

endmodule