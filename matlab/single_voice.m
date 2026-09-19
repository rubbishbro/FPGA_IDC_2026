% 单声部：锯齿波 + ADSR包络 + SVF滤波器
clc; clear; close all;

%% 1. 全局参数设置（对应FPGA的时钟和采样率）
Fs = 48000;             % 采样率 48kHz，与FPGA I2S设计严格对齐
T_total = 4;            % 总时长 4秒
t = 0 : 1/Fs : T_total - 1/Fs;
freq = 440;             % 音高 440Hz (A4)

% 包络时间参数（对应FPGA状态机的计数器阈值）
t_on  = 0.5;            % 0.5秒时按下按键 (Note On)
t_off = 1.0;            % 1.0秒时松开按键 (Note Off)
A = 0.001;              % Attack 时间 (极短，模拟打击/拨弦)
D = 0.2;                % Decay 时间
sustain_level = 0.6;    % Sustain 延音电平 (0~1)

% 包络衰减速率参数
release_rate = 3.0;     % Release阶段指数衰减系数 (数值越大，松手后消失越快)
threshold = 0.0001;     % 🔥 阈值截断：低于此值直接归零（硬件省资源的关键！）

%% 2. 生成振荡器信号
% 在FPGA中，这步对应：DDS相位累加器 + BRAM波形查找表
osc = sawtooth(2 * pi * freq * t);

%% 3. 逐点计算 ADSR 包络（模拟FPGA状态机）
env = zeros(size(t));
env_at_t_off = sustain_level; % 用来记录松开瞬间的包络值，确保Release起始值连续

for i = 1:length(t)
    time = t(i);
    
    if time < t_on
        env(i) = 0;                                   % 阶段0：闲置
        
    elseif time < t_on + A
        env(i) = (time - t_on) / A;                   % 阶段1：Attack 线性上升
        
    elseif time < t_on + A + D
        decay_time = time - t_on - A;
        env(i) = 1 - (1 - sustain_level) * (decay_time / D); % 阶段2：Decay 线性下降
        
    elseif time < t_off
        env(i) = sustain_level;                       % 阶段3：Sustain 保持电平
        env_at_t_off = env(i);                        % 更新松手时的基准值
        
    else
        release_time = time - t_off;
        env(i) = env_at_t_off * exp(-release_time * release_rate); % 阶段4：Release 指数衰减
        
        % 🔥 在FPGA里，这一步相当于比较器：if (env_level < 16'd10) env_level <= 0;
        if env(i) < threshold
            env(i) = 0;                               % 衰减到足够小，强制归零，避免底噪和爆音
        end
    end
end

%% 4. 状态变量滤波器（SVF） + 包络调制截止频率
% 在FPGA中，这对应：2个DSP乘法器 + 几个加减法
q = 0.9;              % 共振 (0~1)，越大声音越尖锐，对应FPGA里的Q系数
f_min = 0.005;        % 最低截止频率系数 (包络衰减到0时，声音很“闷”)
f_max = 0.3;          % 最高截止频率系数 (包络最大时，声音很“亮”)

low  = 0;             % 低通状态寄存器 (对应FPGA里的 low 寄存器)
band = 0;             % 带通状态寄存器 (对应FPGA里的 band 寄存器)
filt_out = zeros(size(t));

for i = 1:length(t)
    % 包络值映射到截止频率：包络大(起音) → 频率高(亮)，包络小(衰减) → 频率低(暗)
    f = f_min + (f_max - f_min) * env(i);
    
    % SVF 核心差分方程（对应FPGA里每个采样周期的运算）
    high = osc(i) - low - q * band;   % 高通 = 输入 - 低通 - 共振*带通
    band = band + f * high;           % 带通 += f * 高通
    low  = low  + f * band;           % 低通 += f * 带通
    
    filt_out(i) = low*0.5+band*0.4+high*0.1;                % 输出低通结果（也可换成 band 或 high）
end

%% 5. VCA（压控放大器）：滤波器输出 × 包络
% 在FPGA中，这对应：1个DSP乘法器
y = filt_out .* env;

%% 6. 播放与可视化
disp('正在播放：带包络 + SVF滤波的锯齿波...');
soundsc(y, Fs);

figure;
subplot(4,1,1); plot(t, osc);      title('1. 振荡器 (锯齿波)');       grid on;
subplot(4,1,2); plot(t, env, 'r'); title('2. ADSR 包络');             grid on;
subplot(4,1,3); plot(t, filt_out); title('3. SVF 滤波器输出');        grid on;
subplot(4,1,4); plot(t, y, 'k');   title('4. 最终输出 (滤波器 × 包络)'); grid on;
xlabel('时间 (秒)')