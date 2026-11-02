"""Integer sample reference for parts/trumpet_excitation.sv; no rendering entry.

The dyadic triangles/noise are an approximation of the earlier float experiment.
RTL equivalence has not been simulated for this implementation.
"""
from pathlib import Path
from functools import lru_cache
import json
import numpy as np

ROOT = Path(__file__).resolve().parents[2]


@lru_cache(None)
def configs():
    data = json.loads((ROOT/'rtl/router/tools/performance/trumpet_excitation.json').read_text())
    return {r['period']: r for r in data['entries']}


def fade_shift(value):
    for shift, threshold in enumerate([32768, 16384, 8192, 4096, 2048, 1024, 512]):
        if value >= threshold:
            return shift
    return 15


def scale_small(unit, draw):
    magnitude = abs(draw)
    value = (unit if magnitude & 1 else 0)+(unit << 1 if magnitude & 2 else 0)+(unit << 2 if magnitude & 4 else 0)
    return -value if draw < 0 else value


class TrumpetExcitation:
    REST, OPEN_UP, OPEN_DOWN, GAP, CLOSE_DOWN, CLOSE_UP = range(6)

    def __init__(self, periods):
        self.period = np.array(periods, dtype=np.int64)
        self.slots = len(periods)
        self.reset()

    def clear_slot(self, slot):
        for field in ['phase', 'rate', 'wave', 'slope', 'stage', 'remaining', 'half',
                      'close', 'gap', 'onset', 'air', 'lp', 'dc']:
            getattr(self, field)[slot] = 0
        self.rng[slot] = 0x5a34d1 ^ (slot+1)

    def reset(self):
        for field in ['phase', 'rate', 'wave', 'slope', 'stage', 'remaining', 'half',
                      'close', 'gap', 'onset', 'air', 'lp', 'dc', 'rng']:
            setattr(self, field, [0]*self.slots)
        self.previous_gate = np.zeros(self.slots, dtype=bool)
        for slot in range(self.slots):
            self.clear_slot(slot)

    def step(self, gate, level, trigger, clear, delta):
        result = np.zeros(self.slots, dtype=np.int64)
        for s in range(self.slots):
            period = int(self.period[s])
            cfg = configs().get(period)
            if clear[s] or not gate[s] or cfg is None:
                self.clear_slot(s)
                continue
            start = bool(trigger[s] or not self.previous_gate[s])
            onset_shift = 0 if start else fade_shift(self.onset[s])
            air_shift = 0 if start else fade_shift(self.air[s])
            random = self.rng[s]
            self.rng[s] = ((random << 1) & 0x7fffff) | (((random >> 22) ^ (random >> 17)) & 1)
            force = int(level[s]) << 16
            amp_draw = ((random >> 8) & 7)-((random >> 11) & 7)
            air_draw = ((random >> 14) & 7)-((random >> 17) & 7)
            amp_unit = 0 if onset_shift == 15 else ((force >> 6)+(force >> 7)) >> onset_shift
            perturbed = force+scale_small(amp_unit, amp_draw)
            slope = sum((-1 if negative else 1)*(perturbed >> shift)
                        for shift, negative in zip(cfg['shifts'], cfg['negative']))
            air_unit = (force >> cfg['air_shift'])+(0 if air_shift == 15 else
                        ((force >> (cfg['air_shift']-3)) >> air_shift))
            white = scale_small(air_unit, air_draw)
            if start:
                self.lp[s], self.dc[s] = white >> 1, 0
            else:
                old_lp = self.lp[s]
                self.lp[s] += (white-old_lp) >> 1
                self.dc[s] += (old_lp-self.dc[s]) >> 4
            old_onset, old_air = self.onset[s], self.air[s]
            self.onset[s] = 65535 if start else max(0, old_onset-((old_onset+2047) >> 11)-((old_onset+4095) >> 12))
            self.air[s] = 65535 if start else max(0, old_air-((old_air+2047) >> 11)-((old_air+32767) >> 15))
            total = self.phase[s]+(1 << 24)+int(delta[s])+self.rate[s]
            if start or total >= period << 24:
                self.phase[s] = 0 if start else total-(period << 24)
                draw = (random & 15)-((random >> 4) & 15)
                self.rate[s] = 0 if onset_shift == 15 else (draw << 14) >> onset_shift
                self.slope[s] = self.wave[s] = slope
                self.half[s] = 1 << cfg['half_shift']
                self.close[s] = self.half[s] >> 2
                self.gap[s] = cfg['gap']
                self.stage[s], self.remaining[s] = self.OPEN_UP, self.half[s]-1
            else:
                self.phase[s] = total
                stage = self.stage[s]
                if stage == self.OPEN_UP:
                    self.wave[s] += self.slope[s]
                    self.remaining[s] -= 1
                    if self.remaining[s] == 0:
                        self.stage[s], self.remaining[s] = self.OPEN_DOWN, self.half[s]
                elif stage == self.OPEN_DOWN:
                    self.wave[s] -= self.slope[s]
                    self.remaining[s] -= 1
                    if self.remaining[s] == 0:
                        self.stage[s], self.remaining[s] = self.GAP, self.gap[s]
                elif stage == self.GAP:
                    self.wave[s] = 0
                    self.remaining[s] -= 1
                    if self.remaining[s] == 0:
                        self.stage[s], self.remaining[s] = self.CLOSE_DOWN, self.close[s]
                elif stage == self.CLOSE_DOWN:
                    self.wave[s] -= self.slope[s] << 4
                    self.remaining[s] -= 1
                    if self.remaining[s] == 0:
                        self.stage[s], self.remaining[s] = self.CLOSE_UP, self.close[s]
                elif stage == self.CLOSE_UP:
                    self.wave[s] += self.slope[s] << 4
                    self.remaining[s] -= 1
                    if self.remaining[s] == 0:
                        self.stage[s] = self.REST
                else:
                    self.wave[s] = 0
            value = self.wave[s]+self.lp[s]-self.dc[s]
            result[s] = min((1 << 31)-1, max(-(1 << 31), value))
        self.previous_gate[:] = gate
        return result
