// =============================================================================
// 文件 : index_loader64.sv
// 模块 : index_loader64
// 功能 : B/C/E2 64-bit index/control/seed 装载器
// 说明 : 读 index/control/coeff/seed，输出 72-bit core、seed 和 ctrl；由 router_loader 包装。
//        64 指 index 表项位宽，不是模态数量；E2 的宽系数记录也由外层读取。
// =============================================================================
`timescale 1ns/1ps

module index_loader64 #(
    parameter int NUM_VOICES   = 32,    // 可装载的 voice 数；load_voice 必须小于此值
    parameter int N_MODES      = 48,    // 每个 voice 允许的最大模态数；E2 可由外层覆盖为 80
    parameter int COEFF_DEPTH  = 5483,  // 系数存储深度，单位为模态 core 字；用于边界检查
    parameter int INDEX_DEPTH  = 8192,  // index 深度；13-bit key 对应 4 类 × 16 乐器 × 128 音高
    parameter int CTRL_DEPTH   = 1024,  // control ROM 深度，每项 256-bit；读地址当前固定 10-bit
    parameter int SEED_DEPTH   = 288 * 4, // seed ROM 深度，每项为一个模态的 64-bit 初始状态
    parameter int V_VARIANTS   = 4,     // seed 变体布局倍率；选择器当前固定使用 note_id[1:0]
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES), // voice 编号位宽
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),  // 模态编号/数量位宽
    parameter COEFF_FILE = "rtl/rom/b_coeff.mem", // 72-bit core ROM 初始化文件
    parameter INDEX_FILE = "rtl/rom/b_index.mem", // 64-bit index ROM 初始化文件
    parameter CTRL_FILE  = "rtl/rom/b_ctrl.mem",  // 256-bit control ROM 初始化文件
    parameter SEED_FILE  = "rtl/rom/c_seed.mem",  // 64-bit seed ROM 初始化文件
    parameter bit USE_BUF = 1'b0       // 仅替换系数源：0=内部 ROM，1=外部 BUF；其余仍读 ROM
) (
    input  logic                   clk,              // 工作时钟，上升沿采样
    input  logic                   rst_n,            // 低有效同步复位

    // 装载请求：握手时锁存事件；index key 不含 layer 和 velocity。
    input  logic                   load_valid,       // 请求有效；与 load_ready 同为 1 时接收
    output logic                   load_ready,       // 空闲时为 1，可接收新事务
    input  logic [1:0]             ev_class,         // 1=B、2=C、3=E2；0=A 被拒绝
    input  logic [1:0]             ev_layer,         // 兼容音色层元数据；只回传，不参与寻址
    input  logic [3:0]             ev_instrument,    // 乐器编号，四位均参与 index 寻址
    input  logic [6:0]             ev_note,          // MIDI 音高/鼓件键号，0..127
    input  logic [7:0]             ev_velocity,      // 8-bit 力度；高两位选择四个力度带之一
    input  logic [11:0]            ev_note_id,       // 音符实例编号；低两位另用于选择四种 seed 变体
    input  logic                   ev_gate,          // 门控元数据；仅锁存，不在此处理开关音
    input  logic [1:0]             ev_event_type,    // 事件类型元数据；仅锁存，不参与装载控制
    input  logic [VW-1:0]          load_voice,       // 本次装载的目标 voice 编号

    output logic                   busy,             // 非空闲状态为 1
    output logic                   load_done,        // 成功完成脉冲；若有 seed，须等所有 seed 写完
    output logic [VW-1:0]          done_voice,        // 完成事务的 voice；load_done 时采样
    output logic [MW-1:0]          loaded_n_modes,    // 当前 index 指定的实际模态数
    output logic [15:0]            theta_base,        // 所选力度带的系数块起始字地址，不是相位值

    output logic                   error_valid,      // 错误脉冲，持续一拍；错误事务不产生 load_done
    output logic [2:0]             error_code,       // error_valid 时有效：1=请求非法，2=缺项，3=元数据非法

    // 清除旧 voice 状态；握手完成后才开始输出 core。
    output logic                   clear_valid,      // 请求下游清除目标 voice
    input  logic                   clear_ready,      // 下游接受 clear 请求
    output logic [VW-1:0]          clear_voice,       // 待清除的 voice 编号

    // core 数据流：这里不按连续力度缩放 G，而是直接输出选定力度带的表内系数。
    output logic                   cfg_valid,        // 当前 core 字有效
    input  logic                   cfg_ready,        // 下游接受当前 core 字；握手后推进模态计数
    output logic [VW-1:0]          cfg_voice,        // 当前 core 字写入的 voice
    output logic [MW-1:0]          cfg_mode,         // 当前 core 字写入的模态编号，0..n_r-1
    output logic [71:0]            cfg_word,         // 原始 {G[25:0], a2[23:0], a1[21:0]}，无运行时 G 缩放

    // 可选外部系数 BUF 接口；当前 router_loader 配置 USE_BUF=0。
    output logic                   buf_rd_en,        // core 预读/输出阶段的 BUF 读使能
    output logic [15:0]            buf_rd_addr,      // BUF 系数字地址，非字节地址
    input  logic [71:0]            buf_rd_data,      // 外部 BUF 返回的 core 字；USE_BUF=1 时直接用于 cfg_word

    // 可选初始状态数据流：系数写完后输出；seed 不是实时噪声流。
    output logic                   seed_valid,       // 当前 seed 字有效，仅 has_seed_r=1 时进入该阶段
    input  logic                   seed_ready,       // 下游接受当前 seed 字；握手后推进模态计数
    output logic [VW-1:0]          seed_voice,       // 当前 seed 写入的 voice
    output logic [MW-1:0]          seed_mode,        // 当前 seed 对应的模态编号，0..n_r-1
    output logic [63:0]            seed_word,        // seed 原始字；ABC 格式为 {y2[31:0], y1[31:0]}，均 Q2.30

    // 装载提交：元数据与 control 应在 commit_valid/load_done 时采样。
    output logic                   commit_valid,     // 与 load_done 相同的完成脉冲
    output logic [1:0]             commit_class,     // 本次装载的类别 B/C/E2
    output logic [1:0]             commit_layer,     // 原始 layer 元数据，不参与 index 寻址
    output logic [3:0]             commit_instrument,// 本次装载的乐器编号
    output logic [6:0]             commit_note,      // 本次装载的 MIDI 音高/鼓件键号
    output logic [7:0]             commit_velocity,  // 原始 8-bit 力度，不是 band 编号
    output logic [11:0]            commit_note_id,   // 完整音符实例编号，不仅低两位
    output logic [MW-1:0]          commit_n_modes,   // 本次装载的实际模态数
    output logic [255:0]           commit_ctrl       // 所选 control ROM 项原样输出，由下游解释
);

    import class_format_pkg::*;

    localparam logic [3:0] S_IDLE   = 4'd0, // 空闲，接收并锁存请求
                           S_IDX    = 4'd1, // 等待同步 index ROM 读取
                           S_CHK    = 4'd2, // 解码/校验 index，生成各 ROM 的基址
                           S_CTRL   = 4'd3, // 等待 control 同步读；当前不判断 has_control
                           S_CLEAR  = 4'd4, // 等待下游接受 voice 清除请求
                           S_RD     = 4'd5, // 首个 core 字预读，建立 rd_valid
                           S_CORE   = 4'd6, // 逐模态输出 core 字
                           S_SEED_RD= 4'd7, // 首个 seed 字预读，重新建立 rd_valid
                           S_SEED   = 4'd8, // 逐模态输出 seed，末字握手后完成
                           S_CHK_DEC= 4'd9; // 寄存 index 读结果，隔离 ROM 与后续解码路径

    // ------------------------------------------------------------------
    // ROM（同步读）
    // ------------------------------------------------------------------
    logic [63:0]  index_rom [0:INDEX_DEPTH-1]; // 每个 class/乐器/音高的 index_t 元数据
    logic [255:0] ctrl_rom  [0:CTRL_DEPTH-1];  // 控制参数表；本模块只读取，不执行控制算法
    logic [71:0]  coeff_rom [0:COEFF_DEPTH-1]; // 按力度带连续排列的模态 G/a2/a1 系数
    logic [63:0]  seed_rom  [0:SEED_DEPTH-1];  // 按变体/模态排列的初始递推状态
    initial begin
        $readmemh(INDEX_FILE, index_rom);
        $readmemh(CTRL_FILE, ctrl_rom);
        $readmemh(COEFF_FILE, coeff_rom);
        $readmemh(SEED_FILE, seed_rom);
    end

    logic [12:0]  idx_raddr;   // index 读地址：{class[1:0], instrument[3:0], note[6:0]}
    logic [9:0]   ctrl_raddr;  // control 读地址；只取 index 中 ctrl_index 的低 10 位
    logic [63:0]  idx_rdata;   // index ROM 的同步读输出
    logic [255:0] ctrl_rdata;  // control ROM 的同步读输出，直接连接 commit_ctrl
    logic [71:0]  coeff_rdata; // core 同步读寄存器；BUF 模式下也寄存 BUF 返回值
    logic [63:0]  seed_rdata;  // seed ROM 的同步读输出，直接连接 seed_word

    // ------------------------------------------------------------------
    // 事务状态
    // ------------------------------------------------------------------
    logic [3:0]  st;                // 当前装载状态机状态
    logic [VW-1:0] voice_r;         // 锁存的目标 voice，整个事务共用
    logic [1:0]  class_r, layer_r;   // 锁存的类别和 layer；仅类别参与 index 寻址
    logic [3:0]  inst_r;            // 锁存的乐器编号，四位均参与寻址
    logic [6:0]  note_r;            // 锁存的 MIDI 音高/鼓件键号
    logic [7:0]  vel_r;             // 锁存的原始力度，高两位经 band_of 得到力度带
    logic [11:0] nid_r;             // 锁存的音符实例编号；低两位选择 seed 变体
    logic        gate_r;            // 锁存的 gate；当前未被后续逻辑消费
    logic [1:0]  evt_r;             // 锁存的事件类型；当前未被后续逻辑消费
    logic [MW-1:0] n_r, cnt;        // n_r：实际模态数；cnt：core/seed 阶段复用的当前模态编号
    logic [15:0] offset_r, seed_base_r; // offset_r：选定力度带的 core 基址；seed_base_r：选定变体的 seed 基址
    logic        has_seed_r;        // 锁存 index.has_seed，决定系数写完后是否继续写 seed
    logic        rd_valid;          // 当前 core/seed 数据流有效；两个阶段各自预读后置 1
    index_t      ix;                // S_CHK 内用阻塞赋值取得的解码工作副本，不是额外的 index 流水级
    index_t      idx_q;             // S_CHK_DEC 锁存的完整 64-bit index，随后用于校验/解码

    // core_next：下一次预取的模态编号；末模态保持 cnt，避免读到块外。
    wire [15:0] core_next   = (cnt == (n_r - MW'(1))) ? {11'b0, cnt}
                                                       : ({11'b0, cnt} + 16'd1);
    wire [15:0] coeff_addr_w = (st == S_CORE) ? (offset_r + core_next) : offset_r; // core ROM/BUF 字地址
    // seed_next：seed 阶段的预取模态编号；cnt 在 core 末尾归零后供 seed 阶段复用。
    wire [15:0] seed_next   = (cnt == (n_r - MW'(1))) ? {11'b0, cnt}
                                                       : ({11'b0, cnt} + 16'd1);
    // seed_addr_w：seed ROM 字地址；预读阶段给基址，输出阶段给下一模态地址。
    wire [15:0] seed_addr_w = (st == S_SEED) ? (seed_base_r + seed_next)
                                               : seed_base_r;

    always_ff @(posedge clk) begin
        idx_rdata   <= index_rom[idx_raddr];
        ctrl_rdata  <= ctrl_rom[ctrl_raddr];
        coeff_rdata <= USE_BUF ? buf_rd_data : coeff_rom[coeff_addr_w];
        seed_rdata  <= seed_rom[seed_addr_w];
    end


    wire [1:0] band = band_of(vel_r); // 力度带编号 = vel_r[7:6]，0..3；须小于 index.n_vel

    assign load_ready     = (st == S_IDLE);
    assign busy           = (st != S_IDLE);
    assign clear_valid    = (st == S_CLEAR);
    assign clear_voice    = voice_r;
    assign cfg_valid      = (st == S_CORE) && rd_valid;
    assign cfg_voice      = voice_r;
    assign cfg_mode       = cnt;
    assign cfg_word       = USE_BUF ? buf_rd_data : coeff_rdata;
    assign buf_rd_en      = (st == S_RD) || (st == S_CORE);
    assign buf_rd_addr    = coeff_addr_w;
    assign seed_valid     = (st == S_SEED) && rd_valid;
    assign seed_voice     = voice_r;
    assign seed_mode      = cnt;
    assign seed_word      = seed_rdata;
    assign done_voice     = voice_r;
    assign theta_base     = offset_r;
    assign loaded_n_modes = n_r;
    assign commit_valid   = load_done;
    assign commit_class   = class_r;
    assign commit_layer   = layer_r;
    assign commit_instrument = inst_r;
    assign commit_note    = note_r;
    assign commit_velocity= vel_r;
    assign commit_note_id = nid_r;
    assign commit_n_modes = n_r;
    assign commit_ctrl    = ctrl_rdata;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st          <= S_IDLE;
            voice_r     <= {VW{1'b0}};
            class_r     <= 2'd0;
            layer_r     <= 2'd0;
            inst_r      <= 4'd0;
            note_r      <= 7'd0;
            vel_r       <= 8'd0;
            nid_r       <= 12'd0;
            gate_r      <= 1'b0;
            evt_r       <= 2'd0;
            n_r         <= {MW{1'b0}};
            cnt         <= {MW{1'b0}};
            offset_r    <= 16'd0;
            seed_base_r <= 16'd0;
            has_seed_r  <= 1'b0;
            idx_raddr   <= 13'd0;
            idx_q       <= '0;
            ctrl_raddr  <= 10'd0;
            rd_valid    <= 1'b0;
            load_done   <= 1'b0;
            error_valid <= 1'b0;
            error_code  <= 3'd0;
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
                            error_code  <= 3'd1;
                        end else if (ev_class == 2'd0) begin
                            error_valid <= 1'b1;      // A 不走本 loader
                            error_code  <= 3'd1;
                        end else begin
                            idx_raddr <= {ev_class, ev_instrument, ev_note};
                            st        <= S_IDX;
                        end
                    end
                end

                S_IDX: begin
                    idx_raddr <= {class_r, inst_r, note_r};
                    st        <= S_CHK_DEC;
                end

                S_CHK_DEC: begin
                    idx_q <= idx_rdata;       // 先寄存 index，再解码，切断 ROM→offset 路径
                    st    <= S_CHK;
                end

                S_CHK: begin
                    // ix 的字段布局见 class_format_pkg::index_t。
                    // 当前检查 present/n_modes/n_vel/所选系数块边界；不校验 version/cls/flags，
                    // 也不按 has_control 跳过 control 读取，seed/control 地址无独立越界检查。
                    ix = idx_q;
                    if (!ix.present) begin
                        error_valid <= 1'b1;
                        error_code  <= 3'd2;
                        st          <= S_IDLE;
                    end else if ((ix.n_modes == 7'd0) || (ix.n_modes > N_MODES) ||
                                 (ix.n_vel == 3'd0) || !band_valid(ix, band)) begin
                        error_valid <= 1'b1;
                        error_code  <= 3'd3;
                        st          <= S_IDLE;
                    end else if ({2'b0, ix.mode_offset} + ({16'b0, band} * ix.n_modes)
                                 + ix.n_modes > COEFF_DEPTH) begin
                        error_valid <= 1'b1;
                        error_code  <= 3'd3;
                        st          <= S_IDLE;
                    end else begin
                        n_r         <= ix.n_modes;
                        offset_r    <= ix.mode_offset + band * ix.n_modes; // 力度带之间步长为实际模态数
                        has_seed_r  <= ix.has_seed;
                        // seed 变体之间步长为 N_MODES；此处用未加力度带偏移的 mode_offset。
                        seed_base_r <= (ix.mode_offset * V_VARIANTS)
                                      + ({{(16-2){1'b0}}, nid_r[1:0]} * N_MODES);
                        ctrl_raddr  <= ix.ctrl_index[9:0];
                        cnt         <= {MW{1'b0}};
                        st          <= S_CTRL;
                    end
                end

                S_CTRL: begin
                    st <= S_CLEAR;
                end

                S_CLEAR: begin
                    if (clear_ready) st <= S_RD;
                end

                S_RD: begin
                    rd_valid <= 1'b1;
                    st       <= S_CORE;
                end

                S_CORE: begin
                    if (rd_valid && cfg_ready) begin
                        if (cnt == (n_r - MW'(1))) begin
                            rd_valid <= 1'b0;
                            cnt      <= {MW{1'b0}};
                            if (has_seed_r) begin
                                st <= S_SEED_RD;
                            end else begin
                                st <= S_IDLE;
                                load_done <= 1'b1;
                            end
                        end else begin
                            cnt <= cnt + MW'(1);
                        end
                    end
                end

                S_SEED_RD: begin
                    rd_valid <= 1'b1;
                    st       <= S_SEED;
                end

                default: begin // S_SEED
                    if (rd_valid && seed_ready) begin
                        if (cnt == (n_r - MW'(1))) begin
                            rd_valid   <= 1'b0;
                            load_done  <= 1'b1;
                            st         <= S_IDLE;
                        end else begin
                            cnt <= cnt + MW'(1);
                        end
                    end
                end
            endcase
        end
    end

endmodule
