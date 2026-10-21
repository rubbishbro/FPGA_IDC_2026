// -----------------------------------------------------------------------------
// tb_b_front.sv -- B 前端字段映射/编译冒烟
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_b_front;

    localparam int N = 4;
    logic clk = 0, rst_n = 0;
    logic [N*256-1:0] ctrl_vec;
    logic [N*2-1:0] class_vec;
    logic [N*16-1:0] vel_vec;
    logic [N-1:0] start_mask, gate_mask;
    logic [15:0] ratio;
    logic [N*32-1:0] x_vec;
    logic [N*24-1:0] attack_vec, release_vec;

    int errors = 0;

    b_front #(.NUM_SLOTS(N)) dut (
        .clk(clk), .rst_n(rst_n),
        .ctrl_vec(ctrl_vec), .class_vec(class_vec), .vel_vec(vel_vec),
        .start_mask(start_mask), .gate_mask(gate_mask), .ratio(ratio),
        .x_vec(x_vec), .attack_vec(attack_vec), .release_vec(release_vec)
    );

    always #5 clk = ~clk;

    initial begin
        ctrl_vec = '0; class_vec = '0; vel_vec = '0;
        start_mask = '0; gate_mask = '0; ratio = 16'h8000;

        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // voice0 control: attack=0x112233, release=0x445566, base_inc=0x00100000
        ctrl_vec[0*256 + 16 +: 24] = 24'h11_2233;
        ctrl_vec[0*256 + 40 +: 24] = 24'h44_5566;
        ctrl_vec[0*256 + 64 +: 32] = 32'h0010_0000;
        class_vec[0*2 +: 2] = 2'd1;
        vel_vec[0*16 +: 16] = 16'h8000;

        #1;
        if (attack_vec[0*24 +: 24] !== 24'h11_2233) begin
            $display("FAIL attack=%h", attack_vec[0*24 +: 24]); errors = errors + 1;
        end
        if (release_vec[0*24 +: 24] !== 24'h44_5566) begin
            $display("FAIL release=%h", release_vec[0*24 +: 24]); errors = errors + 1;
        end

        if (errors == 0) $display("PASS tb_b_front");
        else             $display("FAIL tb_b_front errors=%0d", errors);
        $finish;
    end

endmodule
