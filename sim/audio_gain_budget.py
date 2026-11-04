#!/usr/bin/env python3
"""Board I2S output gain budget, forward and reverse.

The board chain, with the exact fixed-point points:

  excitation x            Q24   (8-bit level << 16; full pressure 250 -> 0.977 Q24)
  eng1 per-mode resonator Q24   (G/a1/a2 Q2.24; ynew=(G*x-a1*y1-a2*y2+2^23)>>24;
                                 y_data = sum of up to 48 mode outputs, 64-bit)
  y_env = (y*emap)>>31    Q24   (emap is Q1.31, unity = 0x7fffffff)
  y_acc = sum(16 voices)  Q24   (no extra scaling)
  body biquad             Q24   (Q4.27 coefficients; piano 40Hz HP + 2kHz +3dB shelf,
                                 guitar 5 sections, trumpet/violin passthrough)
  reverb NONE             Q24   (gd=1.0, gw=0, 6-clock delay; bit-exact passthrough)
  stereo_spatializer      Q42   (Q12 gain 4096/4096 (unity) at center, Q6 fractional ITD)
  PCM16                   >> (27 + h) with round-half-up
  i2s_amp_tx              16-bit MSB-first in a 32-bit slot, 1-bit I2S delay

So at the pins:

  pcm_centered = (y_q24 * 4096 * 64 + 2**(26+h)) >> (27+h)
  pcm_mono     = (y_q24 + 2**(8+h)) >> (9+h)

and backwards, one PCM LSB is:

  y_q24 per LSB = 2**(27+h) / (4096*64) = 2**(27+h) / 262144
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
Q24 = 1 << 24
CENTER_GAIN_Q12 = 4096              # gain_lut(16)=256, Q12
ITD_Q6 = 64                         # spatializer keeps 6 extra fractional bits
SPATIAL_SCALE = CENTER_GAIN_Q12 * ITD_Q6   # 262144


def spatial_pcm16(y_q24: int, headroom: int) -> int:
    """Exact stereo_spatializer -> spatial_pcm16, center pan, ITD frac=0."""
    v = y_q24 * SPATIAL_SCALE
    p = (v + (1 << (26 + headroom))) >> (27 + headroom)
    return max(-32768, min(32767, p))


def mono_pcm16(y_q24: int, headroom: int) -> int:
    """Exact mono pcm16 path (STEREO_ENABLE=0), for comparison."""
    p = (y_q24 + (1 << (8 + headroom))) >> (9 + headroom)
    return max(-32768, min(32767, p))


def y_from_pcm(pcm: int, headroom: int) -> float:
    """Inverse of spatial_pcm16, returned in Q24 units (1.0 = Q24)."""
    return pcm * (1 << (27 + headroom)) / SPATIAL_SCALE / Q24


def pcm_from_q24(peak_q24: float, headroom: int) -> int:
    return spatial_pcm16(round(peak_q24 * Q24), headroom)


def dbfs(pcm: int) -> float:
    return 20.0 * math.log10(abs(pcm) / 32768.0) if pcm else -math.inf


def db_ratio(x: float) -> float:
    return 20.0 * math.log10(x) if x > 0 else -math.inf


def min_headroom(peak_q24: float) -> int:
    """Smallest integer h with no centered PCM16 clipping."""
    v = round(peak_q24 * Q24) * SPATIAL_SCALE
    for h in range(-8, 41):
        p = (v + (1 << (26 + h))) >> (27 + h)
        if p <= 32767:
            return h
    return 40


def load_audit() -> dict:
    path = ROOT / 'build/performance_flash_verify/peak_audit.json'
    if not path.is_file():
        return {}
    return json.loads(path.read_text())


def load_npy_stats(name: str) -> dict:
    path = ROOT / 'python_monotor/results/sim/eng1/pad_path_retest' / name / 'step_pressure_raw_q24.npy'
    if not path.is_file():
        return {}
    try:
        import numpy as np
    except ImportError:
        return {}
    x = np.asarray(np.load(path, mmap_mode='r')).ravel().astype('int64')
    peak = float(np.max(np.abs(x))) / Q24
    rms = float(np.sqrt(np.mean(x.astype('float64') ** 2))) / Q24
    return dict(peak=peak, rms=rms, n=int(x.size), path=str(path.relative_to(ROOT)))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--pcm', type=int, default=None,
                    help='measured 16-bit PCM at amp_din (signed), reverse it to Q24')
    ap.add_argument('--headroom', type=int, default=0,
                    help='PCM_HEADROOM_BITS currently in the bitstream (default 0)')
    args = ap.parse_args()

    h = args.headroom
    print('== fixed points ==')
    print(f'center gain         256/256 = {256/256:.6f} ({db_ratio(256/256):+.3f} dB)')
    print(f'spatializer scale   {SPATIAL_SCALE} (4096<<6)')
    print(f'Q24 unity           {Q24}')
    print(f'headroom h={h}      PCM shift {27+h} (stereo) / {9+h} (mono)')
    print(f'1 PCM LSB (stereo)  = {2**(27+h)/SPATIAL_SCALE:.1f} Q24 units')
    print(f'PCM full scale      = {(32767 << (27+h)) / SPATIAL_SCALE / Q24:.3f} x Q24 (centered)')
    print(f'Q24 unity note      = {spatial_pcm16(Q24, h)} PCM = {dbfs(spatial_pcm16(Q24, h)):+.2f} dBFS (centered)')
    print(f'Q24 unity note      = {mono_pcm16(Q24, h)} PCM = {dbfs(mono_pcm16(Q24, h)):+.2f} dBFS (mono)')

    print('\n== where the dB go for a 1.0 (Q24) note ==')
    print(f'  synth reference       0.00 dB')
    print(f'  center pan           {db_ratio(256/256):+.2f} dB')
    print(f'  PCM headroom h={h}    {-6.0206*h:+.2f} dB')
    print(f'  net                  {db_ratio(256/256) - 6.0206*h:+.2f} dBFS')

    print('\n== forward: measured raw Q24 -> centered PCM at the pins ==')
    audit = load_audit()
    rows = [(name, v['peak_q24'] / Q24) for name, v in audit.items()]
    for name in ('piano', 'guitar', 'trumpet', 'violin'):
        st = load_npy_stats(name)
        if st:
            rows.append((f'{name} single-note', st['peak']))
    if not rows:
        rows = [('unity', 1.0), ('trumpet npy', 1.284)]
    levels = (4, 3, 2, 1, 0)
    print(f"{'source':24s} {'peak':>7s} {'hmin':>4s} " +
          ' '.join(f'h={x:<13d}' for x in levels))
    for name, peak in rows:
        cells = []
        for hh in levels:
            p = pcm_from_q24(peak, hh)
            clip = '*' if abs(p) >= 32767 else ' '
            cells.append(f'{p:>6d}{clip} ({dbfs(p):+6.1f})')
        print(f'{name:24s} {peak:7.3f} {min_headroom(peak):4d} ' + ' '.join(cells))

    print('\n== reverse: measured PCM -> implied router y ==')
    samples = [args.pcm] if args.pcm is not None else [32767, 16384, 8192, 4096, 2048, 1024, 512]
    for p in samples:
        y = y_from_pcm(p, h)
        print(f'PCM {p:>6d} ({dbfs(p):+6.1f} dBFS) -> y = {y:8.3f} x Q24 '
              f'({y*Q24:12.0f} LSB); mono would be {p:8.1f}')


if __name__ == '__main__':
    main()
