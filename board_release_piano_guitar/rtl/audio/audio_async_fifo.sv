// -----------------------------------------------------------------------------
// audio_async_fifo.sv -- 双时钟 Gray 指针（格雷码指针）异步 FIFO。
//
// 一个共享的异步置位复位。每个时钟域各有自己的
// 两级触发器同步器，因此 *释放* 在该域内是同步的。
// 数据阵列从不直接同步：读/写指针以 Gray 码
//（格雷码）经两级触发器跨域，且阵列在每一侧都是单时钟的。
//
// FIFO 契约：
//   * DEPTH 是 2 的幂，>= 4
//   * 仅当 wvalid && wready 时写才提交（wready = !full）；仅当
//     rvalid && rready 时读才提交（rvalid = !empty）
//   * full 时从不覆盖，empty 时从不读取陈旧/未写入的数据
//   * rdata 由读指针寻址，且仅当 rvalid 时才有意义
//
// 存储器读取是组合逻辑（分布式读模型），因此消费者可以
// 在同一周期使用 rvalid/rdata。这是一个通用的仿真/综合
// 模型，不是对物理 BSRAM 映射的承诺。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// 核心计算后的100mhz样本要交给音频发送部分，但是音频发送部分时钟是12.5mhz
// 所以需要一个异步fifo来做时钟域的跨越（避免采集的时候进入亚稳态）
// 所以做一个缓冲区加上握手的结构，让两边各自生产和消费

// fifo模块
module audio_async_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 16
) (
    input  logic             wclk,
    input  logic             rclk,
    input  logic             rst_n,      // 异步置位，按域同步释放

    // 写端口（wclk 域）
    input  logic             wvalid,
    output logic             wready,
    input  logic [WIDTH-1:0] wdata,

    // 读端口（rclk 域）
    output logic             rvalid,
    input  logic             rready,
    output logic [WIDTH-1:0] rdata,

    // 状态
    output logic             wfull,
    output logic             rempty
);

    localparam int ADDRW = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    // DEPTH 必须是 2 的幂且至少为 4（结构性契约）。
    initial begin
        if ((DEPTH < 4) || ((DEPTH & (DEPTH - 1)) != 0))
            $error("%m: DEPTH=%0d must be a power of two and >= 4", DEPTH);
    end

    // ------------------------------------------------------------------
    // 辅助函数
    // ------------------------------------------------------------------
    function automatic [ADDRW:0] bin2gray(input [ADDRW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // 为什么使用格雷code
    // 每次改变的时候，只有一个bit会改变，减少了亚稳态的可能性

    // ------------------------------------------------------------------
    // 按域同步的复位释放
    // ------------------------------------------------------------------
    (* ASYNC_REG="TRUE" *) logic [1:0] wrst_sync, rrst_sync;
    always_ff @(posedge wclk or negedge rst_n)
        if (!rst_n) wrst_sync <= 2'b00;
        else        wrst_sync <= {wrst_sync[0], 1'b1};

    always_ff @(posedge rclk or negedge rst_n)
        if (!rst_n) rrst_sync <= 2'b00;
        else        rrst_sync <= {rrst_sync[0], 1'b1};

    wire wrst_n = wrst_sync[1];
    wire rrst_n = rrst_sync[1];

    // ------------------------------------------------------------------
    // 指针（多一位用于区分 full 与 empty）
    // ------------------------------------------------------------------
    logic [ADDRW:0] wbin, wgray;
    logic [ADDRW:0] rbin, rgray;

    (* ASYNC_REG="TRUE" *) logic [ADDRW:0] wgray_s1, wgray_s2;   // 写 Gray -> 读域
    (* ASYNC_REG="TRUE" *) logic [ADDRW:0] rgray_s1, rgray_s2;   // 读 Gray -> 写域

    logic           wfull_r, rempty_r;

    // ------------------------------------------------------------------
    // 存储器：仅在 wclk 写入，仅由 rclk 中的读指针寻址
    // ------------------------------------------------------------------
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    wire winc = wvalid & wready;
    wire rinc = rvalid & rready;

    // 只有当本域的复位释放后，写/读才会被宣告为已接受；
    // 复位期间指针不推进，因此未门控的 wready
    // 会错误地暗示写已被接受。
    assign wready = wrst_n & ~wfull_r;
    assign rvalid = rrst_n & ~rempty_r;
    assign wfull  = wfull_r;
    assign rempty = rempty_r;

    always_ff @(posedge wclk) begin
        if (winc) mem[wbin[ADDRW-1:0]] <= wdata;
    end

    assign rdata = mem[rbin[ADDRW-1:0]];

    // ------------------------------------------------------------------
    // 次态指针 + 标志（寄存器输出，不经过 wready 形成组合环路：
    // wready 使用寄存后的 wfull_r）
    // full=1 表示满，empty=1 表示空。wfull/rempty 仅在本域的复位释放后才有效。
    // ------------------------------------------------------------------
    wire [ADDRW:0] wbin_nxt  = wbin + {{ADDRW{1'b0}}, winc};
    wire [ADDRW:0] rbin_nxt  = rbin + {{ADDRW{1'b0}}, rinc};
    wire [ADDRW:0] wgray_nxt = bin2gray(wbin_nxt);
    wire [ADDRW:0] rgray_nxt = bin2gray(rbin_nxt);

    // 比较读指针和写指针，判断是否满
    wire [ADDRW:0] rfull_cmp = {~rgray_s2[ADDRW:ADDRW-1],
                                 rgray_s2[ADDRW-2:0]};

    always_ff @(posedge wclk or negedge wrst_n)
        if (!wrst_n) begin
            wbin    <= {ADDRW+1{1'b0}};
            wgray   <= {ADDRW+1{1'b0}};
            wfull_r <= 1'b0;
        end else begin
            wbin    <= wbin_nxt;
            wgray   <= wgray_nxt;
            wfull_r <= (wgray_nxt == rfull_cmp);
        end

    always_ff @(posedge rclk or negedge rrst_n)
        if (!rrst_n) begin
            rbin    <= {ADDRW+1{1'b0}};
            rgray   <= {ADDRW+1{1'b0}};
            rempty_r<= 1'b1;
        end else begin
            rbin    <= rbin_nxt;
            rgray   <= rgray_nxt;
            rempty_r<= (rgray_nxt == wgray_s2);
        end

    // ------------------------------------------------------------------
    // 指针同步器（2 级 FF，Gray 码，在目标域中寄存）
    // ------------------------------------------------------------------
    always_ff @(posedge rclk or negedge rrst_n)
        if (!rrst_n) {wgray_s2, wgray_s1} <= '0;
        else         {wgray_s2, wgray_s1} <= {wgray_s1, wgray};

    always_ff @(posedge wclk or negedge wrst_n)
        if (!wrst_n) {rgray_s2, rgray_s1} <= '0;
        else         {rgray_s2, rgray_s1} <= {rgray_s1, rgray};

endmodule
