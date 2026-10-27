// -----------------------------------------------------------------------------
// voice_router.sv -- 声部路由器（第一版结构骨架）
//
//   职责：
//     1. 持有全部存储（系数 / 状态 / 激励 / 结果）
//     2. 按乐器号把存储口 mux 到两套互斥的引擎之一（modal_engine7 / eng_alt）
//     3. 调度：采样 x 声部，每个（采样, 声部）一个作业
//     4. 激励来自 exc_router（整张 fmap -> 整张 xmap），**一次作业只跑一个采样**，
//        所以 xmap 直接整张寄存一拍当快照（不再有 x_ram / 采样深度）
//     5. 换乐器 = 停机 -> weight_loader 重灌系数表 -> 再跑
//
//   后级（在本文件末尾，顺序固定）：
//     6. 逐声部过自己的包络 -> 全部声部按采样加和 -> **统一过一遍腔体**
//        （body_router，乐器号选系数）-> 混响（reverb_router）-> y_data 输出
//     7. 混响（reverb_router）：预设由上层输入 reverb_preset 选，NONE 时是逐位直通
//        （只是多 6 拍延迟），HALL/BATHROOM 才真的加湿声
//
//   加载是**阻塞**的（S_LOAD 等 ld_done）：这段时间 input_hold=1，fmap 冻结、
//   note 事件不产生，也不出任何 y_valid —— 上层看到的就是"静音 + not ready"。
//   这是有意的设计选择（最省逻辑，代价是换乐器头 1~2 ms 没声音），不是遗漏；
//   要边放边载得改成双缓冲，以后再说。加载出错的处理仍然待定（loader 有 err 输出）。
// -----------------------------------------------------------------------------

`timescale 1ns/1ps

module voice_router #(
    // 声部数。硬件只有 16 个按键（fmap 是 mat4x4），所以 SLOTS 只能 <= 16，
    // 且只用 fmap 的前 SLOTS 个键；地址是 {slot, mode} 纯拼接，所以必须 2 的幂；
    // 还要拆两个 bank（HS = SLOTS/2 >= 2），所以实际可用 4 / 8 / 16。
    parameter int   SLOTS      = 16,
    parameter int   N_MODES    = 64,          // 唯一的模态数：系数表/状态/激励/参数表都按它开
    parameter int   CLK_HZ     = 100_000_000,
    parameter int   SR_HZ      = 48_000,
    parameter logic DEBUG_PORT = 1'b1
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    // ---- 上游 ----
    input  pad_driver_pkg::mat4x4                    fmap,
    input  router_pkg::instrument_e                   inst,
    input  router_pkg::reverb_preset                  reverb_preset,  // 混响预设（NONE/HALL/BATHROOM）
    input  logic                                     reload,      // 强制重灌当前乐器（内部取上升沿）
    input  logic                                     start,
    // 每个乐器用多少模态在内部按 inst 查 router_pkg::n_modes_of()，不再是端口
    // ---- 作业流控 ----
    output logic                                      done,        // **电平**：1 = 空闲、可以 start；0 = 正在工作
    // ---- 配置流控 ----
    output logic                                      ready,       // 1 = 现在会执行挂起的 inst/reload 变更
                                                                    //   （没有挂起变更时恒 1；有变更且还有键按着时为 0）
    // ---- 状态给上层（UI 用；router 自己不处理）----
    output logic                                      load_err,    // 1 = 本乐器的表是坏的（RAM 已被填 0）

    // ---- 输出（每采样一个）----
    output logic                                      y_valid,
    output logic signed [63:0]                        y_data,

    // ---- QSPI flash ----
    output logic                                      qspi_cs_n,
    output logic                                      qspi_sck,
    output logic [3:0]                                qspi_dq_o,
    output logic                                      qspi_dq_oe,
    input  logic [3:0]                                qspi_dq_i,

    // ---- 调试 ----
    input  logic                                      ns_rd_en,
    input  logic [CO_SLOT-1:0]                        ns_rd_addr,
    input  logic                                      ns_rd_sel,
    output logic signed [31:0]                        ns_rd_data,
    output logic                                      ns_rd_valid
);

    import modal_step_pkg::*;
    import router_pkg::*;

    // fmap 先寄存一拍再分发给三个部件：它扇出很大（激励/包络/note_on 比较），
    // 直接从端口进组合逻辑会把路径拉长；加载系数期间冻结（忽略外部输入）
    pad_driver_pkg::mat4x4 fmap_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)           fmap_q <= '0;
        else if (!input_hold) fmap_q <= fmap;
    end

    localparam int IW     = $clog2(N_MODES);
    localparam int VWID   = $clog2(SLOTS);
    // 每声部的模态槽数**补齐到 2 的幂**：地址就退化成 {slot, mode} 的纯拼接（移位），
    // 地址路径上不放乘法器。N_MODES=64 时 NMP 就是 64，和原来完全一样；
    // N_MODES=48 时补齐成 64（RAM 多 33%，但地址不再错位）。
    localparam int NMP    = 1 << IW;
    localparam int CO_SLOT = VWID + IW;
    // 引擎读的阵列拆成两个 bank（每个引擎一个）：两个引擎同拍读不同地址时，
    // 一块 BSRAM 只有两个端口（1R1W），2R1W 是三个口 —— 不拆就只能退化成寄存器阵列。
    // 每 bank HS 个声部 x NMP 个模态 = 512 字，正好一块 512x36 的 BSRAM（块数不变）。
    localparam int HS      = SLOTS / 2;            // 每个 bank 的声部数
    localparam int HVW     = $clog2(HS);           // bank 内声部号位宽
    localparam int BA      = HVW + IW;             // bank 内地址 = {bank内声部, 模态}

    // =========================================================================
    // 存储（与 modal_voice_top 相同的布局；两个引擎互斥，所以只有一套）
    // =========================================================================
    // 引擎读的 9 个阵列按声部拆成 A（声部 0..HS-1）/ B（HS..SLOTS-1）两个 bank
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22_a [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram_a  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram_a  [0:HS*NMP-1];

    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a11_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a12_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a21_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_a22_b [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gq_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_gv_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [CW-1:0] ca_wo_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [QW-1:0] q_ram_b  [0:HS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [VW-1:0] v_ram_b  [0:HS*NMP-1];

    // 调制参数表（引擎不读；加载器写，调制器读）
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_c0 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_s0 [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_gam[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_th [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_g  [0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_k12[0:SLOTS*NMP-1];
    (* syn_ramstyle = "block_ram" *) logic signed [31:0] pm_k21[0:SLOTS*NMP-1];

    // 激励快照：一次作业只有一个采样，所以就是 SLOTS 个寄存器（不再有按采样索引的 RAM）
    logic signed [XW-1:0] x_q [0:SLOTS-1];

    // 早期声明（parts 的选择逻辑要用）
    router_pkg::instrument_e inst_lat;

    logic [IW:0]             nm_lat;


    // =========================================================================
    // 统一采样节拍：所有 part 共用，避免各自分频漂移
    // =========================================================================
    logic                      smp_tick;
    logic [$clog2(CLK_HZ/SR_HZ+1)-1:0] tick_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= '0;
            smp_tick <= 1'b0;
        end else begin
            smp_tick <= 1'b0;
            if (tick_cnt + 1 >= CLK_HZ/SR_HZ) begin
                tick_cnt <= '0;
                smp_tick <= 1'b1;
            end else tick_cnt <= tick_cnt + 1'b1;
        end
    end

    // =========================================================================
    // 三个部件子路由（各自按乐器号选实例，主 router 只连总线）
    // =========================================================================
    logic signed [SLOTS-1:0][31:0] xmap;   // 打包：xmap[i] 是第 i 个声部的激励
    logic                     xmap_valid;
    logic signed [SLOTS-1:0][31:0] emap;   // 打包：emap[i] 是第 i 个声部的包络
    logic                     emap_valid;
    logic [SLOTS-1:0]         env_dead;  // 包络说

    // ---- 音符事件：由 fmap 双阈值在 router 里统一生成 ----
    //   note_on 就是**滞回判定后的门控电平**：这个键现在按着就是 1。
    //     * 只看当前 fmap + 上一次的门控状态（gate_r 做滞回），不取沿、不粘住；
    //     * 按下要 > NOTE_ON_TH，松开要掉到 < NOTE_OFF_TH 才算松；
    //     * 谁要"起音事件"谁自己取沿：激励/包络内部各有一个 prev 寄存器，
    //       router 自己需要的那份在下面取成 note_ev。
    //   note_gate 与 note_on 是同一个电平（保留旧端口名，部件那边还在用）。
    //   加载系数期间 fmap_q 冻结，这个电平也就跟着冻住——等于忽略外部输入，
    //   装完之后按当前键态重新判：装的过程中按下的键照样能起音。
    localparam logic [7:0] NOTE_ON_TH  = 8'd230;
    localparam logic [7:0] NOTE_OFF_TH = 8'd26;

    logic [SLOTS-1:0] gate_r, note_gate, note_on;
    logic [SLOTS-1:0] note_on_q, note_ev;      // router 内部的起音沿
    logic [SLOTS-1:0] note_pend, note_f;       // 攒到帧头的那份（给引擎/调制器）
    logic             input_hold;              // 1 = 忽略外部输入（驱动见调度器上方）

    // 滞回判定直接决定 note_on。判完打一拍再出去：fmap_q 是 128 位、扇出很大，
    // "16 个比较 -> note_on -> note_ev" 挤在一拍 PnR 实测 11.6 ns；下游（激励/
    // 包络/腔体）本来就只在 smp_tick 看它，晚一拍完全无所谓。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_on <= '0;
        end else begin
            for (int i = 0; i < SLOTS; i++)
                note_on[i] <= gate_r[i] ? (fmap_q.flat_d[i].val >= NOTE_OFF_TH)
                                        : (fmap_q.flat_d[i].val >  NOTE_ON_TH);
        end
    end

    assign note_gate = note_on;                // 同一个电平，只是换了名字

    // 滞回用的上一次门控状态
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)        gate_r <= '0;
        else if (smp_tick) gate_r <= note_on;
    end

    exc_router #(.SLOTS(SLOTS), .CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_exc (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap_q),
        .note_on(note_on), .inst(inst_lat),
        .xmap(xmap), .xmap_valid(xmap_valid)
    );

    env_router #(.SLOTS(SLOTS), .CLK_HZ(CLK_HZ), .SR_HZ(SR_HZ)) u_env (
        .clk(clk), .rst_n(rst_n), .smp_tick(smp_tick), .fmap(fmap_q),
        .note_on(note_on), .note_gate(note_gate), .inst(inst_lat),
        .emap(emap), .emap_valid(emap_valid), .dead(env_dead)
    );

    logic                    mod_busy, mod_done, mod_start, mod_p_re;
    logic [VWID-1:0]         mod_slot;
    // 后台调制请求位图：起音的声部在这里置位，调制器空闲时按最低位服务，做完清那一位。
    //   这样谁请求都不会丢（幂等的调制器重复跑也无害），而且**不挡引擎**。
    logic [SLOTS-1:0]        mod_req;

    function automatic logic [VWID-1:0] first_req(input logic [SLOTS-1:0] r);
        first_req = '0;
        for (int i = SLOTS-1; i >= 0; i--) if (r[i]) first_req = VWID'(i);
    endfunction
    logic [IW-1:0]           mod_p_mode, mod_co_mode;
    logic [3:0]              mod_co_we;
    coeff_t                  mod_co_wdata;
    logic signed [31:0]      mod_c0_r, mod_s0_r, mod_gam_r, mod_theta0_r, mod_g_r;
    logic signed [31:0]      mod_k12_r, mod_k21_r;
    logic signed [31:0]      mod_c0, mod_s0, mod_gam, mod_theta0, mod_g;

    assign mod_c0     = mod_c0_r;
    assign mod_s0     = mod_s0_r;
    assign mod_gam    = mod_gam_r;
    assign mod_theta0 = mod_theta0_r;
    assign mod_g      = mod_g_r;

    mod_router #(.SLOTS(SLOTS), .N_MODES(N_MODES)) u_modr (
        .clk(clk), .rst_n(rst_n), .start(mod_start),
        .fmap_i(fmap_q.flat_d[mod_slot].val), .n_modes(16'(nm_lat)),
        .inst(inst_lat), .busy(mod_busy), .done(mod_done),
        .p_re(mod_p_re), .p_mode(mod_p_mode),
        .p_c0(mod_c0), .p_s0(mod_s0), .p_gam(mod_gam),
        .p_theta0(mod_theta0), .p_g(mod_g),
        .p_k12(mod_k12_r), .p_k21(mod_k21_r),
        .co_we(mod_co_we), .co_mode(mod_co_mode), .co_wdata(mod_co_wdata)
    );

    // =========================================================================
    // 系数加载
    // =========================================================================
    logic                           ld_start, ld_busy, ld_done, ld_err;
    logic                           ld_we;
    logic [CO_SLOT:0]               ld_addr;          // 最高位选表：0=系数 1=调制参数（低位 {slot, mode}）
    coeff_t                         ld_co_data;
    router_pkg::mod_par_t           ld_pm_data;
    logic                           ld_co_we, ld_pm_we;
    logic [CO_SLOT-1:0]             ld_idx;

    // 一个写使能 + 地址高位选表
    logic                           ld_sel_pm;
    assign ld_sel_pm = ld_addr[CO_SLOT];
    assign ld_idx    = ld_addr[CO_SLOT-1:0];
    assign ld_co_we  = ld_we & ~ld_sel_pm;
    assign ld_pm_we  = ld_we &  ld_sel_pm;

    weight_loader #(.SLOTS(SLOTS), .N_MODES(N_MODES)) u_ld (
        .clk(clk), .rst_n(rst_n), .inst(4'(inst)),
        .start(ld_start), .busy(ld_busy), .done(ld_done), .err(ld_err),
        .ld_we(ld_we), .ld_addr(ld_addr), .ld_co(ld_co_data), .ld_pm(ld_pm_data),
        .qspi_cs_n(qspi_cs_n), .qspi_sck(qspi_sck),
        .qspi_dq_o(qspi_dq_o), .qspi_dq_oe(qspi_dq_oe), .qspi_dq_i(qspi_dq_i)
    );

    // =========================================================================
    // 两个引擎（各管 HS 个声部，并行跑）+ 各自的存储 bank
    //   * 两个实例的 inst 接同一个乐器号 -> 同一种引擎，时序完全一致
    //   * 每个实例只碰自己 bank 的读口；写口由 loader/调制器按声部号 demux
    // =========================================================================
    logic                    eng_start;                 // 两个引擎同时起
    logic [VWID-1:0]         g;                         // 本组第几个（bank 内声部号）
    logic                    pick_b;                    // 0 = 正在处理 A 声部, 1 = B 声部

    // ---- bank A ----
    logic                 era_co_re, era_st_re, era_st_we, era_x_re, era_yv;
    logic [IW-1:0]        era_co_addr, era_st_addr, era_st_waddr;
    logic [0:0]           era_x_addr;
    logic signed [63:0]   era_y;
    logic signed [QW-1:0] era_qwd;
    logic signed [VW-1:0] era_vwd;

    // ---- bank B ----
    logic                 erb_co_re, erb_st_re, erb_st_we, erb_x_re, erb_yv;
    logic [IW-1:0]        erb_co_addr, erb_st_addr, erb_st_waddr;
    logic [0:0]           erb_x_addr;
    logic signed [63:0]   erb_y;
    logic signed [QW-1:0] erb_qwd;
    logic signed [VW-1:0] erb_vwd;

    logic signed [CW-1:0] co_a11_ra, co_a12_ra, co_a21_ra, co_a22_ra, co_gq_ra, co_gv_ra, co_wo_ra;
    logic signed [CW-1:0] co_a11_rb, co_a12_rb, co_a21_rb, co_a22_rb, co_gq_rb, co_gv_rb, co_wo_rb;
    coeff_t               co_ra, co_rb;
    logic signed [QW-1:0] st_q_ra, st_q_rb;
    logic signed [VW-1:0] st_v_ra, st_v_rb;
    logic signed [XW-1:0] x_ra, x_rb;

    // 清零：只看本组这两个声部有没有"刚起音/刚空了"
    logic [CO_SLOT-1:0]   pm_idx;      // 调制参数读地址 = {slot, mode}（不拆 bank）
    logic                 era_zero, erb_zero;
    assign era_zero = note_f[g[VWID-1:0]]              | dead_f[g[VWID-1:0]];
    assign erb_zero = note_f[VWID'(g + VWID'(HS))]      | dead_f[VWID'(g + VWID'(HS))];

    always_comb begin
        co_ra.a11 = co_a11_ra; co_ra.a12 = co_a12_ra; co_ra.a21 = co_a21_ra;
        co_ra.a22 = co_a22_ra; co_ra.gq  = co_gq_ra;  co_ra.gv  = co_gv_ra;
        co_ra.wo  = co_wo_ra;
        co_rb.a11 = co_a11_rb; co_rb.a12 = co_a12_rb; co_rb.a21 = co_a21_rb;
        co_rb.a22 = co_a22_rb; co_rb.gq  = co_gq_rb;  co_rb.gv  = co_gv_rb;
        co_rb.wo  = co_wo_rb;
    end

    eng_router #(.N_MODES(N_MODES)) u_era (
        .clk(clk), .rst_n(rst_n), .inst(inst_lat),
        .start(eng_start), .st_zero(era_zero), .n_modes(nm_lat),
        .co_re(era_co_re), .co_addr(era_co_addr), .co_data(co_ra),
        .st_re(era_st_re), .st_addr(era_st_addr),
        .st_q(st_q_ra), .st_qdot(st_v_ra),
        .st_we(era_st_we), .st_waddr(era_st_waddr),
        .st_q_wdata(era_qwd), .st_qdot_wdata(era_vwd),
        .x_re(era_x_re), .x_addr(era_x_addr), .x_data(x_ra),
        .y_valid(era_yv), .y_data(era_y)
    );

    eng_router #(.N_MODES(N_MODES)) u_erb (
        .clk(clk), .rst_n(rst_n), .inst(inst_lat),
        .start(eng_start), .st_zero(erb_zero), .n_modes(nm_lat),
        .co_re(erb_co_re), .co_addr(erb_co_addr), .co_data(co_rb),
        .st_re(erb_st_re), .st_addr(erb_st_addr),
        .st_q(st_q_rb), .st_qdot(st_v_rb),
        .st_we(erb_st_we), .st_waddr(erb_st_waddr),
        .st_q_wdata(erb_qwd), .st_qdot_wdata(erb_vwd),
        .x_re(erb_x_re), .x_addr(erb_x_addr), .x_data(x_rb),
        .y_valid(erb_yv), .y_data(erb_y)
    );
    // =========================================================================
    // 存储的读写：两个 bank 各一套读寄存器；写口按声部号 demux
    //   bank 内地址 = {bank 内声部号, 模态偏移}
    //   声部号最高位选 bank：0 -> A（声部 0..HS-1），1 -> B（HS..SLOTS-1）
    //   一次作业固定跑 HS 组，每组 A 的 g + B 的 g+HS（全部 SLOTS 个声部）
    // =========================================================================
    logic                 ld_bank_b, mod_bank_b;
    logic [BA-1:0]        ld_bank_addr, mod_bank_addr;
    logic [VWID:0]        ns_bank;

    assign ld_bank_b    = ld_idx[CO_SLOT-1];
    assign ld_bank_addr = ld_idx[BA-1:0];
    assign mod_bank_b   = mod_slot[VWID-1];
    assign mod_bank_addr= {mod_slot[HVW-1:0], mod_co_mode};
    assign pm_idx       = {mod_slot, mod_p_mode};      // 参数表不拆 bank：{slot, mode}

    // 激励快照：整张 xmap 一拍抄进 x_q（一次作业一个采样，不需要按采样索引）
    logic                     xw_run;

    logic [31:0]            ns_r;
    logic                   ns_vld;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            co_a11_ra <= '0; co_a12_ra <= '0; co_a21_ra <= '0; co_a22_ra <= '0;
            co_a11_rb <= '0; co_a12_rb <= '0; co_a21_rb <= '0; co_a22_rb <= '0;
            co_gq_ra  <= '0; co_gv_ra  <= '0; co_wo_ra  <= '0;
            co_gq_rb  <= '0; co_gv_rb  <= '0; co_wo_rb  <= '0;
            mod_c0_r <= '0; mod_s0_r <= '0; mod_gam_r <= '0; mod_theta0_r <= '0; mod_g_r <= '0;
            mod_k12_r <= '0; mod_k21_r <= '0;
            st_q_ra  <= '0; st_v_ra  <= '0; st_q_rb <= '0; st_v_rb <= '0;
            x_ra     <= '0; x_rb     <= '0;
            ns_r     <= '0; ns_vld   <= 1'b0;
        end else begin
            // 引擎占用状态口时 debug 读根本没执行，valid 不能报
            ns_vld <= ns_rd_en & DEBUG_PORT & ~(era_st_re | erb_st_re);

            // ---- 系数写（loader 优先，其次后台调制）----
            if (ld_co_we) begin
                if (ld_bank_b) begin
                    ca_a11_b[ld_bank_addr] <= ld_co_data.a11;
                    ca_a12_b[ld_bank_addr] <= ld_co_data.a12;
                    ca_a21_b[ld_bank_addr] <= ld_co_data.a21;
                    ca_a22_b[ld_bank_addr] <= ld_co_data.a22;
                    ca_gq_b [ld_bank_addr] <= ld_co_data.gq;
                    ca_gv_b [ld_bank_addr] <= ld_co_data.gv;
                    ca_wo_b [ld_bank_addr] <= ld_co_data.wo;
                end else begin
                    ca_a11_a[ld_bank_addr] <= ld_co_data.a11;
                    ca_a12_a[ld_bank_addr] <= ld_co_data.a12;
                    ca_a21_a[ld_bank_addr] <= ld_co_data.a21;
                    ca_a22_a[ld_bank_addr] <= ld_co_data.a22;
                    ca_gq_a [ld_bank_addr] <= ld_co_data.gq;
                    ca_gv_a [ld_bank_addr] <= ld_co_data.gv;
                    ca_wo_a [ld_bank_addr] <= ld_co_data.wo;
                end
            // 加载期间调制器的写一律丢弃：loader 的优先级只保证“同一拍”；
            // 已经起跑的调制如果在 loader 写完之后才写同一个地址，会把新表改坏。
            // 新表本来就会覆盖全部系数，丢掉这几笔没有副作用。
            end else if ((|mod_co_we) && !ld_busy && !ld_start) begin
                if (mod_bank_b) begin
                    if (mod_co_we[0]) ca_a11_b[mod_bank_addr] <= mod_co_wdata.a11;
                    if (mod_co_we[1]) ca_a12_b[mod_bank_addr] <= mod_co_wdata.a12;
                    if (mod_co_we[2]) ca_a21_b[mod_bank_addr] <= mod_co_wdata.a21;
                    if (mod_co_we[3]) ca_a22_b[mod_bank_addr] <= mod_co_wdata.a22;
                end else begin
                    if (mod_co_we[0]) ca_a11_a[mod_bank_addr] <= mod_co_wdata.a11;
                    if (mod_co_we[1]) ca_a12_a[mod_bank_addr] <= mod_co_wdata.a12;
                    if (mod_co_we[2]) ca_a21_a[mod_bank_addr] <= mod_co_wdata.a21;
                    if (mod_co_we[3]) ca_a22_a[mod_bank_addr] <= mod_co_wdata.a22;
                end
            end

            // ---- 调制参数表：loader 写，调制器读（不拆 bank）----
            if (ld_pm_we) begin
                pm_c0 [ld_idx] <= ld_pm_data.c0;
                pm_s0 [ld_idx] <= ld_pm_data.s0;
                pm_gam[ld_idx] <= ld_pm_data.gam;
                pm_th [ld_idx] <= ld_pm_data.theta0;
                pm_g  [ld_idx] <= ld_pm_data.g;
                pm_k12[ld_idx] <= ld_pm_data.k12;
                pm_k21[ld_idx] <= ld_pm_data.k21;
            end
            if (mod_p_re) begin
                mod_c0_r     <= pm_c0 [pm_idx];
                mod_s0_r     <= pm_s0 [pm_idx];
                mod_gam_r    <= pm_gam[pm_idx];
                mod_theta0_r <= pm_th [pm_idx];
                mod_g_r      <= pm_g  [pm_idx];
                mod_k12_r    <= pm_k12[pm_idx];
                mod_k21_r    <= pm_k21[pm_idx];
            end

            // ---- 系数读：A/B 两个 bank 各一个同步读口 ----
            if (era_co_re) begin
                co_a11_ra <= ca_a11_a[{g[HVW-1:0], era_co_addr}];
                co_a12_ra <= ca_a12_a[{g[HVW-1:0], era_co_addr}];
                co_a21_ra <= ca_a21_a[{g[HVW-1:0], era_co_addr}];
                co_a22_ra <= ca_a22_a[{g[HVW-1:0], era_co_addr}];
                co_gq_ra  <= ca_gq_a [{g[HVW-1:0], era_co_addr}];
                co_gv_ra  <= ca_gv_a [{g[HVW-1:0], era_co_addr}];
                co_wo_ra  <= ca_wo_a [{g[HVW-1:0], era_co_addr}];
            end
            if (erb_co_re) begin
                co_a11_rb <= ca_a11_b[{g[HVW-1:0], erb_co_addr}];
                co_a12_rb <= ca_a12_b[{g[HVW-1:0], erb_co_addr}];
                co_a21_rb <= ca_a21_b[{g[HVW-1:0], erb_co_addr}];
                co_a22_rb <= ca_a22_b[{g[HVW-1:0], erb_co_addr}];
                co_gq_rb  <= ca_gq_b [{g[HVW-1:0], erb_co_addr}];
                co_gv_rb  <= ca_gv_b [{g[HVW-1:0], erb_co_addr}];
                co_wo_rb  <= ca_wo_b [{g[HVW-1:0], erb_co_addr}];
            end

            // ---- 激励（是寄存器，不是 RAM）----
            if (xw_run) for (int i = 0; i < SLOTS; i++) x_q[i] <= xmap[i];
            if (era_x_re) x_ra <= x_q[g[VWID-1:0]];
            if (erb_x_re) x_rb <= x_q[VWID'(g[VWID-1:0] + VWID'(HS))];

            // ---- 状态读（引擎独占；debug 读串行插在空拍里）----
            if (era_st_re) begin
                st_q_ra <= q_ram_a[{g[HVW-1:0], era_st_addr}];
                st_v_ra <= v_ram_a[{g[HVW-1:0], era_st_addr}];
            end
            if (erb_st_re) begin
                st_q_rb <= q_ram_b[{g[HVW-1:0], erb_st_addr}];
                st_v_rb <= v_ram_b[{g[HVW-1:0], erb_st_addr}];
            end
            // debug 口：不再单独读 RAM —— 多一个读口会让 q/v 推断不出 BSRAM
            //   （实测 REG 5.5k -> 72k，PnR 卡在 placement 半小时以上）。
            //   改成吐出"最近一次引擎读到的状态字"，调试够用。
            if (ns_rd_en && DEBUG_PORT) ns_r <= ns_rd_sel ? 32'(st_v_ra) : 32'(st_q_ra);

            // ---- 状态写回 ----
            if (era_st_we) begin
                q_ram_a[{g[HVW-1:0], era_st_waddr}] <= era_qwd;
                v_ram_a[{g[HVW-1:0], era_st_waddr}] <= era_vwd;
            end
            if (erb_st_we) begin
                q_ram_b[{g[HVW-1:0], erb_st_waddr}] <= erb_qwd;
                v_ram_b[{g[HVW-1:0], erb_st_waddr}] <= erb_vwd;
            end
        end
    end

    assign ns_rd_data  = DEBUG_PORT ? 32'(ns_r) : 32'sd0;
    assign ns_rd_valid = ns_vld;
    // =========================================================================
    // 结果：逐声部过自己的包络 -> 全声部混音
    //   y_env = (eng_y * emap[voi]) >>> 31   包络 Q1.31
    //   y_acc = Σ_voi y_env                  帧内跨声部求和
    //   分三拍走（S_RUN_V 取操作数 / S_ENVMUL 乘 / S_ENVACC 累加）：
    //     原来 emap 的 16:1 读 + 96 位乘法 + 64 位累加挤在一拍里，实测 PnR
    //     25.6 ns（Fmax 50 MHz）。分开之后每拍只剩一级：
    //     mux 单独一拍、乘法器两个输入都是寄存器、累加也自己一拍。
    //   y_acc 是 64 位；SLOTS 个声部同时满量程理论上会回绕（实际信号远不到）。
    // =========================================================================
    logic signed [AW-1:0] y_acc;       // Σ y_env（帧内跨声部混音）
    logic signed [AW-1:0] y_lat;       // eng_y 打一拍：乘法器的输入必须是寄存器
    logic signed [31:0]   e_lat;       // emap[voi] 打一拍：16:1 读单独占一拍
    logic signed [AW-1:0] y_env;       // 本声部过包络后的输出
    logic signed [95:0]   y_mul;

    assign y_mul = y_lat * e_lat;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_lat <= '0;
            e_lat <= '0;
            y_env <= '0;
            y_acc <= '0;
        end else begin
            if (state == S_RUN_V && era_yv && erb_yv) begin
                // A 声部先算；B 声部的操作数在 S_ADV 里再装一次
                y_lat <= era_y;
                e_lat <= $signed(emap[g[VWID-1:0]]);
            end
            // 乘法结果先落一拍，下一拍才做 64 位累加（原来是 mul + add 同一拍）
            if (state == S_ENVMUL) y_env <= y_mul[94:31];   // (eng_y*E) >>> 31
            if (state == S_ENVACC)
                y_acc <= (g == '0 && !pick_b) ? y_env : (y_acc + y_env);
            if (state == S_ADV && !pick_b) begin
                y_lat <= erb_y;
                e_lat <= $signed(emap[VWID'(g[VWID-1:0] + VWID'(HS))]);
            end
        end
    end

    // =========================================================================
    // 后级：全声部混音 -> 腔体 -> 混响 -> y_data
    //   mix_v / mix_q : 一笔待接走的混音；腔体 93 拍/样本，忙时 in_ready=0
    //   mix_outstd    : 已经交出去、还没从腔体出来的样本数
    //   rev_outstd    : 已经进混响、还没出来的样本数（混响是固定 6 拍流水）
    //   两者都排空才能报 done，否则最后一帧的 y_data 会丢
    // =========================================================================
    logic                 mix_v;
    logic signed [AW-1:0] mix_q;
    logic                 body_in_ready, body_accept, body_out_valid;
    logic signed [63:0]   body_y;
    logic                 rev_out_valid;
    logic signed [63:0]   rev_y;
    logic [3:0]           mix_outstd, rev_outstd;

    assign body_accept = mix_v && body_in_ready;
    assign y_valid     = rev_out_valid;      // 混响之后才是"data"
    assign y_data      = rev_y;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mix_outstd <= '0;
            rev_outstd <= '0;
        end else begin
            case ({body_accept, body_out_valid})
                2'b10:   mix_outstd <= mix_outstd + 1'b1;
                2'b01:   mix_outstd <= mix_outstd - 1'b1;
                default: ;
            endcase
            case ({body_out_valid, rev_out_valid})
                2'b10:   rev_outstd <= rev_outstd + 1'b1;
                2'b01:   rev_outstd <= rev_outstd - 1'b1;
                default: ;
            endcase
        end
    end

    // =========================================================================
    // 作业调度：IDLE -> (LOAD) -> 每采样 [RUN_X 等 xmap -> XWR 写 SLOTS 路 -> RUN_V 跑声部] -> DONE
    // =========================================================================
    // S_ENVMUL / S_ENVACC：包络乘法流水（取操作数 -> 乘 -> 累加），见上面结果段
    typedef enum logic [3:0] { S_DONE, S_LOAD, S_RUN_X, S_XS, S_RUN_V,
                               S_ENVMUL, S_ENVACC, S_ADV, S_WAIT } st_e;
    st_e                 state;

    // ---- 对外语义 ----
    //   done  : 电平，1 = 空闲可以 start（= 在 S_DONE 等着）
    //   ready : 电平，1 = 现在会执行挂起的 inst/reload 变更（没有挂起变更时恒 1）
    //   load_err: loader 的 err 电平，转发给上层（UI 展示），router 自己不处理
    logic                reload_q, reload_pend;
    logic                change_pend;
    assign change_pend = (inst != inst_prev) || reload_pend;
    assign done        = (state == S_DONE);
    assign ready       = !change_pend || (note_on == '0);
    assign load_err    = ld_err;

    // 这一拍会不会在 S_DONE 里真正启动加载（和 case 里的判定同一条件）。
    //   必须用组合判据：always_ff 里调制器的门在 case 之前执行，非阻塞赋值下
    //   它看不到同一拍稍后才置起的 ld_start / S_LOAD，只加 !ld_start 挡不住。
    logic                load_now;
    assign load_now = (state == S_DONE) && start && change_pend && ready;

    // synthesis translate_off
    // 硬件只有 16 个按键（fmap 是 mat4x4）：SLOTS 不能超过 16；同时它必须是
    // 2 的幂（地址是 {slot, mode} 拼接），且 >= 4（要拆两个 bank，HS = SLOTS/2）。
    initial if (SLOTS > 16 || SLOTS < 4 || (SLOTS & (SLOTS - 1)) != 0)
        $error("voice_router: SLOTS must be 4/8/16 (2^n, <= 16 keys)");
    // synthesis translate_on

    instrument_e         inst_prev;
    logic                wait_xmap;

    // ------------------------------------------------------------------
    // 外部输入采样：加载系数期间一律忽略（fmap_q 冻结，见文件开头）
    //   第一次装载（inst_prev 还是 NONE）也算加载中——否则上电时按下的键
    //   会被 gate_r 记成"已经按下"，装完之后就不再算新起音
    // ------------------------------------------------------------------
    assign input_hold = (state == S_LOAD) || (inst_prev == INST_NONE);

    // router 自己要的那份"起音事件"：note_on 是电平，这里取一拍沿
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) note_on_q <= '0;
        else        note_on_q <= note_on;
    end
    assign note_ev = note_on & ~note_on_q;

    // 引擎是逐声部串行跑的，等它跑到某个声部时沿早没了：事件先攒进 note_pend，
    // 到**作业头**（S_RUN_X 那一拍）一次性交给 note_f，note_f 只在这一次作业里有效：
    // 不跨帧粘住，也不会跨加载残留。
    logic             frame_start;

    assign frame_start = (state == S_RUN_X) && wait_xmap && xmap_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            note_f    <= '0;
            note_pend <= '0;
        end else if (frame_start) begin
            note_f    <= note_pend | note_ev;
            note_pend <= '0;
        end else if (|note_ev) begin
            note_pend <= note_pend | note_ev;
        end
    end

    // st_zero：note-on 首帧 或 该声部**刚刚**变成
    //
    //   注意这里是"归零的那一帧"清一次，不是"归零期间每帧都清"：
    //   eng0 的清零 pass 要 n_modes 拍，全静音时 SLOTS 个声部每帧都清 = SLOTS×80 拍，
    //   实测一个采样 2754 拍（48 kHz 要 132 MHz）。只在包络掉到 0 的那一帧清，
    //   状态被清成正好 0，之后激励也是 0，状态就一直保持 0 了。

    // 比较结果打一拍：原来 emap -> 比较 -> eng_zero 是一条长组合链
    // （包络每采样才更新一次，晚一拍对 st_zero 没有影响）
    logic [SLOTS-1:0] voice_dead, voice_dead_q;
    logic [SLOTS-1:0] dead_ev;         // 归零的那一拍
    logic [SLOTS-1:0] dead_pend, dead_f;   // 攒到帧头的那份（和 note_f 一个套路）

    // "这个声部空了"由包络自己给（ADSR：release 走完才给；dyn0：没按住就给），
    // 顶层不再拿 emap==0 去猜——起音头几个采样 emap 也是 0，猜错就会把刚打进去的
    // 激励清掉（retrigger 的听感是"没声音"）。这里只打一拍当同步。
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            voice_dead   <= '0;
            voice_dead_q <= '0;
        end else begin
            voice_dead   <= env_dead;
            voice_dead_q <= voice_dead;
        end
    end

    assign dead_ev = voice_dead & ~voice_dead_q;

    // 帧头把 note 事件和"刚归零"事件一起交给本帧
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dead_f    <= '0;
            dead_pend <= '0;
        end else if (frame_start) begin
            dead_f    <= dead_pend | dead_ev;
            dead_pend <= '0;
        end else if (|dead_ev) begin
            dead_pend <= dead_pend | dead_ev;
        end
    end

    // 清零信号在引擎实例那边按 bank 各自给（era_zero / erb_zero），这里不用了

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_DONE;        // 上电就是"空闲、可以 start"
            mix_v      <= 1'b0;
            mix_q      <= '0;
            g          <= '0;
            pick_b     <= 1'b0;
            nm_lat     <= '0;
            inst_lat   <= INST_NONE;
            inst_prev  <= INST_NONE;
            eng_start  <= 1'b0;
            ld_start   <= 1'b0;
            xw_run     <= 1'b0;
            wait_xmap  <= 1'b0;
            mod_req    <= '0;
            mod_start  <= 1'b0;
            mod_slot   <= '0;
            reload_q   <= 1'b0;
            reload_pend<= 1'b0;
        end else begin
            if (body_accept) mix_v <= 1'b0;      // 这一笔混音已经被腔体接走
            eng_start <= 1'b0;
            ld_start  <= 1'b0;
            mod_start <= 1'b0;

            // reload 在内部取上升沿（外部一直拉高也只认一次）
            reload_q    <= reload;
            if (reload && !reload_q) reload_pend <= 1'b1;

            // ---- 后台调制：有请求 + 调制器空闲 + 没在加载 -> 发一拍 start ----
            //   一次只发一个（busy 期间不发，发了也会被它忽略），做完清那一位。
            //   load_now 挡“这一拍就要开始加载”：非阻塞下 ld_start/S_LOAD 下一拍才可见，
            //   只靠 !ld_start / state!=S_LOAD 会漏掉 S_DONE 同拍首次加载。
            if (mod_done)
                mod_req[mod_slot] <= 1'b0;
            else if (!mod_start && !mod_busy && !ld_busy && !ld_start &&
                     !load_now && (state != S_LOAD) && (|mod_req)) begin
                mod_slot  <= first_req(mod_req);
                mod_start <= 1'b1;
            end

            case (state)
                // 空闲：done=1（上面组合输出），等 start。
                //   ready=1 才真正执行 inst/reload 的变更（没有挂起变更时恒 1）；
                //   ready=0 时这一帧照常跑（用旧表），变更挂起等下一次。
                S_DONE: begin
                    if (start) begin
                        // 每个乐器用多少模态由 router_pkg 定；超过表的物理深度就限幅
                        //   （n_modes_of 不知道 N_MODES，所以夹在这里）
                        nm_lat   <= (n_modes_of(inst) > N_MODES) ? (IW+1)'(N_MODES)
                                                                 : (IW+1)'(n_modes_of(inst));
                        g        <= '0;
                        pick_b   <= 1'b0;
                        if (change_pend) begin
                            if (ready) begin
                                inst_lat    <= inst;
                                reload_pend <= 1'b0;
                                ld_start    <= 1'b1;
                                state       <= S_LOAD;
                            end else begin
                                // 键还按着：先出这一帧（旧系数、旧乐器号），别停摆
                                wait_xmap <= 1'b1;
                                state     <= S_RUN_X;
                            end
                        end else begin
                            inst_lat  <= inst;
                            wait_xmap <= 1'b1;
                            state     <= S_RUN_X;
                        end
                    end
                end

                S_LOAD: begin
                    if (ld_done) begin
                        inst_prev <= inst_lat;
                        g         <= '0;
                        wait_xmap <= 1'b1;
                        state     <= S_RUN_X;
                    end
                end

                // 等 force_pre 出这一采样的 xmap（它自己按 CLK/SR 分频）
                // 一次作业只跑一个采样，所以 xmap 只要整张寄存进 x_q（一拍），
                // 不需要再分 SLOTS 拍写 x_ram
                S_RUN_X: begin
                    if (wait_xmap && xmap_valid) begin
                        wait_xmap <= 1'b0;
                        xw_run    <= 1'b1;          // 下一拍照抄 xmap -> x_q
                        state     <= S_XS;
                    end
                end

                // 一拍把 xmap 整张抄进 x_q（快照），然后才起引擎：
                // 引擎第一拍就要读 x，抄和读挤同一拍会读到上一笔
                S_XS: begin
                    xw_run    <= 1'b0;
                    g         <= '0;
                    pick_b    <= 1'b0;
                    eng_start <= 1'b1;              // 第 0 组的两个声部**同时**起
                    state     <= S_RUN_V;
                end

                // 起音声部只**登记**一个调制请求，不停下来等 —— 调制器在后台跑
                //   （它写系数用的写口和引擎读系数用的读口是同一块 RAM 的两个端口，
                //    天然可以同时工作；新系数从下一帧开始生效）。
                // 两个引擎都出 y_valid 才算这一组完成（同种引擎、同拍启动，时序一致）
                S_RUN_V: begin
                    if (era_yv && erb_yv) begin
                        if (note_f[g[VWID-1:0]])            mod_req[g[VWID-1:0]] <= 1'b1;
                        if (note_f[VWID'(g + VWID'(HS))])
                                                            mod_req[VWID'(g + VWID'(HS))] <= 1'b1;
                        pick_b <= 1'b0;
                        state  <= S_ENVMUL;
                    end
                end

                // 包络乘法：这一拍把乘法结果打进 y_env
                S_ENVMUL: state <= S_ENVACC;

                // 这一拍把 y_env 累加进 y_acc
                S_ENVACC: state <= S_ADV;

                S_ADV: begin
                    if (!pick_b) begin
                        // 同一组里的 B 声部：复用同一套 乘法/累加 流水
                        pick_b <= 1'b1;
                        state  <= S_ENVMUL;
                    end else if (g + 1'b1 >= VWID'(HS)) begin
                        // 全部声部算完：把这一采样的混音交给腔体。
                        // 上一笔还没被接走就原地等（绝不覆盖），腔体出来才是 y_data
                        if (!mix_v) begin
                            mix_q <= y_acc;
                            mix_v <= 1'b1;
                            g     <= '0;
                            pick_b<= 1'b0;
                            state <= S_WAIT;      // 先排空，排空完才回 S_DONE（done 才变 1）
                        end
                    end else begin
                        g         <= g + 1'b1;
                        pick_b    <= 1'b0;
                        eng_start <= 1'b1;
                        state     <= S_RUN_V;
                    end
                end

                // 排空：等腔体 + 混响把最后几笔都吐完，才回 S_DONE（这时 done 才变 1）
                //   这段时间 done=0，上层不会发新的 start。
                S_WAIT: begin
                    if (mix_outstd == '0 && !mix_v && rev_outstd == '0) begin
                        state <= S_DONE;
                    end
                end

                default: state <= S_DONE;
            endcase
        end
    end

    // =========================================================================
    // 后级实例：混音 -> 腔体 -> 混响 -> y_data
    //   腔体：乐器号选系数（body_router 内部 = 常量表 + body_biquad），用 inst_lat
    //         （一次作业里乐器号不变，系数就不会中途跳）
    //   混响：预设由上层给（reverb_preset），NONE 时是逐位直通的延迟
    // =========================================================================
    body_router #(
        .SLOTS(SLOTS), .NSEC(5), .NTAP(5), .COEFF_FRAC(27), .GUARD_BITS(4)
    ) u_body (
        .clk(clk), .rst_n(rst_n),
        .inst(inst_lat),
        .in_valid(mix_v), .in_ready(body_in_ready), .x(mix_q),
        .out_valid(body_out_valid), .y(body_y)
    );

    reverb_router #(.N(2048)) u_rev (
        .clk(clk), .rst_n(rst_n), .preset(reverb_preset),
        .in_valid(body_out_valid), .x(body_y),
        .out_valid(rev_out_valid), .y(rev_y)
    );

endmodule
