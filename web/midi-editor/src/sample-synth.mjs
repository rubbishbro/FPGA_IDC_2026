import {ReferenceSynth} from './playback.mjs';
import {activeTracks} from './model.mjs';
import {nearestSample,trackInstrument,CHANNEL_SAMPLES} from './sample-instruments.mjs';

export class SampleSynth extends ReferenceSynth {
  constructor(options={}){super(options);this.buffers=new Map();this.inflight=new Map();this.controllers=new Map();this.fetch=options.fetch??globalThis.fetch.bind(globalThis);}
  async bank(){
    if(!this.bankPromise)this.bankPromise=this.fetch('/assets/samples/manifest.json').then(async r=>{
      if(!r.ok)throw Error('乐器录音资源未安装，请检查本地资源是否齐全');
      const bank=await r.json();if(bank.version!==1||!bank.instruments)throw Error('乐器录音清单无效');return bank;
    }).catch(e=>{this.bankPromise=null;throw e;});
    return this.bankPromise;
  }
  async load(instrument,pitch){
    const bank=await this.bank(),sample=nearestSample(bank.instruments[instrument]?.samples,pitch),key=`${instrument}:${sample.pitch}`;
    if(this.buffers.has(key))return this.buffers.get(key);
    if(!this.inflight.has(key))this.inflight.set(key,(async()=>{
      const response=await this.fetch(sample.url);if(!response.ok)throw Error(`乐器录音加载失败：${instrument} ${pitch}`);
      const buffer=await this.context.decodeAudioData(await response.arrayBuffer());
      const loaded={buffer,sample,key};this.buffers.set(key,loaded);return loaded;
    })().finally(()=>this.inflight.delete(key)));
    return this.inflight.get(key);
  }
  async prepare(project,onProgress=()=>{},position=0){
    this.loadedBank=await this.bank();
    const jobs=new Map();
    for(const track of activeTracks(project))for(const note of track.notes){const instrument=trackInstrument(track,note.beat);jobs.set(`${instrument}:${note.pitch}`,{instrument,pitch:note.pitch});}
    const pending=[...jobs.values()];let done=0,index=0;
    await Promise.all(Array.from({length:Math.min(4,pending.length)},async()=>{
      while(index<pending.length){const job=pending[index++];await this.load(job.instrument,job.pitch);onProgress(++done,pending.length);}
    }));
    this.controllers.clear();
    const controls=activeTracks(project).flatMap(t=>t.events.map(e=>({...e,ch:t.channel})))
      .filter(e=>e.beat<=position&&(e.data[0]&0xf0)===0xb0&&[7,10].includes(e.data[1])).sort((a,b)=>a.beat-b.beat);
    for(const e of controls){const control=this.controllers.get(e.ch)??{volume:1,pan:0};if(e.data[1]===7)control.volume=e.data[2]/127;else control.pan=(e.data[2]-64)/64;this.controllers.set(e.ch,control);}
  }
  send(events){
    if(!this.context)return;
    const now=this.context.currentTime;
    for(const e of events){
      const [status,a,b]=e.data,kind=status&0xf0,ch=status&15;
      if(kind===0x90&&b>0){
        const instrument=e.instrument??CHANNEL_SAMPLES[ch]??'piano';
        const bank=this.loadedBank;
        if(!bank)throw Error('乐器录音尚未加载完成');
        const sample=nearestSample(bank.instruments[instrument]?.samples,a),loaded=this.buffers.get(`${instrument}:${sample.pitch}`);
        if(!loaded)throw Error(`乐器录音尚未就绪：${instrument} ${a}`);
        this.release(e.key,true);
        const source=this.context.createBufferSource(),gain=this.context.createGain(),pan=this.context.createStereoPanner();
        source.buffer=loaded.buffer;source.playbackRate.value=2**((a-sample.pitch)/12);
        if(sample.loop){source.loop=true;source.loopStart=sample.loop[0];source.loopEnd=sample.loop[1];}
        const control=this.controllers.get(ch)??{volume:1,pan:0};
        const level=b/127*.32*(sample.gain??1);
        gain.gain.setValueAtTime(0,now);gain.gain.linearRampToValueAtTime(level*control.volume,now+.004);
        pan.pan.value=control.pan;source.connect(gain).connect(pan).connect(this.input);
        const voice={osc:source,gain,pan,ch,down:true,level};this.voices.set(e.key,voice);
        source.onended=()=>{if(this.voices.get(e.key)===voice)this.voices.delete(e.key);source.disconnect();gain.disconnect();pan.disconnect();};
        source.start();
      }else if(kind===0xb0&&(a===7||a===10)){
        const control=this.controllers.get(ch)??{volume:1,pan:0};
        if(a===7)control.volume=b/127;else control.pan=(b-64)/64;
        this.controllers.set(ch,control);
        for(const voice of this.voices.values())if(voice.ch===ch){voice.gain.gain.setTargetAtTime(voice.level*control.volume,now,.01);voice.pan.pan.setTargetAtTime(control.pan,now,.01);}
      }else super.send([e]);
    }
  }
  async resume(){await super.resume();this.loadedBank=await this.bank();}
}
