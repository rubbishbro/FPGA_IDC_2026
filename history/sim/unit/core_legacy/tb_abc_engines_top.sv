// -----------------------------------------------------------------------------
// tb_abc_engines_top.sv -- A/B/C 三引擎顶层 A-only 冒烟
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_abc_engines_top;
    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 4;
    localparam int LANES = 4;
    localparam int VW = 1;
    localparam int MW = 2;

    logic clk=0, rst_n=0;

    logic cfg_we; logic [1:0] cfg_engine; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic clr_we; logic [1:0] clr_engine; logic [VW-1:0] clr_voice; logic [MW-1:0] clr_mode;
    logic seed_we; logic [1:0] seed_engine; logic [VW-1:0] seed_voice; logic [MW-1:0] seed_mode; logic [63:0] seed_data;

    logic [SLOTS-1:0] a_note_start, a_gate, a_active;
    logic [SLOTS*32-1:0] a_x;
    logic [SLOTS*16-1:0] a_x_vel;
    logic [SLOTS*MW-1:0] a_nmodes;

    logic [SLOTS*256-1:0] b_ctrl;
    logic [SLOTS*2-1:0] b_class;
    logic [SLOTS*16-1:0] b_vel, b_theta;
    logic b_a1_enable;
    logic [15:0] b_ratio;
    logic [SLOTS-1:0] b_note_start, b_gate, b_active;
    logic [SLOTS*MW-1:0] b_nmodes;

    logic [SLOTS-1:0] c_note_start, c_choke;
    logic [SLOTS*20-1:0] c_len;
    logic [SLOTS*16-1:0] c_seed_vel;
    logic [SLOTS*24-1:0] c_attack, c_release;
    logic [SLOTS*MW-1:0] c_nmodes;

    logic start, sample_ready, busy, done, out_valid;
    logic signed [63:0] mix_sum;

    int errors=0;

    abc_engines_top #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .LANES(LANES), .REC_W(REC_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_engine(cfg_engine), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .clr_we(clr_we), .clr_engine(clr_engine), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_engine(seed_engine), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_data(seed_data),
        .a_note_start(a_note_start), .a_gate(a_gate), .a_active(a_active),
        .a_x(a_x), .a_x_vel(a_x_vel), .a_nmodes(a_nmodes),
        .b_ctrl(b_ctrl), .b_class(b_class), .b_vel(b_vel), .b_theta(b_theta),
        .b_a1_enable(b_a1_enable), .b_ratio(b_ratio),
        .b_note_start(b_note_start), .b_gate(b_gate), .b_active(b_active), .b_nmodes(b_nmodes),
        .c_note_start(c_note_start), .c_choke(c_choke), .c_len(c_len),
        .c_seed_vel(c_seed_vel), .c_attack(c_attack), .c_release(c_release), .c_nmodes(c_nmodes),
        .c_seed_load_start(1'b0), .c_seed_load_voice('0), .c_seed_load_nmodes('0),
        .c_seed_base('0),
        .start(start), .sample_ready(sample_ready), .busy(busy), .done(done),
        .out_valid(out_valid), .mix_sum(mix_sum)
    );

    always #5 clk = ~clk;

    initial begin
        cfg_we=0; cfg_engine='0; cfg_voice='0; cfg_mode='0; cfg_data='0;
        clr_we=0; clr_engine='0; clr_voice='0; clr_mode='0;
        seed_we=0; seed_engine='0; seed_voice='0; seed_mode='0; seed_data='0;
        a_note_start='0; a_gate='0; a_active='0; a_x='0; a_x_vel={SLOTS{16'h8000}}; a_nmodes='0;
        b_ctrl='0; b_class='0; b_vel='0; b_theta='0; b_a1_enable=0; b_ratio=16'h8000;
        b_note_start='0; b_gate='0; b_active='0; b_nmodes='0;
        c_note_start='0; c_choke='0; c_len='0; c_seed_vel='0; c_attack='0; c_release='0; c_nmodes='0;
        start=0;

        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        // A mode0: G=1
        @(negedge clk);
        cfg_we=1; cfg_engine=0; cfg_voice=0; cfg_mode=0;
        cfg_data=rec_set(cfg_data,E1_G,32'h0100_0000);
        @(posedge clk); @(negedge clk); cfg_we=0;

        a_active = 2'b01;
        a_x[0*32 +: 32] = 32'sh1000_0000; // 0.25
        a_nmodes[0*MW +: MW] = 2'd1;

        // A note-on
        @(negedge clk); a_note_start[0]=1; a_gate[0]=1;
        @(posedge clk); @(negedge clk); a_note_start[0]=0;

        wait (sample_ready);
        start=1;
        @(posedge clk); @(negedge clk); start=0;
        wait (done);
        #1;

        if (mix_sum !== 64'sd268435456) begin
            $display("FAIL mix_sum=%0d exp=268435456", mix_sum); errors++;
        end
        if (!out_valid) begin $display("FAIL out_valid"); errors++; end

        if (errors==0) $display("PASS tb_abc_engines_top");
        else           $display("FAIL tb_abc_engines_top errors=%0d", errors);
        $finish;
    end
endmodule
