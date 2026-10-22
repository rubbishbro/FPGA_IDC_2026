import math

FS = 48000
N = 288000  # 6 s, same size as the old demo ROM

# Ode to Joy, first phrase. Frequencies in Hz, durations in seconds.
E4, F4, G4, D4, C4 = 329.63, 349.23, 392.00, 293.66, 261.63
notes = [
    (E4, 0.4), (E4, 0.4), (F4, 0.4), (G4, 0.4),
    (G4, 0.4), (F4, 0.4), (E4, 0.4), (D4, 0.4),
    (C4, 0.4), (C4, 0.4), (D4, 0.4), (E4, 0.4),
    (E4, 0.4), (D4, 0.8),
]

out = []
for f, dur in notes:
    n = int(dur * FS)
    for i in range(n):
        t = i / FS
        # simple ADSR: 20 ms attack, 80 ms decay to 0.65, release 80 ms
        if t < 0.02:
            env = t / 0.02
        elif t < 0.10:
            env = 1.0 - 0.35 * (t - 0.02) / 0.08
        else:
            env = 0.65
        rel = min(0.08, dur * 0.25)
        if t > dur - rel:
            env *= max(0.0, (dur - t) / rel)
        # harmonic-rich tone so the spectrum/waterfall has visible structure
        s = (1.00 * math.sin(2 * math.pi * f * t)
             + 0.30 * math.sin(2 * math.pi * 2 * f * t + 0.3)
             + 0.15 * math.sin(2 * math.pi * 3 * f * t + 0.7)
             + 0.08 * math.sin(2 * math.pi * 4 * f * t + 1.1))
        v = int(9000 * env * s)
        v = max(-32768, min(32767, v))
        out.append(v)

out = out[:N]
out += [0] * (N - len(out))

with open(r'D:\FPGA_IDC_2026\lcd_draw_learn\ode_to_joy.mem', 'w') as f:
    f.write('\n'.join(f'{v & 0xffff:04x}' for v in out) + '\n')

with open(r'D:\FPGA_IDC_2026\lcd_draw_learn\sim\ode_to_joy.mem', 'w') as f:
    f.write('\n'.join(f'{v & 0xffff:04x}' for v in out) + '\n')

print('samples', len(out), 'min/max', min(out), max(out))
