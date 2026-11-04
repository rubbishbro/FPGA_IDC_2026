"""Quantized static-pole audit of modulation0; does not modify Flash resources."""
from pathlib import Path
import hashlib
import json
import math
import struct
import re
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
FULL_PRESSURE = 230
CURRENT_CAP=int(re.search(r'MAX_LAMBDA_Q30\s*=\s*32\x27sd([\d_]+)',(ROOT/'rtl/router/parts/modulation0.sv').read_text())[1].replace('_',''))
Q50 = round((2 ** (50 / 1200) - 1) * 2**30)
NOTES = [40,42,44,46,48,50,52,54,56,58,60,62,64,67,71,76]


def matrix(pm, lam):
    a, b, d, _w, sa, sb, sd, _sw = map(int, pm)
    a += (lam * sa) >> 31
    b += (lam * sb) >> 29
    d += (lam * sd) >> 31
    c = -(b >> 7)  # RTL arithmetic shift BEFORE negation, Q30 -> Q23.
    return np.array([[a / 2**28, b / 2**30], [c / 2**23, d / 2**28]])


def evaluate(rows, cap, top):
    worst, fail, errors = None, 0, []
    # Include all actual pressure codes for every supported threshold used by
    # this regression, plus a uniformly spaced reference grid.
    lambdas = {(cap * pressure + 127) // 255 for pressure in range(256)}
    for threshold in [64, 102, 230]:
        step = (cap + max(1, FULL_PRESSURE-threshold)//2) // max(1, FULL_PRESSURE-threshold)
        lambdas.update(cap if p >= FULL_PRESSURE else
                       (0 if p <= threshold else step*(p-threshold)) for p in range(256))
    for note, mode, pm in rows:
        if mode >= top:
            continue
        base_angle = np.angle(np.linalg.eigvals(matrix(pm, 0))).max()
        for lam in sorted(lambdas):
            ev = np.linalg.eigvals(matrix(pm, lam))
            radius = float(np.abs(ev).max())
            tr = float(np.trace(matrix(pm, lam)))
            det = float(np.linalg.det(matrix(pm, lam)))
            jury = min(1 - det, 1 - tr + det, 1 + tr + det)
            fail += int(radius >= 1 or jury <= 0)
            item = dict(radius=radius, midi=note, mode=mode, lambda_q30=lam,
                        jury_margin=jury)
            if worst is None or radius > worst['radius']:
                worst = item
            if lam == cap:
                cents = 1200 * math.log2(float(np.angle(ev).max()) / base_angle)
                errors.append(cents)
    return dict(worst=worst, unstable_points=fail, points=len(errors)*len(lambdas),
                endpoint_cents_min=min(errors), endpoint_cents_max=max(errors))


def safe_common_cap(rows):
    """Conservative common cap candidate; validate every code after clamping.

    Bisection is a search aid, not proof of a continuous stability interval.
    The final safety result is the explicit 256-code sweep below.
    """
    p = np.array([row[2] for row in rows], dtype=np.int64)
    def worst(lam):
        a = (p[:,0] + ((lam*p[:,4]) >> 31)) / 2**28
        bi = p[:,1] + ((lam*p[:,5]) >> 29)
        b, c = bi / 2**30, -(bi >> 7) / 2**23
        d = (p[:,2] + ((lam*p[:,6]) >> 31)) / 2**28
        tr, det = a+d, a*d-b*c
        margins = np.minimum.reduce([1-det, 1-tr+det, 1+tr+det])
        return float(margins.min())
    lo, hi = 0, Q50
    while hi-lo > 1:
        mid=(lo+hi)//2
        if worst(mid)>0: lo=mid
        else: hi=mid
    cap=int(lo*0.98)
    levels=set()
    for threshold in [64,102,230]:
        step=(cap+max(1, FULL_PRESSURE-threshold)//2)//max(1, FULL_PRESSURE-threshold)
        levels.update(cap if x>=FULL_PRESSURE else 0 if x<=threshold else step*(x-threshold)
                      for x in range(256))
    margin=min(worst(lam) for lam in levels)
    assert margin>0
    return dict(candidate_lambda_q30=cap, nominal_cents=1200*math.log2(1+cap/2**30),
                sampled_jury_margin_min=margin,
                scope="all 20 modes, all actual pressure codes at thresholds 64/102/230; static only")


def main():
    image = ROOT / 'rtl/router/tools/coefficients/eng0_guitar.bin'
    raw = image.read_bytes()
    rows = []
    for slot, note in enumerate(NOTES):
        for mode in range(20):
            v = struct.unpack_from('>16i', raw, 65536 + (slot*64+mode)*64)
            rows.append((note, mode, v[8:16]))
    # Broader generated text catalog, quantized into the same PM field formats.
    catalog, note = [], None
    for line in (ROOT/'python_monotor/matrix_sim/guitar_param.txt').read_text().splitlines():
        if line.startswith('midi'):
            note = int(line[4:])
        elif line.startswith('mode'):
            label, values = line.split(':')
            mode = int(label[4:]); v = list(map(float, values.split(',')))
            pm = [round(v[i]*2**q) for i,q in [(0,28),(1,30),(3,28),(4,29),(5,29),(7,29),(6,29),(9,29)]]
            catalog.append((note, mode, pm))
    results = dict(lambda_50_q30=Q50, lambda_50=Q50/2**30,
                   old_nominal_cents=1200*math.log2(1+37580959/2**30),
                   source_sha256=hashlib.sha256(raw).hexdigest(),
                   notes=NOTES, flash_is_repository_image_not_board_readback=True)
    for name, data in [('flash16',rows),('catalog',catalog)]:
        for label,cap,top in [('old_4',37580959,4),('current_4',CURRENT_CAP,4),('nominal50_4',Q50,4),('nominal50_20',Q50,20)]:
            results[name+'_'+label] = evaluate(data,cap,top)
    results['catalog_common_clamp20'] = safe_common_cap(catalog)
    out=ROOT/'build/modulation_threshold'
    out.mkdir(parents=True,exist_ok=True)
    (out/'analysis.json').write_text(json.dumps(results,indent=2)+'\n')
    # Inputs and independently computed fixed-point writeback for RTL regression.
    # All pressure values; modes 0..3 updated, mode 4 must not be written.
    with (out/'vectors.txt').open('w') as f:
        for slot in [0,4,15]:
            for pressure in range(256):
                for mode in range(5):
                    pm=rows[slot*20+mode][2]
                    outputs=[]
                    for threshold in [64,102,230]:
                        step=(CURRENT_CAP+max(1, FULL_PRESSURE-threshold)//2)//max(1, FULL_PRESSURE-threshold)
                        lam=CURRENT_CAP if pressure>=FULL_PRESSURE else (0 if pressure<=threshold else step*(pressure-threshold))
                        a,b,d,w,sa,sb,sd,sw=pm
                        a+=(lam*sa)>>31;b+=(lam*sb)>>29;d+=(lam*sd)>>31;w+=(lam*sw)>>30
                        outputs += [a,b,-(b>>7),d,w]
                    f.write(' '.join(map(str,[pressure,mode,*pm,*outputs]))+'\n')
    print(json.dumps(results,indent=2))

if __name__=='__main__':
    main()
