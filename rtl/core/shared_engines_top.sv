// -----------------------------------------------------------------------------
// shared_engines_top.sv -- 单份 9x32 RAM + A/B/C/E2 串行引擎
//
// 目标结构：
//   shared_modal_ram（唯一一份，depth 16*20=320）
//     A/B/C 只用 field0..4，E2 用 field0..8
//   一个 class scheduler，一次只跑一个引擎
//   一个 64-bit 尾部加法器
//
// 包络 loader / 颤音滑音仍由各 engine 的既有端口接入，本版不扩。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module shared_engines_top #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter     C_SEED_FILE = "",
    parameter int VW          = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_ABC      = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2       = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1),
    parameter int LOCAL_RAM   = (N_MODES_E2 + LANES - 1) / LANES,
    parameter int AW_RAM      = (NUM_SLOTS * LOCAL_RAM < 2) ? 1 : $clog2(NUM_SLOTS * LOCAL_RAM)
) (
    input  logic clk, rst_n,

    // A/B/C 共享装载总线
    input  logic cfg_we,
    input  logic [1:0] cfg_engine,
    input  logic [VW-1:0] cfg_voice,
    input  logic [MW_ABC-1:0] cfg_mode,
    input  logic [REC_W-1:0] cfg_data,
    input  logic clr_we,
    input  logic [1:0] clr_engine,
    input  logic [VW-1:0] clr_voice,
    input  logic [MW_ABC-1:0] clr_mode,
    input  logic seed_we,
    input  logic [1:0] seed_engine,
    input  logic [VW-1:0] seed_voice,
    input  logic [MW_ABC-1:0] seed_mode,
    input  logic [63:0] seed_data,

    // A job
    input  logic [NUM_SLOTS-1:0] a_note_start,
    input  logic [NUM_SLOTS-1:0] a_gate,
    input  logic [NUM_SLOTS-1:0] a_active,
    input  logic [NUM_SLOTS*32-1:0] a_x,
    input  logic [NUM_SLOTS*16-1:0] a_x_vel,
    input  logic [NUM_SLOTS*MW_ABC-1:0] a_nmodes,

    // B job
    input  logic [NUM_SLOTS*256-1:0] b_ctrl,
    input  logic [NUM_SLOTS*2-1:0] b_class,
    input  logic [NUM_SLOTS*16-1:0] b_vel,
    input  logic [NUM_SLOTS*16-1:0] b_theta,
    input  logic b_a1_enable,
    input  logic [15:0] b_ratio,
    input  logic [NUM_SLOTS-1:0] b_note_start,
    input  logic [NUM_SLOTS-1:0] b_gate,
    input  logic [NUM_SLOTS-1:0] b_active,
    input  logic [NUM_SLOTS*MW_ABC-1:0] b_nmodes,

    // C job
    input  logic [NUM_SLOTS-1:0] c_note_start,
    input  logic [NUM_SLOTS-1:0] c_choke,
    input  logic [NUM_SLOTS*20-1:0] c_len,
    input  logic [NUM_SLOTS*16-1:0] c_seed_vel,
    input  logic [NUM_SLOTS*24-1:0] c_attack,
    input  logic [NUM_SLOTS*24-1:0] c_release,
    input  logic [NUM_SLOTS*MW_ABC-1:0] c_nmodes,
    input  logic c_seed_load_start,
    input  logic [VW-1:0] c_seed_load_voice,
    input  logic [MW_ABC-1:0] c_seed_load_nmodes,
    input  logic [15:0] c_seed_base,

    // E2 load/job
    input  logic e2_cfg_we,
    input  logic [VW-1:0] e2_cfg_voice,
    input  logic [MW_E2-1:0] e2_cfg_mode,
    input  logic [REC_W-1:0] e2_cfg_data,
    input  logic e2_clr_we,
    input  logic [VW-1:0] e2_clr_voice,
    input  logic [MW_E2-1:0] e2_clr_mode,
    input  logic e2_seed_we,
    input  logic [VW-1:0] e2_seed_voice,
    input  logic [MW_E2-1:0] e2_seed_mode,
    input  logic [63:0] e2_seed_data,
    input  logic [NUM_SLOTS-1:0] e2_active,
    input  logic [NUM_SLOTS-1:0] e2_zero,
    input  logic [NUM_SLOTS*32-1:0] e2_x,
    input  logic [NUM_SLOTS*MW_E2-1:0] e2_nmodes,

    input  logic start,
    output logic sample_ready,
    output logic busy,
    output logic done,
    output logic out_valid,
    output logic signed [63:0] mix_sum
);

    // ---- 共享 RAM 端口 ----
    logic cfg_sel_e2;
    logic [VW-1:0] ram_cfg_voice;
    logic [MW_E2-1:0] ram_cfg_mode, ram_clr_mode, ram_seed_mode;
    logic [REC_W-1:0] ram_cfg_data;
    logic ram_cfg_we, ram_clr_we, ram_seed_we;
    logic [VW-1:0] ram_clr_voice, ram_seed_voice;
    logic [63:0] ram_seed_data;
    logic [3:0] ram_state_first;

    logic [LANES-1:0] ram_rd_re, ram_st_we;
    logic [LANES*AW_RAM-1:0] ram_rd_addr, ram_st_addr;
    logic [LANES*REC_W-1:0] ram_rd_data;
    logic [LANES*64-1:0] ram_st_data;
    logic [LANES-1:0] ram_aux_re;
    logic [VW-1:0] ram_aux_voice;
    logic [MW_E2-1:0] ram_aux_mode;
    logic [REC_W-1:0] ram_aux_data;
    logic ram_aux_valid, ram_co_we;
    logic [VW-1:0] ram_co_voice;
    logic [MW_E2-1:0] ram_co_mode;
    logic [3:0] ram_co_field;
    logic [31:0] ram_co_wdata;

    // ABC 和 E2 的装载口 mux；E2 优先（load 不应同时发生）
    assign cfg_sel_e2  = e2_cfg_we | e2_clr_we | e2_seed_we;
    assign ram_cfg_we  = cfg_sel_e2 ? e2_cfg_we : cfg_we;
    assign ram_cfg_voice = cfg_sel_e2 ? e2_cfg_voice : cfg_voice;
    assign ram_cfg_mode  = cfg_sel_e2 ? e2_cfg_mode : {{(MW_E2-MW_ABC){1'b0}}, cfg_mode};
    assign ram_cfg_data  = cfg_sel_e2 ? e2_cfg_data : cfg_data;
    assign ram_clr_we    = cfg_sel_e2 ? e2_clr_we : clr_we;
    assign ram_clr_voice = cfg_sel_e2 ? e2_clr_voice : clr_voice;
    assign ram_clr_mode  = cfg_sel_e2 ? e2_clr_mode : {{(MW_E2-MW_ABC){1'b0}}, clr_mode};
    assign ram_seed_we    = cfg_sel_e2 ? e2_seed_we : seed_we;
    assign ram_seed_voice = cfg_sel_e2 ? e2_seed_voice : seed_voice;
    assign ram_seed_mode  = cfg_sel_e2 ? e2_seed_mode : {{(MW_E2-MW_ABC){1'b0}}, seed_mode};
    assign ram_seed_data  = cfg_sel_e2 ? e2_seed_data : seed_data;
    assign ram_state_first = cfg_sel_e2 ? 4'd7 : 4'd3;

    shared_modal_ram #(
        .SLOTS(NUM_SLOTS), .MODES(N_MODES_E2), .LANES(LANES),
        .REC_W(REC_W), .FLD_W(32)
    ) u_ram (
        .clk(clk), .rst_n(rst_n), .state_first(ram_state_first),
        .cfg_we(ram_cfg_we), .cfg_voice(ram_cfg_voice), .cfg_mode(ram_cfg_mode), .cfg_data(ram_cfg_data),
        .st_we(ram_st_we), .st_addr(ram_st_addr), .st_data(ram_st_data),
        .rd_re(ram_rd_re), .rd_addr(ram_rd_addr), .rd_data(ram_rd_data),
        .clr_we(ram_clr_we), .clr_voice(ram_clr_voice), .clr_mode(ram_clr_mode),
        .seed_we(ram_seed_we), .seed_voice(ram_seed_voice), .seed_mode(ram_seed_mode), .seed_data(ram_seed_data),
        .aux_re(ram_aux_re), .aux_voice(ram_aux_voice), .aux_mode(ram_aux_mode), .aux_data(ram_aux_data), .aux_valid(ram_aux_valid),
        .co_we(ram_co_we), .co_voice(ram_co_voice), .co_mode(ram_co_mode), .co_field(ram_co_field), .co_wdata(ram_co_wdata)
    );

    // ---- 四个外置 RAM 引擎 ----
    logic a_ready, a_busy, a_done, a_valid; logic signed [63:0] a_mix;
    logic b_ready, b_busy, b_done, b_valid; logic signed [63:0] b_mix;
    logic c_ready, c_busy, c_done, c_valid, c_seed_busy, c_seed_done; logic signed [63:0] c_mix;
    logic e2_ready, e2_busy, e2_done, e2_valid; logic signed [63:0] e2_mix;

    logic [LANES-1:0] a_rd_re, a_st_we, b_rd_re, b_st_we, c_rd_re, c_st_we, e2_rd_re, e2_st_we;
    logic [LANES*AW_RAM-1:0] a_rd_addr, a_st_addr, b_rd_addr, b_st_addr;
    logic [LANES*AW_RAM-1:0] c_rd_addr, c_st_addr, e2_rd_addr, e2_st_addr;
    logic [LANES*64-1:0] a_st_data, b_st_data, c_st_data, e2_st_data;
    logic b_aux_re, b_aux_valid, b_co_we;
    logic [VW-1:0] b_aux_voice, b_co_voice;
    logic [MW_ABC-1:0] b_aux_mode, b_co_mode;
    logic [3:0] b_co_field;
    logic [31:0] b_co_wdata;

    logic a_start, b_start, c_start, e2_start;
    logic [NUM_SLOTS-1:0] c_active, c_timer_done;

    eng1_engine_env_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_ABC), .LANES(LANES),
        .LOCAL(LOCAL_RAM), .REC_W(REC_W)
    ) u_a (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we && (cfg_engine == 2'd0)), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we && (clr_engine == 2'd0)), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we && (seed_engine == 2'd0)), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0), .aux_data('0), .aux_valid(1'b0),
        .co_we(1'b0), .co_voice('0), .co_mode('0), .co_field('0), .co_wdata('0),
        .note_start_mask(a_note_start), .gate_mask(a_gate), .choke_mask('0), .done_mask('0),
        .class_vec('0), .attack_vec('0), .release_vec('0),
        .start(a_start), .active_mask(a_active), .x_vec(a_x), .x_vel_vec(a_x_vel),
        .n_modes_vec(a_nmodes), .sample_ready(a_ready), .done(a_done), .busy(a_busy),
        .out_valid(a_valid), .mix_sum(a_mix), .sat_count(), .voice_valid(), .voice_id(), .voice_sum(),
        .ram_rd_re(a_rd_re), .ram_rd_addr(a_rd_addr), .ram_rd_data(ram_rd_data),
        .ram_st_we(a_st_we), .ram_st_addr(a_st_addr), .ram_st_data(a_st_data)
    );

    b_engine_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_ABC), .LANES(LANES),
        .LOCAL(LOCAL_RAM), .REC_W(REC_W)
    ) u_b (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we && (cfg_engine == 2'd1)), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we && (clr_engine == 2'd1)), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we && (seed_engine == 2'd1)), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .ctrl_vec(b_ctrl), .class_vec(b_class), .vel_vec(b_vel), .theta_base_vec(b_theta),
        .a1_enable(b_a1_enable), .a1_active(), .a1_done(),
        .note_start_mask(b_note_start), .gate_mask(b_gate), .ratio(b_ratio),
        .start(b_start), .active_mask(b_active), .n_modes_vec(b_nmodes),
        .sample_ready(b_ready), .done(b_done), .busy(b_busy),
        .out_valid(b_valid), .mix_sum(b_mix), .sat_count(), .voice_valid(), .voice_id(), .voice_sum(),
        .ram_rd_re(b_rd_re), .ram_rd_addr(b_rd_addr), .ram_rd_data(ram_rd_data),
        .ram_st_we(b_st_we), .ram_st_addr(b_st_addr), .ram_st_data(b_st_data),
        .ram_aux_re(b_aux_re), .ram_aux_voice(b_aux_voice), .ram_aux_mode(b_aux_mode),
        .ram_aux_data(ram_aux_data), .ram_aux_valid(ram_aux_valid),
        .ram_co_we(b_co_we), .ram_co_voice(b_co_voice), .ram_co_mode(b_co_mode),
        .ram_co_field(b_co_field), .ram_co_wdata(b_co_wdata)
    );

    c_engine_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_ABC), .LANES(LANES),
        .LOCAL(LOCAL_RAM), .REC_W(REC_W), .SEED_FILE(C_SEED_FILE)
    ) u_c (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we && (cfg_engine == 2'd2)), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we && (clr_engine == 2'd2)), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we && (seed_engine == 2'd2)), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .note_start_mask(c_note_start), .choke_mask(c_choke), .length_vec(c_len),
        .attack_vec(c_attack), .release_vec(c_release), .seed_vel_vec(c_seed_vel), .n_modes_vec(c_nmodes),
        .seed_load_start(c_seed_load_start), .seed_load_voice(c_seed_load_voice),
        .seed_load_nmodes(c_seed_load_nmodes), .seed_base(c_seed_base),
        .seed_busy(c_seed_busy), .seed_done(c_seed_done),
        .start(c_start), .sample_ready(c_ready), .done(c_done), .busy(c_busy),
        .c_active(c_active), .c_done(c_timer_done),
        .out_valid(c_valid), .mix_sum(c_mix), .sat_count(), .voice_valid(), .voice_id(), .voice_sum(),
        .ram_rd_re(c_rd_re), .ram_rd_addr(c_rd_addr), .ram_rd_data(ram_rd_data),
        .ram_st_we(c_st_we), .ram_st_addr(c_st_addr), .ram_st_data(c_st_data)
    );

    eng2_engine_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES_E2), .LANES(LANES),
        .LOCAL(LOCAL_RAM), .REC_W(REC_W)
    ) u_e2 (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(e2_cfg_we), .cfg_voice(e2_cfg_voice), .cfg_mode(e2_cfg_mode), .cfg_data(e2_cfg_data),
        .clr_we(e2_clr_we), .clr_voice(e2_clr_voice), .clr_mode(e2_clr_mode),
        .seed_we(e2_seed_we), .seed_voice(e2_seed_voice), .seed_mode(e2_seed_mode), .seed_data(e2_seed_data),
        .start(e2_start), .active_mask(e2_active), .zero_mask(e2_zero),
        .x_vec(e2_x), .n_modes_vec(e2_nmodes),
        .sample_ready(e2_ready), .done(e2_done), .busy(e2_busy),
        .out_valid(e2_valid), .mix_sum(e2_mix), .voice_valid(), .voice_id(), .voice_sum(),
        .ram_rd_re(e2_rd_re), .ram_rd_addr(e2_rd_addr), .ram_rd_data(ram_rd_data),
        .ram_st_we(e2_st_we), .ram_st_addr(e2_st_addr), .ram_st_data(e2_st_data)
    );

    // ---- scheduler ----
    typedef enum logic [2:0] {S_IDLE,S_START,S_WAIT,S_ADD,S_DONE} state_t;
    state_t state;
    logic [1:0] sel;
    logic [3:0] done_set;
    logic signed [63:0] acc;

    wire [3:0] eng_ready = {e2_ready, c_ready, b_ready, a_ready};
    wire [3:0] eng_done  = {e2_done,  c_done,  b_done,  a_done};
    wire [3:0] eng_active = {|e2_active, |c_active, |b_active, |a_active};
    logic signed [63:0] eng_mix_sel;
    always_comb begin
        case (sel)
            2'd0: eng_mix_sel = a_mix;
            2'd1: eng_mix_sel = b_mix;
            2'd2: eng_mix_sel = c_mix;
            default: eng_mix_sel = e2_mix;
        endcase
    end

    function automatic logic [1:0] first_active(input logic [3:0] m, input logic [3:0] d);
        logic found;
        begin
            first_active = 2'd0; found = 1'b0;
            for (int i = 0; i < 4; i = i + 1) begin
                if (!found && m[i] && !d[i]) begin first_active = i[1:0]; found = 1'b1; end
            end
        end
    endfunction

    assign a_start = (state == S_START) && (sel == 2'd0);
    assign b_start = (state == S_START) && (sel == 2'd1);
    assign c_start = (state == S_START) && (sel == 2'd2);
    assign e2_start = (state == S_START) && (sel == 2'd3);

    assign sample_ready = (state == S_IDLE) && (&eng_ready);
    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);
    assign out_valid = (state == S_DONE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; sel <= 2'd0; done_set <= '0; acc <= 64'sd0; mix_sum <= 64'sd0;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    acc <= 64'sd0; done_set <= '0;
                    if (eng_active == '0) begin state <= S_DONE; end
                    else begin sel <= first_active(eng_active, '0); state <= S_START; end
                end
                S_START: state <= S_WAIT;
                S_WAIT: if (eng_done[sel]) begin
                    acc <= acc + eng_mix_sel;
                    done_set <= done_set | (4'b0001 << sel);
                    state <= S_ADD;
                end
                S_ADD: begin
                    logic [3:0] next_done;
                    next_done = done_set | (4'b0001 << sel);
                    if ((eng_active & ~next_done) == 4'b0000) begin
                        mix_sum <= acc;      // done 与 mix_sum 同拍有效
                        state <= S_DONE;
                    end else begin
                        sel <= first_active(eng_active, next_done);
                        state <= S_START;
                    end
                end
                S_DONE: begin
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // RAM 端口 mux：只有 active engine 接 RAM
    always_comb begin
        ram_rd_re = 0; ram_st_we = 0; ram_rd_addr = '0; ram_st_addr = '0; ram_st_data = '0;
        ram_aux_re = 0; ram_aux_voice = '0; ram_aux_mode = '0;
        ram_co_we = 0; ram_co_voice = '0; ram_co_mode = '0; ram_co_field = '0; ram_co_wdata = '0;
        case (sel)
            2'd0: begin ram_rd_re=a_rd_re; ram_rd_addr=a_rd_addr; ram_st_we=a_st_we; ram_st_addr=a_st_addr; ram_st_data=a_st_data; end
            2'd1: begin ram_rd_re=b_rd_re; ram_rd_addr=b_rd_addr; ram_st_we=b_st_we; ram_st_addr=b_st_addr; ram_st_data=b_st_data;
                       ram_aux_re=b_aux_re; ram_aux_voice=b_aux_voice; ram_aux_mode=b_aux_mode;
                       ram_co_we=b_co_we; ram_co_voice=b_co_voice; ram_co_mode=b_co_mode; ram_co_field=b_co_field; ram_co_wdata=b_co_wdata; end
            2'd2: begin ram_rd_re=c_rd_re; ram_rd_addr=c_rd_addr; ram_st_we=c_st_we; ram_st_addr=c_st_addr; ram_st_data=c_st_data; end
            default: begin ram_rd_re=e2_rd_re; ram_rd_addr=e2_rd_addr; ram_st_we=e2_st_we; ram_st_addr=e2_st_addr; ram_st_data=e2_st_data; end
        endcase
    end

endmodule
