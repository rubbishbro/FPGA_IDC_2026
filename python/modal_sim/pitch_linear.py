"""Shared first-order eng1 pitch contract; integer reference and offline tables."""
from __future__ import annotations
import math

FRAC=24
SLOPE_FRAC=22
TAG=0x50315431  # P1T1: first-order pitch metadata v1
INTERVAL=96
LFO_STEP=round(5.2*INTERVAL/48000*(1<<24))
SLEW=2*256  # cents Q8 per control update
LIMIT=220*256


def modulation_words(table):
    """words8..15: lower, nominal a1, upper, 0, 0, K, 0, tag.

    K=2*r*theta*sin(theta), from the Q24 poles actually stored in Flash.
    Padding has zero coefficients and bounds but still carries the format tag.
    """
    import numpy as np
    a1=table.a1.astype(float)/(1<<24)
    a2=table.a2.astype(float)/(1<<24)
    r=np.sqrt(a2)
    theta=np.arccos(np.clip(-a1/np.maximum(2*r,1e-20),-1,1))
    slope=np.floor(2*r*theta*np.sin(theta)*(1<<SLOPE_FRAC)+.5).astype(np.int64)
    if np.any(slope >= (1<<24)):
        raise ValueError('pitch slope does not fit signed25 Q3.22')
    words=[]
    for m in range(64):
        if m<table.n_modes:
            bound=max(0,math.isqrt(int(table.a2[m])<<26)-1)
            words.append([-bound,int(table.a1[m]),bound,0,0,int(slope[m]),0,TAG])
        else:words.append([0,0,0,0,0,0,0,TAG])
    return words


def ratio_table():
    return [int(math.floor(2**(c/1200)*(1<<24)+.5)) for c in range(-220,222)]


def sine_table():
    return [round(math.sin(2*math.pi*i/256)*32767) for i in range(256)]


def depth_table():
    return [round(20*256*i/127) for i in range(128)]


def trajectory(bend, wheel, phase, previous):
    sine=sine_table()[(phase>>16)&255]
    vibrato=(sine*depth_table()[wheel]+16384)>>15
    target=max(-LIMIT,min(LIMIT,((bend-8192)*25>>2)+vibrato))
    cents=max(previous-SLEW,min(previous+SLEW,target))
    offset=cents+LIMIT
    index,frac=offset>>8,offset&255
    ratios=ratio_table()
    ratio=ratios[index]+((ratios[index+1]-ratios[index])*frac+128>>8)
    return cents,ratio-(1<<24)


def coefficient(base,slope,lower,upper,delta):
    return max(lower,min(upper,base+((slope*delta+(1<<21))>>22)))


def advance_phase(phase,period,delta,onset=False):
    if onset:return 0,True
    phase+= (1<<24)+delta
    threshold=period<<24
    return (phase-threshold,True) if phase>=threshold else (phase,False)
