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
    """Clocked per-slot aftertouch, matching modulation1's shadow-bank protocol."""
    def __init__(self, resources, interval=96, threshold=102):
        self.resources=tuple(resources);self.slots=len(resources)
        self.interval=int(interval);self.threshold=int(threshold)
        if self.interval<1 or not 0<=self.threshold<=255:raise ValueError('invalid aftertouch parameters')
        self.words=np.array([r.pitch_words for r in resources],dtype=np.int64)
        self.nominal=np.array([r.coeffs.a1 for r in resources],dtype=np.int64)
        self.ratios=P.ratio_table();self.reset()

    def reset(self):
        self.state,self.bank='IDLE',0
        self.buffers=[self.nominal.copy(),self.nominal.copy()]
        self.active_delta=np.zeros(self.slots,dtype=np.int64)
        self.active_sources=np.zeros(self.slots,dtype=np.int8)
        self.cents=[0]*self.slots;self.next_cents=[0]*self.slots;self.next_delta=[0]*self.slots
        self.levels_q=np.zeros(self.slots,dtype=np.int64);self.gates_q=np.zeros(self.slots,dtype=bool)
        self.enabled_q=self.active_enabled=self.pressure_requested=False
        self.tick_count,self.due,self.commits=0,False,0
        self.slot=self.mode=0

    def sources_ready(self,sources):
        return (np.array_equal(sources,self.active_sources) and self.pressure_requested==self.enabled_q
                and self.enabled_q==self.active_enabled)

    @property
    def coefficients(self):return self.buffers[self.bank]

    def clock(self,*,sample_tick=False,commit_ok=True,sources=None,pressure_enable=None,
              pressure_gate=0,pressure_level=0,control=None,cancel=False,cleanup=(False,False),clear=False):
        sources=_lanes(0 if sources is None else sources,self.slots,np.int8)
        if pressure_enable is not None:self.pressure_requested=bool(pressure_enable)
        old_due=self.due;old_enabled=self.enabled_q
        old_levels=self.levels_q.copy();old_gates=self.gates_q.copy()
        old_ready=np.array_equal(sources,self.active_sources) and old_enabled==self.active_enabled
        rejected=control is not None and not cancel and not clear
        if sample_tick:
            self.levels_q=_lanes(pressure_level,self.slots)
            self.gates_q=_lanes(pressure_gate,self.slots,bool)
            self.enabled_q=self.pressure_requested
            self.tick_count+=1
            if self.tick_count==self.interval:self.tick_count,self.due=0,True
        if clear:
            buffers=self.buffers;self.reset();self.buffers=buffers
            return False,False
        if np.any(cleanup):
            self.state,self.due='IDLE',True
            return rejected,rejected
        st=self.state
        if st=='IDLE':
            if old_due or not old_ready:
                self.levels_job,self.gates_job=old_levels,old_gates
                self.enabled_job=old_enabled;self.sources_job=sources.copy()
                self.slot,self.mode,self.due,self.state=0,0,False,'MAP'
        elif st=='MAP':
            s=self.slot
            if not self.enabled_job or self.sources_job[s]!=self.active_sources[s]:
                self.next_cents[s]=self.next_delta[s]=0
            elif not self.gates_job[s]:
                self.next_cents[s]=self.cents[s];self.next_delta[s]=int(self.active_delta[s])
            else:
                q=(max(0,int(self.levels_job[s])-self.threshold)*60*256+50)//100
                self.next_cents[s]=q
                self.ratio_index,self.ratio_fraction=divmod(q+56320,256)
                self.state='RATIO_LD'
            if self.state=='MAP':self._next_slot()
        elif st=='RATIO_LD':self.state='RATIO_DATA'
        elif st=='RATIO_DATA':
            self.ratio_base=self.ratios[self.ratio_index]
            self.mul_a=self.ratios[self.ratio_index+1]-self.ratio_base
            self.mul_b=self.ratio_fraction;self.state='RATIO_MUL'
        elif st=='RATIO_MUL':self.product,self.state=self.mul_a*self.mul_b,'RATIO_APPLY'
        elif st=='RATIO_APPLY':
            self.next_delta[self.slot]=self.ratio_base+((self.product+128)>>8)-(1<<24)
            self._next_slot()
        elif st=='RD':
            self.read_words=self.words[self.slot,self.mode].copy();self.state='WAIT_RD'
        elif st=='WAIT_RD':self.state='CO_LD'
        elif st=='CO_LD':
            w=self.read_words
            if w[7]!=P.TAG:self.state='ACK'
            else:
                self.lower,self.base,self.upper=map(int,w[:3])
                self.mul_a=self.next_delta[self.slot];self.mul_b=R.wrap_signed(int(w[5]),25)
                self.state='CO_MUL'
        elif st=='CO_MUL':self.product,self.state=self.mul_a*self.mul_b,'CO_APPLY'
        elif st=='CO_APPLY':self.state='CO_OUT'
        elif st=='CO_OUT':
            value=self.base+((self.product+2097152)>>22)
            self.buffers[1-self.bank][self.slot,self.mode]=max(self.lower,min(self.upper,value))
            self.mode+=1
            if self.mode==ACTIVE_MODES:self.mode,self.slot=0,self.slot+1
            self.state='COMMIT' if self.slot==self.slots else 'RD'
        elif st=='COMMIT':
            if not np.array_equal(sources,self.sources_job) or old_enabled!=self.enabled_job or self.pressure_requested!=self.enabled_job:
                self.state,self.due='IDLE',True
            elif commit_ok:
                self.bank=1-self.bank;self.active_sources[:]=self.sources_job
                self.active_enabled=self.enabled_job;self.cents=self.next_cents.copy()
                self.active_delta[:]=self.next_delta;self.state='ACK';self.commits+=1
        elif st=='ACK':self.state='IDLE'
        return rejected,rejected

    def _next_slot(self):
        if self.slot==self.slots-1:self.slot,self.state=0,'RD'
        else:self.slot,self.state=self.slot+1,'MAP'

    def advance(self,cycles,*,sources,controls,commit_ok):
        for _ in range(int(cycles)):
            if self.state=='IDLE' and not controls and not self.due and self.sources_ready(sources):break
            ack,_=self.clock(sources=sources,control=controls[0] if controls else None,commit_ok=commit_ok)
            if ack:controls.popleft()


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
            raise ValueError("current production profile contract requires Fs=48000")
        self.sample_rate, self.core_hz = int(sample_rate), int(core_hz)
        self.frame_busy_cycles = int(frame_busy_cycles)
        if not 0 < self.frame_busy_cycles < self.core_hz//self.sample_rate:
            raise ValueError("frame busy window exceeds sample budget")
        self.rows = [self.resources.notes[m] for m in self.note_map]
        self.core = R.Eng1Core(slots=self.slots, n_modes=64)
        if instrument == 'trumpet':
            from trumpet_lip import TrumpetExcitation
            self.excitation = TrumpetExcitation([r.period for r in self.rows])
        else:
            self.excitation = Excitation([r.period for r in self.rows])
        self.envelope = Envelope([r.a_step for r in self.rows], [r.r_step for r in self.rows])
        if instrument=='violin':
            self.envelope=Envelope([2236963]*self.slots,[559241]*self.slots,
                                   sustain_level=0x7fffffff,decay_step=0)
        self.pitch = PitchEngine(self.rows)
        self.reverb, self.spatial = Reverb(reverb), Spatializer(max_itd)
        self.stereo, self.headroom = bool(stereo), int(headroom)
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

    def step_pad(self, pressure, *, on_threshold=102, off_threshold=13, **kwargs):
        """PAD hysteresis at the accepted frame boundary; aftertouch zero is 102.

        Source switching/maintenance is external: reset between input modes.
        """
        pressure = _lanes(pressure, self.slots)
        if np.any((pressure < 0) | (pressure > 255)):
            raise ValueError("PAD pressures must be 8-bit")
        if not 0 <= off_threshold <= on_threshold <= 255:
            raise ValueError("invalid PAD thresholds")
        self.pad_gate = np.where(self.pad_gate, pressure >= off_threshold, pressure > on_threshold)
        return self.step(gate=self.pad_gate, level=pressure, retrigger=False, pressure_enable=True, **kwargs)

    def step(self, *, gate=None, level=None, retrigger=None, clear=None,
             sources=None, committed_delta=None, st_zero=None, pan=16, itd=True,
             active=True, pressure_enable=False):
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
                                            control=self.controls[0] if self.controls else None,
                                            pressure_enable=pressure_enable, pressure_gate=gates, pressure_level=levels)
            if ack:
                self.controls.popleft()
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
        mix = R.wrap_signed(sum(R.wrap_signed((int(y[s])*int(e[s])) >> 31,64)
                                for s in range(self.slots)),64)
        out = self.reverb.step(mix)  # B body_router is five exact passthrough sections.
        voices=int(np.count_nonzero((e>0)&~dead))
        shift=2 if voices==1 else 1 if 2<=voices<=7 else 0
        self.poly_gain=4096<<shift
        out=R.wrap_signed(int(out)<<shift,64)
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
