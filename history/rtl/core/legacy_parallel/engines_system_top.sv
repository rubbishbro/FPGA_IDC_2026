// -----------------------------------------------------------------------------
// engines_system_top.sv -- 全局事件 + voice_router + four_engines_top
//
// 事件只给 note_on/note_off/voice/class；router 维护 16 voice 的 class/active，
// 输出每引擎 active/note_start/gate；四个引擎各自 16 物理 slot。
// index/control/seed 表仍在更外层 router/ROM（本模块只接 cfg 总线）。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module engines_system_top #(
    parameter int NUM_SLOTS   = 16,
    parameter int N_MODES_ABC = 48,
    parameter int N_MODES_E2  = 80,
    parameter int LANES       = 4,
    parameter int REC_W       = 288,
    parameter int VW          = (NUM_SLOTS < 2) ? 1 : $clog2(NUM_SLOTS),
    parameter int MW_ABC      = (N_MODES_ABC < 2) ? 1 : $clog2(N_MODES_ABC),
    parameter int MW_E2       = (N_MODES_E2 < 2) ? 1 : $clog2(N_MODES_E2 + 1),
    parameter     C_SEED_FILE = ""
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // events
    input  logic                       note_on,
    input  logic                       note_off,
    input  logic [VW-1:0]              note_voice,
    input  logic [1:0]                 note_class,

    // A job
    input  logic [NUM_SLOTS*32-1:0]    a_x,
    input  logic [NUM_SLOTS*16-1:0]    a_x_vel,
    input  logic [NUM_SLOTS*MW_ABC-1:0] a_nmodes,

    // B job
    input  logic [NUM_SLOTS*256-1:0]   b_ctrl,
    input  logic [NUM_SLOTS*16-1:0]    b_vel,
    input  logic [NUM_SLOTS*16-1:0]    b_theta,
    input  logic                       b_a1_enable,
    input  logic [15:0]                b_ratio,
    input  logic [NUM_SLOTS*MW_ABC-1:0] b_nmodes,

    // C job
    input  logic [NUM_SLOTS*20-1:0]    c_len,
    input  logic [NUM_SLOTS*16-1:0]    c_seed_vel,
    input  logic [NUM_SLOTS*24-1:0]    c_attack,
    input  logic [NUM_SLOTS*24-1:0]    c_release,
    input  logic [NUM_SLOTS*MW_ABC-1:0] c_nmodes,
    input  logic [15:0]                c_seed_base,

    // cfg/clr/seed ABC
    input  logic                       cfg_we,
    input  logic [1:0]                 cfg_engine,
    input  logic [VW-1:0]              cfg_voice,
    input  logic [MW_ABC-1:0]          cfg_mode,
    input  logic [REC_W-1:0]           cfg_data,
    input  logic                       clr_we,
    input  logic [1:0]                 clr_engine,
    input  logic [VW-1:0]              clr_voice,
    input  logic [MW_ABC-1:0]          clr_mode,
    input  logic                       seed_we,
    input  logic [1:0]                 seed_engine,
    input  logic [VW-1:0]              seed_voice,
    input  logic [MW_ABC-1:0]          seed_mode,
    input  logic [63:0]                seed_data,

    // ENG2 cfg/job
    input  logic                       e2_cfg_we,
    input  logic [VW-1:0]              e2_cfg_voice,
    input  logic [MW_E2-1:0]           e2_cfg_mode,
    input  logic [REC_W-1:0]           e2_cfg_data,
    input  logic                       e2_clr_we,
    input  logic [VW-1:0]              e2_clr_voice,
    input  logic [MW_E2-1:0]           e2_clr_mode,
    input  logic                       e2_seed_we,
    input  logic [VW-1:0]              e2_seed_voice,
    input  logic [MW_E2-1:0]           e2_seed_mode,
    input  logic [63:0]                e2_seed_data,
    input  logic [NUM_SLOTS*32-1:0]    e2_x,
    input  logic [NUM_SLOTS*MW_E2-1:0] e2_nmodes,

    input  logic                       start,
    output logic                       sample_ready,
    output logic                       busy,
    output logic                       done,
    output logic                       out_valid,
    output logic signed [63:0]         mix_sum
);

    logic [NUM_SLOTS-1:0] a_active, b_active, c_active, e2_active;
    logic [NUM_SLOTS-1:0] a_ns, b_ns, c_ns, e2_ns;
    logic [NUM_SLOTS-1:0] a_gate, b_gate, c_choke;
    logic [NUM_SLOTS-1:0] voice_active;
    logic [NUM_SLOTS*2-1:0] voice_class;
    logic [NUM_SLOTS-1:0] e2_zero_r;

    voice_router #(.NUM_VOICES(NUM_SLOTS)) u_router (
        .clk(clk), .rst_n(rst_n),
        .note_on(note_on), .note_off(note_off),
        .voice(note_voice), .cls(note_class),
        .a_active(a_active), .b_active(b_active),
        .c_active(c_active), .e2_active(e2_active),
        .a_note_start(a_ns), .b_note_start(b_ns),
        .c_note_start(c_ns), .e2_note_start(e2_ns),
        .a_gate(a_gate), .b_gate(b_gate), .c_choke(c_choke),
        .voice_active(voice_active), .voice_class(voice_class)
    );

    // ENG2 的 zero 要在 sample start 时仍有效：note-on 时置位，start 时清
    always_ff @(posedge clk) begin
        if (!rst_n) e2_zero_r <= '0;
        else begin
            if (start) e2_zero_r <= '0;
            e2_zero_r <= e2_zero_r | e2_ns;
        end
    end

    wire        c_seed_load_start = c_ns[note_voice];
    wire [MW_ABC-1:0] c_seed_load_nmodes = c_nmodes[note_voice*MW_ABC +: MW_ABC];

    four_engines_top #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES_ABC(N_MODES_ABC),
        .N_MODES_E2(N_MODES_E2), .LANES(LANES), .REC_W(REC_W),
        .C_SEED_FILE(C_SEED_FILE)
    ) u_engines (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_engine(cfg_engine), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_engine(clr_engine), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_engine(seed_engine), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_data(seed_data),
        .a_note_start(a_ns), .a_gate(a_gate), .a_active(a_active),
        .a_x(a_x), .a_x_vel(a_x_vel), .a_nmodes(a_nmodes),
        .b_ctrl(b_ctrl), .b_class(voice_class), .b_vel(b_vel), .b_theta(b_theta),
        .b_a1_enable(b_a1_enable), .b_ratio(b_ratio),
        .b_note_start(b_ns), .b_gate(b_gate), .b_active(b_active), .b_nmodes(b_nmodes),
        .c_note_start(c_ns), .c_choke(c_choke), .c_len(c_len),
        .c_seed_vel(c_seed_vel), .c_attack(c_attack), .c_release(c_release), .c_nmodes(c_nmodes),
        .c_seed_load_start(c_seed_load_start), .c_seed_load_voice(note_voice),
        .c_seed_load_nmodes(c_seed_load_nmodes), .c_seed_base(c_seed_base),
        .e2_cfg_we(e2_cfg_we), .e2_cfg_voice(e2_cfg_voice), .e2_cfg_mode(e2_cfg_mode), .e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we), .e2_clr_voice(e2_clr_voice), .e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we), .e2_seed_voice(e2_seed_voice), .e2_seed_mode(e2_seed_mode), .e2_seed_data(e2_seed_data),
        .e2_active(e2_active), .e2_zero(e2_zero_r), .e2_x(e2_x), .e2_nmodes(e2_nmodes),
        .start(start), .sample_ready(sample_ready), .busy(busy), .done(done),
        .out_valid(out_valid), .mix_sum(mix_sum)
    );

endmodule
