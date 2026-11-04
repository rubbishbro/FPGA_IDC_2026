"""MIDI57 pluck: current RTL coefficient modulation versus unmodulated control.

Run: python python_monotor/matrix_sim/sim_guitar_modulation.py
Coefficient arithmetic matches modulation0 (including Q formats/truncation).
The audio loop uses ENG0's fixed-point modal step, with simultaneous sample-level
coefficient updates; it does not model the router's background bus scheduling.
Body filtering uses the same quantized coefficients in floating point.
"""
from pathlib import Path
import argparse
import hashlib
import json
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / '_libs'))
sys.path.insert(0, str(HERE))

import numpy as np
from scipy.signal import sosfilt
from guitar_coeff_gen import gen_coeff7
from guitar_param_gen import gen_slot, string_params
from sim_guitar import BODY_BIQUADS
from synthlab.ext.io import save_wav

SR = 48000
MOD_TOP = 4
MAX_LAMBDA_Q30 = 37580959
FULL_PRESSURE = 230
CO_Q = np.array([28, 30, 23, 28, 32, 34, 29], dtype=np.int64)


def quantize(values, q):
    # guitar_flash.to_int uses Python round (ties to even), with int32 clipping.
    result = np.array([round(float(v) * 2**int(bits)) for v, bits in zip(values, q)], dtype=np.int64)
    if np.any(result < -2**31) or np.any(result > 2**31-1):
        raise ValueError('coefficient needs clipping; refusing to change timbre silently')
    return result


def lambda_from_pressure(pressure, threshold=102):
    pressure = int(pressure)
    if not 0 <= pressure <= 255 or not 0 <= threshold < 255:
        raise ValueError('invalid pressure or threshold')
    if pressure >= FULL_PRESSURE:
        return MAX_LAMBDA_Q30
    if pressure <= threshold:
        return 0
    span = max(1, FULL_PRESSURE - threshold)
    step = (MAX_LAMBDA_Q30 + span//2) // span
    return step * (pressure-threshold)


def modulation0(pm, lam):
    """Four Q31-truncated multiply-adds; returns a11/a12/a21/a22/wo int32.

    pm columns: a11(Q28),a12(Q30),a22(Q28),wo(Q29),S11/S12/S22/Swo(Q29).
    Apply to modes 0..3 only; the caller leaves the other modes untouched.
    """
    pm = np.asarray(pm, dtype=np.int64)
    a = pm[...,0] + ((int(lam)*pm[...,4]) >> 31)
    b = pm[...,1] + ((int(lam)*pm[...,5]) >> 29)
    d = pm[...,2] + ((int(lam)*pm[...,6]) >> 31)
    w = pm[...,3] + ((int(lam)*pm[...,7]) >> 30)
    out = np.stack([a,b,-(b >> 7),d,w], axis=-1)
    # RTL casts writeback fields to signed32, without saturation.
    return ((out + 2**31) % 2**32) - 2**31


def parameters(midi):
    f0, _length, tlr, pos, gamma = string_params(midi)
    base = np.array(gen_coeff7(f0, tlr, gamma, 20, pos)).T
    co = np.array([quantize(row, CO_Q) for row in base])
    _f0, rows, _err = gen_slot(midi)
    names = ['a11','a12','a22','wo','S11','S12','S22','Swo']
    pm = np.array([quantize([r['base'][k] for k in names], [28,30,28,29,29,29,29,29])
                   for r in rows])
    return co, pm


def coefficient_bank(co, pm, threshold):
    tables = np.repeat(co[None,:,:], 256, axis=0)
    for p in range(256):
        mod = modulation0(pm[:MOD_TOP], lambda_from_pressure(p, threshold))
        tables[p,:MOD_TOP,0:4] = mod[:,:4]
        tables[p,:MOD_TOP,6] = mod[:,4]
    assert np.array_equal(tables[:,MOD_TOP:,:], np.repeat(co[None,MOD_TOP:,:],256,axis=0))
    return tables


def term(state, coefficient, shift):
    return (state * coefficient + (1 << (shift-1))) >> shift


def synthesize(tables, pressures, excitation):
    q = np.zeros(20, dtype=np.int64)
    v = np.zeros(20, dtype=np.int64)
    out = np.empty(len(pressures), dtype=np.int64)
    clipped = 0
    state_peak = 0
    for n, p in enumerate(pressures):
        co = tables[int(p)]
        x = int(excitation[n])
        # ENG0 emits wo*OLD q; independently round products, then sum/saturate.
        out[n] = int(np.sum(term(q, co[:,6], 29)))
        qn = term(q,co[:,0],28) + term(v,co[:,1],30) + term(x,co[:,4],32)
        vn = term(q,co[:,2],23) + term(v,co[:,3],28) + term(x,co[:,5],34)
        clipped += int(np.count_nonzero((qn < -2**31) | (qn > 2**31-1)))
        clipped += int(np.count_nonzero((vn < -2**31) | (vn > 2**31-1)))
        q = np.clip(qn,-2**31,2**31-1)
        v = np.clip(vn,-2**31,2**31-1)
        state_peak = max(state_peak,int(np.abs(q).max()),int(np.abs(v).max()))
    return out, dict(state_saturations=clipped, state_peak_q24=state_peak)


def export_rtl_vectors(path, pm):
    """Vectors consumed by the real modulation0 testbench, including all pressures."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('w') as f:
        for _ in range(3):
            for pressure in range(256):
                for mode in range(5):
                    fields = [pressure, mode, *map(int,pm[mode])]
                    for threshold in [64,102,230]:
                        fields += list(map(int, modulation0(pm[mode], lambda_from_pressure(pressure,threshold))))
                    f.write(' '.join(map(str,fields))+'\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--midi',type=int,default=57)
    ap.add_argument('--seconds',type=float,default=4.0)
    ap.add_argument('--threshold',type=int,default=102)
    ap.add_argument('--out',type=Path,default=HERE/'out/guitar_modulation')
    args=ap.parse_args()
    if not 0 <= args.threshold < FULL_PRESSURE:
        ap.error('audio pressure threshold must be below 230')
    if args.seconds < 1:
        ap.error('at least one second is needed for the vibrato comparison')
    args.out.mkdir(parents=True,exist_ok=True)
    co, pm = parameters(args.midi)
    tables = coefficient_bank(co,pm,args.threshold)
    n = round(args.seconds*SR)
    t = np.arange(n)/SR
    # Unipolar 3 Hz cosine: start at maximum pressure so note-on is valid;
    # visit both lambda endpoints once per period, without negative bending.
    pressure = np.floor(args.threshold + (FULL_PRESSURE-args.threshold)*
                        (0.5+0.5*np.cos(2*np.pi*3*t)) + 0.5).astype(np.uint8)
    lam = np.array([lambda_from_pressure(p,args.threshold) for p in pressure],dtype=np.int64)
    assert lam.min()==0 and lam.max()==MAX_LAMBDA_Q30
    # Current exc_router guitar: SHIFT16/RISE_SH1/PW2/GAP0/N0 => 0,A/2,A,0...
    # Strike amplitude is held identical in A/B and independent of later pressure.
    excitation = np.zeros(n,dtype=np.int64)
    excitation[1:3] = [230<<15,230<<16]
    dry_raw, wet_raw, checks = {}, {}, {}
    # The no-vibrato control freezes lambda=0 through the same writeback path.
    # This also avoids confusing base a21 quantization with a modulation effect.
    control = np.full(n,args.threshold,dtype=np.uint8)
    body = np.floor(np.array(BODY_BIQUADS)*2**27+0.5)/2**27
    sos = np.column_stack([body[:,:3],np.ones(5),body[:,3:]])
    for name, pressures in [('no_vibrato',control),('vibrato_3hz',pressure)]:
        raw, check = synthesize(tables,pressures,excitation)
        # env_router guitar is currently constant while held; Q1.31 output gain.
        env_raw = np.array([(int(y)*0x7fffffff)>>31 for y in raw],dtype=np.int64)
        dry_raw[name] = env_raw
        wet_raw[name] = sosfilt(sos, env_raw.astype(float)/2**24)
        checks[name] = check
        assert check['state_saturations']==0
    gain = 10**(-2/20)/max(float(np.abs(y).max()) for y in wet_raw.values())
    outputs={}
    for name,y in wet_raw.items():
        y=y*gain
        # File boundary fade only; no ADSR, compressor or reverb is added.
        fade=round(0.03*SR)
        y[-fade:]*=np.linspace(1,0,fade)
        y=np.pad(y,(round(0.15*SR),round(0.15*SR)))
        assert np.isfinite(y).all() and np.abs(y).max()<1
        out=args.out/f'guitar_midi{args.midi}_{name}.wav'
        save_wav(out,y,sr=SR,subtype='PCM_16')
        outputs[name]=str(out.resolve())
    # Static diagnostics for all actual coefficients used in this render.
    radii=[]; cents=[]
    angle0=None
    for p in range(256):
        c=tables[p,:MOD_TOP]
        mat=np.zeros((MOD_TOP,2,2))
        mat[:,0,0]=c[:,0]/2**28;mat[:,0,1]=c[:,1]/2**30
        mat[:,1,0]=c[:,2]/2**23;mat[:,1,1]=c[:,3]/2**28
        ev=np.linalg.eigvals(mat)
        radii.append(float(np.abs(ev).max()))
        angles=np.angle(ev).max(axis=1)
        if p==0: angle0=angles
        cents.append((1200*np.log2(angles/angle0)).tolist())
    assert max(radii)<1
    np.savez_compressed(args.out/'render_data.npz',pressure=pressure,lambda_q30=lam,
                        excitation_q24=excitation,co=co,pm=pm,
                        no_vibrato_q24=dry_raw['no_vibrato'],vibrato_3hz_q24=dry_raw['vibrato_3hz'])
    export_rtl_vectors(ROOT/f'build/guitar_modulation/midi{args.midi}_vectors.txt',pm)
    sources=['rtl/router/parts/modulation.sv','rtl/router/parts/excitation.sv',
             'rtl/router/engines/eng0.sv','rtl/router/pkg/modal_step_pkg.sv',
             'python_monotor/matrix_sim/guitar_param_gen.py','python_monotor/matrix_sim/guitar_coeff_gen.py',
             'python_monotor/matrix_sim/sim_guitar.py','rtl/router/routers/exc_router.sv']
    metadata=dict(midi=args.midi,f0_hz=440*2**((args.midi-69)/12),sample_rate=SR,
                  active_seconds=args.seconds,file_seconds=args.seconds+0.3,vibrato_hz=3,
                  threshold=args.threshold,full_pressure=FULL_PRESSURE,
                  lambda_min=int(lam.min())/2**30,lambda_max=int(lam.max())/2**30,
                  maximum_modal_cents=cents[FULL_PRESSURE],modulated_modes=MOD_TOP,
                  total_modes=20,common_playback_gain=gain,checks=checks,
                  max_static_pole_radius=max(radii),outputs=outputs,
                  scope='RTL coefficient arithmetic and ENG0 sample step; float quantized-body filter; atomic sample updates, no cycle-level background scheduler',
                  source_sha256={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources})
    (args.out/'manifest.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(json.dumps(metadata,indent=2))

if __name__=='__main__':
    main()
