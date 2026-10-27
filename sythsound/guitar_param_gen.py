import sys
from pathlib import Path
# Dependencies live in <repo>/_libs (sibling of sythsound/), and this file sits in
# sythsound/, so both the repo root and _libs are one level up.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parent / "_libs"))
    sys.path.insert(0, str(_HERE))

import numpy as np

_OMEGA_D_FLOOR = 1e-5      # keeps an overdamped omega_d off a 0/0
DELTA_T = float(1/48000)


#     qn = a11·q + a12·v + gq·x (pluck)
#     vn = a21·q + a22·v + 0·x
#     y = wo·q
def gen_coeff7(f0: float, TLr: float, gamma: np.ndarray, mode_num: int, pos: float):
    P = np.arange(1, mode_num + 1, 1.0) * np.pi
    omega0_sq = (f0 * 2 * P) ** 2
    damped_omega = np.sqrt(np.clip(omega0_sq -  gamma ** 2, _OMEGA_D_FLOOR, None))

    mode = np.arange(1,  mode_num + 1, 1.0)
    sum_weight = mode * ((-1.0) ** mode) * TLr

    decay = np.exp(- gamma * DELTA_T)
    ec = decay * np.cos(damped_omega * DELTA_T)
    es = decay * np.sin(damped_omega * DELTA_T)
    
    #完整系数预计算式
    a11 = ec + gamma * es / damped_omega
    a12 = es / damped_omega
    a21 = es * omega0_sq / damped_omega
    a22 = ec - gamma * es / damped_omega
    
    gq = 0.001 * np.sin(P * pos) / ((P**2) * pos * (1 - pos))
    gv = np.zeros(mode_num)
    
    wo = sum_weight
    
    return (a11, a12, a21, a22, gq, gv, wo)

def print_guitar_coeff_by_midi(midi: int):
    assert 40 <= midi and midi <= 80

    # Per-string damping, from a measured lookup table and a per-string scale
    DAMP_BIN_HZ = (93.96, 122.52, 159.75, 208.30, 271.60, 354.15,
                   461.78, 602.11, 785.10, 1023.70, 1334.82, 1740.49)
    # natural log of gamma in 1/s at each bin centre
    DAMP_BIN_LN_GAMMA = (0.2148, -0.6427, -0.0040, 0.5375, 0.2490, -0.1477,
                         0.5102, 0.6994, float("nan"), float("nan"), 0.4489, 1.1248)

    if midi < 45:
        midi0 = 40
        t = 115.7
        # mu = 0.010149
        damp_scale = 0.7904          # E2, wound
    elif midi < 50:
        midi0 = 45
        t = 133.4
        # mu = 0.006572
        damp_scale = 0.8145          # A2, wound
    elif midi < 55:
        midi0 = 50
        t = 133.4
        # mu = 0.003689
        damp_scale = 0.8793          # D3, wound
    elif midi < 59:
        midi0 = 55
        t = 133.4
        # mu = 0.002070
        damp_scale = 1.1734          # G3, wound
    elif midi < 64:
        midi0 = 59
        t = 102.3
        # mu = 0.001
        damp_scale = 1.3362          # B3, plain
    else:
        midi0 = 64
        t = 102.3
        # mu = 0.000561
        damp_scale = 1.3023          # E4, plain

    len = 0.6477*2**((midi0 - midi)/12)
    mode_N = 20

    # Interpolate in log frequency and hold the ends; the two NaN bins are skipped by keeping only
    # the finite entries, which is what makes the 688-1169 Hz stretch interpolated.
    _ln_hz = np.log(np.asarray(DAMP_BIN_HZ))
    _ln_g = np.asarray(DAMP_BIN_LN_GAMMA)
    _ok = np.isfinite(_ln_g)
    index = np.arange(1, mode_N + 1, 1)
    f0 = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    gamma = 1.3 * damp_scale * np.exp(np.interp(np.log(index * f0), _ln_hz[_ok], _ln_g[_ok]))

    (a11, a12, a21, a22, gq, gv, wo) = gen_coeff7(f0, float(t/len), gamma, mode_N, float(0.14/len))
        
    for i in range(0,mode_N):
        print(f"mode{i}:{a11[i]},{a12[i]},{a21[i]},{a22[i]},{gq[i]},{gv[i]},{wo[i]}")



if __name__ == "__main__":
    #todo：当前还是系数表生成代码
    with open(_HERE / 'guitar_param.txt', 'w', encoding='utf-8') as file:
        sys.stdout = file
        for midi in range(40,80):
            print(f"midi{midi}")
            print_guitar_coeff_by_midi(66)
            print(end="\n")
    