`timescale 1ns/1ps
// Reuse the independently bit-driven/decoded unit fixtures, not DUT loopback.
`include "sim/unit/comm/tb_comm_uart.sv"
`timescale 1ns/1ps
module tb_comm_uart_rates;
    wire [6:0] done_vec,fail_vec;
    uart_rx_case #(.CLK_HZ(100_000_000),.BAUD(3_000_000),.OVERSAMPLE(8),.TAG("WIRED_3M_8x"))
        a(.done(done_vec[0]),.fail(fail_vec[0]));
    uart_rx_case #(.CLK_HZ(100_000_000),.BAUD(3_000_000),.OVERSAMPLE(16),.TAG("WIRED_3M_16x"))
        b(.done(done_vec[1]),.fail(fail_vec[1]));
    uart_rx_case #(.CLK_HZ(100_000_000),.BAUD(230_400),.OVERSAMPLE(16),.TAG("BT_230400_16x"))
        c(.done(done_vec[2]),.fail(fail_vec[2]));
    uart_rx_case #(.CLK_HZ(1_600_000),.BAUD(100_000),.OVERSAMPLE(16),.TAG("NCO_TICK_EQUALS_CLK"))
        d(.done(done_vec[3]),.fail(fail_vec[3]));
    uart_tx_case #(.CLK_HZ(100_000_000),.BAUD(3_000_000),.TAG("TX_WIRED_3M"))
        e(.done(done_vec[4]),.fail(fail_vec[4]));
    uart_tx_case #(.CLK_HZ(100_000_000),.BAUD(230_400),.TAG("TX_BT_230400"))
        f(.done(done_vec[5]),.fail(fail_vec[5]));
    uart_break_window g(.done(done_vec[6]),.fail(fail_vec[6]));
    initial begin
        wait(&done_vec);
        if(|fail_vec) $fatal(1,"high-rate UART fixture failed");
        $display("PASS tb_comm_uart_rates 3M/230400, independent 8x/16x, NCO equality, continuous BREAK");
        $finish;
    end
    initial begin #100000000;$fatal(1,"UART rates watchdog");end
endmodule

module uart_break_window(output logic done=0,output logic fail=0);
    localparam int BIT_CYC=32;
    logic clk=0,rst_n=0,rx=1,stb,fe,br,fs;
    logic [7:0] data;
    integer framing_count=0,break_count=0,byte_count=0;
    always #5 clk=~clk;
    comm_uart_rx #(.CLK_HZ(3_200_000),.BAUD(100_000),.OVERSAMPLE(16)) dut (
        .clk(clk),.rst_n(rst_n),.rx_i(rx),.rx_stb(stb),.rx_data(data),
        .framing_err(fe),.break_detect(br),.false_start(fs)
    );
    always @(posedge clk) if(rst_n) begin
        if(fe) framing_count++;
        if(br) break_count++;
        if(stb) byte_count++;
    end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        repeat(4) @(negedge clk);
        // FF with an invalid stop: only two consecutive low bit-times.
        // Elapsed time since start is >10.5 bits, but that is NOT a BREAK.
        rx=0;repeat(BIT_CYC) @(negedge clk);
        rx=1;repeat(BIT_CYC*8) @(negedge clk);
        rx=0;repeat(BIT_CYC*2) @(negedge clk);
        rx=1;repeat(BIT_CYC*3) @(negedge clk);
        if(framing_count!=1||break_count!=0||byte_count!=0)
            $fatal(1,"bad-stop must not be reported as BREAK");
        rx=0;repeat(BIT_CYC*14) @(negedge clk);
        if(break_count!=1||byte_count!=0) $fatal(1,"continuous BREAK missing/duplicated");
        repeat(BIT_CYC*3) @(negedge clk);
        if(break_count!=1) $fatal(1,"held BREAK repeated");
        rx=1;repeat(BIT_CYC*3) @(negedge clk);
        done=1;$display("PASS uart_break_window");
    end
endmodule
