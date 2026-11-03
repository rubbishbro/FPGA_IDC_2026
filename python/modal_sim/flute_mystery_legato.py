#!/usr/bin/env python3
"""Chorus overlap and subtle bends via ENG1 committed P1T1 pitch snapshots.

Uses current nonnegative PAD-aftertouch mapping, not unsupported MIDI bend.
Control fixtures update every96 samples; this is not full modulation FSM timing.
"""
from pathlib import Path
from dataclasses import replace
import json
import hashlib
import numpy as np
import soundfile as sf
import eng1_rtl as E
import router_eng1 as R
import pitch_linear as P
from flute_jet_onset_audition import OnsetExcitation, CONFIGS
import flute_mystery_chorus as C

ROOT=C.ROOT
BASE=C.OUT
OUT=ROOT/'FFT_results/sim/eng1/flute_mystery_legato_20261103'
FS=48000


def smooth(x):
    x=np.clip(x,0,1)
    return x*x*(3-2*x)


def build_fixture(n):
    pressure=np.zeros((n,len(C.NOTES)),dtype=np.uint8)
    gates=np.zeros_like(pressure,dtype=bool)
    triggers=np.zeros_like(gates)
    events=[]
    for i,e in enumerate(C.EVENTS):
        prior=C.EVENTS[i-1] if i else None
        following=C.EVENTS[i+1] if i+1<len(C.EVENTS) else None
        connected_in=prior is not None and abs(e['time']-(prior['time']+prior['duration']))<.04
        connected_out=following is not None and abs(following['time']-(e['time']+e['duration']))<.04
        start=e['time']-(.04 if connected_in else 0)
        end=e['time']+e['duration']+(.06 if connected_out else 0)
        a,b=round(start*FS),round(end*FS)
        slot=C.NOTES.index(e['midi']);t=np.arange(b-a)/FS
        assert not gates[a:b,slot].any(),'same-pad gate collision'
        extra=np.zeros(b-a)
        if connected_in and e['midi']<prior['midi']:
            extra+=30*(1-smooth(t/.1)) # 22.5c ->0 over100ms.
        if connected_out and following['midi']>e['midi']:
            extra+=20*smooth((t-((end-start)-.1))/.1) #0 ->15c tail lift.
        level=np.rint(102+extra).astype(np.uint8)
        gates[a:b,slot]=True;pressure[a:b,slot]=level;triggers[a,slot]=True
        events.append(dict(**e,gate_on=start,gate_off=end,connected_in=connected_in,
                           connected_out=connected_out,pressure_min=int(level.min()),pressure_max=int(level.max())))
    return gates,pressure,triggers,events


def pitch_ratio_q24(level):
    # Current modulation1.sv: exact 0.75 cents per pressure count.
    cents_q8=P.aftertouch_cents_q8(level)
    index,frac=divmod(cents_q8+56320,256)
    ratios=P.ratio_table()
    return ratios[index]+(((ratios[index+1]-ratios[index])*frac+128)>>8)-(1<<24),cents_q8


def arithmetic_checks():
    assert pitch_ratio_q24(102)==(0,0)
    assert pitch_ratio_q24(132)[1]==5760
    for level in range(102,256):pitch_ratio_q24(level)
    # Phase increment and modal refresh consume one shared committed delta.
    co=R.build_b_table('flute',64,'forte').padded(64)
    words=np.asarray(P.modulation_words(co),dtype=np.int64)
    for level in [102,112,122,132]:
        delta,_=pitch_ratio_q24(level)
        a=np.clip(words[:,1]+((words[:,5]*delta+2097152)>>22),words[:,0],words[:,2])
        for k in range(48):
            assert int(a[k])==P.coefficient(int(words[k,1]),int(words[k,5]),int(words[k,0]),int(words[k,2]),delta)


def main():
    OUT.mkdir(parents=True,exist_ok=True);arithmetic_checks()
    previous=json.loads((BASE/'manifest.json').read_text())
    resource_rows=json.loads((BASE/'note_resources.json').read_text())
    production=E.ResourceBank.build('flute',C.NOTES);notes={}
    for entry in resource_rows:
        midi=entry['midi'];row=production.notes[midi];table=row.coeffs.padded(64)
        assert np.array_equal(table.a1,entry['a1']) and np.array_equal(table.a2,entry['a2'])
        notes[midi]=replace(row,coeffs=replace(table,G=np.asarray(entry['G'],dtype=np.int64)))
    bank=E.ResourceBank('flute',notes);params=previous['envelope']
    synth=E.Eng1Synth('flute',note_map=C.NOTES,resources=bank,stereo=False,reverb='NONE')
    synth.envelope=E.Envelope([params['A_STEP']]*len(C.NOTES),[params['R_STEP']]*len(C.NOTES),sustain_level=params['S_LEVEL'],decay_step=params['D_STEP'])
    synth.excitation=OnsetExcitation([r.period for r in synth.rows],**CONFIGS['gentle'])
    n=round(previous['seconds']*FS)
    gates,pressure,triggers,events=build_fixture(n)
    np.savez_compressed(OUT/'pressure_fixture.npz',gates=gates,pressure=pressure,retrigger=triggers)
    raw=np.empty(n,dtype=np.int64);native=np.empty(n,dtype=np.int16)
    delta=np.zeros(len(C.NOTES),dtype=np.int64)
    cents=np.zeros(len(C.NOTES),dtype=np.int64)
    trace=np.empty((n,len(C.NOTES)),dtype=np.int16)
    rails=0;updates=0
    # Replay a control snapshot at each96-frame update. Gate-off freezes the
    # last pitch, matching modulation1's release behavior. No negative bend.
    for i in range(n):
        if i%P.INTERVAL==0:
            for slot in range(len(C.NOTES)):
                if gates[i,slot]:delta[slot],cents[slot]=pitch_ratio_q24(pressure[i,slot])
            updates+=1
        trace[i]=cents
        f=synth.step(gate=gates[i],level=pressure[i],retrigger=triggers[i],committed_delta=delta)
        raw[i]=f.out;native[i]=f.pcm[0]
        rails+=int(np.count_nonzero((synth.core.y1==R.Y_MAX)|(synth.core.y1==R.Y_MIN)))
        if i and i%(2*FS)==0:print(f'legato {i/FS:.0f}/{n/FS:.2f}s',flush=True)
    assert rails==0 and not np.any(raw[-round(.2*FS):]) and not gates[-1].any()
    assert int(triggers.sum())==31
    # Pitch must remain frozen from each gate-off until the next same-slot gate-on.
    for slot in range(len(C.NOTES)):
        falling=np.flatnonzero(gates[:-1,slot]&~gates[1:,slot])+1
        for a in falling:
            later=np.flatnonzero(gates[a:,slot]);b=a+int(later[0]) if len(later) else n
            assert np.all(trace[a:b,slot]==trace[a-1,slot])
    original,fs=sf.read(BASE/previous['file'],always_2d=True)
    assert fs==FS and len(original)==n
    original_raw=np.load(BASE/'chorus_raw_q24.npy')
    active=abs(original_raw)>0
    rms=lambda y:float(np.sqrt(np.mean(np.asarray(y,dtype=float)[active]**2)))
    gain=min(rms(original[:,0])/max(rms(raw),1e-30),.88/max(float(abs(raw).max()),1e-30))
    y=raw.astype(float)*gain
    path=OUT/'mystery_of_love_chorus_flute_legato_bend.wav'
    sf.write(path,np.repeat(y[:,None],2,axis=1),FS,subtype='PCM_24')
    sf.write(OUT/'native.wav',np.repeat(native[:,None],2,axis=1),FS,subtype='PCM_16')
    check,fs=sf.read(path,always_2d=True)
    assert fs==FS and check.shape==(n,2) and np.isfinite(check).all() and abs(check).max()<.881
    sf.write(OUT/'original_then_legato_bend.wav',np.concatenate([original,np.zeros((round(.6*FS),2)),check]),FS,subtype='PCM_24')
    np.savez_compressed(OUT/'traces.npz',raw=raw,cents_q8=trace)
    overlap_frames=int(np.count_nonzero(gates.sum(axis=1)>1))
    report=dict(file=path.name,seconds=n/FS,event_count=31,melody_source=previous['melody_source'],
        changes='Adjacent notes: incoming onset40ms early, outgoing gate-off60ms late. Original phrase rests preserved. Rising transitions lift outgoing pitch to12c; falling transitions start incoming18c sharp and settle over100ms.',
        parameters=params,excitation=CONFIGS['gentle'],bend_cents_range=[float(trace.min()/256),float(trace.max()/256)],
        pressure_range=[int(pressure[gates].min()),int(pressure[gates].max())],aftertouch_threshold=102,
        control_updates=updates,control_interval_samples=P.INTERVAL,overlap_gate_seconds=overlap_frames/FS,
        state_rail_hits=rails,native_pcm_rail_samples=int(np.count_nonzero((native==-32768)|(native==32767))),
        peak_dbfs=float(20*np.log10(abs(check).max())),playback_gain=gain,events=events,
        checks='PASS pressure mapping all154 values; shared ratio for modal a1 and excitation phase; release pitch hold;31 retriggers; modal rails, tail silence and WAV peak.',
        scope='ENG1 sample-frame integer DSP with committed_delta replay of PAD-aftertouch-derived snapshots every96 samples. Pitch-engine FSM latency and MIDI/ADC timing not simulated. Existing pressure changes strike amplitude too. No unsupported negative bend/MIDI wheel; production RTL unchanged.',
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),Path(E.__file__),ROOT/'rtl/router/parts/modulation1.sv']})
    (OUT/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    (OUT/'README.md').write_text('''# Mystery of Love副歌：音头音尾重叠与小幅弯音

沿用上一版31音旋律、逐音轻奏权重、240ms Attack、85% Sustain、180ms Release与gentle激励。
相邻音提前40ms起音、延后60ms松键；乐句休止不连接。上行衔接尾音升至12音分；下行新音从+18音分在100ms内回本音。
使用当前PAD aftertouch的非负映射：102为0，100压力计数对应60音分。压力也影响原激励幅度。
松键后保持最后音高；同一P1T1/Q24比例同时改变激励相位增量与模态a1。

mystery_of_love_chorus_flute_legato_bend.wav：新版试听。
original_then_legato_bend.wav：先上一版，后新版。

按96采样控制周期回放committed_delta，未模拟控制FSM提交延迟或ADC/MIDI时钟。
未使用不受支持的负弯音/MIDI弯音接口；未修改生产RTL。
pressure_fixture.npz、traces.npz和manifest.json包含压力、门控、重触发和音高轨迹。
检查31次起音、释放音高保持、压力映射、模态轨限与输出峰值通过。
''')
    print(json.dumps({k:report[k] for k in ['seconds','bend_cents_range','overlap_gate_seconds','state_rail_hits','peak_dbfs']},indent=2),flush=True)
    print('PASS legato+aftertouch bend chorus',flush=True)

if __name__=='__main__':main()
