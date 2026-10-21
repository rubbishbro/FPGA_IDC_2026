// -----------------------------------------------------------------------------
// c_engine_top.sv -- C 引擎：seed/timer + engine/envelope
//
// C 的 x=0，靠 seed 写状态起振；timer 到期/同组 choke 后 envelope fade。
// seed 表在 router/ROM，本模块只接收 seed 写口。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module c_engine_top_ext #(
    parameter int NUM_SLOTS = 16,
    parameter int N_MODES   = 48,
    parameter int LANES     = 4,
    parameter int LOCAL     = (N_MODES + LANES - 1) / LANES,
    parameter int REC_W     = 288,
    parameter int CW        = 20,
    parameter int SEED_DEPTH= 1152,
    parameter     SEED_FILE = "",
    parameter bit USE_SEED_ROM = 1'b0
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       cfg_we,
    input  logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] cfg_voice,
    input  logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     cfg_mode,
    input  logic [REC_W-1:0]           cfg_data,
    input  logic                       clr_we,
    input  logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] clr_voice,
    input  logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     clr_mode,
    input  logic                       seed_we,
    input  logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] seed_voice,
    input  logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     seed_mode,
    input  logic [63:0]                seed_data,

    // 共享 RAM 端口
    output logic [LANES-1:0]           ram_rd_re,
    output logic [(NUM_SLOTS*LOCAL<2)?1:LANES*$clog2(NUM_SLOTS*LOCAL)-1:0] ram_rd_addr,
    input  logic [LANES*REC_W-1:0]     ram_rd_data,
    output logic [LANES-1:0]           ram_st_we,
    output logic [(NUM_SLOTS*LOCAL<2)?1:LANES*$clog2(NUM_SLOTS*LOCAL)-1:0] ram_st_addr,
    output logic [LANES*64-1:0]        ram_st_data,

    input  logic [NUM_SLOTS-1:0]       note_start_mask,
    input  logic [NUM_SLOTS-1:0]       choke_mask,
    input  logic [NUM_SLOTS*CW-1:0]    length_vec,
    input  logic [NUM_SLOTS*24-1:0]    attack_vec,
    input  logic [NUM_SLOTS*24-1:0]    release_vec,
    input  logic [NUM_SLOTS*16-1:0]    seed_vel_vec,   // UQ1.15，C seed 力度
    input  logic [NUM_SLOTS*((N_MODES<2)?1:$clog2(N_MODES))-1:0] n_modes_vec,

    // C seed ROM loader
    input  logic                       seed_load_start,
    input  logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] seed_load_voice,
    input  logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     seed_load_nmodes,
    input  logic [15:0]                seed_base,
    output logic                       seed_busy,
    output logic                       seed_done,

    input  logic                       start,
    output logic                       sample_ready,
    output logic                       done,
    output logic                       busy,
    output logic [NUM_SLOTS-1:0]       c_active,
    output logic [NUM_SLOTS-1:0]       c_done,

    output logic                       out_valid,
    output logic signed [63:0]         mix_sum,
    output logic [((NUM_SLOTS*N_MODES<2)?1:$clog2(NUM_SLOTS*N_MODES+1))-1:0] sat_count,
    output logic                       voice_valid,
    output logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] voice_id,
    output logic signed [63:0]         voice_sum
);

    logic [NUM_SLOTS*2-1:0] class_c;
    logic [NUM_SLOTS*32-1:0] x_zero;
    logic eng_ready;

    function automatic logic signed [31:0] sat32(input logic signed [48:0] v);
        begin
            if (v > 49'sd2147483647)       sat32 = 32'sh7FFFFFFF;
            else if (v < -49'sd2147483648)  sat32 = 32'sh80000000;
            else                            sat32 = v[31:0];
        end
    endfunction

    function automatic logic [63:0] scale_seed(
        input logic [63:0] w,
        input logic [15:0] g
    );
        logic signed [31:0] y1, y2;
        logic signed [48:0] p1, p2, r1, r2;
        begin
            if (g == 16'h8000) begin
                scale_seed = w;
            end else begin
                y1 = $signed(w[31:0]);
                y2 = $signed(w[63:32]);
                p1 = y1 * $signed({1'b0, g});
                p2 = y2 * $signed({1'b0, g});
                r1 = (p1 + 49'sd16384) >>> 15;
                r2 = (p2 + 49'sd16384) >>> 15;
                scale_seed = {sat32(r2), sat32(r1)};
            end
        end
    endfunction


    assign class_c = {NUM_SLOTS{2'd2}};
    assign x_zero  = '0;

    genvar g;
    generate
        for (g = 0; g < NUM_SLOTS; g = g + 1) begin : g_timer
            c_voice_timer #(.CW(CW)) u_timer (
                .clk(clk), .rst_n(rst_n),
                .start(note_start_mask[g]),
                .length(length_vec[g*CW +: CW]),
                .choke(choke_mask[g]),
                .active(c_active[g]),
                .done(c_done[g])
            );
        end
    endgenerate

    logic                    ld_we;
    logic [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] ld_voice;
    logic [((N_MODES<2)?1:$clog2(N_MODES))-1:0]     ld_mode;
    logic [63:0]             ld_data;

    c_seed_loader #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .SEED_DEPTH(SEED_DEPTH),
        .SEED_FILE(SEED_FILE)
    ) u_seed_loader (
        .clk(clk), .rst_n(rst_n),
        .start(seed_load_start), .voice(seed_load_voice),
        .n_modes(seed_load_nmodes), .seed_base(seed_base),
        .seed_we(ld_we), .seed_voice(ld_voice), .seed_mode(ld_mode),
        .seed_data(ld_data), .busy(seed_busy), .done(seed_done)
    );

    wire [63:0] ext_seed_scaled = scale_seed(seed_data, seed_vel_vec[seed_voice*16 +: 16]);
    wire [63:0] ld_seed_scaled  = scale_seed(ld_data, seed_vel_vec[ld_voice*16 +: 16]);

    wire        use_seed_we    = USE_SEED_ROM ? ld_we    : seed_we;
    wire [((NUM_SLOTS<2)?1:$clog2(NUM_SLOTS))-1:0] use_seed_voice =
        USE_SEED_ROM ? ld_voice : seed_voice;
    wire [((N_MODES<2)?1:$clog2(N_MODES))-1:0] use_seed_mode =
        USE_SEED_ROM ? ld_mode : seed_mode;
    wire [63:0] use_seed_data = USE_SEED_ROM ? ld_seed_scaled : ext_seed_scaled;

    eng1_engine_env_top_ext #(
        .NUM_SLOTS(NUM_SLOTS), .N_MODES(N_MODES), .LANES(LANES),
        .LOCAL(LOCAL), .REC_W(REC_W)
    ) u_engine (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(use_seed_we), .seed_voice(use_seed_voice), .seed_mode(use_seed_mode), .seed_data(use_seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0),
        .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0),
        .co_field('0), .co_wdata('0),
        .note_start_mask(note_start_mask),
        .gate_mask({NUM_SLOTS{1'b1}}),
        .choke_mask(choke_mask),
        .done_mask(c_done),
        .class_vec(class_c), .attack_vec(attack_vec), .release_vec(release_vec),
        .start(start), .active_mask(c_active), .x_vec(x_zero),
        .x_vel_vec({NUM_SLOTS{16'h8000}}),
        .n_modes_vec(n_modes_vec), .sample_ready(eng_ready),
        .done(done), .busy(busy), .out_valid(out_valid), .mix_sum(mix_sum),
        .sat_count(sat_count), .voice_valid(voice_valid), .voice_id(voice_id),
        .voice_sum(voice_sum),
        .ram_rd_re(ram_rd_re), .ram_rd_addr(ram_rd_addr), .ram_rd_data(ram_rd_data),
        .ram_st_we(ram_st_we), .ram_st_addr(ram_st_addr), .ram_st_data(ram_st_data)
    );

    assign sample_ready = eng_ready & ~seed_busy & ~seed_load_start;

endmodule
