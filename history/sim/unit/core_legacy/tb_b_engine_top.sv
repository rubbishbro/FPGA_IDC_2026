// -----------------------------------------------------------------------------
// tb_b_engine_top.sv -- B 引擎功能冒烟
//
// 1 voice / 1 mode / G=1；B 的 NCO 每 4 拍产生一个 impulse；
// 在 x 非零的拍启动 engine sample，期待 mix_sum > 0。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_b_engine_top;

    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 4;
    localparam int LANES = 4;
    localparam int VW    = 1;
    localparam int MW    = 2;

    logic clk = 0, rst_n = 0;

    logic cfg_we;
    logic [VW-1:0] cfg_voice;
    logic [MW-1:0] cfg_mode;
    logic [REC_W-1:0] cfg_data;
    logic clr_we;
    logic [VW-1:0] clr_voice;
    logic [MW-1:0] clr_mode;
    logic seed_we;
    logic [VW-1:0] seed_voice;
    logic [MW-1:0] seed_mode;
    logic [63:0] seed_data;

    logic [SLOTS*256-1:0] ctrl_vec;
    logic [SLOTS*2-1:0] class_vec;
    logic [SLOTS*16-1:0] vel_vec;
    logic [SLOTS*16-1:0] theta_base_vec;
    logic a1_enable, a1_active, a1_done;
    logic [SLOTS-1:0] note_start_mask, gate_mask;
    logic [15:0] ratio;

    logic start;
    logic [SLOTS-1:0] active_mask;
    logic [SLOTS*MW-1:0] n_modes_vec;
    logic sample_ready, done, busy;
    logic out_valid;
    logic signed [63:0] mix_sum;
    logic [3:0] sat_count;
    logic voice_valid;
    logic [VW-1:0] voice_id;
    logic signed [63:0] voice_sum;

    int errors = 0;
    int i;

    b_engine_top #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .LANES(LANES), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .ctrl_vec(ctrl_vec), .class_vec(class_vec), .vel_vec(vel_vec),
        .theta_base_vec(theta_base_vec), .a1_enable(a1_enable),
        .a1_active(a1_active), .a1_done(a1_done),
        .note_start_mask(note_start_mask), .gate_mask(gate_mask), .ratio(ratio),
        .start(start), .active_mask(active_mask), .n_modes_vec(n_modes_vec),
        .sample_ready(sample_ready), .done(done), .busy(busy),
        .out_valid(out_valid), .mix_sum(mix_sum), .sat_count(sat_count),
        .voice_valid(voice_valid), .voice_id(voice_id), .voice_sum(voice_sum)
    );

    always #5 clk = ~clk;

    initial begin
        cfg_we = 0; cfg_voice = '0; cfg_mode = '0; cfg_data = '0;
        clr_we = 0; clr_voice = '0; clr_mode = '0;
        seed_we = 0; seed_voice = '0; seed_mode = '0; seed_data = '0;
        ctrl_vec = '0; class_vec = '0; vel_vec = '0;
        theta_base_vec = '0; a1_enable = 0;
        note_start_mask = '0; gate_mask = '0; ratio = 16'h8000;
        start = 0; active_mask = '0; n_modes_vec = '0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // mode0: G=1
        @(negedge clk);
        cfg_we = 1; cfg_voice = 0; cfg_mode = 0; cfg_data = '0;
        cfg_data = rec_set(cfg_data, E1_G, 32'h0100_0000);
        @(posedge clk);
        @(negedge clk); cfg_we = 0;

        // B control: base_inc=0x40000000, attack/release=0.25
        ctrl_vec[0*256 + 64 +: 32] = 32'h4000_0000;
        ctrl_vec[0*256 + 16 +: 24] = 24'h40_0000;
        ctrl_vec[0*256 + 40 +: 24] = 24'h40_0000;
        class_vec[0*2 +: 2] = 2'd1;
        vel_vec[0*16 +: 16] = 16'h8000;
        n_modes_vec[0*MW +: MW] = 2'd1;
        active_mask = 2'b01;

        // B note-on
        @(negedge clk); note_start_mask[0] = 1; gate_mask[0] = 1;
        @(posedge clk); @(negedge clk); note_start_mask[0] = 0;

        // 等到 x_b 非零，再启动一次 engine sample；最多 200 拍
        for (i = 0; i < 200; i = i + 1) begin
            @(posedge clk);
            #1;
            if (dut.x_b[0*32 +: 32] != 32'sd0) begin
                @(negedge clk);
                start = 1;
                @(posedge clk); @(negedge clk); start = 0;
                wait (done);
                #1;
                if (mix_sum != 0) begin
                    i = 1000;
                end
            end
        end

        if (mix_sum == 0) begin
            $display("FAIL B mix_sum stays zero"); errors = errors + 1;
        end

        if (errors == 0) $display("PASS tb_b_engine_top");
        else             $display("FAIL tb_b_engine_top errors=%0d", errors);
        $finish;
    end

endmodule
