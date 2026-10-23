// -----------------------------------------------------------------------------
// tb_modal_ram_aux.sv -- modal_ram 的 aux 读口 / 单字段写口
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_modal_ram_aux;
    import modal_record_pkg::*;

    localparam int SLOTS = 1;
    localparam int MODES = 4;
    localparam int LANES = 4;
    localparam int VW = 1;
    localparam int MW = 2;

    logic clk=0, rst_n=0;
    logic cfg_we; logic [VW-1:0] cfg_voice; logic [MW-1:0] cfg_mode; logic [REC_W-1:0] cfg_data;
    logic [LANES-1:0] st_we; logic [LANES*1-1:0] st_addr; logic [LANES*64-1:0] st_data;
    logic [LANES-1:0] rd_re; logic [LANES*1-1:0] rd_addr; logic [LANES*REC_W-1:0] rd_data;
    logic clr_we; logic [VW-1:0] clr_voice; logic [MW-1:0] clr_mode;
    logic seed_we; logic [VW-1:0] seed_voice; logic [MW-1:0] seed_mode; logic [63:0] seed_data;
    logic aux_re; logic [VW-1:0] aux_voice; logic [MW-1:0] aux_mode; logic [REC_W-1:0] aux_data; logic aux_valid;
    logic co_we; logic [VW-1:0] co_voice; logic [MW-1:0] co_mode; logic [3:0] co_field; logic [31:0] co_wdata;

    int errors=0;

    modal_ram #(.SLOTS(SLOTS), .MODES(MODES), .LANES(LANES),
                .STATE_FIRST(E1_Y1), .REC_W(REC_W), .FLD_W(FLD_W)
    ) dut (
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

    always #5 clk = ~clk;

    task automatic check32(input string n, input logic [31:0] g, input logic [31:0] e);
        begin if (g !== e) begin $display("FAIL %s got=%08x exp=%08x", n, g, e); errors++; end end
    endtask

    initial begin
        cfg_we=0; cfg_voice='0; cfg_mode='0; cfg_data='0;
        st_we='0; st_addr='0; st_data='0;
        rd_re='0; rd_addr='0;
        clr_we=0; clr_voice='0; clr_mode='0;
        seed_we=0; seed_voice='0; seed_mode='0; seed_data='0;
        aux_re=0; aux_voice='0; aux_mode='0;
        co_we=0; co_voice='0; co_mode='0; co_field='0; co_wdata='0;

        repeat (3) @(posedge clk); rst_n=1; repeat (2) @(posedge clk);

        cfg_data='0;
        cfg_data=rec_set(cfg_data,E1_G,32'h1111_1111);
        cfg_data=rec_set(cfg_data,E1_A1,32'h2222_2222);
        cfg_data=rec_set(cfg_data,E1_A2,32'h3333_3333);
        cfg_data=rec_set(cfg_data,E1_Y1,32'h4444_4444);
        cfg_data=rec_set(cfg_data,E1_Y2,32'h5555_5555);
        @(negedge clk); cfg_we=1; cfg_voice=0; cfg_mode=0;
        @(posedge clk); @(negedge clk); cfg_we=0;

        // field 1 write
        @(negedge clk); co_we=1; co_voice=0; co_mode=0; co_field=4'd1; co_wdata=32'hABCD_EF01;
        @(posedge clk); @(negedge clk); co_we=0;

        // aux read
        @(negedge clk); aux_re=1; aux_voice=0; aux_mode=0;
        @(posedge clk); @(negedge clk); aux_re=0;
        #1;
        if (!aux_valid) begin $display("FAIL aux_valid"); errors++; end
        check32("aux.G",  rec_get(aux_data,E1_G),  32'h1111_1111);
        check32("aux.A1", rec_get(aux_data,E1_A1), 32'hABCD_EF01);
        check32("aux.A2", rec_get(aux_data,E1_A2), 32'h3333_3333);
        check32("aux.Y1", rec_get(aux_data,E1_Y1), 32'h4444_4444);

        if (errors==0) $display("PASS tb_modal_ram_aux");
        else           $display("FAIL tb_modal_ram_aux errors=%0d", errors);
        $finish;
    end
endmodule
