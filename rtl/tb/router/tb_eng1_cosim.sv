// -----------------------------------------------------------------------------
// tb_eng1_cosim -- drive eng1 from a Python-generated case list.
//
// The cases are produced by ``python/modal_sim/eng1_cosim.py`` in
// ``build/eng1_cosim/cases.txt``.  One line per job:
//
//   n_modes st_zero x G a1 a2 y1_0..y1_7 y2_0..y2_7 expected_y
//
// All values are decimal signed integers.  ``N=8`` is fixed so the line length
// stays constant; unused modes are zero.
//
// This TB deliberately mirrors ``tb_eng1_g.sv``'s state-memory hook: it loads
// q_mem/v_mem before start and samples eng1's own S_WB write port.  That keeps
// the test independent of the router's address mux while still exercising the
// real pipeline, rounding, saturation and the ``nmod_lat``/``y1_cur`` quirks.
//
// The Python side runs its ``rtl_compat=True`` model, because the current RTL
// still has F05 (previous-mode multiplier / cross-job leak).  When F05 is fixed,
// regenerate the cases with the default model; the TB itself does not change.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_eng1_cosim;

    localparam int N = 8;
    localparam int CASES = 128;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic               start = 0, st_zero = 0;
    logic [3:0]         n_modes = N;
    logic signed [31:0] x_in = 0;

    logic               co_re, st_re, st_we, x_re, yv;
    logic [2:0]         co_addr, st_addr, st_wa, x_addr;
    logic signed [63:0] yd;
    logic signed [31:0] qw, qdw;
    modal_step_pkg::coeff_t cd;

    logic signed [31:0] q_mem [0:N-1], v_mem [0:N-1];
    logic signed [31:0] st_q_r, st_qd_r;

    eng1 #(.N_MODES(N), .X_DEPTH(N)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .st_zero(st_zero),
        .n_modes(n_modes),
        .co_re(co_re), .co_addr(co_addr), .co_data(cd),
        .st_re(st_re), .st_addr(st_addr),
        .st_q(st_q_r), .st_qdot(st_qd_r),
        .st_we(st_we), .st_waddr(st_wa),
        .st_q_wdata(qw), .st_qdot_wdata(qdw),
        .x_re(x_re), .x_addr(x_addr), .x_data(x_in),
        .y_valid(yv), .y_data(yd)
    );

    // State memory hook (same as tb_eng1_g).
    always @(posedge clk) begin
        if (dut.st === 3'd1) begin           // S_RD
            st_q_r  <= q_mem[dut.st_addr];
            st_qd_r <= v_mem[dut.st_addr];
        end
        if (dut.st === 3'd5) begin           // S_WB
            q_mem[dut.st_waddr]  <= dut.st_q_wdata;
            v_mem[dut.st_waddr]  <= dut.st_qdot_wdata;
        end
    end

    integer fd, rc, case_i, errs, i;
    integer f_nmodes, f_zero, f_x, f_g, f_a1, f_a2;
    longint f_exp;
    integer qv [0:N-1], vv [0:N-1];
    longint got [0:CASES-1];

    initial begin
        for (i = 0; i < N; i++) begin
            q_mem[i] = 0;
            v_mem[i] = 0;
            qv[i] = 0;
            vv[i] = 0;
        end
        st_q_r = 0;
        st_qd_r = 0;
    end

    initial begin
        errs = 0;
        case_i = 0;
        fd = $fopen("build/eng1_cosim/cases.txt", "r");
        if (fd == 0) begin
            $display("FAIL cannot open build/eng1_cosim/cases.txt");
            $finish;
        end

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (3) @(posedge clk);

        while (!$feof(fd) && case_i < CASES) begin
            rc = $fscanf(fd, "%d %d %d %d %d %d",
                         f_nmodes, f_zero, f_x, f_g, f_a1, f_a2);
            if (rc != 6) begin
                if ($feof(fd)) break;
                $display("FAIL case %0d: header read rc=%0d", case_i, rc);
                errs = errs + 1;
                break;
            end
            for (i = 0; i < N; i++) rc = $fscanf(fd, "%d", qv[i]);
            for (i = 0; i < N; i++) rc = $fscanf(fd, "%d", vv[i]);
            rc = $fscanf(fd, "%d", f_exp);

            for (i = 0; i < N; i++) begin
                q_mem[i] = qv[i][31:0];
                v_mem[i] = vv[i][31:0];
            end
            st_q_r = q_mem[0];
            st_qd_r = v_mem[0];

            cd.a11 = f_g;
            cd.a12 = f_a1;
            cd.a21 = f_a2;
            cd.a22 = 32'sd0;
            cd.gq  = 32'sd0;
            cd.gv  = 32'sd0;
            cd.wo  = 32'sd0;
            x_in    = f_x;
            n_modes = f_nmodes[3:0];
            st_zero = f_zero[0];

            @(negedge clk);
            start = 1;
            @(negedge clk);
            start = 0;
            wait (yv);
            #1;
            got[case_i] = yd;
            if (yd !== f_exp) begin
                $display("FAIL case %0d: got %0d expected %0d (n=%0d zero=%0d)",
                         case_i, yd, f_exp, f_nmodes, f_zero);
                errs = errs + 1;
            end else begin
                $display("OK   case %0d: y=%0d", case_i, yd);
            end
            @(posedge clk);   // let S_DONE -> S_IDLE settle before the next start
            case_i = case_i + 1;
        end

        $fclose(fd);
        $display("cases=%0d errors=%0d", case_i, errs);
        if (errs == 0 && case_i > 0) $display("RESULT: PASS");
        else                          $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL timeout");
        $display("RESULT: FAIL");
        $finish;
    end

endmodule
