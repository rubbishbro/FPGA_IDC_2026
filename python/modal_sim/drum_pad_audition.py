#!/usr/bin/env python3
"""Dependency-free proposed drum PAD audition; not a production RTL simulation.
Q24 ENG1 free decay, velocity-scaled seeds, fixed pad lanes and 5ms retrigger
crossfade. No noise/body/reverb. Global listening gain is shared by all sections.
"""
import ast
from array import array
import hashlib
import json
import math
from pathlib import Path
import random
import struct
import wave
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'FFT_results/sim/eng1/drum_pad_audition'
FS = 48828  # integer WAV rate within 0.0003% of board 48828.125 Hz
ONE = 1 << 24
KEYS = ('kick', 'snare', 'tom', 'hat', 'ride', 'crash')
GAIN = dict(kick=1., snare=.8, tom=.8, hat=.30, ride=.28, crash=.45)
SOURCE = ROOT / 'FFT_results/params/drums.npz'


def read_array(z, name):
    b = z.read(name + '.npy')
    assert b[:8] == b'\x93NUMPY\x01\x00'
    length = struct.unpack('<H', b[8:10])[0]
    h = ast.literal_eval(b[10:10+length].decode())
    assert h['descr'] == '<f8' and not h['fortran_order']
    return struct.unpack('<' + 'd' * math.prod(h['shape']), b[10+length:])


def render_hit(z, key, velocity):
    f, g, a = (read_array(z, key + '__' + field) for field in ('f', 'gamma', 'a'))
    order = sorted(range(len(a)), key=lambda i: a[i], reverse=True)[:48]
    length = min(3., max(.15, 6.5 / max(min(g[i] for i in order), .1)))
    n = round(length * FS)
    fade = round(.005 * FS)
    out = array('d', [0.]) * (n + fade)
    rng = random.Random(zlib.crc32(key.encode()))
    velocity_q = round(velocity * GAIN[key] * 32768)
    saturated = 0
    for i in order:
        radius = math.exp(-g[i] / FS)
        a1 = round(-2 * radius * math.cos(2 * math.pi * f[i] / FS) * ONE)
        a2 = min(ONE-1, max(0, round(radius * radius * ONE)))
        rq = math.sqrt(a2 / ONE)
        theta = math.acos(max(-1., min(1., -a1 / ONE / (2*rq))))
        phase = rng.uniform(0, 2*math.pi)
        s1 = max(-2**31, min(2**31-1, math.floor(a[i]/rq*math.sin(phase-theta)*ONE+.5)))
        s2 = max(-2**31, min(2**31-1, math.floor(a[i]/rq**2*math.sin(phase-2*theta)*ONE+.5)))
        y1 = (s1*velocity_q + 16384) >> 15
        y2 = (s2*velocity_q + 16384) >> 15
        for j in range(n+fade):
            new = (-a1*y1 - a2*y2 + (1 << 23)) >> 24
            if new < -2**31 or new > 2**31-1:
                saturated += 1
                new = max(-2**31, min(2**31-1, new))
            out[j] += new / ONE
            y2, y1 = y1, new
    for j in range(fade):
        out[n+j] *= .5 * (1+math.cos(math.pi*(j+1)/fade))
    return out, dict(modes=len(order), length_s=length, saturated_states=saturated)


def score():
    ev = []
    def hit(t, key, v=.9, pad=None, hold=.06):
        ev.append(dict(time=t, key=key, velocity=v, pad=pad or key, hold_s=hold))
    # Same output gain: six isolated hits, then soft/medium/hard snare.
    for i,k in enumerate(KEYS): hit(.3 + i*1.65, k)
    for t,v in ((10.4,.35),(11.1,.65),(11.8,.9)): hit(t,'snare',v)
    # Short press and long press sound the same; only rising edges trigger.
    hit(12.7,'crash',.65,hold=.04)
    hit(15.9,'crash',.65,hold=1.4)
    beat = 60/108
    start = 19.2
    for bar in range(8):
        t = start + bar*4*beat
        for b,v in ((0,.9),(2,.9),(2.5,.65)):
            hit(t+b*beat,'kick',v)
        for b in (1,3): hit(t+b*beat,'snare',.9)
        if bar == 3 or bar == 7:
            for j in range(8):
                k = 'snare' if j<4 else 'tom'
                hit(t+(2+j*.25)*beat,k,.65 if j%2 else .9)
        for j in range(8):
            k = 'hat' if bar<4 else 'ride'
            hit(t+j*.5*beat,k,.65 if j%2 else .9)
        if bar in (0,4): hit(t,'crash',.65)
    hit(start+32*beat,'kick',.9)
    hit(start+32*beat,'crash',.9)
    return sorted(ev,key=lambda e:e['time']), start+32*beat+3.3


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    events, seconds = score()
    cache = {}; metrics = {}
    with zipfile.ZipFile(SOURCE) as z:
        for key,v in sorted({(e['key'],e['velocity']) for e in events}):
            cache[key,v], metrics[f'{key}:{v}'] = render_hit(z,key,v)
            print('rendered',key,v,flush=True)
    mix = array('d',[0.])*round(seconds*FS)
    fade = round(.005*FS)
    for index,e in enumerate(events):
        clip = cache[e['key'],e['velocity']]
        at = round(e['time']*FS)
        following = next((x for x in events[index+1:] if x['pad']==e['pad']),None)
        cut = round((following['time']-e['time'])*FS) if following else len(clip)
        for j in range(min(len(clip),len(mix)-at,cut+fade)):
            w = .5*(1+math.cos(math.pi*(j-cut+1)/fade)) if j>=cut else 1.
            mix[at+j] += clip[j]*w
    peak = max(map(abs,mix)); gain = .85/max(peak,1e-12)
    def write(name, first, last):
        pcm = array('h',(round(x*gain*32767) for x in mix[round(first*FS):round(last*FS)]))
        import sys
        if sys.byteorder != 'little': pcm.byteswap()
        with wave.open(str(OUT/name),'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(FS); w.writeframes(pcm.tobytes())
    write('drum_pad_full.wav',0,seconds)
    write('drum_pad_groove.wav',19.2,seconds)
    report = dict(sample_rate=FS,seconds=seconds,source_sha256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        model='Q24 coefficients/states, <=48 modes, velocity-scaled seeds; fixed pad retrigger with 5ms crossfade',
        omitted=['noise branch','reverb','body filter','ADC/RTL scheduling','board output gain'],
        global_listening_gain=gain, output_peak=.85, events=events, hits=metrics)
    (OUT/'manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    assert all(m['saturated_states']==0 for m in metrics.values()), 'State saturation detected'
    print(json.dumps(dict(output=str(OUT),seconds=seconds,hits=len(events),peak=.85,state_saturations=0)),flush=True)

if __name__=='__main__': main()
