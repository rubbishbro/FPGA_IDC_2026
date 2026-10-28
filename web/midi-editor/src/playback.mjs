import {beatToSeconds,secondsToBeat,compileEvents,endBeat} from './model.mjs';
export class ReferenceSynth {
  constructor(){this.voices=new Map();this.pedal=new Set();}
  async resume(){this.context??=new AudioContext();await this.context.resume();}
  send(events) {
    if(!this.context)return;const now=this.context.currentTime;
    for(const e of events) {
      const [s,a,b]=e.data,kind=s&0xf0,ch=s&15;
      if(kind===0x90&&b>0) {
        this.release(e.key,true);const osc=this.context.createOscillator(),gain=this.context.createGain();osc.type='triangle';osc.frequency.value=440*2**((a-69)/12);
        gain.gain.setValueAtTime(0,now);gain.gain.linearRampToValueAtTime(b/127*.055,now+.008);gain.gain.exponentialRampToValueAtTime(b/127*.026,now+.25);
        osc.connect(gain).connect(this.context.destination);osc.start();this.voices.set(e.key,{osc,gain,ch,down:true});
      } else if(kind===0x80||(kind===0x90&&b===0)) {
        const v=this.voices.get(e.key);if(v){v.down=false;if(!this.pedal.has(ch))this.release(e.key);}
      } else if(kind===0xb0&&a===64) {
        if(b>=64)this.pedal.add(ch);else{this.pedal.delete(ch);for(const [key,v] of this.voices)if(v.ch===ch&&!v.down)this.release(key);}
      } else if(kind===0xb0&&(a===120||a===123))for(const [key,v] of this.voices)if(v.ch===ch){v.down=false;if(a===120||!this.pedal.has(ch))this.release(key,a===120);}
    }
  }
  release(key,hard=false){const v=this.voices.get(key);if(!v)return;const now=this.context.currentTime;v.gain.gain.cancelScheduledValues(now);v.gain.gain.setTargetAtTime(0,now,hard?.005:.06);v.osc.stop(now+(hard?.03:.4));this.voices.delete(key);}
  panic(){for(const key of this.voices.keys())this.release(key,true);this.pedal.clear();}
}
export class Playback {
  constructor({send,panic,onPosition,onStop,onError,now=()=>performance.now()}) {Object.assign(this,{send,panic,onPosition,onStop,onError,now,playing:false,position:0});}
  start(project,position=0,hardware=false) {
    this.project=structuredClone(project);this.events=compileEvents(project,{hardware});this.loop=project.loop.enabled;this.startBeat=this.loop?project.loop.start:0;this.endBeat=this.loop?project.loop.end:endBeat(project);
    this.position=position>=this.startBeat&&position<this.endBeat?position:this.startBeat;this.playing=true;this.seek(this.position);
  }
  seek(beat) {
    this.anchor=this.now();this.offset=beatToSeconds(beat,this.project.tempoMap);this.endTime=beatToSeconds(this.endBeat,this.project.tempoMap);
    this.index=this.events.findIndex(e=>e.time>=this.offset-1e-9);if(this.index<0)this.index=this.events.length;
    // Chase only notes crossing the cursor and pedal state; do not replay old attacks.
    const chase=[],pedals=new Map();
    for(const e of this.events)if(e.time<this.offset&&e.data[0]>>4===0xb&&e.data[1]===64)pedals.set(e.data[0]&15,e);
    chase.push(...pedals.values());
    const active=new Map(),heldPedals=new Set();
    for(const e of this.events){
      if(e.time>=this.offset)break;
      const [s,a,b]=e.data,k=s>>4,ch=s&15;
      if(k===9)active.set(e.key,{...e,down:true});
      else if(k===8){const n=active.get(e.key);if(n){if(heldPedals.has(ch))n.down=false;else active.delete(e.key);}}
      else if(k===11&&a===64){if(b>=64)heldPedals.add(ch);else{heldPedals.delete(ch);for(const [key,n] of active)if((n.data[0]&15)===ch&&!n.down)active.delete(key);}}
      else if(k===11&&(a===120||a===123))for(const [key,n] of active)if((n.data[0]&15)===ch){if(a===123&&heldPedals.has(ch))n.down=false;else active.delete(key);}
    }
    for(const n of active.values()){chase.push(n);if(!n.down)chase.push({...n,data:[0x80|(n.data[0]&15),n.data[1],0]});}
    if(chase.length)this.deliver(chase);
  }
  deliver(events){try{Promise.resolve(this.send(events)).catch(e=>{if(e.name!=='AbortError')this.onError?.(e);});}catch(e){this.onError?.(e);}}
  tick() {
    if(!this.playing)return;
    const time=this.offset+(this.now()-this.anchor)/1000;
    if(time>=this.endTime) {
      if(this.loop) {
        // Wait for cleanup to be enqueued before the new cycle. No backlog catch-up.
        this.panic();this.seek(this.startBeat);this.position=this.startBeat;this.onPosition?.(this.position);return;
      }
      this.stop();return;
    }
    const due=[];
    while(this.index<this.events.length&&this.events[this.index].time<=time) {const e=this.events[this.index++];if(e.time<this.endTime)due.push(e);}
    if(due.length)this.deliver(due);
    this.position=secondsToBeat(time,this.project.tempoMap);this.onPosition?.(this.position);
  }
  stop(){const was=this.playing;this.playing=false;this.panic();if(was)this.onStop?.();}
}
