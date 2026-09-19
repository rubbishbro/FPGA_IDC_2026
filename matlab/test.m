% test.m —— 同键连按（重触发）三种方案同场对比测试
% =====================================================================
% 单方案详解（含可调参数与"自己动手"实验）：
%   schemeA_baseline.m / schemeB_egpool.m / schemeC_activetable.m
% 场景：板卡未到，验证"连按同一个键"时的声音表现。
% 本场景故意加压：每0.15s连按一次 + 池/表容量只给3行，
% 让方案B的偷声切到"还比较响"的尾巴（爆音现身），检验方案C的稳定性。
%
%   ★ 方案A = 最简单、最原始的版本（基线）：
%       每键只有1个包络器，重按时强行归零重启（硬重触发）。
%       实现代价最低（一个键一套FSM），音质最差：每次重按都有爆音。
%   方案B = EG池 + 偷声（上一版选定方案）：
%       池满时按优先级硬偷（瞬间归零）。压力小时偷的都是安静尾巴
%       听不出；压力大时会切到较响的尾巴 → 爆音。
%   方案C = 活跃表 + 催死（新方案）：
%       淘汰不等于删除——给贡献最小的行换一个快衰减系数(K_fast)，
%       让它"连续地加速退场"。全程包络无跳变 → 物理上不可能爆音。
%       表容量在FPGA上很便宜（128行≈1块BRAM的零头），实际几乎装不满。
%
% 与硬件的对应（同 single_voice.m 的约定）：
%   - 固定振荡器    : DDS相位累加器+波形表，相位连续、从不重置
%   - 包络器状态机  : 5状态FSM（idle/attack/decay/sustain/release）
%   - 事件流        : 键盘位图 → 边沿检测 → NoteOn/NoteOff
%   - Release指数衰减: 每采样乘定点常数K；催死只是换成另一个系数K_fast
% =====================================================================

clc; clear; close all;

%% 1. 全局参数（与 single_voice.m 保持一致）
Fs = 48000;  T_total = 4;
t  = 0 : 1/Fs : T_total - 1/Fs;
dt = 1/Fs;
freq = 440;                     % 同一个键：A4

% ---- 加压场景：每0.15s连按一次，每次按住0.08s，共10次 ----
press_period = 0.15;  press_dur = 0.08;  n_press = 10;
t_on  = (0:n_press-1)*press_period + 0.1;
t_off = t_on + press_dur;

% 合并成按时间排序的事件流（模拟键盘位图边沿检测后的输出）
ev_time = [t_on, t_off];
ev_type = [ones(1,n_press), zeros(1,n_press)];   % 1=NoteOn, 0=NoteOff
[ev_time, ord] = sort(ev_time);  ev_type = ev_type(ord);
ev_ptr = 1;

%% 2. 包络与滤波器参数（与 single_voice.m 完全一致）
A = 0.001;  D = 0.2;  S = 0.6;
R_rate = 3.0;   thr = 1e-4;
K = exp(-R_rate*dt);            % 正常Release系数 → FPGA: 定点系数
R_fast = 60;                    % 催死系数：20倍加速（纯参数，硬件只是换个乘数）
K_fast = exp(-R_fast*dt);

q = 0.9;  f_min = 0.005;  f_max = 0.3;

%% 3. 固定振荡器（三个方案共用：相位连续，从不重置）
osc = sawtooth(2*pi*freq*t);

%% 4. 方案A（最简基线）：单EG硬重触发
stA = 0;  valA = 0;             % 5状态FSM
lowA = 0;  bandA = 0;           % SVF状态
yA = zeros(size(t));

%% 5. 方案B：固定振荡器 + EG池（容量3，制造池满压力）
N_EG = 3;
st   = zeros(1,N_EG);           % 0idle 1attack 2decay 3sustain 4release
val  = zeros(1,N_EG);
key  = zeros(1,N_EG);           % EG绑定的键号（本仿真只有1个键）
low  = zeros(1,N_EG);  band = zeros(1,N_EG);   % 每EG独立的SVF状态
yB   = zeros(size(t));
env_eg = zeros(N_EG, numel(t)); % 包络轨迹（画图用）
steal_cnt = zeros(1,4);         % 偷声优先级统计
steal_times = [];  steal_vals = [];   % 偷声时刻与被切时的电平

%% 6. 方案C：活跃表 + 催死（容量3、高水位2：行数>2就开始催死最安静行）
N_TAB = 3;   H_TAB = N_TAB - 1; % 高水位：提前催死，保证新音符总有空行
stC  = zeros(1,N_TAB);  valC = zeros(1,N_TAB);  keyC = zeros(1,N_TAB);
lowC = zeros(1,N_TAB);  bandC = zeros(1,N_TAB);
fstC = zeros(1,N_TAB);          % 催死标志：该行是否在用K_fast加速退场
yC   = zeros(size(t));
env_tab = zeros(N_TAB, numel(t));
c_kill_t = [];  c_kill_v = [];  % 催死时刻与起始电平（证明催的是响尾巴也不爆音）
c_hard   = 0;                   % 兜底硬偷次数（理论上应为0）

%% 7. 主循环：逐采样推进（模拟FPGA每个采样周期的行为）
for i = 1:numel(t)
    % ---- 7.1 处理本采样时刻到达的键盘事件 ----
    while ev_ptr <= numel(ev_time) && ev_time(ev_ptr) <= t(i)
        if ev_type(ev_ptr) == 1
            % ===== Note On =====
            % 方案A：硬重触发——不管包络现在多大，直接归零（爆音来源）
            stA = 1;  valA = 0;
            % 方案B：分配算法（空闲→同键release→任意release→切音）
            idx = find(st == 0, 1);
            if ~isempty(idx)
                lvl = 0;
            else
                cand = find(st == 4 & key == 1);
                if isempty(cand), cand = find(st == 4); end
                if ~isempty(cand)
                    [~, kk] = min(val(cand));  idx = cand(kk);  lvl = 2;
                else
                    [~, idx] = min(val);  lvl = 3;
                end
                steal_cnt(lvl) = steal_cnt(lvl) + 1;
                steal_times(end+1) = t(i);  %#ok<SAGROW>
                steal_vals(end+1)  = val(idx);  %#ok<SAGROW>
            end
            st(idx) = 1;  val(idx) = 0;  key(idx) = 1;
            % 方案C：插入新行（有空行就插；高水位催死保证几乎总有空行）
            row = find(stC == 0, 1);
            if isempty(row)                       % 兜底：理论路径，不应发生
                [~, row] = min(valC);  c_hard = c_hard + 1;
            end
            stC(row) = 1;  valC(row) = 0;  keyC(row) = 1;  fstC(row) = 0;
        else
            % ===== Note Off =====
            if stA >= 1 && stA <= 3, stA = 4; end       % A：进Release
            held = find(st >= 1 & st <= 3 & key == 1);  % B：按住中的EG进Release
            if ~isempty(held), st(held(1)) = 4; end
            heldC = find(stC >= 1 & stC <= 3 & keyC == 1); % C：同上
            if ~isempty(heldC), stC(heldC(1)) = 4; end
        end
        ev_ptr = ev_ptr + 1;
    end

    % ---- 7.2 方案C：高水位催死检查（行数>高水位 → 最安静的release行加速退场） ----
    act = sum(stC ~= 0);   nfast = sum(fstC == 1);
    if act > H_TAB && nfast < (act - H_TAB)
        cand = find(stC == 4 & fstC == 0);       % 只催release中的行
        if ~isempty(cand)
            [~, kk] = min(valC(cand));  row = cand(kk);
            fstC(row) = 1;                       % 换K_fast，连续加速衰减
            c_kill_t(end+1) = t(i);  %#ok<SAGROW>
            c_kill_v(end+1) = valC(row);  %#ok<SAGROW>
        end
    end

    % ---- 7.3 方案A：单链路更新（EG → SVF → VCA） ----
    switch stA
        case 1, valA = valA + dt/A;        if valA >= 1, valA = 1; stA = 2; end
        case 2, valA = valA - (1-S)*dt/D;  if valA <= S, valA = S; stA = 3; end
        case 3, valA = S;
        case 4, valA = valA * K;           if valA < thr, valA = 0; stA = 0; end
    end
    fA = f_min + (f_max - f_min) * valA;
    highA = osc(i) - lowA - q*bandA;
    bandA = bandA + fA * highA;
    lowA  = lowA  + fA * bandA;
    yA(i) = (lowA*0.5 + bandA*0.4 + highA*0.1) * valA;

    % ---- 7.4 方案B：每EG独立更新，输出求和 ----
    for n = 1:N_EG
        switch st(n)
            case 1, val(n) = val(n) + dt/A;        if val(n) >= 1, val(n) = 1; st(n) = 2; end
            case 2, val(n) = val(n) - (1-S)*dt/D;  if val(n) <= S, val(n) = S; st(n) = 3; end
            case 3, val(n) = S;
            case 4, val(n) = val(n) * K;           if val(n) < thr, val(n) = 0; st(n) = 0; key(n) = 0; end
        end
        env_eg(n, i) = val(n);
        fn = f_min + (f_max - f_min) * val(n);
        highn = osc(i) - low(n) - q*band(n);
        band(n) = band(n) + fn * highn;
        low(n)  = low(n)  + fn * band(n);
        yB(i) = yB(i) + (low(n)*0.5 + band(n)*0.4 + highn*0.1) * val(n);
    end

    % ---- 7.5 方案C：每行独立更新（催死行用K_fast），输出求和 ----
    for n = 1:N_TAB
        switch stC(n)
            case 1, valC(n) = valC(n) + dt/A;        if valC(n) >= 1, valC(n) = 1; stC(n) = 2; end
            case 2, valC(n) = valC(n) - (1-S)*dt/D;  if valC(n) <= S, valC(n) = S; stC(n) = 3; end
            case 3, valC(n) = S;
            case 4
                if fstC(n), valC(n) = valC(n) * K_fast;   % 催死：快衰减
                else,       valC(n) = valC(n) * K;        % 正常衰减
                end
                if valC(n) < thr
                    valC(n) = 0; stC(n) = 0; keyC(n) = 0; fstC(n) = 0;  % 出局，行回收
                end
        end
        env_tab(n, i) = valC(n);
        fn = f_min + (f_max - f_min) * valC(n);
        highn = osc(i) - lowC(n) - q*bandC(n);
        bandC(n) = bandC(n) + fn * highn;
        lowC(n)  = lowC(n)  + fn * bandC(n);
        yC(i) = yC(i) + (lowC(n)*0.5 + bandC(n)*0.4 + highn*0.1) * valC(n);
    end
end

%% 8. 统计输出
fprintf('===== 同键连按加压仿真（每%.2fs一次×%d次，池/表容量=%d）=====\n', ...
        press_period, n_press, N_EG);
fprintf('[A 基线] 无统计——每次重按都是硬切（听感：连爆音）\n');
fprintf('[B EG池 ] 偷声 %d 次（优先级2=%d, 3=%d, 4=%d），被切电平: %s\n', ...
        sum(steal_cnt), steal_cnt(2), steal_cnt(3), steal_cnt(4), ...
        mat2str(round(steal_vals,3)));
fprintf('[C 活跃表] 催死 %d 次（起始电平: %s），兜底硬偷 %d 次\n', ...
        numel(c_kill_t), mat2str(round(c_kill_v,3)), c_hard);
fprintf('对比要点：B把0.2~0.3电平的尾巴一刀切齐（爆音）；C让它们连续快退场（无跳变）\n');

%% 9. 可视化
figure('Name','方案B：EG池包络（红虚线=偷声时刻）','Position',[60 60 900 600]);
plot(t, env_eg', 'LineWidth', 1.2); hold on;
for s = 1:numel(steal_times)
    plot([steal_times(s) steal_times(s)], [0 1.05], 'r--');
end
xlabel('时间(秒)'); ylabel('各EG包络');
title('方案B：池满硬偷——红线处尾巴被瞬间切齐'); grid on;

figure('Name','方案C：活跃表包络（蓝虚线=催死时刻）','Position',[60 60 900 600]);
plot(t, env_tab', 'LineWidth', 1.2); hold on;
for s = 1:numel(c_kill_t)
    plot([c_kill_t(s) c_kill_t(s)], [0 1.05], 'b--');
end
xlabel('时间(秒)'); ylabel('各行包络');
title('方案C：催死——蓝线后该行加速连续衰减（无跳变）'); grid on;

figure('Name','同一时刻三方案对比（第4次按下 t=0.55s 附近）','Position',[60 60 900 700]);
z = t >= 0.50 & t <= 0.75;
subplot(3,1,1); plot(t(z), yA(z), 'LineWidth', 0.8);
title('A（最简基线）：重按即硬切 → 波形跳变'); grid on;
subplot(3,1,2); plot(t(z), yB(z), 'LineWidth', 0.8);
title('B（EG池+偷声）：0.55s偷0.28电平尾巴 → 波形跳变'); grid on;
subplot(3,1,3); plot(t(z), yC(z), 'LineWidth', 0.8);
title('C（活跃表+催死）：尾巴连续快退场 → 波形无跳变'); grid on;
xlabel('时间(秒)');

figure('Name','方案C：最终输出','Position',[60 60 900 380]);
plot(t, yC, 'LineWidth', 0.5);
title('方案C最终输出（10次连按，全程无爆音）'); grid on;
xlabel('时间(秒)');

%% 10. 试听（A → B → C，对比爆音差异）
try
    disp('正在播放：A 最简基线（每次重按爆音）...');     soundsc(yA, Fs); pause(T_total+0.3);
    disp('正在播放：B EG池+偷声（注意偷声切尾的"哒"）...'); soundsc(yB, Fs); pause(T_total+0.3);
    disp('正在播放：C 活跃表+催死（应全程干净）...');      soundsc(yC, Fs);
catch
    disp('(当前环境无法播放音频——请在MATLAB桌面中直接运行本脚本试听)');
end
