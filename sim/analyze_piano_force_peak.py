"""Summarize raw signed64 voice_router peaks; never converts to PCM or normalizes."""
from pathlib import Path
import argparse, csv, json

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--out',type=Path,default=Path(__file__).resolve().parents[1]/'build/piano_peak_20261101')
 a=ap.parse_args();out=a.out
 log=(out/'verify.log').read_text()
 assert 'PASS tb_piano_force_peak raw signed64 capture complete' in log,'simulation incomplete'
 rows=[list(map(int,line.split())) for line in (out/'raw_trace.txt').read_text().splitlines()]
 assert len(rows)==7*4096
 results=[]
 for ident in range(7):
  r=[v for v in rows if v[0]==ident]
  assert len(r)==4096 and all(v[6]==v[7] and v[8]==0 for v in r)
  if ident<6: assert all(v[5]==(v[4]*v[3])>>31 for v in r), 'envelope alignment mismatch'
  envmax=max(v[3] for v in r)
  assert envmax==2147483647
  # Explicit window: envelope at least 90% of its full-scale maximum.
  window=[v for v in r if v[3]>=1932735282]
  peak=max(window,key=lambda v:abs(v[7]))
  exact=[v for v in r if v[3]==envmax]
  exact_peak=max(exact,key=lambda v:abs(v[7]))
  global_peak=max(r,key=lambda v:abs(v[7]))
  def point(v):
   return dict(frame=v[1],envelope_q31=v[3],y_data_signed64=v[7],absolute_peak_raw=abs(v[7]))
  spec=dict(case=ident,midi=(40 if ident<3 else 60) if ident<6 else None,
            slot=0 if ident<3 or ident==6 else 10,force=[68,128,255][ident%3] if ident<6 else 255,
            all16=ident==6,frames=4096,
            envelope_max=envmax,at_envelope_max=point(exact_peak),
            near_max_window=dict(min_frame=window[0][1],max_frame=window[-1][1],min_envelope=1932735282),
            near_max_peak=point(peak),whole_capture_peak=point(global_peak),
            near_max_stage_peaks={name:max(abs(v[col]) for v in window) for name,col in
                                  [('selected_engine_output',4),('voice_mix_after_envelope',5),('body_output',6),('voice_router_y_data',7)]})
  results.append(spec)
 metadata=dict(amplitude_units='raw signed64 integers; no PCM conversion or normalization',
               rtl_sample_rate_parameter=48000,core_clock_hz=50000000,cycles_per_frame=1024,
               envelope_window_definition='emap_frame >= 1932735282 (90% maximum); not amplitude normalization',
               reverb='NONE',piano_modes=64,results=results)
 (out/'peaks.json').write_text(json.dumps(metadata,indent=2)+'\n')
 with (out/'peaks.csv').open('w') as f:
  w=csv.writer(f);w.writerow(['midi','force','all16','y_at_env_max','peak_raw_near_env_max','peak_raw_whole_capture','near_peak_frame'])
  for r in results:w.writerow([r['midi'],r['force'],r['all16'],r['at_envelope_max']['y_data_signed64'],r['near_max_peak']['absolute_peak_raw'],r['whole_capture_peak']['absolute_peak_raw'],r['near_max_peak']['frame']])
 print((out/'peaks.csv').read_text())

if __name__=='__main__':main()
