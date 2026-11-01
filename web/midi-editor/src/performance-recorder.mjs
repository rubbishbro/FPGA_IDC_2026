import {newTrack,uid,secondsToBeat,beatToSeconds,validateProject} from './model.mjs';
export const PERFORMANCE_TYPE=0x82,RECORD_START=0x12,RECORD_STOP=0x13;
export const recordIdBytes=id=>[id&255,id>>>8&255,id>>>16&255,id>>>24&255];
export function decodePerformance(frame){
  if(frame.type!==PERFORMANCE_TYPE||frame.payload.length!==24)throw Error('演奏录制帧类型或长度错误');
  const p=frame.payload,v=new DataView(p.buffer,p.byteOffset,p.byteLength);
  const event={kind:p[0],flags:p[1],channel:p[2],slot:p[3],id:v.getUint32(4,true),ordinal:v.getUint32(8,true),tick:v.getUint32(12,true),a:v.getUint32(16,true),b:v.getUint32(20,true)};
  if(event.kind>3||event.flags>1||event.channel>5||event.slot>15)throw Error('非法演奏录制字段');
  if((frame.seq&65535)!==(event.ordinal&65535))throw Error('演奏帧序号不一致');
  if([1,2].includes(event.kind)&&((event.a&255)>127||(event.a>>>8&255)<1||(event.a>>>8&255)>127||(event.a>>>16)!==0||event.b!==0))throw Error('非法录制音符');
  return event;
}
export class PerformanceRecorder {
  constructor({id,project,insertBeat=0,maxSeconds=600,maxEvents=50000}) {
    validateProject(project);
    if(!Number.isFinite(insertBeat)||insertBeat<0||insertBeat>=40000-1/480)throw Error('录制插入位置超出工程范围');
    this.maxNotes=50000-project.tracks.reduce((n,t)=>n+t.notes.length+t.events.length,0);
    if(this.maxNotes<1)throw Error('工程事件数量已达上限');
    Object.assign(this,{id,tempoMap:structuredClone(project.tempoMap),insertBeat,maxSeconds,maxEvents,expected:0,lastTick:0,started:false,ended:false,incomplete:false,duplicates:0,received:0,rateNum:0,rateDen:0});
    this.track=newTrack(project.tracks.length);this.track.name=`演奏录制 ${String(project.tracks.length+1).padStart(2,'0')}`;this.open=new Map();this.offsetSeconds=beatToSeconds(insertBeat,this.tempoMap);
  }
  beat(tick){return secondsToBeat(this.offsetSeconds+tick*this.rateDen/this.rateNum,this.tempoMap);}
  push(frame){
    const e=decodePerformance(frame);if(e.id!==this.id)return false;if(this.ended)return false;
    if(e.ordinal<this.expected){this.duplicates++;return false;}
    if(e.ordinal!==this.expected)this.incomplete=true;
    if(e.tick<this.lastTick)throw Error('设备录制时间倒退');
    if(e.kind===0){
      if(this.started||e.ordinal!==0||e.tick!==0||e.a!==12500000||e.b!==256)throw Error('录制起点或采样率无效');
      this.started=true;this.rateNum=e.a;this.rateDen=e.b;this.track.channel=e.channel;
    }else{
      if(!this.started)throw Error('缺少设备录制起点');
      if(e.channel!==this.track.channel)throw Error('录制中设备通道改变');
      if(e.tick>Math.ceil(this.maxSeconds*this.rateNum/this.rateDen)+2)throw Error('录制超过时长上限');
      if(this.beat(e.tick)>40000)throw Error('录制超出工程最大长度');
      if(++this.received>this.maxEvents)throw Error('录制超过事件上限');
      if(e.kind===1){
        if(this.track.notes.length>=this.maxNotes)throw Error('工程音符数量已达上限');
        if(this.open.has(e.slot)){this.close(e.slot,e.tick);this.incomplete=true;}
        const n={id:uid(),pitch:e.a&255,velocity:e.a>>>8&255,beat:this.beat(e.tick),duration:1/480};
        this.track.notes.push(n);this.open.set(e.slot,n);
      }else if(e.kind===2){
        const n=this.open.get(e.slot);if(n&&n.pitch===(e.a&255))this.close(e.slot,e.tick);else this.incomplete=true;
      }else{
        if(e.b!==e.ordinal-1)this.incomplete=true;
        this.incomplete ||= !!e.flags||e.a!==0;
        this.finish(e.tick);return true;
      }
    }
    this.lastTick=e.tick;this.expected=e.ordinal+1;return true;
  }
  close(slot,tick){const n=this.open.get(slot);if(!n)return;n.duration=Math.max(1/480,this.beat(tick)-n.beat);this.open.delete(slot);}
  finish(tick=this.lastTick){for(const slot of this.open.keys())this.close(slot,tick);this.lastTick=tick;this.ended=true;this.track.recording={source:'pad',id:this.id,rateNum:this.rateNum,rateDen:this.rateDen,endFrame:tick,incomplete:this.incomplete};return this.track;}
  abort(){this.incomplete=true;return this.finish();}
  get seconds(){return this.started?this.lastTick*this.rateDen/this.rateNum:0;}
  preview(tick=this.lastTick){const t=structuredClone(this.track);for(const n of t.notes)if([...this.open.values()].some(x=>x.id===n.id))n.duration=Math.max(1/480,this.beat(tick)-n.beat);return t;}
}
