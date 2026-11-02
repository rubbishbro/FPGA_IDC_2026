"""Production model boundaries and regressions; RTL parity: sim/run_eng1_model.py."""
from pathlib import Path
import sys
import numpy as np
import pytest
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'python/modal_sim'))
sys.path.insert(0,str(ROOT/'rtl/router/tools'))
import eng1_rtl as E
import router_eng1 as R

@pytest.fixture(scope='module')
def resources():
    return E.ResourceBank.build('flute',[64,65,66,67])

def synth(resources,**kwargs):
    return E.Eng1Synth('flute',note_map=[64,65,66,67],resources=resources,**kwargs)

def test_primary_router_entry_is_production_q24(resources):
    s=R.RouterEng1('flute',note_map=[64,65,66,67],resources=resources)
    assert isinstance(s,E.Eng1Synth)
    assert s.core.G.shape==(4,64)
    f=s.step(gate=[1,0,0,0],level=[255,0,0,0],committed_delta=[0]*4)
    assert f.x[0]==255<<16 and f.emap[0]==0
    assert not np.any(s.core.y1[:,48:])

def test_core_ignores_unused_word_bits_and_preserves_inactive_states():
    core=R.Eng1Core(slots=1,n_modes=64)
    core.G[0,0]=0x94000001 # low 26 bits = 1
    core.a1[0,0]=0x93ffffff # low 26 bits = -1
    core.a2[0,0]=0x7f000001 # low 24 bits = 1
    core.y1[:]=123;core.y2[:]=456
    y,_=core.step([1<<24],[False],active_modes=1)
    assert y[0]==1
    assert core.y2[0,0]==123
    np.testing.assert_array_equal(core.y1[0,1:],123)
    before=core.y1.copy()
    y,_=core.step([123],[True],active_modes=0)
    assert y[0]==0
    np.testing.assert_array_equal(core.y1,before)

def test_fractional_phase_preserves_41st_carry():
    e=E.Excitation([65535])
    e.previous_gate[0]=True
    e.phase[0]=(65535<<24)-10
    x=e.step([True],[255],[False],[False],[100])
    assert x[0]==255<<16
    assert e.phase[0]==(1<<24)+90

@pytest.mark.parametrize('velocity',[1,63,64,127])
def test_midi_velocity_maps_once_and_does_not_use_pad_threshold(resources,velocity):
    s=synth(resources)
    s.note_on(64,velocity)
    f=s.step()
    assert f.x[0]==((velocity<<1)|(velocity>>6))<<16
    assert f.emap[0]==0
    assert not s.envelope.dead[0] # attack zero is not dead/idle


def test_fixed_resource_map_has_no_implicit_stealing(resources):
    s=synth(resources)
    with pytest.raises(ValueError,match='not in the loaded'):
        s.note_on(80)
    s.step()
    s.note_on(64,100,source=0);s.step()
    s.note_off(0)
    assert s.note_on(64,100,source=1) is None
    for _ in range(4000):
        s.step()
        if s.idle[0]:break
    assert s.idle[0]
    assert not np.any(s.core.y1[0,:48]) and not np.any(s.core.y2[0,:48])
    assert s.note_on(64,100,source=1)==0


def test_same_gate_retrigger_restarts_envelope_and_phase(resources):
    s=synth(resources)
    s.note_on(64)
    for _ in range(100):s.step()
    s.note_on(64,127)
    f=s.step()
    assert f.x[0]==255<<16 and f.emap[0]==0 and f.zero[0]
    assert s.excitation.phase[0]==0


def test_pad_hysteresis_and_release(resources):
    s=synth(resources)
    assert s.step_pad([64,0,0,0],on_threshold=64,off_threshold=48).x[0]==0
    assert s.step_pad([65,0,0,0],on_threshold=64,off_threshold=48).x[0]==65<<16
    s.step_pad([48,0,0,0],on_threshold=64,off_threshold=48)
    assert s.pad_gate[0]
    s.step_pad([47,0,0,0],on_threshold=64,off_threshold=48)
    assert not s.pad_gate[0]


def test_reset_replays_same_samples(resources):
    s=synth(resources,reverb='HALL')
    def play():
        s.note_on(64)
        return [(f.out,f.pcm) for f in (s.step() for _ in range(100))]
    first=play();s.reset();assert play()==first


def test_fs_and_resource_mismatch_fail_explicitly(resources):
    with pytest.raises(ValueError,match='Fs'):
        synth(resources,sample_rate=48828)
    with pytest.raises(ValueError,match='instrument mismatch'):
        E.Eng1Synth('cello',note_map=[64,65,66,67],resources=resources)
    with pytest.raises(ValueError,match='production ENG1'):
        E.ResourceBank('drums',{})

@pytest.mark.parametrize('value',[0,1,-1,1<<24,-(1<<24),1<<41,-(1<<41),1<<42,-(1<<42),(1<<63)-1,-(1<<63)])
def test_reverb_none_preserves_full_width(value):
    assert E.Reverb('NONE').step(value)==value

@pytest.mark.parametrize('headroom',[0,3,53])
def test_pcm_rounds_and_saturates_like_output(headroom):
    assert E.pcm16((1<<63)-1,headroom)==min(32767,((1<<63)-1+(1<<(8+headroom)))>>(9+headroom))
    assert E.pcm16(-(1<<63),headroom)==max(-32768,(-(1<<63)+(1<<(8+headroom)))>>(9+headroom))


def test_public_b_synth_rejects_nonproduction_dynamic(resources):
    import eng1_bc as B
    b=B.BSynth('flute',slots=4,note_map=[64,65,66,67],resources=resources)
    assert b.output_frac==24
    with pytest.raises(ValueError,match='forte'):
        b.note_on(64,dyn='piano')
    pcm=b.render_pcm([(0,64,0.005,0.7,'forte')],0.01)
    assert pcm.shape==(480,2) and pcm.dtype==np.int16
    assert np.any(pcm)


def test_output_mute_does_not_falsely_retire_held_voice(resources):
    s=synth(resources)
    s.note_on(64)
    for _ in range(100):s.step()
    before=s.envelope.level[0]
    f=s.step(active=False)
    assert f.pcm==(0,0)
    assert not f.idle[0] and s.envelope.level[0]>before


def test_aftertouch_tail_hold_and_midi_controls_rejected(resources):
    s=synth(resources)
    for _ in range(120):s.step_pad([202,102,102,102])
    assert s.pitch.active_delta[0]>0 and s.pitch.cents[0]==60*256
    held=s.pitch.active_delta.copy()
    for _ in range(120):s.step_pad([0,0,0,0])
    assert np.array_equal(s.pitch.active_delta,held)
    s.control('bend',16383)
    for _ in range(120):s.step()
    assert not s.pitch.active_delta.any() and not s.controls


def test_pitch_clear_preserves_external_ram_and_resets_epoch(resources):
    rows=[resources.notes[m] for m in [64,65,66,67]]
    p=E.PitchEngine(rows)
    p.buffers[0][0,0]=123456
    p.bank=1;p.active_enabled=True;p.active_delta[:]=100
    p.clock(clear=True)
    assert p.bank==0 and not p.active_enabled and not p.active_delta.any()
    assert p.buffers[0][0,0]==123456  # clear is not a hidden RAM loader


def test_resource_hash_is_checked_before_constructing_coefficients():
    import sustain_resources as S
    row=S.make_note('flute',64,True)
    damaged=bytearray(row['data']);damaged[0]^=1
    with pytest.raises(ValueError,match='hash mismatch'):
        E.NoteResource.decode(64,bytes(damaged),row)
