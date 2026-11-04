#!/usr/bin/env python3
"""Check the production piano ABC silence policy across the 44..75 bank."""
from pathlib import Path
import sys
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'rtl/router/tools'),str(ROOT/'python_monotor/modal_sim')]
import matrix_resources as M
import performance_resources as P
import pitch_linear as L
import router_eng1 as R

def check():
    total=0
    for midi in range(44,76):
        table,row=M.piano_abc(midi)
        assert row['unstable_abc_policy']=='zero_coefficients_preserve_peak_ranking'
        data=P.abc_record(table)
        words=np.frombuffer(data,dtype='>i4').reshape(64,16)
        silent=np.all(words[:table.n_modes,:3]==0,axis=1)
        assert np.flatnonzero(silent).tolist()==row['muted_selected_modes']
        assert row['sounding_modes']==int(np.count_nonzero(~silent))
        assert all(words[k,8:15].tolist()==[0]*7 for k in np.flatnonzero(silent))
        bad={r['mode'] for r in row['muted_source_modes']}
        assert {row['matrix_source_modes'][k] for k in np.flatnonzero(silent)}==bad.intersection(row['matrix_source_modes'])
        core=R.Eng1Core(slots=1,n_modes=64);core.load_slot(0,table)
        core.y1[:]=1234567;core.y2[:]=-7654321
        for x in [-2147483648,2147483647,0]:
            _,y=core.step([x],[False],active_modes=48)
            assert np.all(y[0,np.flatnonzero(silent)]==0)
        if np.any(silent):
            for delta in [-16777216,0,16777216]:
                assert L.coefficient(0,0,0,0,delta)==0
        total+=int(silent.sum())
        if midi==70:assert row['sounding_modes']==47 and row['muted_selected_modes']==[46]
    # The silence exception must not admit an excited zero-a2 resonator.
    try:P.abc_record(R.Eng1Coeffs(np.array([1]),np.array([0]),np.array([0]),1))
    except ValueError:pass
    else:raise AssertionError('noncanonical silent record accepted')
    print(f'PASS 32 piano ABC notes; {total} silent selected records; zero output with stale state and pitch metadata')
if __name__=='__main__':check()
