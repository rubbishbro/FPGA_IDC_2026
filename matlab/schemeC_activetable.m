% schemeC_activetable.m —— 方案C：活跃表 + 催死（当前选定方案）
% =====================================================================
% 做法：不维护"EG槽位+绑定"，只维护一张活跃表——每行就是
%   {键号, 包络值, SVF状态}，输出 = 各行(osc×env)求和。
%   淘汰不等于删除：行数超过高水位 → 给"贡献最小且正在release"的行
%   换一个快衰减系数K_fast，让它连续地加速退场（催死）。
% 优点：全程包络无跳变 → 爆音物理上不可能产生（本场景催死8次、
%       起始电平0.44比B切掉的0.28还响，依然全程干净）；
%       表行状态仅~7字节，128行≈1块BRAM零头 → 容量廉价，实际装不满。
% 缺点：被催死的尾巴变短（~0.1s快速淡出而非完整余音）；
%       R_fast要配平：催死一行的时间必须短于两次按键的最小间隔。
%
%   三方案同场对比见 test.m
%
% 与硬件的对应（同 single_voice.m 的约定）：
%   - 活跃表      : 小RAM（每行键号+包络+SVF状态），free-list管理
%   - 高水位催死  : 行数>H → 最小值行换系数（一次比较+一次写）
%   - 计算        : 逐行扫描，时隙复用DSP（128行×4乘=512周期 < 2083）
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
K      = exp(-R_rate*dt);       % 正常Release系数
R_fast = 60;                    % 催死系数：20倍加速（要按最坏进场速率配平）
K_fast = exp(-R_fast*dt);
q = 0.9;  f_min = 0.005;  f_max = 0.3;

% 事件流
ev_time = [t_on, t_off];
ev_type = [ones(1,n_press), zeros(1,n_press)];
[ev_time, ord] = sort(ev_time);  ev_type = ev_type(ord);
ev_ptr = 1;

%% 2. 活跃表状态
osc   = sawtooth(2*pi*freq*t);   % 固定振荡器（相位连续）
N_TAB = 3;   H_TAB = N_TAB - 1; % 表容量3、高水位2：行数>2就开始催死
stC  = zeros(1,N_TAB);  valC = zeros(1,N_TAB);  keyC = zeros(1,N_TAB);
lowC = zeros(1,N_TAB);  bandC = zeros(1,N_TAB);
fstC = zeros(1,N_TAB);          % 催死标志（该行是否在用K_fast）
yC   = zeros(size(t));
env_tab = zeros(N_TAB, numel(t));
c_kill_t = [];  c_kill_v = [];  % 催死时刻与起始电平
c_hard   = 0;                   % 兜底硬偷次数（理论上应为0）

%% 3. 主循环
for i = 1:numel(t)
    % ---- 键盘事件 ----
    while ev_ptr <= numel(ev_time) && ev_time(ev_ptr) <= t(i)
        if ev_type(ev_ptr) == 1
            % NoteOn：插入新行（高水位催死保证几乎总有空行）
            row = find(stC == 0, 1);
            if isempty(row)                  % 兜底：理论路径，不应发生
                [~, row] = min(valC);  c_hard = c_hard + 1;
            end
            stC(row) = 1;  valC(row) = 0;  keyC(row) = 1;  fstC(row) = 0;
        else
            % NoteOff：该键按住中的行进Release（正常系数）
            heldC = find(stC >= 1 & stC <= 3 & keyC == 1);
            if ~isempty(heldC), stC(heldC(1)) = 4; end
        end
        ev_ptr = ev_ptr + 1;
    end

    % ---- 高水位催死检查：行数>高水位 → 最安静的release行加速退场 ----
    act = sum(stC ~= 0);   nfast = sum(fstC == 1);
    if act > H_TAB && nfast < (act - H_TAB)
        cand = find(stC == 4 & fstC == 0);       % 只催release中的行
        if ~isempty(cand)
            [~, kk] = min(valC(cand));  row = cand(kk);
            fstC(row) = 1;                       % ★换K_fast，连续加速衰减
            c_kill_t(end+1) = t(i);   %#ok<SAGROW>
            c_kill_v(end+1) = valC(row);  %#ok<SAGROW>
        end
    end

    % ---- 每行独立更新（催死行用K_fast），输出求和 ----
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

%% 4. 统计
fprintf('===== 方案C（活跃表+催死）单方案仿真，容量=%d、高水位=%d =====\n', N_TAB, H_TAB);
fprintf('催死 %d 次（起始电平: %s），兜底硬偷 %d 次\n', ...
        numel(c_kill_t), mat2str(round(c_kill_v,3)), c_hard);
fprintf('催死的尾巴(0.44)比B切掉的(0.28)还响，但衰减连续 → 全程无爆音\n');

%% 5. 可视化
figure('Name','方案C：活跃表各行包络','Position',[60 60 900 600]);
plot(t, env_tab', 'LineWidth', 1.2); hold on;
for s = 1:numel(c_kill_t)
    plot([c_kill_t(s) c_kill_t(s)], [0 1.05], 'b--');
end
xlabel('时间(秒)'); ylabel('各行包络');
title('方案C：催死——蓝虚线后该行加速连续衰减（无跳变）'); grid on;

figure('Name','方案C：催死瞬间放大','Position',[60 60 900 380]);
z = t >= 0.50 & t <= 0.75;      % 与方案B同一时间窗，方便对照
plot(t(z), yC(z), 'LineWidth', 0.8);
title('放大（与B同一时刻）：尾巴连续快退场 → 波形无跳变'); grid on; xlabel('时间(秒)');

figure('Name','方案C：最终输出','Position',[60 60 900 380]);
plot(t, yC, 'LineWidth', 0.5);
title('方案C输出（10次连按，全程无爆音）'); grid on; xlabel('时间(秒)');

%% 6. 试听
try
    disp('正在播放：方案C 活跃表+催死（应全程干净）...');
    soundsc(yC, Fs);
catch
    disp('(当前环境无法播放音频——请在MATLAB桌面中直接运行本脚本试听)');
end

% 【自己动手】
% 1) N_TAB 改成 16：催死永不触发，尾巴完整保留。FPGA上一行状态仅
%    ~7字节（键号+包络+SVF），128行≈1块BRAM零头 → 容量廉价是C的立身之本
% 2) R_fast 改成 20（催死更温和）：出局变慢 → 可能出现兜底硬偷(c_hard>0)
%    → 说明R_fast必须配平：催死一行的时间 < 两次按键的最小间隔
% 3) 与 schemeB_egpool.m 同容量对比：B切0.28跳变，C催0.44不跳变
% → 结论：把"删除"变成"催死"，爆音在物理上不存在；代价是被催的尾巴变短
