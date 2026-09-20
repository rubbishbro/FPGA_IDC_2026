import sys
from pathlib import Path
# Dependencies live in <repo>/_libs (sibling of python/), and this file sits in
# python/, so both the repo root and _libs are one level up.
_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent / "_libs"))
sys.path.insert(0, str(_HERE))

import numpy as np
from synthlab.ext.io import play
from synthlab.core import Source, render

class StringSim(Source):
    def __init__(self, length: float, tension: float, density: float, mode_num: int, damping: np.ndarray):
        assert length>0 and tension>0 and density>0 and mode_num>0 
        assert 0<=damping.min() and damping.max() <= np.sqrt(tension/density)/length 
        
        self.l = length
        self.t = tension
        self.mu = density
        self.mode_N = mode_num 
        self.gamma = damping
        
        #hit string at a specific point
        self.init_force = 1.5
        self.force_decay = 0.0002 
        self.f = self.init_force
        
        index = np.arange(1, mode_num+1, 1)
        c = np.sqrt(tension/density)
        
        self.omega0 = np.pi*c/length * index
        self.damped_omega = np.sqrt(np.square(self.omega0) - np.square(damping))
        self.force_pos = np.sin(index*np.pi*0.03)#0.03 is the ratio of total length
        self.sum_weight = np.array(list(map(lambda n: n*((-1)**n)*tension*np.pi/length, index)))
        
        self.u = -(self.init_force * self.force_pos * 2) / (self.mu * self.l * np.square(self.omega0))
        self.u_dot = np.zeros(mode_num)
        
    
    def simStep(self, dt: float):
        exp_damp = np.exp(-self.gamma * dt)
        cosines = np.cos(self.damped_omega * dt)
        sines = np.sin(self.damped_omega * dt)
        
        next_u = exp_damp * (self.u*cosines + (self.u_dot + self.gamma*self.u)*sines/self.damped_omega)
        next_u_dot = exp_damp * (self.u_dot*cosines - (np.square(self.omega0)*self.u + self.gamma*self.u_dot)*sines/self.damped_omega)
        
        self.u = next_u
        self.u_dot = next_u_dot
        
        q = self.u + (self.f * self.force_pos * 2) / (self.mu * self.l * np.square(self.omega0))
        
        self.f *= np.pow(self.force_decay, dt)
        
        return q.dot(self.sum_weight)
    
    def reset(self):
        super().reset()
        self.f = self.init_force
        self.u = -(self.init_force * self.force_pos * 2) / (self.mu * self.l * np.square(self.omega0))
        self.u_dot.fill(0)
     
    def process(self, ctx):
        return self.simStep(1.0 / ctx.sr)

mode_N = 16
string_len = 0.4
string_tension = 140
string_density = 0.005

index = np.arange(1, mode_N+1, 1)
exp_fac = (0.5*(np.log(string_tension)-np.log(string_density)) - np.log(string_len))/(mode_N + 1)

sim = StringSim(string_len, string_tension, string_density, mode_N, 
                np.array(list(map(lambda n: np.exp(n*exp_fac), index))))

audio = render(sim, 3.0)
play(audio)
