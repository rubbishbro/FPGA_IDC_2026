`timescale 1ns/1ps
// =============================================================================
// comm_fifo : 带预取输出寄存器的同步字节/字 FIFO。
//
// - 两侧都使用标准 valid/ready 握手。
// - 在 m_valid && !m_ready 期间，输出 valid/data 保持稳定。
// - 同步 RAM 读；一个周期的读延迟由预取寄存器隐藏。pop 之后允许出现气泡
//   （这是已文档化的行为）。
// - level 统计所有已存字，包括输出寄存器里的字和已经发出但未返回的读。
// - flush 是同步维护清零，只清指针/计数；RAM 内容有意不复位。
// - 支持任意正整数 DEPTH，包括 DEPTH=1。
// =============================================================================
module comm_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         flush,

    input  logic                         s_valid,
    output logic                         s_ready,
    input  logic [WIDTH-1:0]             s_data,

    output logic                         m_valid,
    input  logic                         m_ready,
    output logic [WIDTH-1:0]             m_data,

    output logic [$clog2(DEPTH+1)-1:0]   level
);

    localparam int PTR_W  = (DEPTH < 2) ? 1 : $clog2(DEPTH);
    localparam int CNT_W  = $clog2(DEPTH + 1);

    localparam logic [PTR_W-1:0] PTR_MAX   = PTR_W'(DEPTH - 1);
    localparam logic [CNT_W-1:0] DEPTH_VAL = CNT_W'(DEPTH);

    logic [PTR_W-1:0] wr_ptr;
    logic [PTR_W-1:0] rd_ptr;
    logic [CNT_W-1:0] ram_count;

    logic             out_valid;
    logic [WIDTH-1:0] out_data;
    logic             load_pending;
    logic [WIDTH-1:0] rd_data_q;

    // 总占用量是一个寄存器，不在 ready/故障路径上累加 RAM/输出/预取计数器。
    // 内部搬移永远不会改变总占用量。
    assign s_ready = rst_n && !flush && (level != DEPTH_VAL);

    wire do_push = s_valid && s_ready;
    wire do_pop  = m_valid && m_ready && !flush;

    // 当输出级为空（或即将为空）且 RAM 中有字可用时，启动一次读。
    // 上一次读尚未返回时，不启动新的读。
    wire out_will_be_empty = !out_valid || do_pop;
    wire issue_read = !flush && !load_pending && out_will_be_empty &&
                      (ram_count != '0);

    assign m_valid = out_valid;
    assign m_data  = out_data;

    // 很小的回复队列不应各自占用一块 BSRAM。较大的 FIFO 保留简单的同步 RAM
    // 端口，且不放在复位/flush 控制下，便于工具推断。
    generate
        if (DEPTH >= 32) begin : g_bram
            (* syn_ramstyle = "block_ram" *) logic [WIDTH-1:0] mem [0:DEPTH-1];
            always_ff @(posedge clk) begin
                if (do_push) mem[wr_ptr] <= s_data;
                if (issue_read) rd_data_q <= mem[rd_ptr];
            end
        end else begin : g_small
            logic [WIDTH-1:0] mem [0:DEPTH-1];
            always_ff @(posedge clk) begin
                if (do_push) mem[wr_ptr] <= s_data;
                if (issue_read) rd_data_q <= mem[rd_ptr];
            end
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr       <= '0;
            rd_ptr       <= '0;
            ram_count    <= '0;
            out_valid    <= 1'b0;
            out_data     <= '0;
            load_pending <= 1'b0;
            level        <= '0;
        end else if (flush) begin
            // 不要复位 mem[]；只丢弃所有有效的记录/计数。
            wr_ptr       <= '0;
            rd_ptr       <= '0;
            ram_count    <= '0;
            out_valid    <= 1'b0;
            out_data     <= '0;
            load_pending <= 1'b0;
            level        <= '0;
        end else begin
            if (do_push) begin
                wr_ptr <= (wr_ptr == PTR_MAX) ? '0 : (wr_ptr + 1'b1);
            end

            if (issue_read) begin
                rd_ptr    <= (rd_ptr == PTR_MAX) ? '0 : (rd_ptr + 1'b1);
                load_pending <= 1'b1;
            end else if (load_pending) begin
                out_data     <= rd_data_q;
                out_valid    <= 1'b1;
                load_pending <= 1'b0;
            end

            if (do_pop)
                out_valid <= 1'b0;

            // RAM 写/读指针各自独立更新；在上面的占用量限制下，
            // 它们不会指向同一个有效槽位，从而不会破坏同时发生的 push/pop。
            case ({do_push, issue_read})
                2'b10:   ram_count <= ram_count + 1'b1;
                2'b01:   ram_count <= ram_count - 1'b1;
                default: ram_count <= ram_count;
            endcase
            case ({do_push, do_pop})
                2'b10: level <= level + 1'b1;
                2'b01: level <= level - 1'b1;
                default: ;
            endcase
        end
    end

endmodule
