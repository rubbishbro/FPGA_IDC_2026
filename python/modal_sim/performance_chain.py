"""Sample-frame raw matrix/ABC reference for shared-headroom calibration.

Coefficients are read from the actual mixed-format Flash image. No listening
normalization or runtime gain is applied by this model.
"""
import numpy as np
import eng1_rtl as E
import eng1_audition as A
import router_eng1 as R


class RawPerformance:
    def __init__(self, name, manifest, image, bank=0):
        self.name=name;self.cfg=manifest['frontends'][name]
        self.rows=sorted((r for r in manifest['entries'] if r['name']==name),key=lambda r:r['slot'])
        if bank not in (0,1):raise ValueError('bank must be 0/1')
        self.rows=self.rows[bank*16:bank*16+16]
        self.slots=len(self.rows)
        raw=b''.join(image[r['offset']:r['offset']+4096] for r in self.rows)
        self.words=np.frombuffer(raw,dtype='>i4').astype(np.int64).reshape(self.slots,64,16)
        self.matrix=self.cfg['engine']=='eng0'
        self.q=np.zeros((self.slots,64),dtype=np.int64);self.v=self.q.copy()
        if not self.matrix:
            self.core=R.Eng1Core(slots=self.slots,n_modes=64)
            for s,row in enumerate(self.rows):
                self.core.load_slot(s,R.Eng1Coeffs(self.words[s,:,0],self.words[s,:,1],self.words[s,:,2],row['modes']))
        if name=='trumpet':
            self.env=E.Envelope([r['a_step'] for r in self.rows],[r['r_step'] for r in self.rows])
        else:
            c=self.cfg
            self.env=E.Envelope([c['a_step']]*self.slots,[c['r_step']]*self.slots,
                                sustain_level=c['s_level'],decay_step=c['d_step'])
        if name in ('piano','guitar','piano_abc','guitar_abc'):
            self.exc=A.Strike('piano' if 'piano' in name else 'guitar',self.slots)
            self.exc.rise=self.cfg['rise_sh'];self.exc.width=self.cfg['pw_len']
            self.exc.gap=self.cfg['gap_len'];self.exc.pulses=self.cfg['n_pulse']
            self.exc.output_shift=self.cfg.get('output_shift',0)
        elif name=='trumpet':
            from trumpet_lip import TrumpetExcitation
            self.exc=TrumpetExcitation([r['period'] for r in self.rows])
        else:self.exc=E.Excitation([r['period'] for r in self.rows])
        self.previous_gate=np.zeros(self.slots,dtype=bool)
        self.previous_dead=np.ones(self.slots,dtype=bool);self.pending_dead=np.zeros(self.slots,dtype=bool)

    def step(self, gate, level, trigger=None, clear=None):
        gate=np.asarray(gate,dtype=bool);level=np.asarray(level,dtype=np.int64)
        trigger=np.zeros(self.slots,dtype=bool) if trigger is None else np.asarray(trigger,dtype=bool)
        clear=np.zeros(self.slots,dtype=bool) if clear is None else np.asarray(clear,dtype=bool)
        old=self.env.level.copy();env=self.env.step(gate,trigger,clear)
        if self.name in ('piano','guitar','piano_abc','guitar_abc'):env=np.where(trigger|clear,0,old)
        zero=trigger|(gate&~self.previous_gate)|clear|self.pending_dead
        if self.name in ('piano','guitar','piano_abc','guitar_abc'):x=self.exc.step(level,gate,trigger,clear)
        else:x=self.exc.step(gate,level,trigger,clear,np.zeros(self.slots,dtype=np.int64))
        if self.matrix:
            n=64 if self.name=='piano' else 20;w=self.words[:,:n,:7]
            q=self.q[:,:n].copy();v=self.v[:,:n].copy();q[zero]=0;v[zero]=0
            def term(value,coef,shift):return (value*coef+(1<<(shift-1)))>>shift
            qn=term(q,w[:,:,0],28)+term(v,w[:,:,1],30)+term(x[:,None],w[:,:,4],32)
            vn=term(q,w[:,:,2],23)+term(v,w[:,:,3],28)+term(x[:,None],w[:,:,5],34)
            y=np.sum(term(q,w[:,:,6],29),axis=1)
            self.q[:,:n]=np.clip(qn,-(1<<31),(1<<31)-1)
            self.v[:,:n]=np.clip(vn,-(1<<31),(1<<31)-1)
        else:y,_=self.core.step(x,zero,active_modes=48)
        self.pending_dead=self.env.dead&~self.previous_dead
        self.previous_dead=self.env.dead.copy();self.previous_gate=gate.copy()
        return (y*env)>>31,env,self.env.dead.copy()
