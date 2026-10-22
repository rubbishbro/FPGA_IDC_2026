`timescale 1ns/1ps
module tb_post_chain;
    logic clk=0, rst_n=0;
    // envelope
    logic env_v; logic signed [63:0] env_in, env_out;
    // dry/wet
    logic dw_v; logic signed [63:0] dw_out;
    // final
    logic fa_v; logic signed [63:0] fa_out;
    // body
    logic body_clear, body_clear_ready, body_in_v, body_in_ready;
    logic signed [63:0] body_in, body_out;
    logic body_out_v, body_ready, body_err; logic [3:0] body_sat; logic [2:0] body_sat_cnt;
    int errors=0; int body_outs=0;

    envelope_mul u_env(.clk(clk),.rst_n(rst_n),.in_valid(env_v),.in_data(env_in),.gain(16'h4000),.out_valid(),.out_data(env_out));
    dry_wet_mix u_dw(.clk(clk),.rst_n(rst_n),.in_valid(dw_v),.dry(64'sd1073741824),.wet(64'sd536870912),.gd(16'h4000),.gw(16'h4000),.out_valid(),.out_data(dw_out));
    final_adder #(.N(2)) u_fa(.clk(clk),.rst_n(rst_n),.in_valid(fa_v),.in_bus({64'sd2,64'sd1}),.out_valid(),.out_data(fa_out));
    body_filter #(.BODY_INSTRUMENT(0), .BODY_FILE("rtl/rom/body_coeff.mem")) u_body(
        .clk(clk),.rst_n(rst_n),.clear_valid(body_clear),.clear_ready(body_clear_ready),
        .in_valid(body_in_v),.in_ready(body_in_ready),.in_sum(body_in),
        .out_valid(body_out_v),.out_sum(body_out),.out_sat(body_sat),.sat_count(body_sat_cnt),
        .coeff_ready(body_ready),.coeff_error(body_err)
    );
    always #5 clk=~clk;

    initial begin
        env_v=0; env_in=0; dw_v=0; fa_v=0; body_clear=0; body_in_v=0; body_in=0;
        repeat(3) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        // envelope: 0.5 * 0.5 = 0.25
        @(negedge clk); env_v=1; env_in=64'sd536870912;
        @(posedge clk); @(negedge clk); env_v=0;
        @(posedge clk); #1;
        if (env_out != 64'sd268435456) begin $display("FAIL env=%0d",env_out); errors++; end
        // dry/wet: 0.5*0.5 + 0.25*0.5 = 0.375
        @(negedge clk); dw_v=1;
        @(posedge clk); @(negedge clk); dw_v=0;
        @(posedge clk); #1;
        if (dw_out != 64'sd805306368) begin $display("FAIL dw=%0d",dw_out); errors++; end
        // final: 1+2=3
        @(negedge clk); fa_v=1;
        @(posedge clk); @(negedge clk); fa_v=0;
        @(posedge clk); #1;
        if (fa_out != 64'sd3) begin $display("FAIL fa=%0d",fa_out); errors++; end

        // body: wait coeff, feed 64 samples impulse/step
        wait(body_ready);
        for (int i=0;i<64;i++) begin
            @(negedge clk); body_in_v=1; body_in = (i==0) ? 64'sd1073741824 : 64'sd0;
            while (!body_in_ready) @(negedge clk);
            @(posedge clk);
        end
        @(negedge clk); body_in_v=0;
        for (int i=0;i<200;i++) begin
            @(posedge clk);
            if (body_out_v) body_outs++;
        end
        if (body_outs == 0) begin $display("FAIL body no output"); errors++; end
        if (body_err) begin $display("FAIL body coeff error"); errors++; end

        if (errors==0) $display("PASS tb_post_chain");
        else $display("FAIL tb_post_chain errors=%0d",errors);
        $finish;
    end
endmodule
