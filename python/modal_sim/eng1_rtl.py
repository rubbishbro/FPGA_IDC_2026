"""Current production ENG1, at committed audio-frame boundaries.

Q24 input/state, 64 stored / 48 computed modes, four sustained instruments.
The DSP consumes accepted gate/level/retrigger/clear snapshots, not raw MIDI
bytes. PitchEngine separately models the core-clock pitch FSM. Loader/QSPI,
MIDI queues and audio FIFO/serializer clocks are outside this sample model.
Reverb uses full-width products and signed saturation, matching production RTL.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from collections import deque
import hashlib
import json
import math
import struct
from types import MappingProxyType

import numpy as np
import router_eng1 as R
import pitch_linear as P

ROOT = Path(__file__).resolve().parents[2]
INSTRUMENTS = {"flute": 2, "trumpet": 3, "cello": 4, "violin": 5}
STATE_FRAC = 24
STORAGE_MODES = 64
ACTIVE_MODES = 48


def _lanes(value, slots, dtype=np.int64):
    a = np.asarray(value, dtype=dtype)
    if a.ndim == 0:
        return np.full(slots, a, dtype=dtype)
    a = a.reshape(-1)
    if a.size != slots:
        raise ValueError(f"expected {slots} lanes, got {a.size}")
    return a.copy()


@dataclass(frozen=True)
class NoteResource:
    midi: int
    coeffs: R.Eng1Coeffs
    period: int
    a_step: int
    r_step: int
    pitch_words: np.ndarray

    @classmethod
    def decode(cls, midi, data, profile):
        if len(data) != 4096:
            raise ValueError("one production note is 64 records of 64 bytes")
        if hashlib.sha256(data).hexdigest() != profile['coeff_sha256']:
            raise ValueError("coefficient/profile hash mismatch")
        w = np.array(struct.unpack('>1024i', data), dtype=np.int64).reshape(64, 16)
        if not 2 <= profile['period'] <= 65535 or not all(
                0 < profile[k] <= 0x7fffffff for k in ['a_step', 'r_step']):
            raise ValueError("invalid sustain profile")
        if not 0 < profile['modes'] <= ACTIVE_MODES:
            raise ValueError("production ENG1 computes at most 48 modes")
        if np.any(w[48:, :3]):
            raise ValueError("nonzero coefficients outside production active modes")
        co = R.Eng1Coeffs(w[:, 0], w[:, 1], w[:, 2], profile['modes'],
                          label=f"{profile['name']}:{midi}")
        w.setflags(write=False)
        for field in (co.G, co.a1, co.a2):
            field.setflags(write=False)
        return cls(midi, co, profile['period'], profile['a_step'], profile['r_step'], w[:, 8:16])


class ResourceBank:
    """Immutable note resources decoded from the actual production byte layout."""
    def __init__(self, instrument, notes, sample_rate=48000):
        if instrument not in INSTRUMENTS:
            raise ValueError("only flute/trumpet/cello/violin have production ENG1 front ends")
        self.instrument, self.notes, self.sample_rate = instrument, MappingProxyType(dict(notes)), int(sample_rate)

    @classmethod
    def from_directory(cls, directory, instrument):
        if instrument not in INSTRUMENTS:
            raise ValueError("only four sustained instruments have production ENG1 resources")
        directory = Path(directory)
        m = json.loads((directory/'manifest.json').read_text())
        if (m.get('a1_format'), m.get('storage_modes'), m.get('active_modes_limit')) != ('Q2.24', 64, 48):
            raise ValueError("expected current Q2.24 / 64-storage / 48-active resources")
        data = (directory/'sustain_flash.bin').read_bytes()
        region_bytes = m['notes'] * 4096
        inst = INSTRUMENTS[instrument]
        notes = {}
        for e in m['entries']:
            if e['instrument'] != inst:
                continue
            off = inst*region_bytes+(e['midi']-m['first_midi'])*4096
            notes[e['midi']] = NoteResource.decode(e['midi'], data[off:off+4096], e)
        if not notes:
            raise ValueError("instrument missing from resource manifest")
        return cls(instrument, notes, m['resource_fs'])

    @classmethod
    def build(cls, instrument, notes):
        if instrument not in INSTRUMENTS:
            raise ValueError("only four sustained instruments have production ENG1 resources")
        # Use the same exported bytes/profile identity as the production packer.
        import sys
        tools_path = str(ROOT/'rtl/router/tools')
        if tools_path not in sys.path:
            sys.path.insert(0, tools_path)
        import sustain_resources as S
        decoded = {}
        for midi in notes:
            row = S.make_note(instrument, int(midi), True)
            if row is None:
                raise ValueError(f"no usable production resource for {instrument} MIDI{midi}")
            decoded[int(midi)] = NoteResource.decode(int(midi), row['data'], row)
        return cls(instrument, decoded)


class Excitation:
    """excitation_gen SUSTAIN_ENABLE branch; one call is one clk_en edge."""
    def __init__(self, periods):
        self.period = np.array(periods, dtype=np.int64)
        self.slots = len(periods)
        self.reset()

    def reset(self):
        self.phase = np.zeros(self.slots, dtype=np.int64)
        self.previous_gate = np.zeros(self.slots, dtype=bool)

    def step(self, gate, level, trigger, clear, delta):
        x = np.zeros(self.slots, dtype=np.int64)
        for i in range(self.slots):
            if clear[i] or not gate[i] or self.period[i] < 2:
                self.phase[i] = 0
            elif trigger[i] or not self.previous_gate[i]:
                self.phase[i] = 0
                x[i] = R.wrap_signed(int(level[i]) << 16, 32)
            else:
                total = int(self.phase[i]) + (1 << 24) + int(delta[i])
                threshold = int(self.period[i]) << 24
                if total >= threshold:
                    total -= threshold
                    x[i] = R.wrap_signed(int(level[i]) << 16, 32)
                self.phase[i] = total & ((1 << 40)-1)
        self.previous_gate[:] = gate
        return x


class Envelope:
    """Current B-class envelope_ADSR, including explicit dead and retrigger."""
    IDLE, ATTACK, DECAY, SUSTAIN, RELEASE = range(5)

    def __init__(self, attack, release, *, sustain_level=0x1fffffff, decay_step=1048576):
        self.attack, self.release = np.array(attack), np.array(release)
        self.sustain_level,self.decay_step=int(sustain_level),int(decay_step)
        self.slots = len(attack)
        self.reset()

    def reset(self):
        self.level = np.zeros(self.slots, dtype=np.int64)
        self.state = np.zeros(self.slots, dtype=np.int8)
        self.previous_gate = np.zeros(self.slots, dtype=bool)
        self.dead = np.ones(self.slots, dtype=bool)

    def step(self, gate, trigger, clear):
        for i in range(self.slots):
            old, state = int(self.level[i]), int(self.state[i])
            if clear[i]:
                self.level[i], self.state[i], self.dead[i] = 0, self.IDLE, True
            elif trigger[i] or (gate[i] and not self.previous_gate[i]):
                self.level[i], self.state[i], self.dead[i] = 0, self.ATTACK, False
            elif not gate[i]:
                self.dead[i] = old <= self.release[i]
                self.level[i] = max(0, old-int(self.release[i]))
                self.state[i] = self.IDLE if self.dead[i] else self.RELEASE
            else:
                self.dead[i] = False
                if state == self.IDLE:
                    self.state[i] = self.ATTACK
                elif state == self.ATTACK:
                    new = old+int(self.attack[i])
                    self.level[i] = min(0x7fffffff, new)
                    if new >= 1 << 31:
                        self.state[i] = self.DECAY
                elif state == self.DECAY:
                    if old <= min(0x7fffffff,self.sustain_level+self.decay_step):
                        self.level[i], self.state[i] = self.sustain_level, self.SUSTAIN
                    else:
                        self.level[i] = old-self.decay_step
                elif state == self.RELEASE:
                    self.state[i] = self.IDLE
        self.previous_gate[:] = gate
        return self.level.copy()


class Reverb:
    """Current comb_reverb + reverb_router, full-width products and saturation."""
    def __init__(self, preset='NONE'):
        self.preset = None
        self.configure(preset)

    def configure(self, preset):
        preset = str(preset).upper()
        if preset not in R.REVERB_PRESETS:
            raise ValueError(preset)
        if preset != self.preset:
            self.preset = preset
            self.reset()

    def reset(self):
        self.lines = [[0]*2048 for _ in range(4)]
        self.pointers = [0]*4
        self.clear_count = 0

    def step(self, x):
        p = R.REVERB_PRESETS[self.preset]
        taps = []
        # At the last clearing sample A deasserts clr_run before B consumes it.
        # Audio samples are separated by many core clocks in the production path.
        clear = self.clear_count < 2047
        for i in range(4):
            at = self.pointers[i]
            s = 0 if clear else self.lines[i][at]
            feedback = (s*p.feedback[i]) >> 27
            taps.append((s*p.weight[i]) >> 27)
            self.lines[i][at] = R.sat_signed(int(x)+feedback, 64)
            self.pointers[i] = 0 if at+1 >= p.lengths[i] else at+1
        self.clear_count = min(2048, self.clear_count+1)
        total = sum(taps)
        wet = R.sat_signed(total, 64)
        dry = (int(x)*p.dry) >> 27
        wet = (wet*p.wet) >> 27
        return R.sat_signed(dry+wet, 64)


class Spatializer:
    """stereo_spatializer sample arithmetic, ILD then fractional ITD."""
    LUT = tuple(round(256*(32-i)/max(32-i, i)) for i in range(33))

    def __init__(self, max_itd=4):
        if max_itd not in [0, 1, 2, 4, 8]:
            raise ValueError("max_itd must be 0/1/2/4/8")
        self.max_itd = max_itd
        self.reset()

    def reset(self):
        self.position, self.left_delay, self.right_delay = 256, 0, 0
        self.left_history, self.right_history = [], []

    @staticmethod
    def _slew(value, target, limit=1):
        return value+max(-limit, min(limit, target-value))

    @classmethod
    def gain(cls, position):
        # TEMP_AUDIO_AUDITION_20261101: mirror exact-center unity in RTL.
        if position == 256:
            return 4096
        i, f = divmod(position, 16)
        return cls.LUT[i]*16 if i == 32 else cls.LUT[i]*(16-f)+cls.LUT[i+1]*f

    def step(self, x, pan=16, itd=True, clear=False):
        self.position = self._slew(self.position, min(32, max(0, int(pan)))*16)
        dl = (self.position-256)*self.max_itd//4 if itd and self.position > 256 else 0
        dr = (256-self.position)*self.max_itd//4 if itd and self.position < 256 else 0
        limit = 2 if self.max_itd == 8 else 1
        self.left_delay = self._slew(self.left_delay, dl, limit)
        self.right_delay = self._slew(self.right_delay, dr, limit)
        if clear:
            self.left_history, self.right_history = [], []
        result = []
        for hist, gain, delay in [(self.left_history, self.gain(self.position), self.left_delay),
                                  (self.right_history, self.gain(512-self.position), self.right_delay)]:
            hist.insert(0, 0 if clear else int(x)*gain)
            del hist[self.max_itd+1:]
            whole, fraction = divmod(delay, 64)
            a = hist[whole] if whole < len(hist) else 0
            b = hist[whole+1] if whole+1 < len(hist) else 0
            result.append(a*(64-fraction)+b*fraction)
        return tuple(result)


def pcm16(value, headroom=3, extra_frac=0):
    if not 0 <= headroom <= 53:
        raise ValueError("headroom must be 0..53")
    shift = 9+headroom+extra_frac
    return R.sat_signed((int(value)+(1 << (shift-1))) >> shift, 16)


@dataclass
class Frame:
    x: np.ndarray
    emap: np.ndarray
    y: np.ndarray
    mix: int
    out: int
    pcm: tuple[int, int]
    delta: np.ndarray
    zero: np.ndarray
    idle: np.ndarray


class PitchEngine:
    """eng1_pitch FSM; clock() is one core edge, including atomic cancellation.

    control=(kind, source, value), kind='bend' or 'cc1', stays valid until ack.
    prepare writes the shadow buffer; only a qualified committing edge changes
    active coefficients AND ratios. No waveform state is changed by preparation.
    """
    def __init__(self, resources, interval=96):
        self.resources = tuple(resources)
        self.slots = len(resources)
        self.interval = int(interval)
        if self.interval < 1:
            raise ValueError("pitch interval must be positive")
        self.words = np.array([r.pitch_words for r in resources], dtype=np.int64)
        self.nominal = np.array([r.coeffs.a1 for r in resources], dtype=np.int64)
        self.ratios, self.sine, self.depth = P.ratio_table(), P.sine_table(), P.depth_table()
        self.reset()

    def reset(self):
        self.state, self.bank, self.enabled = 'IDLE', 0, False
        self.buffers = [self.nominal.copy(), self.nominal.copy()]
        self.active_delta = np.zeros(self.slots, dtype=np.int64)
        self.active_sources = np.zeros(self.slots, dtype=np.int8)
        self.bend, self.wheel, self.cents, self.current_delta = [8192]*2, [0]*2, [0]*2, [0]*2
        self.next_cents, self.next_delta = [0]*2, [0]*2
        self.tick_count, self.phase, self.due, self.cleanup_wait = 0, 0, False, False
        self.control_job = False
        self.commits = 0

    def sources_ready(self, sources):
        return not self.enabled or (np.array_equal(sources, self.active_sources) and not self.cleanup_wait)

    @property
    def coefficients(self):
        return self.buffers[self.bank]

    def clock(self, *, sample_tick=False, commit_ok=True, sources=None,
              control=None, cancel=False, cleanup=(False, False), clear=False):
        sources = _lanes(0 if sources is None else sources, self.slots, np.int8)
        cleanup = _lanes(cleanup, 2, bool)
        old_due, old_phase = self.due, self.phase
        if sample_tick:
            self.tick_count += 1
            if self.tick_count == self.interval:
                self.tick_count = 0
                self.due = True
                self.phase = (self.phase+P.LFO_STEP) & 0xffffff
        if clear:
            buffers = self.buffers
            self.reset()
            # The RTL block owns bank selection/control, not coefficient RAM.
            # Its clear pin cannot magically rewrite external a1 memories.
            self.buffers = buffers
            return False, False
        if cleanup.any():
            self.state, self.due, self.control_job, self.cleanup_wait = 'IDLE', True, False, True
            for s in range(2):
                if cleanup[s]:
                    self.bend[s], self.wheel[s], self.cents[s] = 8192, 0, 0
            return False, False
        if self.control_job and cancel:
            self.state, self.control_job, self.due = 'IDLE', False, True
            return False, False
        st = self.state
        if st == 'IDLE':
            valid = control is not None and not cancel
            if valid or (old_due and self.enabled) or not self.sources_ready(sources):
                self.candidate_bend, self.candidate_wheel = self.bend.copy(), self.wheel.copy()
                self.control_job = valid
                if valid:
                    kind, src, value = control
                    if kind == 'bend':
                        self.candidate_bend[src] = value
                    elif kind == 'cc1':
                        self.candidate_wheel[src] = value
                    else:
                        raise ValueError("pitch engine accepts bend or cc1")
                self.sources_job = sources.copy()
                self.phase_job, self.source, self.due, self.state = old_phase, 0, False, 'SETUP'
                if not valid and not old_due:
                    self.next_cents, self.next_delta = self.cents.copy(), self.current_delta.copy()
                    self.slot, self.mode, self.state = 0, 0, 'RD'
        elif st == 'SETUP':
            self.mul_a = self.sine[(self.phase_job >> 16) & 255]
            self.mul_b = self.depth[self.candidate_wheel[self.source]]
            self.state = 'VIB_MUL'
        elif st == 'VIB_MUL':
            self.product, self.state = self.mul_a*self.mul_b, 'VIB_ROUND'
        elif st == 'VIB_ROUND':
            self.vibration, self.state = (self.product+16384) >> 15, 'VIB_APPLY'
        elif st == 'VIB_APPLY':
            target = (((self.candidate_bend[self.source]-8192)*25) >> 2)+self.vibration
            target = max(-56320, min(56320, target))
            c = max(self.cents[self.source]-512, min(self.cents[self.source]+512, target))
            self.next_cents[self.source] = c
            self.ratio_index, self.ratio_fraction = divmod(c+56320, 256)
            self.state = 'RATIO_LD'
        elif st == 'RATIO_LD':
            self.ratio_base = self.ratios[self.ratio_index]
            self.mul_a = self.ratios[self.ratio_index+1]-self.ratio_base
            self.mul_b = self.ratio_fraction
            self.state = 'RATIO_MUL'
        elif st == 'RATIO_MUL':
            self.product, self.state = self.mul_a*self.mul_b, 'RATIO_APPLY'
        elif st == 'RATIO_APPLY':
            self.next_delta[self.source] = self.ratio_base+((self.product+128) >> 8)-(1 << 24)
            if self.source == 0:
                self.source, self.state = 1, 'SETUP'
            else:
                self.slot, self.mode, self.state = 0, 0, 'RD'
        elif st == 'RD':
            self.read_words = self.words[self.slot, self.mode].copy()
            self.state = 'WAIT_RD'
        elif st == 'WAIT_RD':
            self.state = 'CO_LD'
        elif st == 'CO_LD':
            w = self.read_words
            if w[7] != P.TAG:
                rejected = self.control_job and control is not None and not cancel
                self.state, self.control_job, self.due = 'ACK', False, False
                return rejected, rejected
            self.lower, self.base, self.upper = map(int, w[:3])
            self.mul_a = self.next_delta[self.sources_job[self.slot]]
            self.mul_b = R.wrap_signed(int(w[5]), 25)
            self.state = 'CO_MUL'
        elif st == 'CO_MUL':
            self.product, self.state = self.mul_a*self.mul_b, 'CO_APPLY'
        elif st == 'CO_APPLY':
            self.state = 'CO_OUT'
        elif st == 'CO_OUT':
            value = self.base+((self.product+2097152) >> 22)
            self.buffers[1-self.bank][self.slot, self.mode] = max(self.lower, min(self.upper, value))
            self.mode += 1
            if self.mode == ACTIVE_MODES:
                self.mode, self.slot = 0, self.slot+1
            if self.slot == self.slots:
                self.state = 'COMMIT'
            else:
                self.state = 'RD'
        elif st == 'COMMIT':
            if not np.array_equal(sources, self.sources_job):
                self.state, self.due = 'IDLE', True
            elif commit_ok and (not self.control_job or (control is not None and not cancel)):
                ack = self.control_job and control is not None
                self.bank, self.enabled, self.cleanup_wait = 1-self.bank, True, False
                self.active_sources[:] = self.sources_job
                self.bend, self.wheel = self.candidate_bend.copy(), self.candidate_wheel.copy()
                self.cents, self.current_delta = self.next_cents.copy(), self.next_delta.copy()
                self.active_delta[:] = [self.next_delta[s] for s in self.sources_job]
                self.control_job, self.state = False, 'ACK'
                self.commits += 1
                return ack, False
        elif st == 'ACK':
            self.state = 'IDLE'
        return False, False

    def advance(self, cycles, *, sources, controls, commit_ok):
        """Advance a tick-free core interval, skipping quiescent IDLE cycles."""
        for _ in range(int(cycles)):
            if self.state == 'IDLE' and not controls and not (self.due and self.enabled) and self.sources_ready(sources):
                break
            ack, rejected = self.clock(sources=sources, control=controls[0] if controls else None, commit_ok=commit_ok)
            if ack:
                controls.popleft()
            if rejected:
                raise ValueError("P1T1 metadata missing; active pitch preserved")


class Eng1Synth:
    """Production B DSP with explicit, fixed note slots and committed snapshots.

    step() returns the result for the input frame, without serializer/FIFO delay.
    Retired idle is published after that frame's state writes. For trace replay,
    committed_delta bypasses the control scheduler and applies the actual atomic
    RTL commit; it does not bypass excitation, ADSR, arithmetic or postprocessing.
    Automatic controls use PitchEngine with a configurable frame busy window;
    raw MIDI parser/queue/configuration cycle timing is intentionally external.
    """
    output_frac = STATE_FRAC
    output_one = 1 << STATE_FRAC

    def __init__(self, instrument='flute', *, note_map=tuple(range(48, 64)),
                 resources=None, reverb='NONE', stereo=True, headroom=3,
                 sample_rate=48000, core_hz=50_000_000, frame_busy_cycles=632,
                 max_itd=4, initialized=True):
        self.note_map = tuple(map(int, note_map))
        if len(self.note_map) not in (4, 8, 16) or len(set(self.note_map)) != len(self.note_map):
            raise ValueError("production slots must be 4/8/16 distinct loaded notes")
        self.slots = len(self.note_map)
        self.resources = resources or ResourceBank.build(instrument, self.note_map)
        if self.resources.instrument != instrument:
            raise ValueError("resource instrument mismatch")
        if int(sample_rate) != self.resources.sample_rate:
            raise ValueError("resource Fs and playback Fs differ; resample explicitly")
        if self.resources.sample_rate != 48000:
            raise ValueError("current production profile/LFO contract requires Fs=48000")
        self.sample_rate, self.core_hz = int(sample_rate), int(core_hz)
        self.frame_busy_cycles = int(frame_busy_cycles)
        if not 0 < self.frame_busy_cycles < self.core_hz//self.sample_rate:
            raise ValueError("frame busy window exceeds sample budget")
        self.rows = [self.resources.notes[m] for m in self.note_map]
        self.core = R.Eng1Core(slots=self.slots, n_modes=64)
        self.excitation = Excitation([r.period for r in self.rows])
        self.envelope = Envelope([r.a_step for r in self.rows], [r.r_step for r in self.rows])
        if instrument=='violin':
            self.envelope=Envelope([2236963]*self.slots,[559241]*self.slots,
                                   sustain_level=0x7fffffff,decay_step=0)
        self.pitch = PitchEngine(self.rows)
        self.reverb, self.spatial = Reverb(reverb), Spatializer(max_itd)
        self.stereo, self.headroom = bool(stereo), int(headroom)
        gain_file=ROOT/'rtl/router/tools/performance/gain.json'
        gain_rows=json.loads(gain_file.read_text())['instruments'] if gain_file.is_file() else {}
        profile=gain_rows.get(instrument,{}).get('note_gain_q12',{})
        self.note_gains=tuple(int(profile.get(str(note),4096)) for note in self.note_map)
        pcm16(0, self.headroom)  # validate even before rendering
        self.reset(initialized=initialized)

    def reset(self, *, initialized=True):
        self.core.reset()
        for s, r in enumerate(self.rows):
            self.core.load_slot(s, r.coeffs)
        self.excitation.reset()
        self.envelope.reset()
        self.pitch.reset()
        self.reverb.reset()
        self.spatial.reset()
        self.gate = np.zeros(self.slots, dtype=bool)
        self.level = np.zeros(self.slots, dtype=np.int64)
        self.sources = np.zeros(self.slots, dtype=np.int8)
        self.trigger = np.zeros(self.slots, dtype=bool)
        self.clear = np.zeros(self.slots, dtype=bool)
        # Construction/reset represents a successful load whose initial clear
        # frame already retired, as required before MIDI backend admission.
        self.idle = np.full(self.slots, bool(initialized), dtype=bool)
        self.previous_dead = np.ones(self.slots, dtype=bool)
        self.dead_pending = np.zeros(self.slots, dtype=bool)
        self._previous_gate = np.zeros(self.slots, dtype=bool)
        self.init_zero = not initialized
        self.controls = deque()
        self.sample_index = 0
        self.rejected_notes = 0
        self.pad_gate = np.zeros(self.slots, dtype=bool)
        self.poly_gain=4096

    def slot_for(self, midi):
        try:
            return self.note_map.index(int(midi))
        except ValueError:
            raise ValueError(f"MIDI {midi} is not in the loaded note map {self.note_map}") from None

    def note_on(self, midi, velocity=100, source=0):
        s = self.slot_for(midi)
        if source not in (0, 1) or not 1 <= int(velocity) <= 127:
            raise ValueError("source must be 0/1, velocity 1..127")
        if (self.gate[s] or not self.idle[s]) and self.sources[s] != source:
            self.rejected_notes += 1
            return None
        self.sources[s], self.gate[s] = source, True
        self.level[s] = (int(velocity)*255+63)//127
        self.trigger[s] = True
        return s

    def note_off(self, slot):
        self.gate[int(slot)] = False

    def hard_clear(self, source=None):
        mask = np.ones(self.slots, dtype=bool) if source is None else self.sources == source
        self.gate[mask], self.clear[mask] = False, True

    def control(self, kind, value, source=0):
        if source not in (0, 1) or kind not in ('bend', 'cc1'):
            raise ValueError("expected bend/cc1 from source 0 or 1")
        limit = 16383 if kind == 'bend' else 127
        if not 0 <= int(value) <= limit:
            raise ValueError("pitch control outside MIDI range")
        self.controls.append((kind, int(source), int(value)))

    def cleanup(self, source):
        if source not in (0, 1):
            raise ValueError(source)
        self.hard_clear(source)
        self.controls = deque(c for c in self.controls if c[1] != source)
        flags = [False, False]
        flags[source] = True
        self.pitch.clock(sources=self.sources, cleanup=flags)

    def step_pad(self, pressure, *, on_threshold=2, off_threshold=1, **kwargs):
        """PAD hysteresis at the accepted frame boundary; board uses 64/48.

        Source switching/maintenance is external: reset between input modes.
        """
        pressure = _lanes(pressure, self.slots)
        if np.any((pressure < 0) | (pressure > 255)):
            raise ValueError("PAD pressures must be 8-bit")
        if not 0 <= off_threshold <= on_threshold <= 255:
            raise ValueError("invalid PAD thresholds")
        self.pad_gate = np.where(self.pad_gate, pressure >= off_threshold, pressure > on_threshold)
        return self.step(gate=self.pad_gate, level=pressure, retrigger=False, **kwargs)

    def step(self, *, gate=None, level=None, retrigger=None, clear=None,
             sources=None, committed_delta=None, st_zero=None, pan=16, itd=True,
             active=True):
        explicit = gate is not None
        gates = _lanes(self.gate if gate is None else gate, self.slots, bool)
        levels = _lanes(self.level if level is None else level, self.slots)
        triggers = _lanes(self.trigger if retrigger is None else retrigger, self.slots, bool)
        clears = _lanes(self.clear if clear is None else clear, self.slots, bool)
        if np.any((levels < 0) | (levels > 255)):
            raise ValueError("strike levels must be 8-bit")
        if sources is not None:
            self.sources[:] = _lanes(sources, self.slots, np.int8)
        if np.any((self.sources < 0) | (self.sources > 1)):
            raise ValueError("slot sources must be 0/1")
        replay = committed_delta is not None
        if not replay:
            ack, rejected = self.pitch.clock(sample_tick=True, commit_ok=False, sources=self.sources,
                                            control=self.controls[0] if self.controls else None)
            if ack:
                self.controls.popleft()
            if rejected:
                raise ValueError("P1T1 metadata missing")
            # High-level note helpers wait for an ownership-related pitch rebuild.
            # Explicit snapshots already passed the real performance admission gate.
            if not explicit and triggers.any() and not self.pitch.sources_ready(self.sources):
                gates = self.envelope.previous_gate & gates & ~clears
                triggers = np.zeros(self.slots, dtype=bool)
            else:
                self.trigger[:] = False
            delta = self.pitch.active_delta.copy()
            self.core.a1[:] = self.pitch.coefficients
        else:
            delta = _lanes(committed_delta, self.slots)
            if np.any((delta < -(1 << 23)) | (delta >= (1 << 23))):
                raise ValueError("pitch delta must fit signed24")
            words = self.pitch.words
            if np.any(words[:, :48, 7] != P.TAG):
                raise ValueError("atomic pitch replay requires P1T1 metadata")
            self.core.a1[:] = np.clip(words[:, :, 1]+((words[:, :, 5]*delta[:, None]+2097152) >> 22),
                                     words[:, :, 0], words[:, :, 2])
        x = self.excitation.step(gates, levels, triggers, clears, delta)
        e = self.envelope.step(gates, triggers, clears)
        dead = self.envelope.dead.copy()
        zero = triggers | (gates & ~self._previous_gate)
        # env_dead changes on the same edge as frame_start; its registered edge
        # reaches dead_pend for the NEXT frame, not this frame's zero mask.
        zero |= self.dead_pending | clears | self.init_zero
        if st_zero is not None:
            zero = _lanes(st_zero, self.slots, bool)
        y, _ = self.core.step(x, zero, active_modes=48)
        mix = R.wrap_signed(sum(R.sat_signed(((((int(y[s])*int(e[s])) >> 31)*self.note_gains[s])+2048)>>12,64)
                                for s in range(self.slots)),64)
        out = self.reverb.step(mix)  # B body_router is five exact passthrough sections.
        voices=int(np.count_nonzero((e>0)&~dead))
        target=self.poly_gain if voices==0 else round(4096/math.sqrt(voices))
        if target<self.poly_gain:self.poly_gain-=max(1,(self.poly_gain-target)>>3)
        elif target>self.poly_gain:self.poly_gain+=max(1,(target-self.poly_gain)>>12)
        out=(int(out)*self.poly_gain+2048)>>12
        if clears.any() and not gates.any():self.poly_gain=4096
        if self.stereo:
            left, right = self.spatial.step(out if active else 0, pan, itd, clear=not active)
            pcm = (pcm16(left, self.headroom, 18), pcm16(right, self.headroom, 18))
        else:
            pcm = (pcm16(out if active else 0, self.headroom),)*2
        self.idle = (self.idle | (zero & dead & ~gates)) & ~gates
        self.dead_pending = dead & ~self.previous_dead
        self.previous_dead, self._previous_gate = dead, gates.copy()
        self.init_zero = False
        self.clear[:] = False
        if not replay:
            # One tick per frame; preparation is clocked while the DSP is busy,
            # but committing is allowed only in the tick-free frame gap.
            n = self.sample_index
            clocks = ((n+1)*self.core_hz)//self.sample_rate-(n*self.core_hz)//self.sample_rate
            self.pitch.advance(self.frame_busy_cycles-1, sources=self.sources, controls=self.controls, commit_ok=False)
            self.pitch.advance(clocks-self.frame_busy_cycles, sources=self.sources, controls=self.controls, commit_ok=True)
        self.sample_index += 1
        return Frame(x, e, y, mix, out, pcm, delta, zero, self.idle.copy())
