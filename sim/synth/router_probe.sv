// -----------------------------------------------------------------------------
// router_probe.sv -- 新四引擎/router 的 Fmax/资源探针
// 只有 clk/reset/led；内部 FSM 循环加载 A/B/C 并跑 sample。
// 使用小型测试 ROM（sim/unit/core/router_*），只为时序/资源，不代表真实音色。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module router_probe (
    input  logic clk,
    input  logic reset,     // board reset, high active
    output logic led
);
    logic rst_n;
    assign rst_n = ~reset;

    localparam int SLOTS = 16;
    localparam int MA = 48;
    localparam int ME = 80;

    logic load_valid, load_ready;
    logic [1:0] load_class;
    logic [3:0] load_voice;
    logic [1:0] load_inst;
    logic [6:0] load_note;
    logic [7:0] load_vel;
    logic load_dyn;
    logic [11:0] load_note_id;
    logic load_done;
    logic [3:0] done_voice;
    logic [5:0] loaded_n;
    logic load_error;

    logic [SLOTS*32-1:0] a_x;
    logic [SLOTS*16-1:0] a_x_vel;
    logic [SLOTS*16-1:0] b_vel;
    logic [15:0] b_ratio;
    logic b_a1_enable;
    logic [SLOTS*16-1:0] c_seed_vel;
    logic [15:0] c_seed_base;

    logic e2_cfg_we;
    logic [3:0] e2_cfg_voice;
    logic [6:0] e2_cfg_mode;
    logic [287:0] e2_cfg_data;
    logic e2_clr_we;
    logic [3:0] e2_clr_voice;
    logic [6:0] e2_clr_mode;
    logic e2_seed_we;
    logic [3:0] e2_seed_voice;
    logic [6:0] e2_seed_mode;
    logic [63:0] e2_seed_data;
    logic [SLOTS*32-1:0] e2_x;
    logic [SLOTS*7-1:0] e2_nmodes;

    logic start, sample_ready, busy, done, out_valid;
    logic signed [63:0] mix_sum;

    router_system_top #(
        .NUM_SLOTS(SLOTS), .N_MODES_ABC(MA), .N_MODES_E2(ME),
        .LANES(4), .REC_W(288),
        .A_COEFF_DEPTH(2), .A_INDEX_DEPTH(128),
        .A_COEFF_FILE("sim/unit/core/router_a_coeff.mem"),
        .A_INDEX_FILE("sim/unit/core/router_a_index.mem"),
        .BC_COEFF_DEPTH(8), .BC_INDEX_DEPTH(8192),
        .BC_CTRL_DEPTH(2), .BC_SEED_DEPTH(24),
        .BC_COEFF_FILE("sim/unit/core/router_bc_coeff.mem"),
        .BC_INDEX_FILE("sim/unit/core/router_bc_index.mem"),
        .BC_CTRL_FILE("sim/unit/core/router_bc_ctrl.mem"),
        .BC_SEED_FILE("sim/unit/core/router_bc_seed.mem"),
        .C_SEED_FILE("sim/unit/core/router_bc_seed.mem"),
        .E2_COEFF_DEPTH(2), .E2_INDEX_DEPTH(8192), .E2_CTRL_DEPTH(2), .E2_SEED_DEPTH(8),
        .E2_COEFF_FILE("sim/unit/core/router_e2_coeff.mem"),
        .E2_INDEX_FILE("sim/unit/core/router_e2_index.mem"),
        .E2_CTRL_FILE("sim/unit/core/router_e2_ctrl.mem"),
        .E2_SEED_FILE("sim/unit/core/router_e2_seed.mem"),
        .E2_L72_FILE("sim/unit/core/router_e2_l72.mem")
    ) u_sys (
        .clk(clk), .rst_n(rst_n),
        .load_valid(load_valid), .load_ready(load_ready), .load_class(load_class),
        .load_voice(load_voice), .load_inst(load_inst), .load_note(load_note),
        .load_vel(load_vel), .load_dyn(load_dyn), .load_note_id(load_note_id),
        .rcfg_valid(1'b0), .rcfg_instrument(4'd0), .rcfg_voice(4'd0), .rcfg_note(7'd0),
        .rcfg_velocity(8'd0), .fmap(128'd0), .fmap_valid(1'b0),
        .load_done(load_done), .done_voice(done_voice), .loaded_n_modes(loaded_n),
        .load_error(load_error),
        .off_valid(1'b0), .off_voice('0),
        .a_x(a_x), .a_x_vel(a_x_vel),
        .b_vel(b_vel), .b_ratio(b_ratio), .b_a1_enable(b_a1_enable),
        .c_seed_vel(c_seed_vel), .c_seed_base(c_seed_base),
        .e2_cfg_we(e2_cfg_we), .e2_cfg_voice(e2_cfg_voice),
        .e2_cfg_mode(e2_cfg_mode), .e2_cfg_data(e2_cfg_data),
        .e2_clr_we(e2_clr_we), .e2_clr_voice(e2_clr_voice), .e2_clr_mode(e2_clr_mode),
        .e2_seed_we(e2_seed_we), .e2_seed_voice(e2_seed_voice),
        .e2_seed_mode(e2_seed_mode), .e2_seed_data(e2_seed_data),
        .e2_x(e2_x), .e2_nmodes(e2_nmodes),
        .start(start), .sample_ready(sample_ready), .busy(busy),
        .done(done), .out_valid(out_valid), .mix_sum(mix_sum)
    );

    // 单独例化 ENG2，保证它不被优化掉（router 系统里 E2 仍走外部 cfg）
    logic e2_start;
    logic [SLOTS-1:0] e2_zero;
    logic e2_done, e2_ready, e2_out;
    logic [15:0] e2_active;
    logic [SLOTS*32-1:0] e2_x2;
    logic [SLOTS*7-1:0] e2_nm;
    logic [287:0] e2_cfg;
    logic [15:0] e2_cnt;

    assign e2_active = 16'h0001;
    assign e2_nm = {SLOTS{7'd1}};
    assign e2_cfg = {32'sh0, 32'sh7000, 32'sh6000, 32'sh5000,
                     32'sh4000, 32'sh3000, 32'sh2000, 32'sh1000, 32'sh0};

    // E2 已由 router_system_top 内部的 shared_engines_top 承担；这里不再单独例化旧 E2。


    logic [31:0] lfsr;
    logic [3:0]  phase;
    logic [7:0]  run_cnt;
    logic [63:0] acc;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 32'h1234_5678;
            phase <= 4'd0;
            run_cnt <= 8'd0;
            acc <= 64'd0;
            led <= 1'b0;
            load_valid <= 1'b0;
            load_class <= 2'd0;
            load_voice <= 4'd0;
            load_inst <= 2'd0;
            load_note <= 7'd60;
            load_vel <= 8'd255;
            load_dyn <= 1'b1;
            load_note_id <= 12'd0;
            a_x <= '0;
            a_x_vel <= {SLOTS{16'h8000}};
            b_vel <= {SLOTS{16'h8000}};
            b_ratio <= 16'h8000;
            b_a1_enable <= 1'b0;
            c_seed_vel <= {SLOTS{16'h8000}};
            c_seed_base <= 16'd20;
            e2_cfg_voice <= '0; e2_cfg_mode <= '0; e2_cfg_data <= '0;
            e2_clr_we <= 1'b0; e2_clr_voice <= '0; e2_clr_mode <= '0;
            e2_seed_we <= 1'b0; e2_seed_voice <= '0; e2_seed_mode <= '0; e2_seed_data <= '0;
            e2_x <= '0; e2_nmodes <= '0; e2_x2 <= '0;
            start <= 1'b0;
            e2_cfg_we <= 1'b0;
            e2_start <= 1'b0;
            e2_zero <= '0;
            e2_cnt <= 16'd0;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            led <= ^acc;
            start <= 1'b0;
            e2_cfg_we <= 1'b0;
            e2_start <= 1'b0;
            e2_zero <= '0;
            e2_cnt <= e2_cnt + 1'b1;
            if (e2_cnt == 16'd0) e2_cfg_we <= 1'b1;
                if (e2_cnt[5:0] == 6'd0) begin
                e2_start <= 1'b1;
                if (e2_cnt == 16'd0) e2_zero[0] <= 1'b1;
            end
            e2_x2 <= '0;
            e2_x2[0*32 +: 32] <= lfsr;
            a_x[0*32 +: 32] <= lfsr;
            a_x[1*32 +: 32] <= {lfsr[7:0], lfsr[31:8]};
            case (phase)
                4'd0: begin // load A
                    load_valid <= 1'b1; load_class <= 2'd0; load_note <= 7'd60;
                    load_vel <= 8'd255; load_dyn <= 1'b1; load_note_id <= 12'd0;
                    phase <= 4'd1;
                end
                4'd1: begin
                    load_valid <= 1'b0;
                    if (load_done) begin phase <= 4'd2; run_cnt <= 8'd0; end
                end
                4'd2: begin // load B
                    load_valid <= 1'b1; load_class <= 2'd1; load_note <= 7'd60;
                    load_vel <= 8'd0; load_dyn <= 1'b0;
                    phase <= 4'd3;
                end
                4'd3: begin
                    load_valid <= 1'b0;
                    if (load_done) begin phase <= 4'd4; run_cnt <= 8'd0; end
                end
                4'd4: begin // load C
                    load_valid <= 1'b1; load_class <= 2'd2; load_note <= 7'd36;
                    load_vel <= 8'd0; load_dyn <= 1'b0; load_note_id <= 12'd1;
                    phase <= 4'd5;
                end
                4'd5: begin
                    load_valid <= 1'b0;
                    if (load_done) begin phase <= 4'd6; end
                end
                4'd6: begin // run samples
                    if (sample_ready && !busy) begin
                        start <= 1'b1;
                        phase <= 4'd7;
                    end
                end
                4'd7: begin
                    if (done) begin
                        acc <= acc ^ mix_sum;
                        if (run_cnt == 8'd7) begin
                            phase <= 4'd0;
                        end else begin
                            run_cnt <= run_cnt + 1'b1;
                            phase <= 4'd6;
                        end
                    end
                end
                default: phase <= 4'd0;
            endcase
        end
    end

endmodule
