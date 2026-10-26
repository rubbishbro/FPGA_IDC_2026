`timescale 1ns/1ps
// 设备层边界：FIFO 背压/溢出、维护 flush、STATE 不自行清数据、无 STATE 为未知。
// UART 输入与 TX 解码均使用独立 bit BFM，不访问驱动内部实现。
module tb_comm_drivers;
    logic clk = 0, rst_n = 0, rx_i = 1, state_async = 0;
    always #5 clk = ~clk;
    logic [2:0] capture = 3'b111, flush = 0, rv, rr = 0, tv = 0, tr, tx, busy;
    logic [23:0] rd;
    logic [5:0] level;
    logic [2:0] fe, brk, fs, ov;
    logic [1:0] known, up, connected, disconnected, init_done;
    integer overflow_count [0:2];
    integer connect_count [0:1];
    integer disconnect_count [0:1];

    uart_driver #(.CLK_HZ(3200000), .BAUD(100000), .OVERSAMPLE(16), .RX_DEPTH(3)) wired (
        .clk(clk), .rst_n(rst_n), .rx_i(rx_i), .tx_o(tx[0]),
        .capture_enable(capture[0]), .flush_rx(flush[0]),
        .rx_valid(rv[0]), .rx_ready(rr[0]), .rx_data(rd[7:0]), .rx_level(level[1:0]),
        .tx_valid(tv[0]), .tx_ready(tr[0]), .tx_data(8'hA5), .tx_busy(busy[0]),
        .framing_err(fe[0]), .break_detect(brk[0]), .false_start(fs[0]), .overflow(ov[0])
    );
    for (genvar g = 0; g < 2; g++) begin : g_bt
        hc05_driver #(.CLK_HZ(3200000), .BAUD(100000), .OVERSAMPLE(16),
            .RX_DEPTH(3), .HAS_STATE(g == 0), .DEBOUNCE_CYCLES(8)) bt (
            .clk(clk), .rst_n(rst_n), .rx_i(rx_i), .tx_o(tx[g+1]), .state_async(state_async),
            .capture_enable(capture[g+1]), .flush_rx(flush[g+1]),
            .rx_valid(rv[g+1]), .rx_ready(rr[g+1]), .rx_data(rd[(g+1)*8 +: 8]),
            .rx_level(level[(g+1)*2 +: 2]),
            .tx_valid(tv[g+1]), .tx_ready(tr[g+1]), .tx_data(8'hA5), .tx_busy(busy[g+1]),
            .framing_err(fe[g+1]), .break_detect(brk[g+1]), .false_start(fs[g+1]), .overflow(ov[g+1]),
            .link_state_known(known[g]), .link_up(up[g]), .connect_event(connected[g]),
            .disconnect_event(disconnected[g]), .init_done(init_done[g])
        );
    end
    always @(posedge clk) if (rst_n) begin
        for (int i = 0; i < 3; i++) if (ov[i]) overflow_count[i]++;
        for (int i = 0; i < 2; i++) begin
            if (connected[i]) connect_count[i]++;
            if (disconnected[i]) disconnect_count[i]++;
        end
        if (|fe || |brk || |fs) $fatal(1, "unexpected physical error");
    end
    task automatic clocks(input int n);
        repeat(n) @(negedge clk);
    endtask
    task automatic send_byte(input logic [7:0] data);
        @(negedge clk); rx_i = 0; clocks(32);
        for (int b=0; b<8; b++) begin rx_i=data[b]; clocks(32); end
        rx_i=1; clocks(40);
    endtask
    task automatic pop_byte(input logic [7:0] expected);
        wait (&rv);
        @(negedge clk);
        for (int i=0; i<3; i++)
            if (rd[i*8 +: 8] !== expected) $fatal(1, "driver %0d byte mismatch", i);
        rr=3'b111;
        @(negedge clk); rr=0;
    endtask
    initial begin
        for(int i=0;i<3;i++) overflow_count[i]=0;
        for(int i=0;i<2;i++) begin connect_count[i]=0; disconnect_count[i]=0; end
        clocks(5);
        if (init_done !== 0) $fatal(1,"init asserted in reset");
        rst_n=1; state_async=1; clocks(30);
        if (known !== 2'b01 || up !== 2'b01 || init_done !== 2'b11)
            $fatal(1,"known/unknown link state contract");

        send_byte(8'h11); send_byte(8'h22); send_byte(8'h33); send_byte(8'h44);
        for (int i=0;i<3;i++)
            if (overflow_count[i]!=1 || level[i*2 +: 2]!=3)
                $fatal(1,"driver %0d overflow/occupancy mismatch",i);
        state_async=0; clocks(30);
        if (up !== 0 || connect_count[0]!=1 || disconnect_count[0]!=1 ||
            connect_count[1]!=0 || disconnect_count[1]!=0)
            $fatal(1,"STATE event contract");
        // 断开事件只上报，不私自清 FIFO 或门控字节。
        repeat(40) begin
            clocks(1);
            if (rv !== 3'b111 || rd !== 24'h111111) $fatal(1,"stalled RX changed on disconnect");
        end
        pop_byte(8'h11); pop_byte(8'h22); pop_byte(8'h33); clocks(10);
        send_byte(8'h55);
        flush=3'b111; clocks(1); flush=0; clocks(5);
        if (|rv || level!=0) $fatal(1,"RX flush failed");
        capture=0; send_byte(8'h66);
        if (|rv || level!=0) $fatal(1,"capture disable failed");
        capture=3'b111; send_byte(8'h77); pop_byte(8'h77);

        // RX flush 不截断已经被 UART TX 接受的字节。
        fork
            begin
                @(negedge clk); tv=3'b111;
                wait (&busy); @(negedge clk); tv=0;
                clocks(90); flush=3'b111; clocks(1); flush=0;
            end
            begin : tx_decode
                logic [7:0] got [0:2];
                @(negedge tx[0]);
                repeat(48) @(posedge clk);
                for(int b=0;b<8;b++) begin
                    #1;
                    for(int i=0;i<3;i++) got[i][b]=tx[i];
                    repeat(32) @(posedge clk);
                end
                #1;
                for(int i=0;i<3;i++)
                    if(got[i]!==8'hA5 || !tx[i]) $fatal(1,"TX cancelled/corrupt driver %0d",i);
            end
        join
        clocks(40);
        if (busy!=0 || tr!==3'b111) $fatal(1,"TX failed to retire");
        $display("PASS tb_comm_drivers"); $finish;
    end
    initial begin #200000; $fatal(1,"driver watchdog"); end
endmodule
