// =============================================================================
// 文件 : index_loader20.sv
// 模块 : index_loader20
// 功能 : A 类 20-bit index ROM 装载器
// 说明 : 读 index/coeff ROM，输出 72-bit core；9×32 打包由 router_loader 完成。
//        一次装载一个 voice；20 指 index 表项位宽，不是模态数量。
// =============================================================================
`timescale 1ns/1ps

module index_loader20 #(
    parameter int NUM_VOICES  = 32,     // 可装载的 voice 数；load_voice 必须小于此值
    parameter int N_MODES     = 48,     // 每个 voice 允许的最大模态数
    parameter int COEFF_DEPTH = 5483,   // 系数 ROM 深度，单位为一个模态的 core 字
    parameter int INDEX_DEPTH = 1024,   // index ROM 深度；默认 4 乐器 × 128 音高 × 2 层
    parameter int COEFF_BITS  = 72,     // core 字宽；scale_word 当前固定使用 72-bit 布局
    parameter int INDEX_BITS  = 20,     // index 表项位宽：present + 模态数 + 系数偏移
    parameter int OFFSET_BITS = 13,    // index 内系数起始偏移的位宽
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES), // voice 编号位宽
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),  // 模态编号/数量位宽
    parameter COEFF_FILE = "rtl/rom/modal_coeff.mem", // 系数 ROM 初始化文件
    parameter INDEX_FILE = "rtl/rom/modal_index.mem", // index ROM 初始化文件
    parameter bit USE_BUF = 1'b0       // 0：读内部系数 ROM；1：用外部 BUF 返回的系数
) (
    input  logic                   clk,              // 工作时钟，上升沿采样
    input  logic                   rst_n,            // 低有效同步复位

    // Event（E1：class 必须为 0；layer[0] 承载旧 dyn）
    input  logic                   load_valid,       // 请求有效；与 load_ready 同为 1 时接收
    output logic                   load_ready,       // 空闲时为 1，可接收新事务
    input  logic [1:0]             ev_class,         // 乐器类别；本模块只接受 0（A 类）
    input  logic [1:0]             ev_layer,         // 音色层；仅 bit0 参与 index 寻址
    input  logic [3:0]             ev_instrument,    // 乐器编号；仅低两位参与 index 寻址
    input  logic [6:0]             ev_note,          // MIDI 音高编号，0..127
    input  logic [7:0]             ev_velocity,      // 力度，0..255；用于缩放各模态的 G
    input  logic [11:0]            ev_note_id,       // 音符实例编号；仅锁存并在 commit 时回传
    input  logic                   ev_gate,          // 门控元数据；仅锁存，不在此处理开关音
    input  logic [1:0]             ev_event_type,    // 事件类型元数据；仅锁存，不参与装载控制
    input  logic [VW-1:0]          load_voice,       // 本次装载的目标 voice 编号

    output logic                   busy,             // 非空闲状态为 1
    output logic                   load_done,        // 成功装载完成脉冲，持续一拍
    output logic [VW-1:0]          done_voice,        // 完成事务对应的 voice；load_done 时采样
    output logic [MW-1:0]          loaded_n_modes,    // 本次 index 指定的实际模态数
    output logic [15:0]            theta_base,        // 兼容接口；A 路径恒为 0，不输出系数基址

    output logic                   error_valid,      // 错误脉冲，持续一拍；错误事务不产生 load_done
    output logic [1:0]             error_code,       // error_valid 时有效：1=请求非法，2=缺项，3=元数据非法

    // 下游 clear
    output logic                   clear_valid,      // 请求下游清除目标 voice 的旧状态
    input  logic                   clear_ready,      // 下游接受 clear；握手后开始装载系数
    output logic [VW-1:0]          clear_voice,       // 待清除的 voice 编号

    // 下游 core 写入（burst 1 词/拍）
    output logic                   cfg_valid,        // 当前 core 字有效
    input  logic                   cfg_ready,        // 下游接受当前 core 字；握手后推进模态计数
    output logic [VW-1:0]          cfg_voice,        // 当前 core 字写入的 voice
    output logic [MW-1:0]          cfg_mode,         // 当前 core 字写入的模态编号，0..n_r-1
    output logic [COEFF_BITS-1:0]  cfg_word,         // 已缩放 G 的 {G[25:0], a2[23:0], a1[21:0]}

    // BUF 读口（USE_BUF=1 时替代 coeff_rom）
    output logic                   buf_rd_en,        // 系数预读/输出阶段的 BUF 读使能
    output logic [15:0]            buf_rd_addr,      // BUF 系数字地址，非字节地址
    input  logic [COEFF_BITS-1:0]  buf_rd_data,      // 外部 BUF 返回的 core 字；USE_BUF=1 时被选中

    // 下游 seed 兼容接口：A 不写初始状态，实际 seed 装载由 index_loader64 支持
    output logic                   seed_valid,       // 恒为 0，不发出 seed 写请求
    input  logic                   seed_ready,       // 兼容输入；本模块不使用
    output logic [VW-1:0]          seed_voice,       // 回传锁存的目标 voice；seed_valid=0 时无效
    output logic [MW-1:0]          seed_mode,        // 恒为 0
    output logic [63:0]            seed_word,        // 恒为 0；不是实时噪声数据

    // 装载提交：commit_valid 时采样；当前 router_loader 未连接这些元数据输出
    output logic                   commit_valid,     // 与 load_done 相同的完成脉冲
    output logic [2:0]             commit_class,     // 锁存类别补零到 3-bit；成功事务为 A=0
    output logic [1:0]             commit_layer,     // 原始音色层，两位均回传
    output logic [3:0]             commit_instrument,// 原始乐器编号，四位均回传
    output logic [6:0]             commit_note,      // 本次装载的 MIDI 音高
    output logic [7:0]             commit_velocity,  // 本次装载的原始 8-bit 力度
    output logic [11:0]            commit_note_id,   // 本次装载的音符实例编号
    output logic [MW-1:0]          commit_n_modes    // 本次装载的实际模态数
);

    localparam logic [2:0] S_IDLE  = 3'd0,  // 空闲，接收并锁存请求
                           S_IDX   = 3'd1,  // 等待同步 index ROM 读取
                           S_CHK   = 3'd2,  // 校验已寄存的 index，保存偏移和模态数
                           S_CLEAR = 3'd3,  // 等待下游接受 voice 清除请求
                           S_RD    = 3'd4,  // 首个 core 字预读，建立 rd_valid
                           S_CORE  = 3'd5,  // 逐模态输出 core 字
                           S_DONE  = 3'd6,  // 产生完成脉冲并返回空闲
                           S_CHK_DEC = 3'd7; // 将同步 index 读结果寄存，隔离解码路径

    // ------------------------------------------------------------------
    // A ROM（同步读）
    // ------------------------------------------------------------------
    logic [COEFF_BITS-1:0] coeff_rom [0:COEFF_DEPTH-1]; // 每项为一个模态的 G/a2/a1
    logic [INDEX_BITS-1:0] index_rom [0:INDEX_DEPTH-1]; // 每项为某乐器/音高/层的元数据
    initial begin
        $readmemh(COEFF_FILE, coeff_rom);
        $readmemh(INDEX_FILE, index_rom);
    end

    logic [9:0]             idx_raddr;   // index 读地址：{instrument[1:0], note[6:0], layer[0]}
    logic [COEFF_BITS-1:0]  coeff_rdata; // 系数同步读寄存器；BUF 模式下也寄存 BUF 返回值
    logic [INDEX_BITS-1:0]  idx_rdata;   // index ROM 的同步读输出
    logic                   rd_valid;    // core 数据流有效标志；首字预读后置 1，末字握手后清零
    logic [INDEX_BITS-1:0]  idx_q;       // 进入 S_CHK 前额外寄存的 index，用于元数据解码

    // ------------------------------------------------------------------
    // 事务状态
    // ------------------------------------------------------------------
    logic [2:0]          st;            // 当前装载状态机状态
    logic [VW-1:0]       voice_r;       // 锁存的目标 voice，整个事务共用
    logic [1:0]          class_r, layer_r; // 锁存的类别、音色层；layer_r[0] 用于寻址
    logic [3:0]          inst_r;        // 锁存的乐器编号；inst_r[1:0] 用于寻址
    logic [6:0]          note_r;        // 锁存的 MIDI 音高
    logic [7:0]          vel_r;         // 锁存的力度，供 vel_q 和 G 缩放使用
    logic [11:0]         nid_r;         // 锁存的音符实例编号；仅用于 commit 回传
    logic                gate_r;        // 锁存的 gate；当前未被后续逻辑消费
    logic [1:0]          evt_r;         // 锁存的事件类型；当前未被后续逻辑消费
    logic [OFFSET_BITS-1:0] offset_r;   // 当前音色块在系数 ROM/BUF 中的起始字地址
    logic [MW-1:0]       n_r;           // index 校验通过后锁存的实际模态数，1..N_MODES
    logic [MW-1:0]       cnt;           // 当前输出模态编号；每次 cfg 握手后递增

    // 1 词/拍：地址组合给出「下一个词」，同步 ROM 在下一拍把数据送到
    // cfg；当前拍呈现的是上一拍读出的词。代价是 offset+cnt 加法进入
    // ROM 地址路径，综合/P&R 时必须单独检查。
    // core_next：预取的模态编号；通常为 cnt+1，最后一个模态保持 cnt 防止越界。
    wire [OFFSET_BITS-1:0] core_next = (cnt == (n_r - MW'(1))) ? cnt
                                                                  : (cnt + MW'(1));
    // coeff_raddr：系数 ROM/BUF 的字地址；启动时读 offset_r，输出时预取下一模态。
    wire [OFFSET_BITS-1:0] coeff_raddr = (st == S_CORE) ? (offset_r + core_next) :
                                         ((st == S_CLEAR) || (st == S_RD)) ? offset_r :
                                         {OFFSET_BITS{1'b0}};

    assign buf_rd_en   = (st == S_RD) || (st == S_CORE);
    assign buf_rd_addr = {3'b0, coeff_raddr};

    always_ff @(posedge clk) begin
        coeff_rdata <= USE_BUF ? buf_rd_data : coeff_rom[coeff_raddr];
        idx_rdata   <= index_rom[idx_raddr];
    end


    wire [9:0] req_addr = {inst_r[1:0], note_r, layer_r[0]}; // 由锁存事件重建的 index 地址

    // 20-bit A index 适配：present[19], n[18:13], offset[12:0]
    localparam int N_FIELD_W = INDEX_BITS - 1 - OFFSET_BITS; // 模态数字段位宽，默认 6
    wire [N_FIELD_W-1:0]   n_field   = idx_q[INDEX_BITS-2 -: N_FIELD_W]; // 解码的实际模态数
    wire [OFFSET_BITS-1:0] off_field = idx_q[OFFSET_BITS-1:0]; // 解码的系数块起始字地址
    wire [OFFSET_BITS:0]   entry_end = {1'b0, off_field} + {1'b0, n_field}; // 块尾后一项地址，用于越界检查
    wire n_illegal = (n_field == {N_FIELD_W{1'b0}}) || (n_field > N_MODES); // 模态数为 0 或超过上限

    // 用移位加法近似 vel/255 的 UQ1.15 增益；实际计算 floor((vel*257+1)/2)。
    wire [16:0] vel_q_sum = {1'b0, vel_r, 8'b0} + {9'b0, vel_r} + 17'd1; // vel*257+1，中间值保留进位
    wire [15:0] vel_q     = vel_q_sum[16:1]; // UQ1.15 力度增益；vel=255 时恰为 32768（1.0）

    // 与旧 coeff_loader 相同的 G 缩放（vel=255 旁路，逐位不变）
    // w：原始 72-bit core；vq：UQ1.15 力度增益；返回只修改 G、保留 a2/a1 的 core。
    function automatic [71:0] scale_word(input [71:0] w, input [15:0] vq);
        logic signed [25:0] g;         // 从 w[71:46] 取出的有符号 Q2.24 模态输入增益
        logic signed [42:0] prod, rnd; // prod：G×力度全精度积；rnd：加半 LSB 并右移 15 位的结果
        logic signed [25:0] gs;        // 舍入、饱和或满力度旁路后的 Q2.24 增益
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
    wire [COEFF_BITS-1:0] coeff_data = USE_BUF ? buf_rd_data : coeff_rdata; // 实际送入缩放器的原始 core
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
            idx_q       <= '0;
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
                    st        <= S_CHK_DEC;
                end

                S_CHK_DEC: begin
                    idx_q <= idx_rdata;
                    st    <= S_CHK;
                end

                S_CHK: begin
                    if (!idx_q[INDEX_BITS-1]) begin
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
                        n_r      <= idx_q[INDEX_BITS-2 -: N_FIELD_W];
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
