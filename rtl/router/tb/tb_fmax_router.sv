`timescale 1ns/1ps
module tb_fmax_router;
    logic clk = 0, rst_n = 0, led;
    always #5 clk = ~clk;
    fmax_router #(.SLOTS(16), .N_MODES(64)) dut (.clk(clk), .rst_n(rst_n), .led(led));
    int yv_cnt = 0;
    always @(posedge clk) if (dut.y_valid) yv_cnt++;
    initial begin
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (400000) @(posedge clk);
        $display("y_valid pulses=%0d  led=%0b  state=%0d ready=%0b busy=%0b",
                 yv_cnt, led, dut.u_vr.state, dut.u_vr.ready, dut.u_vr.busy);
        $finish;
    end
endmodule
