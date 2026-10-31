# sustain_q24 coefficient format

This directory contains **Q2.24 a1** resources for the current eng1.
Older Q2.20 B images must be regenerated before use. Q2.24 images
without P1T1 metadata play unmodulated and reject pitch controls.

Record: 64 bytes per mode, 16 big-endian 32-bit words;
64 modes per note = 4096 bytes per note.

| word | field | format |
|---:|---|---|
| 0 | G | Q2.24 signed 26, sign-extended to 32 |
| 1 | a1 | **Q2.24 signed 26**, sign-extended to 32 |
| 2 | a2 | UQ0.24 unsigned 24 |
| 3..7 | reserved | zero |
| 8 | lower a1 bound | Q2.24 |
| 9 | nominal a1 | Q2.24 |
| 10 | upper a1 bound | Q2.24 |
| 11..12 | reserved | zero |
| 13 | K = 2r theta sin(theta) | signed25 Q3.22 |
| 14 | reserved | zero |
| 15 | pitch metadata identity | 0x50315431 (P1T1) |

The a1 26-bit value is stored in the low bits of word 1; bits
[31:26] are the sign extension of bit 25. The current eng1 reads
`a12[25:0]` directly, with no left shift.

G is re-calibrated from the Q2.24-quantised poles:
`r = sqrt(a2q/2^24)`, `theta = acos(-a1q/(2r))`, `G = w/A_unit`.

First record example (flute MIDI36):
```
G  = 0x00000C6D
a1 = 0xFE001DEF
a2 = 0x00FFE6DF
```

Files:
- `sustain_q24.npz` — signed arrays, padded to 64 modes
- `sustain_profiles_q24.json` — manifest with `a1_format: Q2.24`
- `sustain_flash_q24.bin/.mem` — 6-region flash image
- `q24_check.csv` — per-entry static pitch error, Q2.20 vs Q2.24
