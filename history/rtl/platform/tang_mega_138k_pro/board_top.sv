// -----------------------------------------------------------------------------
// board_top.sv -- 围绕 top.sv 的 Gowin 综合构建包装。
//
// Gowin 综合器会按它自己的工作目录（而不是仓库根目录）来解析 $readmemh 的
// 相对路径，这导致系数/索引 ROM 静默加载失败（WARN EX3988），
// 并让引擎阵列被常量折叠掉。本包装用绝对路径覆盖 COEFF_FILE/INDEX_FILE，
// 从而不依赖工具的当前工作目录（CWD），总能找到真实的 ROM 镜像。
//
// 它只是综合/构建便利层：实例化与仿真中相同的 top.sv，
// 除 ROM 文件路径外不做任何改动。板级仿真并不使用它
// （板级仿真从仓库根目录运行并直接使用 top.sv），
// 它也不修改任何 core/audio 文件。
//
// 综合器没有命令行参数覆盖机制，因此这里的绝对路径
// 必须是字面量。若目录树移动，请同步更新本文件。
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// 顶层端口
module board_top (
    input  logic clk,
    input  logic reset,
    output logic amp_bclk,
    output logic amp_lrc,
    output logic amp_din,
    output logic amp_sd
);

    top #(
        .ENABLE_BODY(1), // 启动共鸣体建模
        .BODY_INSTRUMENT(0), // 乐器编号0，0吉他，1钢琴，2班卓琴，3曼陀林
        .COEFF_FILE("/home/rubbishbro/Desktop/FPGA_IDC_2026/rtl/rom/modal_coeff.mem"),
        .INDEX_FILE("/home/rubbishbro/Desktop/FPGA_IDC_2026/rtl/rom/modal_index.mem"),
        .BODY_FILE("/home/rubbishbro/Desktop/FPGA_IDC_2026/rtl/rom/body_coeff.mem")
    ) u_top (
        .clk     (clk),
        .reset   (reset),
        .amp_bclk(amp_bclk),
        .amp_lrc (amp_lrc),
        .amp_din (amp_din),
        .amp_sd  (amp_sd)
    );

endmodule
