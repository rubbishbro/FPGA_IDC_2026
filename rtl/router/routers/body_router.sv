// -----------------------------------------------------------------------------
// body_router.sv -- 腔体滤波器子路由：乐器号 -> 系数常量表 -> 内嵌 body_biquad
//
// 和 env_router / exc_router 同一个套路：
//     1) case (inst) 选参数 —— 本级的"参数"就是 25 个 Q4.27 系数；
//     2) 里面封装 parts/body_biquad（对应 env_router 封装 envelope_*）；
//     3) 对外只露信号：进来一个样本，出去是滤完的样本，不再输出系数表。
// 不一样的地方：腔体是串行流水（NSEC*NTAP*3 + 3*NSEC + 3 = 93 拍/样本），
//     所以多一根 in_ready 反压。48 kHz @ 100 MHz 一个样本有 2083 拍，
//     占 4.5%，正常不会真的反压；上游把 smp_tick 接到 in_valid 即可。
//
// 系数不来自 flash、也不是 ROM：按乐器号直接选常量 LUT（综合成 LUT/寄存器）。
// 不足 NSEC 段的乐器在末尾保持直通段（b0 = 1.0，其余 0），所以默认就是直通。
// 排布：coef_q[s*NTAP + t]，s = section 0..NSEC-1，
//       t = 0..4 依次为 b0, b1, b2, a1, a2。
// 符号约定：y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2（a1/a2 给正值）。
// 定点：Q4.27（1.0 = 1 << COEFF_FRAC = 1 << 27），
//       数值 = floor(c * 2**27 + 0.5)，c 取自 sythsound/sim_guitar.py 的
//       BODY_BIQUADS；rtl/router/tools/bq_gen.py 会重算一遍并回读本文件核对
//       字面量，改系数必须两边一起改。
// -----------------------------------------------------------------------------
module body_router #(
    parameter int SLOTS      = 16,
    parameter int NSEC       = 5,
    parameter int NTAP       = 5,
    parameter int COEFF_FRAC = 27,
    parameter int GUARD_BITS = 4
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    clear_req,
    output logic                    clear_busy,
    input  router_pkg::instrument_e inst,

    // 样本输入（in_valid && in_ready 一拍握手）
    input  logic                    in_valid,
    output logic                    in_ready,
    input  logic signed [63:0]      x,

    // 滤完的样本
    output logic                    out_valid,
    output logic signed [63:0]      y
);

    // ------------------------------------------------------------------
    // 1) 参数常量表：加乐器 = 加一行
    // ------------------------------------------------------------------
    localparam logic signed [31:0] ONE = 32'sd1 <<< COEFF_FRAC;   // 1.0

    logic signed [NSEC*NTAP-1:0][31:0] coef_q;
    wire router_pkg::instrument_e body_inst=inst==router_pkg::INST_GUITAR_ABC ? router_pkg::INST_GUITAR : inst;

    always_comb begin
        // 默认：NSEC 段全直通（段数少的乐器末尾自动直通，不用额外补逻辑）
        coef_q = '0;
        for (int s = 0; s < NSEC; s++)
            coef_q[s*NTAP + 0] = ONE;

        case (body_inst)
            router_pkg::INST_GUITAR: begin
                // 5 段实测腔体（Q4.27 定点，见文件头）
                // section 0
                coef_q[ 0] = -32'sd1384742;
                coef_q[ 1] =  32'sd2643546;
                coef_q[ 2] = -32'sd1276654;
                coef_q[ 3] = -32'sd52919616;
                coef_q[ 4] =  32'sd5278273;
                // section 1
                coef_q[ 5] =  32'sd263172294;
                coef_q[ 6] = -32'sd509271216;
                coef_q[ 7] =  32'sd246390671;
                coef_q[ 8] = -32'sd198078454;
                coef_q[ 9] =  32'sd73085422;
                // section 2
                coef_q[10] =  32'sd270135281;
                coef_q[11] = -32'sd262206539;
                coef_q[12] =  32'sd63779949;
                coef_q[13] = -32'sd259408516;
                coef_q[14] =  32'sd125642630;
                // section 3
                coef_q[15] =  32'sd263886234;
                coef_q[16] = -32'sd69071998;
                coef_q[17] =  32'sd4530693;
                coef_q[18] = -32'sd259427865;
                coef_q[19] =  32'sd125661046;
                // section 4
                coef_q[20] = -32'sd483728579;
                coef_q[21] =  32'sd931755490;
                coef_q[22] = -32'sd452836863;
                coef_q[23] = -32'sd223863730;
                coef_q[24] =  32'sd94210040;
            end
            router_pkg::INST_PIANO:begin
                coef_q[ 0]=32'sd603840;coef_q[ 1]=32'sd76002;coef_q[ 2]=-32'sd715860;
                coef_q[ 3]=-32'sd247369736;coef_q[ 4]=32'sd123858118;
                coef_q[ 5]=-32'sd436574912;coef_q[ 6]=32'sd81584862;coef_q[ 7]=32'sd409619507;
                coef_q[ 8]=-32'sd27521759;coef_q[ 9]=-32'sd94371634;
                coef_q[10]=32'sd299364184;coef_q[11]=-32'sd493793142;coef_q[12]=32'sd221367920;
                coef_q[13]=-32'sd255674090;coef_q[14]=32'sd122404426;
            end
            router_pkg::INST_PIANO_ABC: begin
                // Selected ENG1 piano: 40Hz highpass + 2kHz/+3dB shelf.
                // Exact audition Q4.27 constants; sections 2..4 passthrough.
                // section 0
                coef_q[ 0] =  32'sd133721719;
                coef_q[ 1] = -32'sd267443437;
                coef_q[ 2] =  32'sd133721719;
                coef_q[ 3] = -32'sd267441604;
                coef_q[ 4] =  32'sd133227543;
                // section 1
                coef_q[ 5] =  32'sd183667245;
                coef_q[ 6] = -32'sd305371893;
                coef_q[ 7] =  32'sd130743169;
                coef_q[ 8] = -32'sd214866875;
                coef_q[ 9] =  32'sd89687668;
            end
            default: ;                    // 全直通
        endcase
    end

    // ------------------------------------------------------------------
    // 清历史：换乐器，或调用方排空样本后的 clear_req 维护请求
    //   起音不清：腔体是所有声部共用的，起音就清会把上一音的腔体尾音切掉。
    //   clear 再打一拍才送进 biquad：inst 比较 -> clear -> 状态写 mux，
    //   寄存之后两边各只剩一级。
    // ------------------------------------------------------------------
    router_pkg::instrument_e inst_q;
    logic                    clear_c, clear;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inst_q <= router_pkg::INST_NONE;
            clear  <= 1'b0;
        end else begin
            inst_q <= inst;
            clear  <= clear_c;
        end
    end

    assign clear_c = (inst != inst_q);
    logic core_ready;
    // A request is accepted only after the caller has drained its samples.
    // Keep completion low until the core has physically zeroed its history RAM.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) clear_busy <= 1'b1;
        else if (clear_req || clear || clear_c) clear_busy <= 1'b1;
        else if (core_ready) clear_busy <= 1'b0;
    end
    assign in_ready = core_ready && !clear_busy;

    // ------------------------------------------------------------------
    // 2) 内嵌 parts/body_biquad
    // ------------------------------------------------------------------
    logic [NSEC-1:0] body_sat;        // 诊断口，本级不对外
    logic [2:0]      body_sat_cnt;

    body_biquad #(
        .NSEC(NSEC), .NTAP(NTAP),
        .COEFF_FRAC(COEFF_FRAC), .GUARD_BITS(GUARD_BITS)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .clear(clear || clear_req),
        .in_valid(in_valid && !clear_busy), .in_ready(core_ready), .in_sum(x),
        .coef_q(coef_q),
        .out_valid(out_valid), .out_sum(y),
        .out_sat(body_sat), .sat_count(body_sat_cnt)
    );

endmodule
