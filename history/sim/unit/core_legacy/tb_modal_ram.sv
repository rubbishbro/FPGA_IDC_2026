// -----------------------------------------------------------------------------
// tb_modal_ram.sv -- 9×32 RAM 层单测（iverilog）
//
// 覆盖：
//   * cfg 整条记录写入/同步读回
//   * core 只写状态字段，系数保留
//   * clear 只清状态，不清系数
//   * seed 只写状态，系数保留
//   * 4 lane 地址映射（mode % LANES / mode / LANES）
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_modal_ram;

    import modal_record_pkg::*;

    localparam int SLOTS = 2;
    localparam int MODES = 8;
    localparam int LANES = 4;
    localparam int LOCAL = (MODES + LANES - 1) / LANES;   // 2
    localparam int AW    = $clog2(SLOTS * LOCAL);          // 2
    localparam int VW    = $clog2(SLOTS);                  // 1
    localparam int MW    = $clog2(MODES);                  // 3

    logic clk = 0;
    logic rst_n = 0;

    logic cfg_we;
    logic [VW-1:0] cfg_voice;
    logic [MW-1:0] cfg_mode;
    logic [REC_W-1:0] cfg_data;

    logic [LANES-1:0] st_we;
    logic [LANES*AW-1:0] st_addr;
    logic [LANES*64-1:0] st_data;

    logic [LANES-1:0] rd_re;
    logic [LANES*AW-1:0] rd_addr;
    logic [LANES*REC_W-1:0] rd_data;

    logic clr_we;
    logic [VW-1:0] clr_voice;
    logic [MW-1:0] clr_mode;

    logic seed_we;
    logic [VW-1:0] seed_voice;
    logic [MW-1:0] seed_mode;
    logic [63:0] seed_data;

    int errors = 0;
    int lane, loc, addr;

    modal_ram #(
        .SLOTS(SLOTS), .MODES(MODES), .LANES(LANES),
        .STATE_FIRST(E1_Y1), .REC_W(REC_W), .FLD_W(FLD_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_voice(cfg_voice),
        .cfg_mode(cfg_mode), .cfg_data(cfg_data),
        .st_we(st_we), .st_addr(st_addr), .st_data(st_data),
        .rd_re(rd_re), .rd_addr(rd_addr), .rd_data(rd_data),
        .clr_we(clr_we), .clr_voice(clr_voice), .clr_mode(clr_mode),
        .seed_we(seed_we), .seed_voice(seed_voice),
        .seed_mode(seed_mode), .seed_data(seed_data),
        .aux_re(1'b0), .aux_voice('0), .aux_mode('0),
        .aux_data(), .aux_valid(),
        .co_we(1'b0), .co_voice('0), .co_mode('0),
        .co_field('0), .co_wdata('0)
    );

    always #5 clk = ~clk;

    task automatic check32(input string name, input logic [31:0] got, input logic [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %-18s got=%08x exp=%08x", name, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    task automatic cfg_write(input int voice, input int mode, input logic [REC_W-1:0] rec);
        begin
            @(negedge clk);
            cfg_we = 1; cfg_voice = voice[VW-1:0]; cfg_mode = mode[MW-1:0];
            cfg_data = rec;
            @(posedge clk);
            @(negedge clk);
            cfg_we = 0;
        end
    endtask

    task automatic read_rec(input int voice, input int mode, output logic [REC_W-1:0] rec);
        begin
            lane = mode % LANES;
            loc  = mode / LANES;
            addr = voice * LOCAL + loc;
            @(negedge clk);
            rd_re = '0;
            rd_re[lane] = 1'b1;
            rd_addr = '0;
            rd_addr[lane*AW +: AW] = addr[AW-1:0];
            @(posedge clk);
            #1;
            rec = rd_data[lane*REC_W +: REC_W];
            @(negedge clk);
            rd_re = '0;
        end
    endtask

    task automatic write_state(input int voice, input int mode, input logic [63:0] state);
        begin
            lane = mode % LANES;
            loc  = mode / LANES;
            addr = voice * LOCAL + loc;
            @(negedge clk);
            st_we = '0;
            st_we[lane] = 1'b1;
            st_addr = '0;
            st_addr[lane*AW +: AW] = addr[AW-1:0];
            st_data = '0;
            st_data[lane*64 +: 64] = state;
            @(posedge clk);
            @(negedge clk);
            st_we = '0;
        end
    endtask

    task automatic clear_state(input int voice, input int mode);
        begin
            @(negedge clk);
            clr_we = 1; clr_voice = voice[VW-1:0]; clr_mode = mode[MW-1:0];
            @(posedge clk);
            @(negedge clk);
            clr_we = 0;
        end
    endtask

    task automatic seed_state(input int voice, input int mode, input logic [63:0] state);
        begin
            @(negedge clk);
            seed_we = 1; seed_voice = voice[VW-1:0]; seed_mode = mode[MW-1:0];
            seed_data = state;
            @(posedge clk);
            @(negedge clk);
            seed_we = 0;
        end
    endtask

    logic [REC_W-1:0] rec, rec2;
    logic [31:0] g, a1, a2, y1, y2;

    initial begin
        cfg_we = 0; cfg_voice = '0; cfg_mode = '0; cfg_data = '0;
        st_we = '0; st_addr = '0; st_data = '0;
        rd_re = '0; rd_addr = '0;
        clr_we = 0; clr_voice = '0; clr_mode = '0;
        seed_we = 0; seed_voice = '0; seed_mode = '0; seed_data = '0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ---- cfg + read ----
        rec = '0;
        rec = rec_set(rec, E1_G,  32'h1111_1111);
        rec = rec_set(rec, E1_A1, 32'h2222_2222);
        rec = rec_set(rec, E1_A2, 32'h3333_3333);
        rec = rec_set(rec, E1_Y1, 32'h4444_4444);
        rec = rec_set(rec, E1_Y2, 32'h5555_5555);
        rec = rec_set(rec, 5,     32'hA5A5_A5A5);

        cfg_write(0, 0, rec);
        read_rec(0, 0, rec2);
        check32("cfg.G",  rec_get(rec2, E1_G),  32'h1111_1111);
        check32("cfg.A1", rec_get(rec2, E1_A1), 32'h2222_2222);
        check32("cfg.A2", rec_get(rec2, E1_A2), 32'h3333_3333);
        check32("cfg.Y1", rec_get(rec2, E1_Y1), 32'h4444_4444);
        check32("cfg.Y2", rec_get(rec2, E1_Y2), 32'h5555_5555);
        check32("cfg.R5", rec_get(rec2, 5),     32'hA5A5_A5A5);

        // ---- core state write: coeff preserved ----
        write_state(0, 0, {32'hDEAD_BEEF, 32'hCAFE_BABE}); // {y2,y1}
        read_rec(0, 0, rec2);
        check32("st.G",  rec_get(rec2, E1_G),  32'h1111_1111);
        check32("st.A1", rec_get(rec2, E1_A1), 32'h2222_2222);
        check32("st.Y1", rec_get(rec2, E1_Y1), 32'hCAFE_BABE);
        check32("st.Y2", rec_get(rec2, E1_Y2), 32'hDEAD_BEEF);

        // ---- clear: state zero, coeff preserved ----
        clear_state(0, 0);
        read_rec(0, 0, rec2);
        check32("clr.G",  rec_get(rec2, E1_G),  32'h1111_1111);
        check32("clr.A1", rec_get(rec2, E1_A1), 32'h2222_2222);
        check32("clr.Y1", rec_get(rec2, E1_Y1), 32'h0000_0000);
        check32("clr.Y2", rec_get(rec2, E1_Y2), 32'h0000_0000);

        // ---- seed: state replaced, coeff preserved ----
        seed_state(0, 0, {32'h1234_5678, 32'h9ABC_DEF0});
        read_rec(0, 0, rec2);
        check32("seed.G",  rec_get(rec2, E1_G),  32'h1111_1111);
        check32("seed.A2", rec_get(rec2, E1_A2), 32'h3333_3333);
        check32("seed.Y1", rec_get(rec2, E1_Y1), 32'h9ABC_DEF0);
        check32("seed.Y2", rec_get(rec2, E1_Y2), 32'h1234_5678);

        // ---- another mode -> lane 1 ----
        rec = '0;
        rec = rec_set(rec, E1_G, 32'h0BAD_F00D);
        cfg_write(1, 5, rec);
        read_rec(1, 5, rec2);
        check32("mode5.G", rec_get(rec2, E1_G), 32'h0BAD_F00D);
        check32("mode5.Y1", rec_get(rec2, E1_Y1), 32'h0000_0000);

        if (errors == 0)
            $display("PASS tb_modal_ram");
        else
            $display("FAIL tb_modal_ram errors=%0d", errors);

        $finish;
    end

endmodule
