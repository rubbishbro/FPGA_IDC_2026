下面把**线性阻尼 + 弯曲刚度 + 一般初始条件 + 一般外力**的弦振动模态法，从连续方程到离散更新公式完整推导一遍。

---

## 1. 连续方程

弦长 \(L\)，张力 \(T\)，线密度 \(\mu\)，弯曲刚度 \(EI\)。横向位移 \(y(x,t)\)。加线性阻尼 \(-2\mu\gamma\,\partial_t y\)，外加分布力 \(f(x,t)\)。

运动方程：

\[
\mu \frac{\partial^2 y}{\partial t^2}
=
T \frac{\partial^2 y}{\partial x^2}
-
EI \frac{\partial^4 y}{\partial x^4}
-
2\mu\gamma \frac{\partial y}{\partial t}
+
f(x,t)
\]

移项并除以 \(\mu\)：

\[
\boxed{
\frac{\partial^2 y}{\partial t^2}
+
2\gamma \frac{\partial y}{\partial t}
-
c^2 \frac{\partial^2 y}{\partial x^2}
+
\beta^2 \frac{\partial^4 y}{\partial x^4}
=
\frac{f(x,t)}{\mu}
}
\]

其中

\[
c^2=\frac{T}{\mu},\qquad
\beta^2=\frac{EI}{\mu}
\]

若定义 \(k_n=\dfrac{n\pi}{L}\)，则频率变为

\[
\omega_n^2 = c^2 k_n^2 + \beta^2 k_n^4
\]

当有非零的弯曲刚度时，频率不再是严格谐波，写成基频形式：

\[
\omega_n
=
n\omega_1
\sqrt{
1+
\frac{EI}{T}\left(\frac{n\pi}{L}\right)^2
}
\]

令不谐和性系数

\[
B=\frac{\pi^2 EI}{T L^2}
\]

则

\[
\boxed{
f_n
=
n f_1 \sqrt{1+B n^2}
}
\]

这正是钢琴弦等真实弦的不谐和性公式。弯曲刚度越大，高频被拉得越高。

---

## 2. 边界条件与模态展开

### 简支边界

琴弦两端通常可近似为简支：

\[
y(0,t)=y(L,t)=0,\qquad
y_{xx}(0,t)=y_{xx}(L,t)=0
\]

此时空间模态为

\[
\phi_n(x)=\sin\left(\frac{n\pi x}{L}\right)
=\sin(k_n x),\qquad n=1,2,3,\dots
\]

并且

\[
\phi_n''=-k_n^2\phi_n,\qquad
\phi_n''''=k_n^4\phi_n
\]

正交性：

\[
\int_0^L \phi_n(x)\phi_m(x)\,dx
=
\frac{L}{2}\delta_{nm}
\]

把位移展开成模态叠加：

\[
y(x,t)=\sum_{n=1}^{\infty} q_n(t)\phi_n(x)
\]

其中 \(q_n(t)\) 是第 \(n\) 阶模态坐标。

### 固支或其他边界

若两端固支：

\[
y(0,t)=y(L,t)=0,\qquad
y_x(0,t)=y_x(L,t)=0
\]

则模态不再是简单正弦，需要求解特征值问题：

\[
\beta^2 \phi'''' - c^2 \phi'' = \omega^2 \phi
\]

频率由超越方程给出，实际模拟需数值求解。

---

## 3. 从 PDE 到每个模态的 ODE

### 3.1 代入并投影

把展开式代入运动方程：

\[
\sum_n \ddot q_n\phi_n
+
2\gamma\sum_n \dot q_n\phi_n
-
c^2\sum_n q_n\phi_n''
=
\frac{f}{\mu}
\]

利用 \(\phi_n''=-k_n^2\phi_n\)：

\[
\sum_n
\left(
\ddot q_n+2\gamma\dot q_n+c^2k_n^2 q_n
\right)\phi_n
=
\frac{f}{\mu}
\]

定义

\[
\omega_n=c k_n=\frac{n\pi c}{L}
\]

于是

\[
\sum_n
\left(
\ddot q_n+2\gamma\dot q_n+\omega_n^2 q_n
\right)\phi_n
=
\frac{f}{\mu}
\]

两边乘以 \(\phi_m(x)\)，在 \([0,L]\) 上积分，利用正交性：

\[
\frac{L}{2}
\left(
\ddot q_m+2\gamma\dot q_m+\omega_m^2 q_m
\right)
=
\frac{1}{\mu}\int_0^L f(x,t)\phi_m(x)\,dx
\]

定义**模态力**：

\[
F_n(t)=\int_0^L f(x,t)\phi_n(x)\,dx
\]

得到每个模态独立的受迫阻尼振子方程：

\[
\boxed{
\ddot q_n+2\gamma\dot q_n+\omega_n^2 q_n
=
\frac{F_n(t)}{M_n}
}
\]

其中**模态质量**：

\[
M_n=\frac{\mu L}{2}
\]

> 注意：如果外力是点力 \(f(x,t)=F(t)\delta(x-x_f)\)，则
> 
> \[
> F_n(t)=F(t)\sin\left(\frac{n\pi x_f}{L}\right)
> \]
> 如果是分布力，则用上面的积分。

### 3.2 初始条件投影

由 \(y(x,0)=y_0(x)\)：

\[
\sum_n q_n(0)\phi_n(x)=y_0(x)
\]

两边乘 \(\phi_m\) 积分：

\[
\boxed{
q_n(0)=\frac{2}{L}\int_0^L y_0(x)\phi_n(x)\,dx
}
\]

同理：

\[
\boxed{
\dot q_n(0)=\frac{2}{L}\int_0^L v_0(x)\phi_n(x)\,dx
}
\]

### 3.3 解析解（连续时间）

对每个模态，方程是标准阻尼振子。定义阻尼比：

\[
\zeta_n=\frac{\gamma}{\omega_n}
\]

欠阻尼时 \(\gamma<\omega_n\)，阻尼频率：

\[
\omega_{d,n}=\sqrt{\omega_n^2-\gamma^2}
\]

齐次解：

\[
q_n^h(t)=
e^{-\gamma t}
\left[
q_n(0)\cos(\omega_{d,n}t)
+
\frac{\dot q_n(0)+\gamma q_n(0)}{\omega_{d,n}}
\sin(\omega_{d,n}t)
\right]
\]

受迫响应用卷积：

\[
q_n(t)=q_n^h(t)
+
\frac{1}{M_n}
\int_0^t h_n(t-\tau)F_n(\tau)\,d\tau
\]

其中单位脉冲响应：

\[
h_n(t)=\frac{e^{-\gamma t}}{\omega_{d,n}}
\sin(\omega_{d,n}t)
\]

总位移：

\[
y(x,t)=\sum_{n=1}^{N} q_n(t)\phi_n(x)
\]

其中\(N\) 是截断模态数。其合法范围由混叠与带宽共同确定：

\[
N<\frac{f_s}{2f_1}
\qquad\text{（不混叠）},\qquad
N\ge\frac{f_{\text{bw}}}{f_1}
\qquad\text{（覆盖到 }f_{\text{bw}}\text{）}
\]

在不混叠范围内应尽可能大。

---


## 4. 外力与初始条件的数值处理

### 4.1 初始条件积分

对一般 \(y_0(x)\)、\(v_0(x)\)，用数值积分：

\[
q_n(0)=\frac{2}{L}\int_0^L y_0(x)\sin\left(\frac{n\pi x}{L}\right)dx
\]

\[
\dot q_n(0)=\frac{2}{L}\int_0^L v_0(x)\sin\left(\frac{n\pi x}{L}\right)dx
\]

可用梯形法或辛普森法。若 \(y_0\) 是分段线性（如拨点在 \(x_p\)的拨弦三角形）

\[
y_0(x)=
\begin{cases}
A\dfrac{x}{x_p}, & 0\le x\le x_p\\[6pt]
A\dfrac{L-x}{L-x_p}, & x_p\le x\le L
\end{cases}
\]

由初始速度 \(v_0(x)=0\)，代入积分可得解析结果：

\[
q_n(0)=
\frac{2 A L^2}{n^2\pi^2 x_p(L-x_p)}
\sin\left(\frac{n\pi x_p}{L}\right)
\]

\[
\dot q_n(0)=0
\]

所以拨弦位置 \(x_p\) 直接决定各阶模态的幅度，也就决定了音色。

### 4.2 外力积分

点力：

\[
F_n(t)=F(t)\sin\left(\frac{n\pi x_f}{L}\right)
\]

击弦就可以视为突然出现并快速衰减的单点力
分布力：

\[
F_n(t)=\int_0^L f(x,t)\sin\left(\frac{n\pi x}{L}\right)dx
\]

数值上对空间网格做梯形积分即可。

### 4.3 弓摩擦激励

弓与琴弦摩擦时会在接触点处发生粘滑过程，可近似视为周期的点力驱动。设$v_{rel}=v_{bow}-v_{str}$，$N$为弓下压力，摩擦力满足

\[
f(t)=\mu(v_{rel})N
\]

其中$\mu(v_{rel})$通常随相对速度$v_{rel}$增加而快速衰减，比如可取为

\[
\mu(x) = \mu_d+\frac{\mu_s - \mu_d}{1+|x|}
\]

但此形式只适用于单向粘滑过程（$v_{rel}$不变号），由于琴弦与弓的相对速度并不确定，故需要对负相对速度也进行处理。简单的奇延拓会导致函数零点处不连续，进而引发数值不稳定。解决方法是降低参数大小，同时使用连续的奇函数

\[
\mu(x) = \begin{cases}
\frac{\mu_s}{\epsilon}x & |x| < \epsilon \\
\left(\mu_d + (\mu_s-\mu_d)e^{\epsilon-|x|}\right)\text{sgn}(x) & \text{otherwise}
\end{cases}
\]

当$|v_{rel}| < \epsilon$时制造负反馈，使模拟算法倾向于将相对速度降为零，从而在数值稳定的情况下模拟出粘滞状态。此处指数函数可以替换为其它具有衰减性质的函数。

---

## 5. 输出：位移、琴桥力、声音

弦上任意点位移：

\[
y(x,t)=\sum_{n=1}^N q_n(t)\phi_n(x)
\]

琴桥处对琴桥的力近似为

\[
F_b(t)=T\left.\frac{\partial y}{\partial x}\right|_{x=L}
\]

因为

\[
\phi_n'(x)=\frac{n\pi}{L}\cos\left(\frac{n\pi x}{L}\right)
\]

在 \(x=L\)：

\[
\phi_n'(L)=\frac{n\pi}{L}(-1)^n
\]

所以

\[
F_b(t)=T\sum_{n=1}^N q_n(t)\frac{n\pi}{L}(-1)^n
\]

这个 \(F_b(t)\) 就是驱动面板/共鸣箱的输入。之后经滤波（共鸣箱频率响应）或瑞利积分得到听者处的声压。

---

## 6. 时间离散化

连续解里的卷积要数值算。因为外力是逐采样给出的外部输入，离散格式必须让外力真正做功，并把状态取成物理量，才能在弦长、张力变化时保持连续。

### 6.1 分段常力精确更新

设第 \(k\) 步内 \(t\in[t_k,t_k+\Delta t]\) 外力 \(F_n\) 取常值 \(F_n^k\)，记

\[
g_n^k=\frac{F_n^k}{M_n}
\]

该步的模态方程是常系数受迫振子：

\[
\ddot q_n+2\gamma\dot q_n+\omega_n^2q_n=g_n^k
\]

特解是 \(q_{n,p}=g_n^k/\omega_n^2\)，齐次解是阻尼振荡。代入步首状态 \((q_n^k,\dot q_n^k)\) 得精确解：

\[
q_n(t)=
\frac{g_n^k}{\omega_n^2}
+
e^{-\gamma(t-t_k)}
\left[
A\cos\bigl(\omega_{d,n}(t-t_k)\bigr)
+
B\sin\bigl(\omega_{d,n}(t-t_k)\bigr)
\right]
\]

其中

\[
A=q_n^k-\frac{g_n^k}{\omega_n^2},
\qquad
B=\frac{\dot q_n^k+\gamma\left(q_n^k-g_n^k/\omega_n^2\right)}{\omega_{d,n}}
\]

取 \(t=t_{k+1}\)，用 \(EC=e^{-\gamma\Delta t}\cos(\omega_{d,n}\Delta t)\)、\(ES=e^{-\gamma\Delta t}\sin(\omega_{d,n}\Delta t)\) 整理：

\[
\boxed{
q_n^{k+1}
=
EC\,q_n^k
+
\frac{ES}{\omega_{d,n}}\left(\dot q_n^k+\gamma q_n^k\right)
+
\frac{g_n^k}{\omega_n^2}
\left(1-EC-\frac{\gamma ES}{\omega_{d,n}}\right)
}
\]

对时间求导后同取 \(t=t_{k+1}\)：

\[
\boxed{
\dot q_n^{k+1}
=
EC\,\dot q_n^k
-
\frac{ES}{\omega_{d,n}}\left(\omega_n^2q_n^k+\gamma\dot q_n^k\right)
+
\frac{g_n^k}{\omega_n^2}
\left(\gamma+\frac{\omega_n^2ES}{\omega_{d,n}}-\gamma EC\right)
}
\]

这就是分段常力算法，无条件稳定。

外力只在 \(x_n^k=g_n^k/\omega_n^2\) 里出现，所以输入可以是单个标量，逐模态展开由 \(K_n\) 完成。固定采样率下四个系数只依赖 \(\omega_n\) 与 \(\Delta t\)，可预先算好：

\[
\frac{1}{\omega_{d,n}},\qquad
EC_n,\qquad
ES_n,\qquad
\frac{1}{\omega_n^2}
\]

更新退化为每模态两次乘加，\(O(N)\) 每采样。齐次部分的幅度是

\[
|z|=e^{-\gamma\Delta t}
\]

它只含 \(\gamma\Delta t\)，与 \(\omega_n\Delta t\) 无关，所以不存在 CFL 型限制，步长可以取到音频采样率。

### 6.2 时变弦长与张力

演奏中弦长和张力都会变：按弦改变有效弦长，揉弦同时摆动二者。由 3.1 节

\[
\omega_n=\frac{n\pi}{L}\sqrt{\frac{T}{\mu}+\frac{EI}{\mu}\left(\frac{n\pi}{L}\right)^2}
\]

\(T\) 使频率按 \(\sqrt{T}\) 缩放，\(L\) 使频率按 \(1/L\) 缩放，同时不谐和性系数 \(B=\pi^2EI/(TL^2)\) 也跟着变，谐波峰的位置整体重排。

参数变化时只需重建依赖 \(L\)、\(T\) 的量：\(\omega_n\)、\(\omega_{d,n}\) 以及四个预计算系数。稳定性不受影响，收缩因子 \(|z|=e^{-\gamma\Delta t}\) 与 \(\omega_n\) 无关。重建相当于对 \(\omega_n(t)\) 做零阶保持。

重建时把与 \(n\) 无关的量提出，\(P_n=n\pi\) 保持为常量 ROM：

\[
\omega_n=\frac{P_n}{L}\sqrt{A+BP_n^2},
\qquad
A=\frac{T}{\mu},
\qquad
B=\frac{EI}{\mu L^2}
\]

\(T\) 与 \(L\) 各只影响一个标量。FPGA 上每采样需要：4 次标量运算得到 \(A\)、\(B\)，\(N\) 次乘加与 \(N\) 次开方得到 \(\omega_n\)，\(N\) 次乘加得到 \(\omega_{d,n}\)，然后是 \(2N\) 次三角函数得到 \(EC_n\)、\(ES_n\)。

---

## 7. 完整算法流程

```text
输入：L, T, mu, gamma, EI, N, q[n](0), qdot[n](0), 外力序列 F(t)

初始化：
  P[n] = n*pi
  K[n] = (2/(mu*L)) * sin(n*pi*x_f/L)          # 点力权重
  q[n] = q[n](0), qdot[n] = qdot[n](0)          # 物理状态，打击时全为 0

每个采样步 k = 0,1,2,...：
  1. 若 L 或 T 相比上一采样变化，重建频率表：
       A = T/mu,  B = EI/(mu*L^2)
       omega[n]   = (P[n]/L) * sqrt(A + B*P[n]^2)
       omega_d[n] = sqrt(max(omega[n]^2 - gamma^2, eps))
       EC[n] = exp(-gamma*dt)*cos(omega_d[n]*dt)
       ES[n] = exp(-gamma*dt)*sin(omega_d[n]*dt)
       sw[n] = n*(-1)^n * T/L                    # 琴桥力权重

  2. 逐模态更新：
       x[n] = F(t) * K[n] / omega[n]^2
       q_new[n] = EC[n]*q[n] + ES[n]*(qdot[n] + gamma*q[n])/omega_d[n]
                  + x[n]*(1 - EC[n] - gamma*ES[n]/omega_d[n])
       qdot_new[n] = EC[n]*qdot[n]
                     - ES[n]*(omega[n]^2*q[n] + gamma*qdot[n])/omega_d[n]
                     + x[n]*(gamma + omega[n]^2*ES[n]/omega_d[n] - gamma*EC[n])
       q[n] = q_new[n],  qdot[n] = qdot_new[n]

  3. 输出琴桥力：
       F_b = sum_n q[n] * sw[n]
```

---

## 8. 模态法与有限差分的对比

| 方面 | 模态法 | 有限差分法 |
|---|---|---|
| 基本思想 | 把解展开成解析空间模态，时间坐标独立演化 | 直接在空间网格和时间步上离散波动方程 |
| 空间离散 | 全局基函数，理想弦时空间精确 | 局部网格，二阶或高阶精度 |
| 时间演化 | 可解析求解；也可数值积分 | 必须时间步进，显式或隐式 |
| 稳定性 | 解析解无 CFL；数值积分需满足最高模态频率 | 显式需 \(C=c\Delta t/\Delta x\le 1\)，即 CFL 条件 |
| 计算量 | 每时间步 \(O(N)\)，\(N\) 为模态数，通常几十到几百 | 每时间步 \(O(M)\)，\(M\) 为空间网格点数，通常几百到几千，且时间步更小 |
| 高频精度 | 理想弦频率精确，截断误差来自忽略高阶模态 | 有数值频散，高频波速不准，需要很细网格 |



