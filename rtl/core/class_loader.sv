// -----------------------------------------------------------------------------
// class_loader.sv -- ENG1 统一装载器（E1：A 路径 + 统一端口）
//
// 目标：把旧的 coeff_loader（20-bit index / 每词 4 拍）替换成统一记录流：
//   Event -> Index -> Control -> Core -> (Seed) -> Commit
// E1 只实现 A 类数据路径：
//   * 外部仍收旧的 (instrument, midi, dyn, vel)，内部合成 Event；
//   * A 的 index 仍是 20-bit {present,n[5:0],offset[12:0]}，在本模块内
//     适配成统一视图；
//   * Control 暂用 A 默认值（E1 不消费，端口先留）；
//   * Core 改为 burst 1 词/拍；
//   * Seed 端口保留，A 恒 0（C 在 E2/E4 接）。
//
// 契约：
//   * load 输入仅在 load 握手时锁存；busy 时 load_ready=0
//   * 先完整查表并校验，再 clear，再 burst 写系数；失败不 clear/cfg
//   * cfg/clear 字段在 ready 前保持稳定；背压不丢词、不重复
//   * 最后一个 cfg 握手后才 load_done
//   * reset 取消事务
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module class_loader #(
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
    parameter INDEX_FILE = "rtl/rom/modal_index.mem",
    parameter bit USE_BUF = 1'b0
) (
    input  logic                   clk,
    input  logic                   rst_n,

    // Event（E1：class 必须为 0；layer[0] 承载旧 dyn）
    input  logic                   load_valid,
    output logic                   load_ready,
    input  logic [1:0]             ev_class,
    input  logic [1:0]             ev_layer,
    input  logic [3:0]             ev_instrument,
    input  logic [6:0]             ev_note,
    input  logic [7:0]             ev_velocity,
    input  logic [11:0]            ev_note_id,
    input  logic                   ev_gate,
    input  logic [1:0]             ev_event_type,
    input  logic [VW-1:0]          load_voice,

    output logic                   busy,
    output logic                   load_done,
    output logic [VW-1:0]          done_voice,
    output logic [MW-1:0]          loaded_n_modes,
    output logic [15:0]            theta_base,

    output logic                   error_valid,
    output logic [1:0]             error_code,

    // 下游 clear
    output logic                   clear_valid,
    input  logic                   clear_ready,
    output logic [VW-1:0]          clear_voice,

    // 下游 core 写入（burst 1 词/拍）
    output logic                   cfg_valid,
    input  logic                   cfg_ready,
    output logic [VW-1:0]          cfg_voice,
    output logic [MW-1:0]          cfg_mode,
    output logic [COEFF_BITS-1:0]  cfg_word,

    // BUF 读口（USE_BUF=1 时替代 coeff_rom）
    output logic                   buf_rd_en,
    output logic [15:0]            buf_rd_addr,
    input  logic [COEFF_BITS-1:0]  buf_rd_data,

    // 下游 seed 写入（E1 恒 0；C 在 E2/E4 接）
    output logic                   seed_valid,
    input  logic                   seed_ready,
    output logic [VW-1:0]          seed_voice,
    output logic [MW-1:0]          seed_mode,
    output logic [63:0]            seed_word,

    // 装载提交（E1 先留端口；engine 暂不消费）
    output logic                   commit_valid,
    output logic [2:0]             commit_class,
    output logic [1:0]             commit_layer,
    output logic [3:0]             commit_instrument,
    output logic [6:0]             commit_note,
    output logic [7:0]             commit_velocity,
    output logic [11:0]            commit_note_id,
    output logic [MW-1:0]          commit_n_modes
);

    localparam logic [2:0] S_IDLE  = 3'd0,
                           S_IDX   = 3'd1,
                           S_CHK   = 3'd2,
                           S_CLEAR = 3'd3,
                           S_RD    = 3'd4,
                           S_CORE  = 3'd5,
                           S_DONE  = 3'd6;

    // ------------------------------------------------------------------
    // A ROM（同步读）
    // ------------------------------------------------------------------
    logic [COEFF_BITS-1:0] coeff_rom [0:COEFF_DEPTH-1];
    logic [INDEX_BITS-1:0] index_rom [0:INDEX_DEPTH-1];
    initial begin
        $readmemh(COEFF_FILE, coeff_rom);
        $readmemh(INDEX_FILE, index_rom);
    end

    logic [9:0]             idx_raddr;
    logic [COEFF_BITS-1:0]  coeff_rdata;
    logic [INDEX_BITS-1:0]  idx_rdata;
    logic                   rd_valid;

    // ------------------------------------------------------------------
    // 事务状态
    // ------------------------------------------------------------------
    logic [2:0]          st;
    logic [VW-1:0]       voice_r;
    logic [1:0]          class_r, layer_r;
    logic [3:0]          inst_r;
    logic [6:0]          note_r;
    logic [7:0]          vel_r;
    logic [11:0]         nid_r;
    logic                gate_r;
    logic [1:0]          evt_r;
    logic [OFFSET_BITS-1:0] offset_r;
    logic [MW-1:0]       n_r;
    logic [MW-1:0]       cnt;

    // 1 词/拍：地址组合给出「下一个词」，同步 ROM 在下一拍把数据送到
    // cfg；当前拍呈现的是上一拍读出的词。代价是 offset+cnt 加法进入
    // ROM 地址路径，综合/P&R 时必须单独检查。
    wire [OFFSET_BITS-1:0] core_next = (cnt == (n_r - MW'(1))) ? cnt
                                                                  : (cnt + MW'(1));
    wire [OFFSET_BITS-1:0] coeff_raddr = (st == S_CORE) ? (offset_r + core_next) :
                                         ((st == S_CLEAR) || (st == S_RD)) ? offset_r :
                                         {OFFSET_BITS{1'b0}};

    assign buf_rd_en   = (st == S_RD) || (st == S_CORE);
    assign buf_rd_addr = {3'b0, coeff_raddr};

    always_ff @(posedge clk) begin
        coeff_rdata <= USE_BUF ? buf_rd_data : coeff_rom[coeff_raddr];
        idx_rdata   <= index_rom[idx_raddr];
    end


    wire [9:0] req_addr = {inst_r[1:0], note_r, layer_r[0]};

    // 20-bit A index 适配：present[19], n[18:13], offset[12:0]
    localparam int N_FIELD_W = INDEX_BITS - 1 - OFFSET_BITS;   // 6
    wire [N_FIELD_W-1:0]   n_field   = idx_rdata[INDEX_BITS-2 -: N_FIELD_W];
    wire [OFFSET_BITS-1:0] off_field = idx_rdata[OFFSET_BITS-1:0];
    wire [OFFSET_BITS:0]   entry_end = {1'b0, off_field} + {1'b0, n_field};
    wire n_illegal = (n_field == {N_FIELD_W{1'b0}}) || (n_field > N_MODES);

    // vel_q = round(vel * 32768 / 255)
    wire [16:0] vel_q_sum = {1'b0, vel_r, 8'b0} + {9'b0, vel_r} + 17'd1;
    wire [15:0] vel_q     = vel_q_sum[16:1];

    // 与旧 coeff_loader 相同的 G 缩放（vel=255 旁路，逐位不变）
    function automatic [71:0] scale_word(input [71:0] w, input [15:0] vq);
        logic signed [25:0] g;
        logic signed [42:0] prod, rnd;
        logic signed [25:0] gs;
        begin
            g    = $signed(w[71:46]);
            prod = g * $signed({1'b0, vq});
            rnd  = (prod + 43'sd16384) >>> 15;
            if (vq == 16'd32768)
                gs = g;
            else if (rnd > 43'sd33554431)
                gs = 26'sd33554431;
            else if (rnd < -43'sd33554432)
                gs = 26'sh2000000;
            else
                gs = rnd[25:0];
            scale_word = {gs, w[45:0]};
        end
    endfunction

    assign load_ready     = (st == S_IDLE);
    assign busy           = (st != S_IDLE);
    assign clear_valid    = (st == S_CLEAR);
    assign clear_voice    = voice_r;
    assign cfg_valid      = (st == S_CORE) && rd_valid;
    assign cfg_voice      = voice_r;
    assign cfg_mode       = cnt;
    wire [COEFF_BITS-1:0] coeff_data = USE_BUF ? buf_rd_data : coeff_rdata;
    assign cfg_word       = scale_word(coeff_data, vel_q);
    assign done_voice     = voice_r;
    assign loaded_n_modes = n_r;
    assign theta_base     = 16'd0;

    // E1：A 不写 seed
    assign seed_valid = 1'b0;
    assign seed_voice = voice_r;
    assign seed_mode  = {MW{1'b0}};
    assign seed_word  = 64'd0;

    assign commit_valid      = load_done;
    assign commit_class      = {1'b0, class_r};
    assign commit_layer      = layer_r;
    assign commit_instrument = inst_r;
    assign commit_note       = note_r;
    assign commit_velocity   = vel_r;
    assign commit_note_id    = nid_r;
    assign commit_n_modes    = n_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st          <= S_IDLE;
            voice_r     <= {VW{1'b0}};
            class_r     <= 2'd0;
            layer_r     <= 2'd0;
            inst_r      <= 4'd0;
            note_r      <= 7'd0;
            vel_r       <= 8'd255;
            nid_r       <= 12'd0;
            gate_r      <= 1'b0;
            evt_r       <= 2'd0;
            offset_r    <= {OFFSET_BITS{1'b0}};
            n_r         <= {MW{1'b0}};
            cnt         <= {MW{1'b0}};
            idx_raddr   <= 10'd0;
            rd_valid    <= 1'b0;
            load_done   <= 1'b0;
            error_valid <= 1'b0;
            error_code  <= 2'd0;
        end else begin
            load_done   <= 1'b0;
            error_valid <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (load_valid) begin
                        voice_r <= load_voice;
                        class_r <= ev_class;
                        layer_r <= ev_layer;
                        inst_r  <= ev_instrument;
                        note_r  <= ev_note;
                        vel_r   <= ev_velocity;
                        nid_r   <= ev_note_id;
                        gate_r  <= ev_gate;
                        evt_r   <= ev_event_type;
                        if (load_voice >= NUM_VOICES) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd1;      // voice 越界
                        end else if (ev_class != 2'd0) begin
                            error_valid <= 1'b1;
                            error_code  <= 2'd1;      // E1 只接 A
                        end else begin
                            idx_raddr <= {ev_instrument[1:0], ev_note, ev_layer[0]};
                            st        <= S_IDX;
                        end
                    end
                end

                S_IDX: begin
                    idx_raddr <= req_addr;
                    st        <= S_CHK;
                end

                S_CHK: begin
                    if (!idx_rdata[INDEX_BITS-1]) begin
                        error_valid <= 1'b1;
                        error_code  <= 2'd2;          // 缺失 entry
                        st          <= S_IDLE;
                    end else if (n_illegal ||
                                 (entry_end > (OFFSET_BITS+1)'(COEFF_DEPTH))) begin
                        error_valid <= 1'b1;
                        error_code  <= 2'd3;          // metadata 非法
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
                        st <= S_RD;
                    end
                end

                S_RD: begin
                    // 地址已在 S_CLEAR 周期给出 offset；本拍末尾 ROM 输出
                    // word 0，S_CORE 从下一拍起 1 词/拍。
                    rd_valid <= 1'b1;
                    st       <= S_CORE;
                end

                S_CORE: begin
                    if (rd_valid && cfg_ready) begin
                        if (cnt == (n_r - MW'(1))) begin
                            rd_valid <= 1'b0;
                            st       <= S_DONE;
                        end else begin
                            cnt <= cnt + MW'(1);
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
