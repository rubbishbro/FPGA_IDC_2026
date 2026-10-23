// =============================================================================
// 文件 : index_loader64.sv
// 模块 : index_loader64
// 功能 : B/C/E2 64-bit index/control/seed 装载器
// 说明 : 读 index/control/coeff/seed，输出 9×32 cfg、seed 和 ctrl；由 router_loader 选择 class。
// =============================================================================
`timescale 1ns/1ps

module index_loader64 #(
    parameter int NUM_VOICES   = 32,
    parameter int N_MODES      = 48,
    parameter int COEFF_DEPTH  = 5483,
    parameter int INDEX_DEPTH  = 8192,
    parameter int CTRL_DEPTH   = 1024,
    parameter int SEED_DEPTH   = 288 * 4,
    parameter int V_VARIANTS   = 4,
    parameter int VW = (NUM_VOICES < 2) ? 1 : $clog2(NUM_VOICES),
    parameter int MW = (N_MODES < 1) ? 1 : $clog2(N_MODES + 1),
    parameter COEFF_FILE = "rtl/rom/b_coeff.mem",
    parameter INDEX_FILE = "rtl/rom/b_index.mem",
    parameter CTRL_FILE  = "rtl/rom/b_ctrl.mem",
    parameter SEED_FILE  = "rtl/rom/c_seed.mem",
    parameter bit USE_BUF = 1'b0
) (
    input  logic                   clk,
    input  logic                   rst_n,

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
    output logic [2:0]             error_code,

    output logic                   clear_valid,
    input  logic                   clear_ready,
    output logic [VW-1:0]          clear_voice,

    output logic                   cfg_valid,
    input  logic                   cfg_ready,
    output logic [VW-1:0]          cfg_voice,
    output logic [MW-1:0]          cfg_mode,
    output logic [71:0]            cfg_word,

    output logic                   buf_rd_en,
    output logic [15:0]            buf_rd_addr,
    input  logic [71:0]            buf_rd_data,

    output logic                   seed_valid,
    input  logic                   seed_ready,
    output logic [VW-1:0]          seed_voice,
    output logic [MW-1:0]          seed_mode,
    output logic [63:0]            seed_word,

    output logic                   commit_valid,
    output logic [1:0]             commit_class,
    output logic [1:0]             commit_layer,
    output logic [3:0]             commit_instrument,
    output logic [6:0]             commit_note,
    output logic [7:0]             commit_velocity,
    output logic [11:0]            commit_note_id,
    output logic [MW-1:0]          commit_n_modes,
    output logic [255:0]           commit_ctrl
);

    import class_format_pkg::*;

    localparam logic [3:0] S_IDLE   = 4'd0,
                           S_IDX    = 4'd1,
                           S_CHK    = 4'd2,
                           S_CTRL   = 4'd3,
                           S_CLEAR  = 4'd4,
                           S_RD     = 4'd5,
                           S_CORE   = 4'd6,
                           S_SEED_RD= 4'd7,
                           S_SEED   = 4'd8,
                           S_CHK_DEC= 4'd9;

    // ------------------------------------------------------------------
    // ROM（同步读）
    // ------------------------------------------------------------------
    logic [63:0]  index_rom [0:INDEX_DEPTH-1];
    logic [255:0] ctrl_rom  [0:CTRL_DEPTH-1];
    logic [71:0]  coeff_rom [0:COEFF_DEPTH-1];
    logic [63:0]  seed_rom  [0:SEED_DEPTH-1];
    initial begin
        $readmemh(INDEX_FILE, index_rom);
        $readmemh(CTRL_FILE, ctrl_rom);
        $readmemh(COEFF_FILE, coeff_rom);
        $readmemh(SEED_FILE, seed_rom);
    end

    logic [12:0]  idx_raddr;
    logic [9:0]   ctrl_raddr;
    logic [63:0]  idx_rdata;
    logic [255:0] ctrl_rdata;
    logic [71:0]  coeff_rdata;
    logic [63:0]  seed_rdata;

    // ------------------------------------------------------------------
    // 事务状态
    // ------------------------------------------------------------------
    logic [3:0]  st;
    logic [VW-1:0] voice_r;
    logic [1:0]  class_r, layer_r;
    logic [3:0]  inst_r;
    logic [6:0]  note_r;
    logic [7:0]  vel_r;
    logic [11:0] nid_r;
    logic        gate_r;
    logic [1:0]  evt_r;
    logic [MW-1:0] n_r, cnt;
    logic [15:0] offset_r, seed_base_r;
    logic        has_seed_r;
    logic        rd_valid;
    index_t      ix;
    index_t      idx_q;

    wire [15:0] core_next   = (cnt == (n_r - MW'(1))) ? {11'b0, cnt}
                                                       : ({11'b0, cnt} + 16'd1);
    wire [15:0] coeff_addr_w = (st == S_CORE) ? (offset_r + core_next) : offset_r;
    wire [15:0] seed_next   = (cnt == (n_r - MW'(1))) ? {11'b0, cnt}
                                                       : ({11'b0, cnt} + 16'd1);
    wire [15:0] seed_addr_w = (st == S_SEED) ? (seed_base_r + seed_next)
                                               : seed_base_r;

    always_ff @(posedge clk) begin
        idx_rdata   <= index_rom[idx_raddr];
        ctrl_rdata  <= ctrl_rom[ctrl_raddr];
        coeff_rdata <= USE_BUF ? buf_rd_data : coeff_rom[coeff_addr_w];
        seed_rdata  <= seed_rom[seed_addr_w];
    end


    wire [1:0] band = band_of(vel_r);

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
                        offset_r    <= ix.mode_offset + band * ix.n_modes;
                        has_seed_r  <= ix.has_seed;
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
