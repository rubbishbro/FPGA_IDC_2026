下面把**线性阻尼 + 一般初始条件 + 一般外力**的弦振动模态法，从连续方程到离散更新公式完整推导一遍。

---

## 1. 连续方程

弦长 \(L\)，张力 \(T\)，线密度 \(\mu\)，横向位移 \(y(x,t)\)。加线性粘性阻尼，单位长度阻尼力 \(-2\mu\gamma\,\partial_t y\)，外加分布力 \(f(x,t)\)。

运动方程：

\[
\mu \frac{\partial^2 y}{\partial t^2}
=
T \frac{\partial^2 y}{\partial x^2}
-
2\mu\gamma \frac{\partial y}{\partial t}
+
f(x,t)
\]

两边除以 \(\mu\)：

\[
\boxed{
\frac{\partial^2 y}{\partial t^2}
+
2\gamma \frac{\partial y}{\partial t}
-
c^2 \frac{\partial^2 y}{\partial x^2}
=
\frac{f(x,t)}{\mu}
}
\]

其中

\[
c=\sqrt{\frac{T}{\mu}}
\]

边界条件（两端固定）：

\[
y(0,t)=0,\qquad y(L,t)=0
\]

初始条件（一般形式）：

\[
y(x,0)=y_0(x),\qquad
\frac{\partial y}{\partial t}(x,0)=v_0(x)
\]

---

## 2. 模态展开

理想弦的空间模态：

\[
\phi_n(x)=\sin\left(\frac{n\pi x}{L}\right),\qquad n=1,2,3,\dots
\]

满足

\[
\phi_n''(x)=-k_n^2\phi_n(x),\qquad
k_n=\frac{n\pi}{L}
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

\(N\) 是截断模态数。

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

分布力：

\[
F_n(t)=\int_0^L f(x,t)\sin\left(\frac{n\pi x}{L}\right)dx
\]

数值上对空间网格做梯形积分即可。

### 4.3 两种激励是互斥的：拨弦 vs 打击

上面两小节描述的是**两种不同的物理激励方式**，用哪一种决定了初始条件怎么设：

| | 拨弦（pluck） | 打击 / 施加外力（strike） |
|---|---|---|
| 物理过程 | 把弦拉到某个形状后释放 | 弦静止，外力在一段时间内推它 |
| 初始条件 | \(q_n(0)\ne0\)（式见 4.1），\(\dot q_n(0)=0\) | \(q_n(0)=0\)，\(\dot q_n(0)=0\) |
| 外力 | \(f(x,t)=0\) | \(f(x,t)\ne0\) |
| 弦初始形状 | 三角/折线形 | 静止直线 |

**不要同时用两种。** 若既设非零初始位移又施加外力，等于把两次激励叠加到同一条弦上，
能量会重复计入。4.1 节的三角拨弦公式与 4.2 节的模态力公式只能选一个。

**关于 \(u\) 代换下的初始条件。** 方法 A 用的变量是 \(u_n=q_n-g_n/\omega_n^2\)，
初值必须由 \(q_n\) 反推，不能直接把 \(q_n(0)\) 赋给 \(u_n\)。两种激励对应的 \(u\) 初值：

* **打击**（\(q_n(0)=0\)）：\(u_n(0)=-\,g_n(0)/\omega_n^2\)，
  且 \(\dot u_n(0)=\dot q_n(0)=0\)。
  注意 \(u_n(0)\ne0\) 并不代表弦有初始位移——它正好抵消静态力项，使
  \(q_n(0)=u_n(0)+g_n(0)/\omega_n^2=0\)。
* **拨弦**（\(f\equiv0\Rightarrow g_n=0\)）：\(u_n(0)=q_n(0)\)，即 4.1 节的值。

下文的 `stringSim` 实现走的是**打击**这一路。

### 4.4 截断模态数 \(N\) 的选取

模态法把无穷级数截断到 \(N\) 项。\(N\) 有上下两个方向的约束，**合法区间**由它们共同围出，
在区间内取**尽可能大**（大则音色完整，代价是计算量线性增长）：

**(1) 不混叠（硬上限）。** 最高模态必须留在 Nyquist 以下：

\[
f_N=N f_1<\frac{f_s}{2}
\;\Longrightarrow\;
N<\frac{f_s}{2f_1}
\]

否则高次模态会折叠到可听频段，产生非谐波杂音（且模态法是逐个振子积分，
折叠不会像采样那样只是镜像，而是直接变成错误的音高成分）。

**(2) 目标带宽（下限）。** 要覆盖到 \(f_{\text{bw}}\)：

\[
N\ge\frac{f_{\text{bw}}}{f_1}
\]

**(3) 精度（方法 B 才需要）。** 用中心差分时，第 6.4 节的频散要求
\(\omega_N\Delta t<0.118\)，即

\[
N<\frac{0.118\,f_s}{2\pi f_1}
\]

方法 A 是解析精确解，没有这一条。

**当前参数下的具体数值**（\(f_1=209.2\ \text{Hz}\)，\(f_s=48\ \text{kHz}\)）：

| 判据 | 结果 |
|---|---|
| 不混叠 | \(N<114\) |
| 覆盖 5 kHz / 10 kHz / 20 kHz | \(N\ge24\) / \(48\) / \(96\) |
| 方法 B 频散（1 音分） | \(N<4.3\)，即最多 4 阶——与方法 A 相比条件苛刻得多 |
| 方法 A 频散 | 无约束 |

最后一行是选择方法 A 的关键理由：若用中心差分且要求 1 音分精度，\(f_1=209\ \text{Hz}\)
的弦只能取 4 阶模态（最高 837 Hz），音色极闷；方法 A 没有这个限制。

`stringSim_demo.py` 取 \(N=16\)，覆盖到 \(16\times209.2=3347\ \text{Hz}\)。
这是在音色亮度与计算量之间的折中：16 阶只够覆盖约 3.3 kHz，听感偏闷；
想更亮就调大 \(N\)，上限由不混叠条件给出（当前参数下 114）。

---

## 5 输出：位移、琴桥力、声音

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

**\(F_b(t)\) 本身就直接当音频输出了。** 当前实现没有建模共鸣箱，而是把
\(F_b(t)\) 一步归一化后直接送扬声器（见第 7 节算法流程第 3 步与
`stringSim_demo.py`）。这样做是合理的近似：琴桥力与近场声压近似成正比。

两点需要注意：

* \(F_b\) 是**带符号**的振动量，以零为中心上下摆动。不要对它取绝对值——那等于做全波
  整流，会把基频能量搬到一个 DC 分量和二次谐波上，听起来变闷、发八度，并且直流会被
  音频硬件滤掉。
* 本节用的是**理想固定端**边界（\(y(L,t)=0\)）。真实琴桥有有限阻抗，会与弦耦合、让
  能量反射回弦内。这个效应在这里被完全忽略，\(F_b\) 只是"读出来"而没有反馈回弦。
  要建模需把 \(F_b\) 经琴桥导纳算成 \(y(L,t)\ne0\)，此时边界条件本身变成动态方程，
  模态不再正交解耦。

**实际输出的量是 \(F_b\)，不是 \(y(x,t)\)。** \(y(x,t)\) 在本实现里没有用到；上面给出
它是因为弦上位移是理解模态叠加的基础，也是若要取"拾音器位置信号"时应该用的量。

---

## 6. 时间离散化

连续解里卷积要数值算。下面给两种常用离散格式。

### 6.1 方法 A：分段常力精确更新（无条件稳定，当前stringSim实现）

假设在时间步 \([t_k,t_{k+1}]\) 内，外力 \(F_n\) 近似为常数 \(F_n^k\)，步长 \(\Delta t\)。

令

\[
g_n^k=\frac{F_n^k}{M_n}
\]

方程：

\[
\ddot q_n+2\gamma\dot q_n+\omega_n^2 q_n=g_n^k
\]

令 \(u_n=q_n-g_n^k/\omega_n^2\)，则 \(u_n\) 满足齐次方程：

\[
\ddot u_n+2\gamma\dot u_n+\omega_n^2 u_n=0
\]

从 \(t_k\) 到 \(t_{k+1}=t_k+\Delta t\) 的精确解：

\[
u_n^{k+1}
=
e^{-\gamma\Delta t}
\left[
u_n^k\cos(\omega_{d,n}\Delta t)
+
\frac{\dot u_n^k+\gamma u_n^k}{\omega_{d,n}}
\sin(\omega_{d,n}\Delta t)
\right]
\]

\[
\dot u_n^{k+1}
=
e^{-\gamma\Delta t}
\left[
\dot u_n^k\cos(\omega_{d,n}\Delta t)
-
\frac{\omega_n^2 u_n^k+\gamma\dot u_n^k}{\omega_{d,n}}
\sin(\omega_{d,n}\Delta t)
\right]
\]

然后还原：

\[
q_n^{k+1}=u_n^{k+1}+\frac{g_n^k}{\omega_n^2}
\]

\[
\dot q_n^{k+1}=\dot u_n^{k+1}
\]

**优点**：无条件稳定，精度高，步长可以取到音频采样率。

**缺点**：形式上是每步要算 \(\sin,\cos,\exp\)，但 \(E,C,S\) 只依赖 \(\Delta t\) 与
\(\omega_n\)，在固定采样率下是**常量**，一次性预计算即可（见下），所以实际每步只做乘加。

预计算系数：

\[
E=e^{-\gamma\Delta t},\qquad
C=\cos(\omega_{d,n}\Delta t),\qquad
S=\sin(\omega_{d,n}\Delta t)
\]

则更新可写成：

\[
u_n^{k+1}
=
E\left[
u_n^k C
+
\frac{\dot u_n^k+\gamma u_n^k}{\omega_{d,n}}S
\right]
\]

\[
\dot u_n^{k+1}
=
E\left[
\dot u_n^k C
-
\frac{\omega_n^2 u_n^k+\gamma\dot u_n^k}{\omega_{d,n}}S
\right]
\]

### 6.2 方法 B：中心差分显式格式

对

\[
\ddot q_n+2\gamma\dot q_n+\omega_n^2 q_n=\frac{F_n}{M_n}
\]

用中心差分：

\[
\ddot q_n\approx
\frac{q_n^{k+1}-2q_n^k+q_n^{k-1}}{\Delta t^2}
\]

\[
\dot q_n\approx
\frac{q_n^{k+1}-q_n^{k-1}}{2\Delta t}
\]

代入：

\[
\frac{q_n^{k+1}-2q_n^k+q_n^{k-1}}{\Delta t^2}
+
2\gamma
\frac{q_n^{k+1}-q_n^{k-1}}{2\Delta t}
+
\omega_n^2 q_n^k
=
\frac{F_n^k}{M_n}
\]

乘以 \(\Delta t^2\)：

\[
q_n^{k+1}-2q_n^k+q_n^{k-1}
+
\gamma\Delta t(q_n^{k+1}-q_n^{k-1})
+
\omega_n^2\Delta t^2 q_n^k
=
\frac{\Delta t^2}{M_n}F_n^k
\]

整理：

\[
(1+\gamma\Delta t)q_n^{k+1}
+
(-2+\omega_n^2\Delta t^2)q_n^k
+
(1-\gamma\Delta t)q_n^{k-1}
=
\frac{\Delta t^2}{M_n}F_n^k
\]

解出 \(q_n^{k+1}\)：

\[
\boxed{
q_n^{k+1}
=
\frac{
\frac{\Delta t^2}{M_n}F_n^k
+
(2-\omega_n^2\Delta t^2)q_n^k
-
(1-\gamma\Delta t)q_n^{k-1}
}{
1+\gamma\Delta t
}
}
\]

初始步：

\[
q_n^0=q_n(0)
\]

\[
q_n^1
=
q_n^0+\Delta t\,\dot q_n(0)
+
\frac{\Delta t^2}{2}
\left(
\frac{F_n^0}{M_n}
-
2\gamma\dot q_n(0)
-
\omega_n^2 q_n^0
\right)
\]

**稳定性条件**（无阻尼时）：

\[
\omega_N\Delta t<2
\]

即

\[
\Delta t<\frac{2}{\omega_N}
\]

**关于阻尼：阻尼是放宽而不是收紧这个条件。** 特征方程
\((1+\gamma\Delta t)z^2+(\omega^2\Delta t^2-2)z+(1-\gamma\Delta t)=0\) 的根，
当判别式 \(4\gamma^2\Delta t^2+\omega^4\Delta t^4-4\omega^2\Delta t^2<0\) 时为共轭复根，
其模为

\[
|z|=\sqrt{\frac{1-\gamma\Delta t}{1+\gamma\Delta t}}\;<\;1
\qquad(\gamma\Delta t>0)
\]

与 \(\omega\Delta t\) 无关。数值扫描验证：\(\gamma\Delta t=0.1\) 时，从
\(\omega\Delta t=0.5\) 到 \(1.99\) 全程 \(|z|_{\max}=0.9045<1\)；
只有 \(\gamma\Delta t=0\) 时才是 \(|z|=1\) 的**临界**稳定。所以有阻尼时反而更稳。

实践中仍取 \(\omega_N\Delta t\ll 1\)，但理由是**精度**而非稳定性：中心差分的相位误差随
\(\omega\Delta t\) 增长（见第 6.4 节），\(\omega\Delta t\) 越接近 1 频率失真越大。

### 6.3 方法 C：状态空间 + 四阶龙格-库塔

把每个模态写成状态向量：

\[
\mathbf z_n=
\begin{bmatrix}
q_n\\
\dot q_n
\end{bmatrix}
\]

则

\[
\dot{\mathbf z}_n
=
\begin{bmatrix}
0 & 1\\
-\omega_n^2 & -2\gamma
\end{bmatrix}
\mathbf z_n
+
\begin{bmatrix}
0\\
F_n(t)/M_n
\end{bmatrix}
\]

用 RK4 步进。精度高，但计算量比方法 A/B 大。

### 6.4 方法 B 的相位误差

中心差分格式的数值频率 \(\tilde\omega\) 与真实 \(\omega\) 有偏差。无阻尼时把
\(q_n^k=e^{i\tilde\omega k\Delta t}\) 代入更新式
\(q^{k+1}+(\omega^2\Delta t^2-2)q^k+q^{k-1}=0\)，得数值色散关系

\[
2\cos(\tilde\omega\Delta t)=\bigl(2-\omega^2\Delta t^2\bigr)
\;\Longrightarrow\;
\sin\!\left(\frac{\tilde\omega\Delta t}{2}\right)=\frac{\omega\Delta t}{2}
\]

于是

\[
\tilde\omega=\frac{2}{\Delta t}\arcsin\!\left(\frac{\omega\Delta t}{2}\right)
\]

小量展开：

\[
\tilde\omega
=\omega\left(1+\frac{\omega^2\Delta t^2}{24}+\cdots\right)
\]

即数值频率**偏高**（数值频散）。由
\(\Delta\tilde\omega/\omega=\omega^2\Delta t^2/24\)，要求偏差不超过
1 音分（\(1200\log_2(1+\epsilon)<1\Rightarrow\epsilon<5.78\times10^{-4}\)）：

\[
\frac{\omega_N^2\Delta t^2}{24}<5.78\times10^{-4}
\;\Longrightarrow\;
\omega_N\Delta t<0.118
\]

这比稳定性条件 \(\omega_N\Delta t<2\) 严格约 17 倍——**精度**才是实际取值时真正要满足的
约束，而不是稳定性。方法 A 是解析精确解，没有这一项误差。

---

## 7. 方法 A 完整算法流程

```text
输入：L, T, mu, gamma, N, y0(x), v0(x), f(x,t)
计算：c = sqrt(T/mu)
      omega[n] = n*pi*c/L, n=1..N
      M_n = mu*L/2
      omega_d[n] = sqrt(omega[n]^2 - gamma^2)

初始化：
  # 先由激励方式决定 q、qdot 的初值（见 4.3，两者只能选一）
  #   (a) 打击：q[n] = 0, qdot[n] = 0, 且 f(x,0) != 0
  #   (b) 拨弦：q[n] = (2/L)*integral(y0(x)*sin(n*pi*x/L)), qdot[n] = 0, 且 f == 0
  # 初始速度同理： qdot[n] = (2/L)*integral(v0(x)*sin(n*pi*x/L))

  # 关键：方法 A 的积分变量是 u，不是 q。u 的初值必须由 q 反推：
  #   u = q - g/omega^2
  # 打击情形 q=0，于是 u[n](0) = -g_n(0)/omega[n]^2，即 u 初值非零而弦是静止的。
  # 若直接把 q 的初值赋给 u，等效于多加了一份静态力位移。
  g0[n] = Fn[n](0) / M_n
  u[n]     = q[n] - g0[n]/omega[n]^2
  u_dot[n] = qdot[n]

预计算方法A系数（只依赖 dt 与 omega，固定采样率下算一次）：
  E[n] = exp(-gamma*dt)
  C[n] = cos(omega_d[n]*dt)
  S[n] = sin(omega_d[n]*dt)

时间步进 k=0,1,2,...:
  1. 计算模态力：
     Fn[n] = integral(f(x,t_k)*sin(n*pi*x/L))
     或点力：Fn[n] = F(t_k)*sin(n*pi*x_f/L)
  2. 对每个 n：
     g = Fn[n]/M_n
     更新（u 是积分变量）：
       u_new     = E[n]*(u*C[n] + (u_dot+gamma*u)/omega_d[n]*S[n])
       u_dot_new = E[n]*(u_dot*C[n] - (omega[n]^2*u+gamma*u_dot)/omega_d[n]*S[n])
     u     = u_new
     u_dot = u_dot_new
     # 还原 q，用的是本步的同一个 g（力在该步内取常数，见 6.1）
     q[n]     = u + g/omega[n]^2
     qdot[n]  = u_dot
  3. 输出：
     位移 y(x,t) = sum_n q[n]*sin(n*pi*x/L)
     琴桥力 F_b(t) = T * sum_n q[n]*(n*pi/L)*(-1)^n
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
| 非线性 | 困难：模态会耦合，不再独立 | 自然处理，如张力随位移变化、琴槌非线性接触 |
| 非均匀弦 | 需数值求模态，或分区模态 | 直接设置每点 \(\mu(x),T(x)\) 即可 |
| 复杂边界 | 简单边界有解析模态；复杂边界用有限元模态 | 容易处理复杂几何和边界 |
| 外力 | 可加广义力 \(Q_n(t)\)，适合拨、击、琴桥反馈 | 可直接在空间点施加力 |
| 实时性 | 非常适合实时音频合成 | 通常较慢，除非网格很粗或 GPU 加速 |
| 适用场景 | 线性阻尼，线性张力 | 非线性情况、复杂边界结构 |

