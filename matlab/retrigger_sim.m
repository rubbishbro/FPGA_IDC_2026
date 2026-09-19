% retrigger_sim.m —— 同键连按（重触发）问题两种方案的对比仿真
% =====================================================================
% 场景：板卡未到，验证"连按同一个键"时的声音表现
%   方案A：每键只有 1 个包络器，重按时强行归零重启（硬重触发）
%          → 上一音的尾巴被腰斩，包络从~0.5直接跳0，产生爆音"哒"
%   方案B：固定振荡器 + 包络器池(EG Pool)按算法分配（本项目选定方案）
%          → 每次按下分配一个新的EG，旧EG自然进入Release，尾巴完整
%            池满时按优先级"偷"最安静的EG（优先偷同键release尾巴）
%
% 与硬件的对应（同 single_voice.m 的约定）：
%   - 固定振荡器    : DDS相位累加器+波形表，相位连续、从不重置
%   - EG池状态机    : 5状态FSM（idle/attack/decay/sustain/release）
%   - 分配算法      : 键盘事件(NoteOn/Off) → 分配器 → EG绑定/偷声
%   - Release指数衰减: 每采样乘常数K（FPGA里是一个定点系数）
% =====================================================================

clc; clear; close all;

%% 1. 全局参数（与 single_voice.m 保持一致）
Fs = 48000;  T_total = 4;
t  = 0 : 1/Fs : T_total - 1/Fs;
dt = 1/Fs;
freq = 440;                     % 同一个键：A4

% ---- 同键连按事件：每0.22秒按一次，每次按住0.12秒，共8次 ----
press_period = 0.22;  press_dur = 0.12;  n_press = 8;
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
K = exp(-R_rate*dt);            % Release每采样乘的常数 → FPGA: 定点系数

q = 0.9;  f_min = 0.005;  f_max = 0.3;

%% 3. 固定振荡器（关键：相位连续，从不重置——这是本方案的核心）
osc = sawtooth(2*pi*freq*t);

%% 4. 方案A：单EG硬重触发
stA = 0;  valA = 0;             % 同一套5状态FSM
lowA = 0;  bandA = 0;           % SVF状态
yA = zeros(size(t));

%% 5. 方案B：固定振荡器 + N_EG个包络器池
N_EG = 4;                       % 故意只给4个：制造池满压力，验证偷声策略
st   = zeros(1,N_EG);           % 0idle 1attack 2decay 3sustain 4release
val  = zeros(1,N_EG);
key  = zeros(1,N_EG);           % EG当前绑定的键号（本仿真只有1个键）
low  = zeros(1,N_EG);  band = zeros(1,N_EG);   % 每EG独立的SVF状态
yB   = zeros(size(t));
env_eg = zeros(N_EG, numel(t)); % 记录每个EG的包络轨迹（画图用）
steal_cnt = zeros(1,4);         % 偷声优先级统计
steal_times = [];

%% 6. 主循环：逐采样推进（模拟FPGA每个采样周期的行为）
for i = 1:numel(t)
    % ---- 6.1 处理本采样时刻到达的键盘事件 ----
    while ev_ptr <= numel(ev_time) && ev_time(ev_ptr) <= t(i)
        if ev_type(ev_ptr) == 1
            % ===== Note On =====
            % 方案A：硬重触发——不管包络现在多大，直接归零（爆音来源）
            stA = 1;  valA = 0;
            % 方案B：分配算法（空闲 → 同键release尾巴 → 任意release → 切音）
            idx = find(st == 0, 1);                    % 优先级1：空闲EG
            if ~isempty(idx)
                lvl = 0;
            else
                cand = find(st == 4 & key == 1);       % 优先级2：同键正在release
                if isempty(cand)
                    cand = find(st == 4);              % 优先级3：任意正在release
                end
                if ~isempty(cand)
                    [~, kk] = min(val(cand));  idx = cand(kk);  lvl = 2;
                else
                    [~, idx] = min(val);  lvl = 3;     % 优先级4：最坏情况切音
                end
                steal_cnt(lvl) = steal_cnt(lvl) + 1;
                steal_times(end+1) = t(i); %#ok<SAGROW>
            end
            st(idx) = 1;  val(idx) = 0;  key(idx) = 1; % 从0起音 → 天然无爆音
        else
            % ===== Note Off =====
            if stA >= 1 && stA <= 3, stA = 4; end      % 方案A：进Release
            held = find(st >= 1 & st <= 3 & key == 1); % 方案B：按住中的EG进Release
            if ~isempty(held), st(held(1)) = 4; end    % （物理键最多一个按住中）
        end
        ev_ptr = ev_ptr + 1;
    end

    % ---- 6.2 方案A：单链路更新（EG → SVF → VCA） ----
    switch stA
        case 1, valA = valA + dt/A;        if valA >= 1, valA = 1; stA = 2; end
        case 2, valA = valA - (1-S)*dt/D;  if valA <= S, valA = S; stA = 3; end
        case 3, valA = S;                  % Sustain保持
        case 4, valA = valA * K;           if valA < thr, valA = 0; stA = 0; end
    end
    fA = f_min + (f_max - f_min) * valA;
    highA = osc(i) - lowA - q*bandA;
    bandA = bandA + fA * highA;
    lowA  = lowA  + fA * bandA;
    yA(i) = (lowA*0.5 + bandA*0.4 + highA*0.1) * valA;

    % ---- 6.3 方案B：每个EG独立更新（EG → SVF → VCA），输出求和 ----
    for n = 1:N_EG
        switch st(n)
            case 1, val(n) = val(n) + dt/A;        if val(n) >= 1, val(n) = 1; st(n) = 2; end
            case 2, val(n) = val(n) - (1-S)*dt/D;  if val(n) <= S, val(n) = S; st(n) = 3; end
            case 3, val(n) = S;                    % Sustain保持
            case 4, val(n) = val(n) * K;           if val(n) < thr, val(n) = 0; st(n) = 0; key(n) = 0; end
        end
        env_eg(n, i) = val(n);
        fn = f_min + (f_max - f_min) * val(n);
        highn = osc(i) - low(n) - q*band(n);
        band(n) = band(n) + fn * highn;
        low(n)  = low(n)  + fn * band(n);
        yB(i) = yB(i) + (low(n)*0.5 + band(n)*0.4 + highn*0.1) * val(n);
    end
end

%% 7. 统计输出
fprintf('===== 同键连按仿真（%d次连按，每%.2fs一次，EG池=%d个）=====\n', ...
        n_press, press_period, N_EG);
fprintf('方案B偷声统计：偷同键release尾巴 %d 次，偷任意release %d 次，切音 %d 次\n', ...
        steal_cnt(2), steal_cnt(3), steal_cnt(4));
fprintf('偷"同键尾巴"= 同音高且已衰减很小 → 人耳几乎无感\n');

%% 8. 可视化
figure('Name','方案B：EG池包络轨迹（红虚线=偷声时刻）','Position',[80 80 900 650]);
plot(t, env_eg', 'LineWidth', 1.2); hold on;
for s = 1:numel(steal_times)
    plot([steal_times(s) steal_times(s)], [0 1.05], 'r--');
end
xlabel('时间(秒)'); ylabel('各EG包络');
title('方案B：每次按下分配新EG，旧EG自然Release，尾巴叠加'); grid on;

figure('Name','重触发瞬间对比（第2次按下 t=0.32s）','Position',[80 80 900 650]);
z = t >= 0.28 & t <= 0.42;
subplot(2,1,1); plot(t(z), yA(z), 'LineWidth', 0.8);
title('方案A：硬重触发 → 0.32s 处波形跳变（爆音"哒"）'); grid on;
subplot(2,1,2); plot(t(z), yB(z), 'LineWidth', 0.8);
title('方案B：新EG从零起音叠加，波形连续无跳变'); grid on;
xlabel('时间(秒)');

figure('Name','方案B：最终输出','Position',[80 80 900 380]);
plot(t, yB, 'LineWidth', 0.5);
title('方案B最终输出（8次连按，尾巴完整保留）'); grid on;
xlabel('时间(秒)');

%% 9. 试听（先A后B，对比爆音差异）
try
    disp('正在播放：方案A 硬重触发（注意每次重按的爆音）...');
    soundsc(yA, Fs);  pause(T_total + 0.3);
    disp('正在播放：方案B 固定振荡器+EG池（连按自然，无爆音）...');
    soundsc(yB, Fs);
catch
    disp('(当前环境无法播放音频——请在MATLAB桌面中直接运行本脚本试听)');
end
