// =============================================================================
// 文件 : control_loop.sv
// 模块 : control_loop
// 功能 : 周期轮询请求来源，暂存并原样转交一条配置请求。
// 说明 : 不解释载荷、不修改配置索引、不驱动音频或动画。
//        所有端口同一 clk 域；来源必须保持 valid/payload 到握手。
//        poll_tick 只允许空闲时读取来源，不限制已暂存请求的交付。
//        满槽时不再读取来源；出队同拍不入队。reset 取消未交付请求。
// =============================================================================
`timescale 1ns/1ps

module control_loop #(
    parameter int SOURCES   = 1,
    parameter int REQUEST_W = 32
) (
    input  logic clk,
    input  logic rst_n,
    input  logic poll_tick,

    input  logic [SOURCES-1:0]                src_valid,
    output logic [SOURCES-1:0]                src_ready,
    input  logic [SOURCES-1:0][REQUEST_W-1:0] src_request,

    output logic req_valid,
    input  logic req_ready,
    output logic [REQUEST_W-1:0] req_request,
    output logic [((SOURCES > 1) ? $clog2(SOURCES) : 1)-1:0] req_source
);
    localparam int SOURCE_W = (SOURCES > 1) ? $clog2(SOURCES) : 1;

    logic [SOURCE_W-1:0] rr_next;
    logic [SOURCE_W-1:0] selected_source;
    logic selected_valid;
    integer candidate;

    // Scan once from rr_next; explicit wrap also handles non-power-of-two counts.
    always_comb begin
        src_ready       = '0;
        selected_source = '0;
        selected_valid  = 1'b0;
        candidate       = 0; // 给扫描临时量完整赋值，避免 Gowin 推断锁存器。
        if (rst_n && poll_tick && !req_valid) begin
            for (int offset = 0; offset < SOURCES; offset++) begin
                candidate = int'(rr_next) + offset;
                if (candidate >= SOURCES) candidate = candidate - SOURCES;
                // Ready describes capacity, independent of this source's valid.
                // Stop offering later sources only after an earlier valid one.
                // This breaks the bridge valid -> arbiter ready return path.
                if (!selected_valid) begin
                    src_ready[candidate]  = 1'b1;
                    if (src_valid[candidate]) begin
                        selected_valid  = 1'b1;
                        selected_source = SOURCE_W'(candidate);
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_next     <= '0;
            req_valid   <= 1'b0;
            req_request <= '0;
            req_source  <= '0;
        end else if (req_valid) begin
            if (req_ready) req_valid <= 1'b0;
        end else if (selected_valid) begin
            req_valid   <= 1'b1;
            req_request <= src_request[selected_source];
            req_source  <= selected_source;
            rr_next     <= (selected_source == SOURCE_W'(SOURCES-1))
                         ? '0 : selected_source + 1'b1;
        end
    end

    // synthesis translate_off
    initial begin
        if (SOURCES < 1)   $fatal(1, "control_loop SOURCES must be >= 1");
        if (REQUEST_W < 1) $fatal(1, "control_loop REQUEST_W must be >= 1");
    end
    // synthesis translate_on
endmodule
