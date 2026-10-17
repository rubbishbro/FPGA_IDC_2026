"""为 string_mode_step.sv 生成逐位对的黄金向量（钢琴与吉他共用同一模块）。

系数与测试点全部来自真实模型，而不是另行假设：

  * 钢琴：`_fpga_fixed_point.Ensemble`（它按 `sim_piano.StringSim` 自己读表）
  * 吉他：`sim_guitar.guitar_generator`（拨弦是初始条件 q += K_n，等价于输入项 gq=K_n、x=1）

定点约定（与 SV 模块逐位一致）：
  * 每个常量 = (尾数 mant, 移位 shift)，值 = mant * 2^-shift，尾数 CW 位有符号
  * 乘积四舍五入：((a*m) + 2^(s-1)) >>> s   （s=0 时不加偏置；>>> 为算术右移）
  * 三项在 64 位有符号累加器里相加，状态结果饱和到 32 位
  * 状态按每模态归一化：sq = 2^QF/peak_q，sv = 2^VF/peak_v
  * 输入 x 是整数：x = x_phys * 2^XF（XF 见包；v1 取 28）

输出文件（同目录）：golden_piano.txt / golden_guitar.txt
每个非注释行 20 个十进制数：
    a11 s11 a12 s12 a21 s21 a22 s22 gq sgq gv sgv wo swo q v x q_exp v_exp y_exp

Run: python _analysis/rtl_modal/gen_golden.py
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))                 # _analysis
sys.path.insert(0, str(REPO / "sythsound"))

import numpy as np                                              # noqa: E402
import soundfile as sf                                          # noqa: E402,F401
from synthlab.core import Context                                # noqa: E402

import _fpga_fixed_point as fp                                  # noqa: E402
import _piano_model as pm                                       # noqa: E402
import sim_guitar as guitar                                     # noqa: E402

SR = 48000
CW = 24          # 系数尾数位（与 modal_step_pkg::CW 一致）
XF = 28          # 激励小数位（与 modal_step_pkg::XF 一致）
QF = 24          # 状态名义小数位（每模态再按峰值归一化）
YF = 40          # 输出共同指数（bank 级；本测试逐模态取同一值）
NOTES = (40, 55)          # 低音与中音各取一个
N_MODES = 4               # 每音取前 4 个模态
N_STEPS = 4800            # 参考跑的步数（0.1 s）


def quant(c):
    """(mant, shift)：值 = mant * 2^-shift，CW 位**有符号**，即 |mant| <= 2^(CW-1)-1。

    注意不能直接用 fp.quant(c, CW)：它把幅值占满 CW 位（|mant| ∈ [2^(CW-1), 2^CW)），
    最高位会被 24 位有符号端口当成符号位 —— 第一版就是这样把 16776243 变成 -973 的。
    这里用 CW-1 位幅值（多留一位符号位），零值单独处理（否则 shift 会溢出 SW 位）。
    """
    v = float(c)
    if v == 0.0:
        return 0, 0
    m, s = fp.quant(np.asarray([v]), CW - 1)
    m, s = int(m[0]), int(s[0])
    assert 0 <= s <= 63, f"shift {s} does not fit SW=6 bits (coefficient {v:g})"
    assert abs(m) < (1 << (CW - 1)), f"mantissa {m} does not fit CW signed"
    return m, s


def mac(a, m, s):
    """((a*m) + 2^(s-1)) >>> s —— 与 SV 的 term() 逐位一致。"""
    p = int(a) * int(m)
    if s > 0:
        p += 1 << (s - 1)
    return p >> s


def sat32(v):
    return max(-(1 << 31), min((1 << 31) - 1, int(v)))


def piano_modes(midi):
    """钢琴：直接问 fp.Ensemble 要 (a11..b2, wout)（它读的是 sim_piano 自己的表）。"""
    fp.N = N_STEPS
    ens = fp.Ensemble((midi,))
    ens.float_run(fp.drive())                    # 只为填 peak_q / peak_v
    out = []
    for i in range(N_MODES):
        out.append(dict(a11=float(ens.a11[i]), a12=float(ens.a12[i]),
                        a21=float(ens.a21[i]), a22=float(ens.a22[i]),
                        b1=float(ens.b1[i]), b2=float(ens.b2[i]),
                        sw=float(ens.wout[i]),
                        pq=float(ens.peak_q[i]), pv=float(ens.peak_v[i]),
                        label=f"piano midi={midi} mode={i + 1}"))
    return out, fp.drive()


def guitar_modes(midi):
    """吉他：从 guitar_generator 拿 ec/es/omega0_sq/sum_weight，拼出同样的四项。

    吉他没有外力项：拨弦把 q += K_n 加上去，因此 gq = K_n、gv = 0、x 为触发（1.0）。
    """
    g = guitar.guitar_generator(midi)
    ctx = Context(sr=SR)
    g.reset(ctx)
    n = np.arange(1, g.mode_num + 1, dtype=float)
    P = g.P
    kick = 0.001 * np.sin(P * g.pos) / ((P ** 2) * g.pos * (1.0 - g.pos))
    out = []
    for i in range(N_MODES):
        wd, ec, es, w0sq, gm = (float(g.damped_omega[i]), float(g.ec[i]),
                                float(g.es[i]), float(g.omega0_sq[i]),
                                float(g.gamma[i]))
        inv = 1.0 / wd
        out.append(dict(a11=ec + gm * es * inv, a12=es * inv,
                        a21=-w0sq * es * inv, a22=ec - gm * es * inv,
                        b1=float(kick[i]), b2=0.0, sw=float(g.sum_weight[i]),
                        pq=None, pv=None, label=f"guitar midi={midi} mode={i + 1}"))
    # 触发序列：第 0 步 x=1（对应模型里 process() 的那次 q += K_n），其余为 0
    x = np.zeros(N_STEPS)
    x[0] = 1.0
    return out, x


def run_float(modes, x):
    """用与模型相同的递推跑一遍，返回每模态的 (q,v) 轨迹与峰值。"""
    N = x.size
    out = []
    for m in modes:
        q = np.zeros(N)
        v = np.zeros(N)
        qq = vv = 0.0
        for k in range(N):
            q[k], v[k] = qq, vv
            qn = m["a11"] * qq + m["a12"] * vv + m["b1"] * x[k]
            vn = m["a21"] * qq + m["a22"] * vv + m["b2"] * x[k]
            qq, vv = qn, vn
        out.append(dict(q=q, v=v, pq=max(np.max(np.abs(q)), 1e-30),
                        pv=max(np.max(np.abs(v)), 1e-30)))
    return out


def emit(path, modes, x, traj):
    saturated = 0
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# string_mode_step golden vectors\n")
        fh.write(f"# CW={CW} XF={XF} QF={QF} YF={YF} steps={x.size}\n")
        fh.write("# a11 s11 a12 s12 a21 s21 a22 s22 gq sgq gv sgv wo swo q v x "
                 "q_exp v_exp y_exp\n")
        cases = 0
        for m, tr in zip(modes, traj):
            sq = (2.0 ** QF) / max(m["pq"] if m["pq"] else tr["pq"], 1e-30)
            sv = (2.0 ** QF) / max(m["pv"] if m["pv"] else tr["pv"], 1e-30)
            c = {
                "a11": quant(m["a11"]),
                "a12": quant(m["a12"] * sq / sv),
                "a21": quant(m["a21"] * sv / sq),
                "a22": quant(m["a22"]),
                "gq":  quant(m["b1"] * sq / 2.0 ** XF),
                "gv":  quant(m["b2"] * sv / 2.0 ** XF),
                "wo":  quant(m["sw"] * 2.0 ** YF / sq),
            }
            fh.write(f"# {m['label']}: float a11={m['a11']:.9f} a12={m['a12']:.3e} "
                     f"a21={m['a21']:.6g} a22={m['a22']:.9f} b1={m['b1']:.3e} "
                     f"b2={m['b2']:.3e} sw={m['sw']:.6g}\n")
            fh.write(f"#   sq={sq:.6e} sv={sv:.6e} (state scale)\n")
            # 测试点：激励峰值处（真实运行状态）、从静止受一次激励、以及 0.02/0.06 s 的自由衰减
            kmax = int(np.argmax(np.abs(x)))
            pts = [(kmax, float(tr["q"][kmax]), float(tr["v"][kmax]), float(x[kmax])),
                   (None, 0.0, 0.0, float(x[kmax])),
                   (int(0.02 * SR), float(tr["q"][int(0.02 * SR)]),
                    float(tr["v"][int(0.02 * SR)]), 0.0),
                   (int(0.06 * SR), float(tr["q"][int(0.06 * SR)]),
                    float(tr["v"][int(0.06 * SR)]), 0.0)]
            for k, qf_, vf_, xf_ in pts:
                q = int(round(qf_ * sq))
                v = int(round(vf_ * sv))
                xi = int(round(xf_ * 2.0 ** XF))
                qf = mac(q, *c["a11"]) + mac(v, *c["a12"]) + mac(xi, *c["gq"])
                vf = mac(q, *c["a21"]) + mac(v, *c["a22"]) + mac(xi, *c["gv"])
                ye = mac(q, *c["wo"])
                if qf != sat32(qf) or vf != sat32(vf):
                    saturated += 1
                fh.write(" ".join(str(t) for t in (
                    c["a11"][0], c["a11"][1], c["a12"][0], c["a12"][1],
                    c["a21"][0], c["a21"][1], c["a22"][0], c["a22"][1],
                    c["gq"][0], c["gq"][1], c["gv"][0], c["gv"][1],
                    c["wo"][0], c["wo"][1], q, v, xi, sat32(qf), sat32(vf), ye)) + "\n")
                cases += 1
        print(f"wrote {path.name}: {cases} cases, "
              f"{saturated} saturating (should be 0 with per-mode normalisation)")


def coeff_fields(c):
    """把 7 个 (mant, shift) 摊平成 14 个整数，顺序与 SV 的 coeff_t 字段一致。"""
    out = []
    for key in ("a11", "a12", "a21", "a22", "gq", "gv", "wo"):
        out.append(c[key][0])
        out.append(c[key][1])
    return out


def emit_seq(path, modes, traj, x_seq, n_modes, n_samples):
    """整段作业的黄金向量：纯整数流（前两个是 n_modes / n_samples）。

    布局：
        n_modes n_samples
        <14 个整数> × n_modes     系数字段 a11 s11 a12 s12 ... wo swo
        <n_samples 个整数>        激励序列（已是整数：x * 2^XF）
        <n_samples 个整数>        每采样的 Σ wo·q（结果 RAM 的内容）
        <2 个整数> × n_modes      末态 q / q'
    """
    sq_of = [2.0 ** QF / max(m["pq"] if m["pq"] else t["pq"], 1e-30)
             for m, t in zip(modes, traj)]
    sv_of = [2.0 ** QF / max(m["pv"] if m["pv"] else t["pv"], 1e-30)
             for m, t in zip(modes, traj)]
    coeffs = []
    for m, sq, sv in zip(modes, sq_of, sv_of):
        coeffs.append({
            "a11": quant(m["a11"]),
            "a12": quant(m["a12"] * sq / sv),
            "a21": quant(m["a21"] * sv / sq),
            "a22": quant(m["a22"]),
            "gq":  quant(m["b1"] * sq / 2.0 ** XF),
            "gv":  quant(m["b2"] * sv / 2.0 ** XF),
            "wo":  quant(m["sw"] * 2.0 ** YF / sq),
        })

    # 与硬件逐位相同的整数递推（先算 qn/vn/y，再写回；y 用更新前的 q）
    q = [0] * len(modes)
    v = [0] * len(modes)
    ys = []
    for xf in x_seq:
        xi = int(round(xf * 2.0 ** XF))
        ysum = 0
        for i, c in enumerate(coeffs):
            qn = mac(q[i], *c["a11"]) + mac(v[i], *c["a12"]) + mac(xi, *c["gq"])
            vn = mac(q[i], *c["a21"]) + mac(v[i], *c["a22"]) + mac(xi, *c["gv"])
            y  = mac(q[i], *c["wo"])
            ysum += y
            q[i] = sat32(qn)
            v[i] = sat32(vn)
        ys.append(ysum)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"{len(modes)} {len(x_seq)}\n")
        for c in coeffs:
            fh.write(" ".join(str(t) for t in coeff_fields(c)) + "\n")
        fh.write(" ".join(str(int(round(xf * 2.0 ** XF))) for xf in x_seq) + "\n")
        fh.write(" ".join(str(y) for y in ys) + "\n")
        for i in range(len(modes)):
            fh.write(f"{q[i]} {v[i]}\n")
    print(f"wrote {path.name}: {len(modes)} modes x {len(x_seq)} samples, "
          f"y range {min(ys)}..{max(ys)}")


def main():
    for notes, builder, tag in ((NOTES, piano_modes, "piano"),
                                (NOTES, guitar_modes, "guitar")):
        modes, x = [], None
        for midi in notes:
            ms, xx = builder(midi)
            modes += ms
            x = xx
        traj = run_float(modes, x)
        emit(HERE / f"golden_{tag}.txt", modes, x, traj)

    # 序列向量：只用 MIDI 40 的前 4 个模态，跑 48 个采样（钢琴 = 前 48 个激励样本，
    # 吉他 = 拨弦触发一次），用于验证 modal_bank_ram 的整段作业
    fp.N = 4800
    drive = fp.drive()
    kmax = int(np.argmax(np.abs(drive)))
    for notes, builder, tag, xseq in (
            ((40,), piano_modes, "piano", [float(t) for t in drive[:48]]),
            ((40,), guitar_modes, "guitar", [1.0] + [0.0] * 47)):
        modes, x = builder(notes[0])
        modes = modes[:4]
        traj = run_float(modes, xseq if isinstance(xseq, np.ndarray) else np.asarray(xseq))
        emit_seq(HERE / f"golden_seq_{tag}.txt", modes, traj, xseq, 4, len(xseq))

        # 单帧版本：与 golden_{tag}.txt 里"从静止受一次激励"同源，用于隔离"读路径"与
        # "多帧路径"。状态标度沿用上面 48 帧那次（不能另算一条退化轨迹，否则标度会爆）。
        emit_seq(HERE / f"golden_seq_{tag}_1.txt", modes, traj,
                 [float(drive[kmax])], 4, 1)


if __name__ == "__main__":
    main()
