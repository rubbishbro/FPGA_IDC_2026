// -----------------------------------------------------------------------------
// tb_b_a1_ram.sv -- B a1 刷新写入 9×32 RAM 的单测
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_b_a1_ram;
    import modal_record_pkg::*;

    localparam int SLOTS = 1;
    localparam int MODES = 4;
    localparam int LANES = 4;
    localparam int VW = 1;
    localparam int MW = 2;

    logic clk=0, rst_n=0;

    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic [LANES-1:0] st_we; logic [LANES-1:0] st_addr; logic [LANES*64-1:0] st_data;
    logic [LANES-1:0] rd_re; logic [LANES-1:0] rd_addr; logic [LANES*REC_W-1:0] rd_data;
    logic clr_we; logic [VW-1:0] clr_voice; logic [MW-1:0] clr_mode;
    logic seed_we; logic [VW-1:0] seed_voice; logic [MW-1:0] seed_mode; logic [63:0] seed_data;
    logic aux_re; logic [VW-1:0] aux_voice; logic [MW-1:0] aux_mode; logic [REC_W-1:0] aux_data; logic aux_valid;
    logic co_we; logic [VW-1:0] co_voice; logic [MW-1:0] co_mode; logic [3:0] co_field; logic [31:0] co_wdata;

    logic [SLOTS*2-1:0] class_vec;
    logic [SLOTS*16-1:0] theta_base_vec;
    logic [15:0] ratio;
    logic a1_enable;
    logic a1_active, a1_done;

    int errors=0;
    logic [REC_W-1:0] rec;

    modal_ram #(.SLOTS(SLOTS), .MODES(MODES), .LANES(LANES),
                .STATE_FIRST(E1_Y1), .REC_W(REC_W), .FLD_W(FLD_W)
    ) u_ram (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice), .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .st_we(st_we), .st_addr(st_addr), .st_data(st_data),
        .rd_re(rd_re), .rd_addr(rd_addr), .rd_data(rd_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice), .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(aux_re), .aux_voice(aux_voice), .aux_mode(aux_mode),
        .aux_data(aux_data), .aux_valid(aux_valid),
        .co_we(co_we), .co_voice(co_voice), .co_mode(co_mode),
        .co_field(co_field), .co_wdata(co_wdata)
    );

    b_a1_ram_engine #(
        .NUM_SLOTS(SLOTS), .N_MODES(MODES), .COEFF_DEPTH(16),
        .THETA_DEPTH(1), .THETA_FILE("sim/unit/core/tb_b_a1_theta.mem"), .REC_W(REC_W)
    ) u_a1 (
        .clk(clk), .rst_n(rst_n),
        .class_vec(class_vec), .theta_base_vec(theta_base_vec),
        .ratio(ratio), .enable(a1_enable), .idle(1'b1),
        .aux_re(aux_re), .aux_voice(aux_voice), .aux_mode(aux_mode),
        .aux_data(aux_data), .aux_valid(aux_valid),
        .co_we(co_we), .co_voice(co_voice), .co_mode(co_mode),
        .co_field(co_field), .co_wdata(co_wdata),
        .active(a1_active), .done(a1_done)
    );

    always #5 clk = ~clk;

    initial begin
        cfg_we=0; cfg_voice='0; cfg_mode='0; cfg_data='0;
        st_we='0; st_addr='0; st_data='0;
        rd_re='0; rd_addr='0;
        clr_we=0; clr_voice='0; clr_mode='0;
        seed_we=0; seed_voice='0; seed_mode='0; seed_data='0;
        class_vec=2'd1; theta_base_vec='0; ratio=16'h9000; a1_enable=0;

        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        // a1=-0.5, a2=0.25, G=0, state 0
        cfg_data='0;
        cfg_data=rec_set(cfg_data,E1_A1,32'hFFF8_0000);
        cfg_data=rec_set(cfg_data,E1_A2,32'h0040_0000);
        @(negedge clk); cfg_we=1; cfg_voice=0; cfg_mode=0;
        @(posedge clk); @(negedge clk); cfg_we=0;

        @(negedge clk); a1_enable=1;
        wait (a1_done);
        @(negedge clk); a1_enable=0;

        // read mode0 via lane0 read port
        @(negedge clk); rd_re[0]=1; rd_addr=0;
        @(posedge clk); #1;
        rec = rd_data[0*REC_W +: REC_W];
        @(negedge clk); rd_re[0]=0;
        if (rec_get(rec,E1_A1) === 32'hFFF8_0000) begin
            $display("FAIL a1 not refreshed"); errors++;
        end
        if (rec_get(rec,E1_A2) !== 32'h0040_0000) begin
            $display("FAIL a2 changed"); errors++;
        end
        if (rec_get(rec,E1_G) !== 32'h0000_0000) begin
            $display("FAIL G changed"); errors++;
        end

        if (errors==0) $display("PASS tb_b_a1_ram");
        else           $display("FAIL tb_b_a1_ram errors=%0d", errors);
        $finish;
    end
endmodule
