`timescale 1ns/1ps
//          eng0 +          /  /
module tb_voice_router;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    pad_driver_pkg::mat4x4 fmap;
    router_pkg::instrument_e inst;
    logic        reload = 0, start = 0, mod_req = 0;
    logic [4:0]  n_voices;
    logic [6:0]  n_modes;
    logic [6:0]  n_samples;
    logic [15:0] st_zero_mask;
    logic        ready, busy, done, y_valid;
    logic signed [63:0] y_data;
    logic        ns_rd_en = 0, ns_rd_sel = 0;
    logic [11:0] ns_rd_addr = 0;
    logic signed [31:0] ns_rd_data;
    logic        ns_rd_valid;

    voice_router dut (
        .clk(clk), .rst_n(rst_n), .fmap(fmap), .inst(inst),
        .reload(reload), .mod_req(mod_req), .start(start),
        .n_voices(n_voices), .n_modes(n_modes), .n_samples(n_samples),
        .st_zero_mask(st_zero_mask), .ready(ready), .busy(busy), .done(done),
        .y_valid(y_valid), .y_data(y_data),
        .qspi_cs_n(), .qspi_sck(), .qspi_dq_o(), .qspi_dq_oe(), .qspi_dq_i(4'b0),
        .ns_rd_en(ns_rd_en), .ns_rd_addr(ns_rd_addr), .ns_rd_sel(ns_rd_sel),
        .ns_rd_data(ns_rd_data), .ns_rd_valid(ns_rd_valid)
    );

    int fd, a11m,a11s,a12m,a12s,a21m,a21s,a22m,a22s,gqm,gqs,gvm,gvs,wom,wos;
    int n_yv = 0, n_nz = 0;
    longint ymax = 0;

    always @(posedge clk) if (y_valid) begin
        n_yv++;
        if (y_data != 0) n_nz++;
        if (y_data > ymax || -y_data > ymax) ymax = (y_data > 0) ? y_data : -y_data;
    end

    task automatic load_coefs();
        fd = $fopen("../../rtl/simsynth/golden_seq_piano.txt", "r");
        if (fd == 0) fd = $fopen("golden_seq_piano.txt", "r");
        if (fd == 0) begin $display("FAIL: no golden_seq_piano.txt"); $finish; end
        for (int i = 0; i < 4; i++) begin
            void'($fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                a11m,a11s,a12m,a12s,a21m,a21s,a22m,a22s,gqm,gqs,gvm,gvs,wom,wos));
            dut.ca_a11[i] = a11m; dut.ca_a12[i] = a12m;
            dut.ca_a21[i] = a21m; dut.ca_a22[i] = a22m;
            dut.ca_gq[i]  = gqm;  dut.ca_gv[i]  = gvm;
            dut.ca_wo[i]  = wom;
        end
        $fclose(fd);
        $display("coefs loaded: a11=%0d a12=%0d a21=%0d wo=%0d", a11m, a12m, a21m, wom);
    endtask

    int dbg_n = 0;
    always @(posedge clk) begin
        #1;
        if (dut.xmap_valid && dbg_n < 10) begin
            $display("TICK fmap0=%0d xmap0=%0d x_ram0=%0d st=%0d fidx=%0d xw=%0b",
                     fmap.flat_d[0].val, dut.xmap[0], dut.x_ram[0], dut.state, dut.fidx, dut.xw_run);
            dbg_n++;
        end
    end

    initial begin
        for (int i = 0; i < 16; i++) fmap.flat_d[i].val = 0;
        inst = router_pkg::INST_PIANO;  // piano: eng0 + ADSR
        n_voices = 1; n_modes = 4; n_samples = 64; st_zero_mask = 16'h0001;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        load_coefs();
        repeat (5) @(posedge clk);

        // 空作业：让 weight_loader 的先走完（否则按键脉冲会在加载期间被吃掉）
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        repeat (5) @(posedge clk);
        load_coefs();               // 加载器是占位实现，不真的写表，重新灌一次
        repeat (5) @(posedge clk);

        //       255
        fmap.flat_d[0].val = 8'd255;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;

        wait (done);
        $display("R1: yv=%0d nz=%0d ymax=%0d emap=%0d x0=%0d q0=%0d", n_yv, n_nz, ymax, dut.emap[0], dut.x_ram[0], dut.q_ram[0]);

        //         0
        fmap.flat_d[0].val = 8'd0;
        n_yv = 0;
        @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
        wait (done);
        repeat (3) @(posedge clk);
        $display("R2: y_valid=%0d  emap=%0d  q0=%0d v0=%0d  dead=%0b",
                 n_yv, dut.emap[0], dut.q_ram[0], dut.v_ram[0], dut.voice_dead[0]);

        if (n_nz > 0 && ymax != 0 && dut.emap[0] == 0 && dut.q_ram[0] == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $finish;
    end
endmodule
