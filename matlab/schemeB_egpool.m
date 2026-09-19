% schemeB_egpool.m —— 方案B：EG池 + 偷声（上一版方案，现为对照组）
% =====================================================================
% 做法：固定振荡器（每键1个，相位连续）+ N个包络器池。
%   NoteOn  → 分配一个空闲EG；池满 → 按优先级"偷"：
%             ①同键release尾巴 → ②任意release尾巴 → ③切音（兜底）
%   NoteOff → 该键按住中的EG进Release，尾巴自然衰减
% 优点：小压力下偷的都是安静尾巴，听感无感，结构简单。
% 缺点：偷声=瞬间归零，本质还是"切"——压力一大就切到响尾巴 → 爆音
%       （本场景7次偷声每次切~0.28电平，试听有"哒"声）。
%
%   三方案同场对比见 test.m
%
% 与硬件的对应（同 single_voice.m 的约定）：
%   - EG池        : N个5状态FSM，每个EG独立SVF+VCA
%   - 分配器      : 组合逻辑找空闲/最小值EG（偷声优先级）
%   - Release     : 每采样乘定点常数K
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
K = exp(-R_rate*dt);
q = 0.9;  f_min = 0.005;  f_max = 0.3;

% 事件流
ev_time = [t_on, t_off];
ev_type = [ones(1,n_press), zeros(1,n_press)];
[ev_time, ord] = sort(ev_time);  ev_type = ev_type(ord);
ev_ptr = 1;

%% 2. EG池状态
osc  = sawtooth(2*pi*freq*t);    % 固定振荡器（相位连续）
N_EG = 3;                        % 池容量（故意压小制造池满压力）
st   = zeros(1,N_EG);            % 0idle 1attack 2decay 3sustain 4release
val  = zeros(1,N_EG);
key  = zeros(1,N_EG);            % EG绑定的键号（本仿真只有1个键）
low  = zeros(1,N_EG);  band = zeros(1,N_EG);   % 每EG独立的SVF状态
yB   = zeros(size(t));
env_eg = zeros(N_EG, numel(t));
steal_cnt   = zeros(1,4);
steal_times = [];  steal_vals = [];

%% 3. 主循环
for i = 1:numel(t)
    % ---- 键盘事件 ----
    while ev_ptr <= numel(ev_time) && ev_time(ev_ptr) <= t(i)
        if ev_type(ev_ptr) == 1
            % NoteOn：分配算法（空闲→同键release→任意release→切音）
            idx = find(st == 0, 1);
            if ~isempty(idx)
                lvl = 0;
            else
                cand = find(st == 4 & key == 1);        % 同键release优先
                if isempty(cand), cand = find(st == 4); end
                if ~isempty(cand)
                    [~, kk] = min(val(cand));  idx = cand(kk);  lvl = 2;
                else
                    [~, idx] = min(val);  lvl = 3;
                end
                steal_cnt(lvl) = steal_cnt(lvl) + 1;
                steal_times(end+1) = t(i);   %#ok<SAGROW>
                steal_vals(end+1)  = val(idx);  %#ok<SAGROW>
            end
            st(idx) = 1;  val(idx) = 0;  key(idx) = 1;
        else
            % NoteOff：按住中的EG进Release（尾巴自然衰减）
            held = find(st >= 1 & st <= 3 & key == 1);
            if ~isempty(held), st(held(1)) = 4; end
        end
        ev_ptr = ev_ptr + 1;
    end
    % ---- 每EG独立更新（EG → SVF → VCA），输出求和 ----
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
end

%% 4. 统计
fprintf('===== 方案B（EG池+偷声）单方案仿真，池容量=%d =====\n', N_EG);
fprintf('偷声 %d 次（优先级2=%d, 3=%d, 4=%d），被切电平: %s\n', ...
        sum(steal_cnt), steal_cnt(2), steal_cnt(3), steal_cnt(4), ...
        mat2str(round(steal_vals,3)));
fprintf('偷声=瞬间归零：被切0.28电平的尾巴 → 波形跳变 → 可闻"哒"声\n');

%% 5. 可视化
figure('Name','方案B：EG池包络','Position',[60 60 900 600]);
plot(t, env_eg', 'LineWidth', 1.2); hold on;
for s = 1:numel(steal_times)
    plot([steal_times(s) steal_times(s)], [0 1.05], 'r--');
end
xlabel('时间(秒)'); ylabel('各EG包络');
title('方案B：池满硬偷——红虚线处尾巴被瞬间切齐'); grid on;

figure('Name','方案B：偷声瞬间放大','Position',[60 60 900 380]);
z = t >= 0.50 & t <= 0.75;      % 覆盖第4次按下(0.55s)的偷声
plot(t(z), yB(z), 'LineWidth', 0.8);
title('放大：0.55s 偷0.28电平尾巴 → 波形跳变（爆音）'); grid on; xlabel('时间(秒)');

figure('Name','方案B：最终输出','Position',[60 60 900 380]);
plot(t, yB, 'LineWidth', 0.5);
title('方案B输出（小压力无感，大压力爆音现形）'); grid on; xlabel('时间(秒)');

%% 6. 试听
try
    disp('正在播放：方案B EG池+偷声（注意偷声切尾的"哒"声）...');
    soundsc(yB, Fs);
catch
    disp('(当前环境无法播放音频——请在MATLAB桌面中直接运行本脚本试听)');
end

% 【自己动手】
% 1) N_EG 改成 16：偷声消失——但FPGA上16条完整EG链是真实的寄存器成本
% 2) press_period 改成 0.22（减压）：被切电平降到~0.08，几乎听不出
%    → B在轻压力下其实够用，重压力下才现形
% 3) 对照 schemeC_activetable.m：同样的3行容量，C不切而是催死
% → 结论：B的爆音=偷声时被切尾巴的电平；"挑安静的偷"只能缓解不能根治
