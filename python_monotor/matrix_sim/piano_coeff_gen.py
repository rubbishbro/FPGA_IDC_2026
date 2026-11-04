import sys
from pathlib import Path
# Optional dependencies live in <repo>/_libs; matrix_sim is two levels below the repo root.
if __package__ in (None, ""):
    _HERE = Path(__file__).resolve().parent
    sys.path.insert(0, str(_HERE.parents[1] / "_libs"))
    sys.path.insert(0, str(_HERE))

import numpy as np

_OMEGA_D_FLOOR = 1e-5      # keeps an overdamped omega_d off a 0/0

GAMMA_KEY = (0,0,0,0,0,0,0,0,0,0,0,
            1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,
            2,2,2,2,2,2,2,2,2,2,2,2,2,2,2)

# 三十二模态足够，听感几乎无差异
GAMMA_SLOW_32 = (
    # MIDI 36-50   (150 partials, 32 indices)
    (0.3837, 0.3837, 0.2884, 0.2473, 0.2556, 0.3835, 0.3835, 0.4335, 0.4335, 0.5007,
     0.5169, 0.4817, 0.5901, 0.6770, 0.6407, 0.7280, 0.9257, 1.0190, 1.2820, 1.2790,
     1.3470, 1.2940, 1.1590, 0.9567, 0.9543, 1.0420, 1.1160, 1.0260, 0.7887, 0.4765,
     0.3512, 0.2736),
    # MIDI 51-65   (107 partials, 32 indices)
    (1.0800, 1.0800, 0.7359, 0.5668, 0.4673, 0.5466, 0.5466, 0.7449, 0.8121, 0.9258,
     0.9878, 1.2630, 1.3010, 1.0650, 0.8856, 0.7599, 0.8285, 0.9299, 0.9211, 0.9211,
     1.0170, 1.0170, 1.0170, 1.0480, 1.0480, 1.0480, 1.1520, 1.1520, 1.1520, 1.1520,
     1.1520, 1.5180),
    # MIDI 66-80   (72 partials, 32 indices, 0 padding)
    (1.4550, 1.4550, 1.6800, 2.3040, 2.2100, 2.1140, 2.0450, 2.0980, 1.9540, 1.7290,
     1.9160, 2.2040, 1.4260, 1.2610, 1.2610, 1.2610, 1.1950, 1.1950, 1.1950, 1.1950,
     1.1950, 1.1950, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000, 0.0000,
     0.0000, 0.0000),
)

OCTAVE_KEY = (33, 45, 57, 69, 81)
OCTAVE_STRETCH = (-4.245724, -2.447415, -1.170808, 0.0, 3.146409)

INHARMONICITY_1024X = (0.173804,0.169186,0.165751,0.163488,0.162397,0.162487,0.163774,0.166284,
                    0.170053,0.175125,0.181557,0.189414,0.198773,0.209725,0.222371,0.236829,
                    0.253230,0.271720,0.292466,0.315651,0.341479,0.370177,0.401996,0.437213,
                    0.476133,0.519096,0.566472,0.618671,0.676145,0.739388,0.808946,0.885418,
                    0.969463,1.061803,1.163232,1.274624,1.396934,1.531214,1.678617,1.840410,2.017981,)

POS_A0, POS_SLOPE = 0.155, 0.00364

DELTA_T = float(1/48000)

def piano_f0(midi: int):
    equal = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    cents = float(np.interp(midi, OCTAVE_KEY, OCTAVE_STRETCH))
    return float(equal * 2.0 ** (cents / 1200.0))


#     qn = a11·q + a12·v + gq·x
#     vn = a21·q + a22·v + gv·x
#     y = wo·q
def gen_coeff7(mode_num: int, f0: float, inharmonicity: float,
               strike_pos: float, amp: float, gamma: 'np.ndarray') :
    n = np.arange(1, mode_num + 1, dtype=float)
    f_n = n * f0 * np.sqrt(1.0 + inharmonicity * n * n)
    omega0 = 2.0 * np.pi * f_n
    omega0_sq = omega0 ** 2
    # static_weight is K_n/omega_n^2 with the gauge factor 2/(mu L) folded away
    static_weight = (np.sin(np.pi * n * strike_pos) * amp / omega0_sq)
    # and 8 f0^2 carries T/(mu L^2) = 4 f0^2 together with the absorbed 2
    sum_weight = n * ((-1.0) ** n) * 8.0 * f0 ** 2
    
    damped_omega = np.sqrt(np.clip(omega0_sq - gamma ** 2, _OMEGA_D_FLOOR, None))
    
    decay = np.exp(-gamma * DELTA_T)
    ec = decay * np.cos(damped_omega * DELTA_T)
    es = decay * np.sin(damped_omega * DELTA_T)
    
    #完整系数预计算式
    #  a21 必须是**负**的：这是回复力项（sim_piano.py::sim_step 里是
    #  `ec*q_dot - es*(omega0_sq*q + g*q_dot)/wd`）。写成正号时 2x2 矩阵的
    #  特征值变成实数 |lambda| = 1.0107 / 0.9892 -> 发散，状态单调爬升（直流），
    #  听感就是"没激励起来"。改回负号后 |lambda| = 0.99999，正常衰减振荡。
    a11 = ec + gamma * es / damped_omega
    a12 = es * omega0 / damped_omega
    a21 = -es * omega0 / damped_omega
    a22 = ec - gamma * es / damped_omega
    
    gq = static_weight * (1 - ec - gamma * es / damped_omega)
    gv = static_weight * ((1 - ec) * gamma + omega0_sq * es / damped_omega)
    
    sq = np.ones(mode_num)
    fin_mode_cnt = 0 
    #找到合适的缩放系数
    while fin_mode_cnt < mode_num:
        fin_mode_cnt = 0 
        for i in range(0,mode_num):
            if sq[i] <= np.abs(sum_weight[i]):
                sq[i] *= 2
            elif sq[i] >= 1/np.abs(gq[i]) or sq[i] >= omega0[i]/np.abs(gv[i]): 
                sq[i] /= 2
            else:
                fin_mode_cnt += 1
            
    
    sv = sq / omega0
    
    gq = gq * sq
    gv = gv * sv
    
    wo = sum_weight / sq
    
    return (a11, a12, a21, a22, gq, gv, wo)
    

def print_piano_coeff_by_midi(midi: int):
    assert 40 <= midi and midi <= 80
        
    f0 = piano_f0(midi)
    inharmonicity = INHARMONICITY_1024X[midi-40]/1024
    gamma = np.asarray(GAMMA_SLOW_32[GAMMA_KEY[midi-40]])
    mode_num = gamma.size
    
    strike_pos = POS_A0 * np.exp(-POS_SLOPE * (midi - 21.0))
    beat_hz = f0 * 0.0005777895 # f0 * 2 ** (1/1200) - 1
    
    (ma11, ma12, ma21, ma22, mgq, mgv, mwo) = gen_coeff7(mode_num, f0+beat_hz, inharmonicity,
                                                         strike_pos, 0.3, gamma)
    (a11, a12, a21, a22, gq, gv, wo) = gen_coeff7(mode_num, f0, inharmonicity, strike_pos, 0.7, gamma)
    
    for i in range(0,mode_num):
        print(f"mode{i*2}:{ma11[i]},{ma12[i]},{ma21[i]},{ma22[i]},{mgq[i]},{mgv[i]},{mwo[i]}")
        print(f"mode{i*2+1}:{a11[i]},{a12[i]},{a21[i]},{a22[i]},{gq[i]},{gv[i]},{wo[i]}")
    



if __name__ == "__main__":
    with open(_HERE / 'piano_coeff_scaled.txt', 'w', encoding='utf-8') as file:
        sys.stdout = file
        for midi in range(40,80):
            print(f"midi{midi}")
            print_piano_coeff_by_midi(midi)
            print(end="\n")