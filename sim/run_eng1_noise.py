#!/usr/bin/env python3
"""Production ENG1 versus independent integer oracle, with synchronous 1R1W RAM.
No numpy/tool installation needed. Covers noise disable/clear/trigger and ABC.
"""
from pathlib import Path
import json
import os
import random
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/eng1_noise'
Q=1<<24


def sat(x): return max(-2**31,min(2**31-1,x))
def signed(x,bits=32): return (x+(1<<(bits-1)))%(1<<bits)-(1<<(bits-1))
def u(x): return x&0xffffffff

def oracle(co,q,v,n,clear,x):
    q=list(q);v=list(v);out=0;writes=[0]*64
    n=min(n,64); regular=min(n,48)
    for i in range(regular):
        old1,old2=(0,0) if clear else (signed(q[i]),signed(v[i]))
        g,a1,a2= signed(co[i][0],26),signed(co[i][1],26),u(co[i][2])&0xffffff
        new=sat((g*x-a1*old1-a2*old2+(1<<23))>>24)
        q[i],v[i]=u(new),u(old1);out+=new;writes[i]=1
    if n>48:
        for i in range(48,n,2):
            seed,initial,decay,lo_a,hi_a,gain,_=co[i]
            restart=q[i]==0 and x>0
            pair=i+1<n
            disabled=(clear or not pair or not seed or initial>Q or decay>Q or
                      lo_a>hi_a or hi_a>Q or signed(gain)<=0 or
                      (q[i]==0 and x<=0) or (q[i]!=0 and v[i]>Q))
            if disabled:
                q[i]=v[i]=0;writes[i]=1
                if pair:q[i+1]=v[i+1]=0;writes[i+1]=1
                continue
            lfsr=seed if restart else q[i]
            env=(initial*min(x,Q)+(Q>>1))>>24 if restart else v[i]
            low,high=(0,0) if restart else (signed(q[i+1]),signed(v[i+1]))
            bit=Q if lfsr&1 else -Q
            low=sat(low+(((bit-low)*lo_a+(1<<23))>>24))
            high=sat(high+(((bit-high)*hi_a+(1<<23))>>24))
            shaped=sat(((high-low)*env+(1<<23))>>24)
            out+=sat((shaped*signed(gain)+32768)>>16)
            q[i]=(lfsr>>1)^(0x80200003 if lfsr&1 else 0)
            v[i]=(env*decay+(1<<23))>>24
            q[i+1],v[i+1]=u(low),u(high);writes[i]=writes[i+1]=1
    return q,v,out,writes


def vectors():
    rng=random.Random(20261102);cases=[]
    co=[[0]*7 for _ in range(64)];q=[0]*64;v=[0]*64
    def add(name,n=52,clear=0,x=0):
        nonlocal q,v
        before=(list(q),list(v))
        afterq,afterv,out,writes=oracle(co,q,v,n,clear,x)
        cases.append((name,(n,clear,x),[list(c) for c in co],before,afterq,afterv,out,writes))
        q,v=afterq,afterv
    q=[rng.getrandbits(32) for _ in range(64)];v=[rng.getrandbits(32) for _ in range(64)]
    add('all_zero_flash_clears_stale_states',x=Q)
    good=[0x81234567,Q,Q-10,Q//20,Q//2,65536,0]
    co[48]=good.copy();co[50]=[0x10203040,Q//2,Q-30000,Q//10,Q//2,90000,0]
    add('maintenance_clears_even_with_positive_x',clear=1,x=Q)
    add('nonzero_seed_does_not_self_start')
    add('negative_excitation_does_not_start',x=-Q)
    add('two_branches_auto_start',x=Q*2//3)
    assert q[48] and q[50]
    for i in range(250):add(f'free_decay_{i}',x=(Q if i%7==0 else 0))
    add('clear_prepares_retrigger',clear=1,x=Q)
    add('zero_excitation_delays_start')
    add('positive_excitation_retriggers',x=Q//4)
    add('clear_before_clamp',clear=1)
    add('amplitude_clamps_at_one',x=2*Q)
    # Only changing Flash seed shuts off a running branch; no extra control port.
    co[48][0]=0
    add('zero_seed_while_running_clears_pair',x=Q)
    assert q[48]==v[48]==q[49]==v[49]==0 and q[50]!=0
    co[48][0]=good[0]
    add('restore_seed_waits_for_excitation')
    assert q[48]==v[48]==q[49]==v[49]==0
    add('restore_seed_then_hit',x=Q//2)
    assert q[48]!=0
    # Reserved fields/tags do not act as a second hidden enable.
    co[48][6]=0xffffffff;co[49]=[0xffffffff]*7
    add('reserved_fields_are_ignored',clear=1)
    add('seed_alone_enables_without_tags',x=Q)
    assert q[48]!=0
    co[48]=[0]*7;co[49]=[0]*7
    add('all_zero_record_while_running')
    assert q[48]==v[48]==q[49]==v[49]==0
    for field,value in ((0,0),(1,Q+1),(2,Q+1),(3,Q),(4,Q+1),(5,0),(5,0xffffffff)):
        co[48]=good.copy();co[48][field]=value
        add(f'invalid_field_{field}_{value}',n=50,x=Q)
        assert q[48]==v[48]==q[49]==v[49]==0
    co[48]=good.copy()
    add('single_tail_slot',n=49,x=Q)
    add('full64_noise_records',n=64,x=Q)
    add('empty_job',n=0)
    add('48_modes_do_not_read_noise_records',n=48)
    # Current ordinary ENG1 resources have <=48 active modes.
    for j in range(100):
        co=[[rng.getrandbits(32) for _ in range(7)] for _ in range(64)]
        q=[rng.getrandbits(32) for _ in range(64)];v=[rng.getrandbits(32) for _ in range(64)]
        add(f'abc_or_noise_boundary_{j}',n=(0,1,20,48,49,50,52,64,127)[j%9],clear=j%3==0,x=signed(rng.getrandbits(32)))
    for j in range(40):
        for i in range(48):co[i]=[rng.randrange(-Q,Q),rng.randrange(-Q,Q),rng.randrange(Q),0,0,0,0]
        co[48]=good.copy();co[49]=[0]*7
        co[50]=[12345,Q,Q-1000,Q//30,Q//4,32123,0];co[51]=[0]*7
        add(f'mixed_{j}',n=52,clear=j%17==0,x=rng.randrange(-Q,Q))
    return cases


TB=r'''`timescale 1ns/1ps
module tb_eng1_noise;
    import modal_step_pkg::*;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,start=0,st_zero=0;
    logic [6:0] n_modes=0;
    logic co_re,st_re,st_we,x_re,y_valid;
    logic [5:0] co_addr,st_addr,st_waddr;
    coeff_t co_data, coefficients[0:63];
    logic signed [31:0] st_q,st_qdot,st_q_wdata,st_qdot_wdata,x_data=0;
    logic signed [63:0] y_data;
    logic [31:0] qmem[0:63],vmem[0:63],expectedq[0:63],expectedv[0:63];
    integer counts[0:63],expectedwrites[0:63];
    eng1 dut(.*);
    always @(posedge clk) begin
        if(co_re) co_data<=coefficients[co_addr];
        if(st_re)begin st_q<=qmem[st_addr];st_qdot<=vmem[st_addr];end
        if(st_we)begin
            qmem[st_waddr]<=st_q_wdata;vmem[st_waddr]<=st_qdot_wdata;
            counts[st_waddr]<=counts[st_waddr]+1;
        end
    end
    integer file,scan,jobs,job,i,cycles,maxcycles=0;
    logic [31:0] a,b,c,d,e,f,g,qi,vi,eq,ev;
    logic signed [63:0] expectedout;
    initial begin
        file=$fopen("vectors.txt","r");if(!file)$fatal(1,"missing vectors");
        scan=$fscanf(file,"%d",jobs);
        repeat(3)@(negedge clk);rst_n=1;
        for(job=0;job<jobs;job=job+1)begin
            @(negedge clk);
            scan=$fscanf(file,"%d %d %h %h",n_modes,st_zero,x_data,expectedout);
            if(scan!=4)$fatal(1,"control parse job %0d",job);
            for(i=0;i<64;i=i+1)begin
                scan=$fscanf(file,"%h %h %h %h %h %h %h %h %h %h %h %d",a,b,c,d,e,f,g,qi,vi,eq,ev,expectedwrites[i]);
                if(scan!=12)$fatal(1,"row parse");
                coefficients[i]={a,b,c,d,e,f,g};qmem[i]=qi;vmem[i]=vi;
                expectedq[i]=eq;expectedv[i]=ev;counts[i]=0;
            end
            start=1;@(negedge clk);start=0;
            // Inputs changing while a job runs must not change the latched controls.
            st_zero=~st_zero;n_modes=0;
            cycles=0;
            while(!y_valid && cycles<300)begin @(negedge clk);cycles=cycles+1;end
            if(!y_valid)$fatal(1,"timeout job %0d",job);
            if(y_data!==expectedout)$fatal(1,"mix job %0d got %0d expected %0d",job,y_data,expectedout);
            for(i=0;i<64;i=i+1)begin
                if(qmem[i]!==expectedq[i] || vmem[i]!==expectedv[i])
                    $fatal(1,"state job %0d slot %0d got %h/%h expected %h/%h",job,i,qmem[i],vmem[i],expectedq[i],expectedv[i]);
                if(counts[i]!=expectedwrites[i])$fatal(1,"write count job %0d slot %0d",job,i);
            end
            if(cycles>maxcycles)maxcycles=cycles;
            @(negedge clk);
            if(y_valid)$fatal(1,"duplicate completion");
        end
        $display("PASS ENG1 ABC/noise %0d jobs max_cycles=%0d",jobs,maxcycles);$finish;
    end
endmodule
'''


def executable(name):
    found=os.environ.get(name.upper()) or shutil.which(name)
    if found:return found
    p=Path.home()/'micromamba/envs/torch312/bin'/name
    if p.is_file():return str(p)
    raise RuntimeError(f'{name} not found')


def main():
    OUT.mkdir(parents=True,exist_ok=True);cases=vectors()
    with (OUT/'vectors.txt').open('w') as f:
        f.write(f'{len(cases)}\n')
        for name,control,co,(q,v),eq,ev,out,writes in cases:
            n,cl,x=control
            f.write(f'{n} {int(cl)} {u(x):08x} {out&((1<<64)-1):016x}\n')
            for i in range(64):f.write(' '.join(f'{u(x):08x}' for x in (*co[i],q[i],v[i],eq[i],ev[i]))+f' {writes[i]}\n')
    (OUT/'tb_eng1_noise.sv').write_text(TB)
    image=OUT/'test.vvp'
    cmd=[executable('iverilog'),'-g2012','-Wall','-s','tb_eng1_noise','-o',str(image),
         str(ROOT/'rtl/math/pkg/fxp_pkg.sv'),str(ROOT/'rtl/router/pkg/modal_step_pkg.sv'),
         str(ROOT/'rtl/router/engines/eng1.sv'),str(OUT/'tb_eng1_noise.sv')]
    c=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
    (OUT/'compile.log').write_text(c.stdout+c.stderr)
    if c.returncode:raise RuntimeError(c.stdout+c.stderr)
    r=subprocess.run([executable('vvp'),str(image)],cwd=OUT,capture_output=True,text=True,timeout=60)
    (OUT/'run.log').write_text(r.stdout+r.stderr)
    print(r.stdout+r.stderr,end='')
    if r.returncode:raise RuntimeError('ENG1 regression failed')
    (OUT/'summary.json').write_text(json.dumps(dict(jobs=len(cases),passed=True,cases=[x[0] for x in cases]),indent=2)+'\n')

if __name__=='__main__':main()
