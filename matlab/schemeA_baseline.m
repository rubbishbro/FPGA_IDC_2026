% schemeA_baseline.m —— 方案A：最简基线（单包络器 + 硬重触发）
% =====================================================================
% ★ 三个方案中最简单、最原始的版本，作为对照组。
%   做法：每个键固定 1 个包络器；重按键 = 包络强行归零、重新Attack。
%   优点：实现代价最低——一键一套FSM，没有分配器、没有池。
%   缺点：每次重按都把上一音的尾巴一刀切到0 → 波形跳变 → 爆音"哒"。
%         爆音强度 = 被切瞬间的包络电平（本场景约0.68，非常响）。
%
%   三方案同场对比见 test.m
%
% 与硬件的对应（同 single_voice.m 的约定）：
%   - 振荡器  : DDS相位累加器+波形表（相位连续，从不重置）
%   - 包络    : 5状态FSM（idle/attack/decay/sustain/release）
%   - Release : 每采样乘定点常数K
% =====================================================================

clc; clear; close all;

%% 1. 可调参数
Fs = 48000;  T_total = 4;
t  = 0 : 1/Fs : T_total - 1/Fs;
dt = 1/Fs;
freq = 440;                     % 同一个键：A4

% 连按场景（与test.m一致）：每0.15s按一次，每次按住0.08s，共10次
press_period = 0.15;  press_dur = 0.08;  n_press = 10;
t_on  = (0:n_press-1)*press_period + 0.1;
t_off = t_on + press_dur;

% 包络与滤波器参数（与 single_voice.m 完全一致）
A = 0.001;  D = 0.2;  S = 0.6;
R_rate = 3.0;   thr = 1e-4;
K = exp(-R_rate*dt);            % Release系数 → FPGA: 定点系数
q = 0.9;  f_min = 0.005;  f_max = 0.3;

% 事件流（模拟键盘位图边沿检测后的输出）
ev_time = [t_on, t_off];
ev_type = [ones(1,n_press), zeros(1,n_press)];   % 1=NoteOn, 0=NoteOff
[ev_time, ord] = sort(ev_time);  ev_type = ev_type(ord);
ev_ptr = 1;

%% 2. 状态
osc  = sawtooth(2*pi*freq*t);    % 固定振荡器（相位连续）
stA  = 0;  valA = 0;             % 单个包络器（每键一套）
lowA = 0;  bandA = 0;            % SVF状态
yA   = zeros(size(t));
envA = zeros(size(t));
cut_t = [];  cut_v = [];         % 每次硬切的时刻与当时电平（=爆音强度）

%% 3. 主循环（逐采样推进，模拟FPGA行为）
for i = 1:numel(t)
    % ---- 键盘事件 ----
    while ev_ptr <= numel(ev_time) && ev_time(ev_ptr) <= t(i)
        if ev_type(ev_ptr) == 1
            cut_t(end+1) = t(i);  cut_v(end+1) = valA;  %#ok<SAGROW>
            stA = 1;  valA = 0;                   % ★硬重触发：一刀切到0
        else
            if stA >= 1 && stA <= 3, stA = 4; end  % 松手进Release
        end
        ev_ptr = ev_ptr + 1;
    end
    % ---- 包络状态机 ----
    switch stA
        case 1, valA = valA + dt/A;        if valA >= 1, valA = 1; stA = 2; end
        case 2, valA = valA - (1-S)*dt/D;  if valA <= S, valA = S; stA = 3; end
        case 3, valA = S;
        case 4, valA = valA * K;           if valA < thr, valA = 0; stA = 0; end
    end
    envA(i) = valA;
    % ---- SVF + VCA ----
    fA = f_min + (f_max - f_min) * valA;
    highA = osc(i) - lowA - q*bandA;
    bandA = bandA + fA * highA;
    lowA  = lowA  + fA * bandA;
    yA(i) = (lowA*0.5 + bandA*0.4 + highA*0.1) * valA;
end

%% 4. 统计
fprintf('===== 方案A（最简基线）单方案仿真 =====\n');
fprintf('硬切 %d 次，被切电平: %s\n', numel(cut_t), mat2str(round(cut_v,3)));
fprintf('爆音强度=被切电平：本场景每次切掉约0.68的包络 → 每次重按都是明显的"哒"\n');

%% 5. 可视化
figure('Name','方案A：包络与输出','Position',[60 60 900 620]);
subplot(2,1,1); plot(t, envA, 'r', 'LineWidth', 1.2); hold on;
plot(cut_t, cut_v, 'ro', 'MarkerFaceColor', 'r');
title('方案A包络（红圈=硬切瞬间，尾巴被腰斩）'); grid on; ylabel('包络');
subplot(2,1,2); plot(t, yA, 'LineWidth', 0.5);
title('方案A输出（每次重按有爆音）'); grid on; xlabel('时间(秒)');

figure('Name','方案A：重触发瞬间放大','Position',[60 60 900 380]);
z = t >= 0.50 & t <= 0.75;      % 覆盖第4次按下(0.55s)
plot(t(z), yA(z), 'LineWidth', 0.8);
title('放大：0.55s 处波形直接跳变（爆音来源）'); grid on; xlabel('时间(秒)');

%% 6. 试听
try
    disp('正在播放：方案A 最简基线（每次重按的爆音"哒"）...');
    soundsc(yA, Fs);
catch
    disp('(当前环境无法播放音频——请在MATLAB桌面中直接运行本脚本试听)');
end

% 【自己动手】
% 1) press_period 改成 0.5：间隔变长，被切电平更低 → 爆音变轻但不消失
% 2) press_dur 改成 0.5：切的是sustain电平(0.6) → 爆音最响
% → 结论：爆音强度=被切电平，本方案结构上无法消除，只能按慢点
