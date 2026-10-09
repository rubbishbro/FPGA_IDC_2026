// -----------------------------------------------------------------------------
// coeff_loader.sv -- module 2B：index/coefficient ROM loader。
//
// 为一个 (instrument, MIDI, dynamic) key 查找稠密的 1024-entry
// index ROM，校验该 entry，清除目标 voice 的状态，然后
// 通过 cfg 握手将该 entry 的系数流式
// 写入 modal bank。只有最终的 cfg 握手才会产生 load_done。
//
// 契约（rtl/module2BC_design.md 第 3 和 5 节）：
//   * load 输入仅在 load 握手时锁存；busy 期间 load_ready=0
//   * 在进行任何 clear/cfg 之前，整个 entry 都被查找并做范围检查
//   * 缺失的 entry 或非法 ROM metadata 会发出一个 error 脉冲并返回 idle，
//     不进行 clear、cfg 或 load_done
//   * cfg/clear 字段保持稳定，直到下游握手
//   * 任意下游 backpressure 都不会丢失或重复一个 word
//   * reset 取消事务和每个有效 token
//
// 这些 ROM 为同步读，用 $readmemh 初始化，运行时从不解析。
// 72-bit 逻辑读端口并不承诺物理 BSRAM 映射。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module coeff_loader #(
    parameter int NUM_VOICES  = 32,
    parameter int N_MODES     = 48,
    parameter int COEFF_DEPTH = 5483,
    parameter int INDEX_DEPTH = 1024,
    parameter int COEFF_BITS  = 72,
    parameter int INDEX_BITS  = 20,
    parameter int OFFSET_BITS = 13,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/modal_index.mem"
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // 加载请求
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [VW-1:0]          load_voice,
    input  logic [1:0]             load_instrument,
    input  logic [6:0]             load_midi,
    input  logic                   load_dyn,

    output logic                   busy,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,

    output logic                   error_valid,
    output logic [1:0]             error_code,

    // 下游状态清除
    output logic                   clear_valid,
    input  logic                   clear_ready,
    output logic [VW-1:0]          clear_voice,

    // 下游系数写入
    output logic                   cfg_valid,
    input  logic                   cfg_ready,
    output logic [VW-1:0]          cfg_voice,
    output logic [MW-1:0]          cfg_mode,
    output logic [COEFF_BITS-1:0]  cfg_word
);

    localparam logic [2:0] S_IDLE  = 3'd0,
                           S_IDX   = 3'd1,
                           S_CHK   = 3'd2,
                           S_CLEAR = 3'd3,
                           S_CRD   = 3'd4,
                           S_CFG   = 3'd5,
                           S_DONE  = 3'd6;

    // ------------------------------------------------------------------
    // ROM 数组（同步读），从生成的映像初始化
    // ------------------------------------------------------------------
    logic [COEFF_BITS-1:0] coeff_rom [0:COEFF_DEPTH-1];
    logic [INDEX_BITS-1:0] index_rom [0:INDEX_DEPTH-1];
    initial begin
        $readmemh(COEFF_FILE, coeff_rom);
        $readmemh(INDEX_FILE, index_rom);
    end

    logic [OFFSET_BITS-1:0]           coeff_raddr;
    logic [9:0]                       idx_raddr;
    logic [COEFF_BITS-1:0]            coeff_rdata;
    logic [INDEX_BITS-1:0]            idx_rdata;

    always_ff @(posedge clk) begin
        coeff_rdata <= coeff_rom[coeff_raddr];
        idx_rdata   <= index_rom[idx_raddr];
    end

    // ------------------------------------------------------------------
    // 事务状态
    // ------------------------------------------------------------------
    logic [2:0]          st;
    logic [VW-1:0]       voice_r;
    logic [1:0]          inst_r;
    logic [6:0]          midi_r;
    logic                dyn_r;
    logic [OFFSET_BITS-1:0] offset_r;
    logic [MW-1:0]       n_r;          // 完整 entry 的 mode 数量
    logic [MW-1:0]       cnt;          // 正在写入的 mode

    wire [9:0] req_addr = {inst_r, midi_r, dyn_r};

    // index word 字段
    localparam int N_FIELD_W = INDEX_BITS - 1 - OFFSET_BITS;   // 6
    wire [N_FIELD_W-1:0]   n_field = idx_rdata[INDEX_BITS-2 -: N_FIELD_W];
    wire [OFFSET_BITS-1:0] off_field = idx_rdata[OFFSET_BITS-1:0];
    wire [OFFSET_BITS:0]   entry_end = {1'b0, off_field} + {1'b0, n_field};
    wire n_illegal = (n_field == {N_FIELD_W{1'b0}}) || (n_field > N_MODES);

    // 呈现给下游 bank 的字段；等待 ready 期间保持稳定
    assign load_ready    = (st == S_IDLE);
    assign busy          = (st != S_IDLE);
    assign clear_valid   = (st == S_CLEAR);
    assign clear_voice   = voice_r;
    assign cfg_valid     = (st == S_CFG);
    assign cfg_voice     = voice_r;
    assign cfg_mode      = cnt;
    assign cfg_word      = coeff_rdata;
    assign done_voice    = voice_r;
    assign loaded_n_modes= n_r;

    // 系数读地址：offset + cnt（额外余量，然后截断）
    wire [OFFSET_BITS+MW:0] coff_sum = {1'b0, offset_r} + {{(OFFSET_BITS+1){1'b0}},
                                                           cnt};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st           <= S_IDLE;
            voice_r      <= {VW{1'b0}};
            inst_r       <= 2'd0;
            midi_r       <= 7'd0;
            dyn_r        <= 1'b0;
            offset_r     <= {OFFSET_BITS{1'b0}};
            n_r          <= {MW{1'b0}};
            cnt          <= {MW{1'b0}};
            idx_raddr    <= 10'd0;
            coeff_raddr  <= {OFFSET_BITS{1'b0}};
            load_done    <= 1'b0;
            error_valid  <= 1'b0;
            error_code   <= 2'd0;
        end else begin
            load_done   <= 1'b0;
            error_valid <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (load_valid) begin
                        // 锁存请求
                        voice_r <= load_voice;
                        inst_r  <= load_instrument;
                        midi_r  <= load_midi;
                        dyn_r   <= load_dyn;
                        if (load_voice >= NUM_VOICES) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd1;        // voice 越界
                        end else begin
                            idx_raddr <= {load_instrument, load_midi, load_dyn};
                            st        <= S_IDX;
                        end
                    end
                end

                S_IDX: begin
                    // 该边沿后 index_rom[req_addr] 出现在 idx_rdata 上
                    idx_raddr <= req_addr;
                    st        <= S_CHK;
                end

                S_CHK: begin
                    if (!idx_rdata[INDEX_BITS-1]) begin
                        error_valid <= 1'b1;
                        error_code  <= 2'd2;            // 缺失 entry
                        st          <= S_IDLE;
                    end else if (n_illegal ||
                                 (entry_end > (OFFSET_BITS+1)'(COEFF_DEPTH))) begin
                        error_valid <= 1'b1;
                        error_code  <= 2'd3;            // metadata 非法 / 超出 ROM
                        st          <= S_IDLE;
                    end else begin
                        offset_r <= off_field;
                        n_r      <= idx_rdata[INDEX_BITS-2 -: N_FIELD_W];
                        cnt      <= {MW{1'b0}};
                        st       <= S_CLEAR;
                    end
                end

                S_CLEAR: begin
                    if (clear_ready) begin
                        coeff_raddr <= offset_r;
                        st          <= S_CRD;
                    end
                end

                S_CRD: begin
                    coeff_raddr <= coff_sum[OFFSET_BITS-1:0];
                    st          <= S_CFG;
                end

                S_CFG: begin
                    if (cfg_ready) begin
                        if (cnt == (n_r - MW'(1))) begin
                            st <= S_DONE;
                        end else begin
                            cnt         <= cnt + MW'(1);
                            coeff_raddr <= offset_r + cnt + MW'(1);
                            st          <= S_CRD;
                        end
                    end
                end

                default: begin // S_DONE
                    load_done <= 1'b1;
                    st        <= S_IDLE;
                end
            endcase
        end
    end

endmodule
