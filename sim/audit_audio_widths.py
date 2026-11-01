"""Independent integer width audit; read-only production RTL, full-width regression probes."""
from pathlib import Path
import argparse, json, os, random, re, shutil, subprocess
ROOT=Path(__file__).resolve().parents[1]
Q=[28,30,23,28,32,34,29]
def sat(x,b):return max(-(1<<(b-1)),min((1<<(b-1))-1,x))
def term(x,c,q):return (x*c+(1<<(q-1)))>>q

def generate(out):
    rng=random.Random(20261101)
    text=[]
    for j in range(256):
        n=[1,2,20,64][j%4] if j<32 else rng.randrange(1,65)
        z=int(j%3==0);x=rng.randrange(-2**31,2**31);rows=[];total=0
        for m in range(64):
            c=[rng.randrange(-2**31,2**31) for _ in range(7)]
            q,v=[rng.randrange(-2**31,2**31) for _ in range(2)]
            a,b=(0,0) if z else (q,v)
            eq,ev=q,v
            if m<n:
                eq=sat(term(a,c[0],28)+term(b,c[1],30)+term(x,c[4],32),32)
                ev=sat(term(a,c[2],23)+term(b,c[3],28)+term(x,c[5],34),32)
                total+=term(a,c[6],29)
            rows.append(' '.join(map(str,[*c,q,v,eq,ev])))
        text += [f'{n} {z} {x} {total}',*rows]
    (out/'eng0_cases.txt').write_text('\n'.join(text)+'\n')
    tb=(ROOT/'sim/unit/audio/tb_eng1_pipeline.sv').read_text()
    tb=tb.replace('tb_eng1_pipeline','tb_eng0_width_audit').replace('eng1 dut','eng0 dut').replace('eng1_cases.txt','eng0_cases.txt')
    tb=tb.replace('logic signed [31:0] g[64],a1[64],a2[64],qm[64],vm[64],eq[64],ev[64];','modal_step_pkg::coeff_t cm[64];\n    logic signed [31:0] qm[64],vm[64],eq[64],ev[64];')
    tb=tb.replace("cd<='0;cd.a11<=g[ca];cd.a12<=a1[ca];cd.a21<=a2[ca];",'cd<=cm[ca];')
    tb=tb.replace('"%d %d %d %d %d %d %d",g[i],a1[i],a2[i],qm[i],vm[i],eq[i],ev[i]', '"%d %d %d %d %d %d %d %d %d %d %d",cm[i].a11,cm[i].a12,cm[i].a21,cm[i].a22,cm[i].gq,cm[i].gv,cm[i].wo,qm[i],vm[i],eq[i],ev[i]')
    tb=tb.replace('rc!=7','rc!=11')
    (out/'tb_eng0_width_audit.sv').write_text(tb)
    source=(ROOT/'rtl/router/routers/body_router.sv').read_text()
    identity=[[1<<27,0,0,0,0] for _ in range(5)]
    tables=[identity,[[8<<27,0,0,0,0],*identity[1:]]]
    for name,stop in [('GUITAR','PIANO'),('PIANO','default:')]:
        part=source.split('router_pkg::INST_'+name+': begin')[1]
        part=part.split('router_pkg::INST_'+stop if stop!='default:' else stop)[0]
        table=[r[:] for r in identity]
        for idx,sign,value in re.findall(r"coef_q\[\s*(\d+)\s*\]\s*=\s*(-?)32'sd(\d+)",part):
            table[int(idx)//5][int(idx)%5]=(-1 if sign else 1)*int(value)
        tables.append(table)
    text=[]
    for table in tables:
        text += [' '.join(map(str,sum(table,[])))]
        hist=[[0,0,0,0] for _ in table]
        for i in range(128):
            probes=[0,1,-1,2**24,-2**24,2**42,-2**42,2**63-1,-2**63]
            x=probes[i%len(probes)] if i<64 else rng.randrange(-2**63,2**63)
            a=x<<4
            for k,(b0,b1,b2,a1,a2) in enumerate(table):
                x1,x2,y1,y2=hist[k]
                b=sat((b0*a+b1*x1+b2*x2-a1*y1-a2*y2+(1<<26))>>27,68)
                hist[k]=[a,x1,b,y1];a=b
            expected=sat((a+8)>>4,64)
            text.append(f'{x} {expected}')
    (out/'body_cases.txt').write_text('\n'.join(text)+'\n')

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=ROOT/'build/audio_width_audit_20261101/core')
    a=ap.parse_args();out=a.out.resolve();out.mkdir(parents=True,exist_ok=True);generate(out)
    ini=Path.home()/'gowin/simlib_questa/modelsim.ini';work=out/'work'
    (out/'modelsim.ini').write_text(re.sub(r'^work\s*=.*$','work = '+str(work),ini.read_text(),flags=re.M))
    env=os.environ.copy();env['MODELSIM']=env['QSIM_INI']=str(out/'modelsim.ini')
    def run(tool,args,log):
        exe=shutil.which(tool) or str(Path.home()/'.local/bin'/tool)
        p=subprocess.run([exe,*map(str,args)],cwd=out,env=env,capture_output=True,text=True,timeout=180)
        s=p.stdout+p.stderr;(out/(log+'.log')).write_text(s)
        if p.returncode or re.search(r'\*\* (?:Error|Fatal)|\bFAIL\b|Trouble making server',s):raise RuntimeError(s[-5000:])
        return s
    run('vlib',[work],'vlib')
    src=['rtl/math/pkg/fxp_pkg.sv','rtl/router/pkg/modal_step_pkg.sv','rtl/router/pkg/router_pkg.sv',
         'rtl/router/engines/eng0.sv','rtl/router/engines/eng1.sv','rtl/router/parts/body_biquad.sv',
         'rtl/router/parts/comb_reverb.sv','rtl/router/routers/reverb_router.sv',
         'sim/unit/audio/tb_audio_width_probes.sv']
    run('vlog',['-sv','-work',work,*[ROOT/p for p in src],out/'tb_eng0_width_audit.sv'],'compile')
    for top in ['tb_eng0_width_audit','tb_body_width_audit','tb_reverb_width_probes']:
        s=run('vsim',['-c','-lib',work,top,'-do','run -all; quit -f'],top)
        print('\n'.join(line for line in s.splitlines() if 'PASS ' in line or 'DONE ' in line),flush=True)
    results=[]
    buf=None;phase_old=None;idx=[0]*4;ns=[2,3,4,5]
    for line in (out/'reverb_observed.txt').read_text().splitlines():
        kind,*vals=line.split();vals=list(map(int,vals))
        if kind=='NONE':
            x,y=vals;results.append(dict(kind=kind,input=x,observed=y,expected=x,mismatch=y!=x))
        elif kind=='COMB':
            phase,n,x,y=vals
            if phase!=phase_old:buf=[[0]*d for d in ns];idx=[0]*4;phase_old=phase
            taps=[buf[k][idx[k]] for k in range(4)]
            expected=sat(sum((s*(1<<25))>>27 for s in taps),64)
            for k in range(4):
                buf[k][idx[k]]=sat(x+((taps[k]*(1<<26))>>27),64)
                idx[k]=(idx[k]+1)%ns[k]
            results.append(dict(kind=kind,phase=phase,sample=n,input=x,observed=y,expected=expected,mismatch=y!=expected))
        elif kind=='SUM':
            case,y=vals;expected=2**63-1 if case==0 else -2**63
            results.append(dict(kind=kind,case=case,observed=y,expected=expected,mismatch=y!=expected))
    summary=dict(rows=results,eng0_jobs=256,body_frames=512,
                 reverb_mismatches=sum(r['mismatch'] for r in results),
                 mismatches_by_kind={kind:sum(r['mismatch'] for r in results if r['kind']==kind) for kind in ['NONE','COMB','SUM']},
                 note='SUM additionally exercises positive and negative weighted-sum overflow; all probes must match')
    (out/'results.json').write_text(json.dumps(summary,indent=2)+'\n')
    assert summary['reverb_mismatches']==0, summary['mismatches_by_kind']
    print('PASS full-width reverb regression:',summary['mismatches_by_kind'])

if __name__=='__main__':main()
