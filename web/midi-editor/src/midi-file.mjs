import {PPQ,COLORS,uid,validateProject,blankProject} from './model.mjs';
import {SAMPLE_PROGRAMS} from './sample-instruments.mjs';
const decoder=new TextDecoder();
export function parseMidi(input) {
  const bytes=new Uint8Array(input);let pos=0,eventsSeen=0;
  const need=(n,end=bytes.length)=>{if(pos+n>end)throw Error('MIDI 文件截断或长度错误');};
  const u8=()=>{need(1);return bytes[pos++];};
  const u16=()=>u8()*256+u8();
  const u32=()=>u8()*0x1000000+u8()*65536+u8()*256+u8();
  const text=(n)=>{need(n);const s=decoder.decode(bytes.slice(pos,pos+n));pos+=n;return s;};
  const vlq=(end)=>{let v=0;for(let i=0;i<4;i++){need(1,end);const b=u8();v=v*128+(b&127);if(!(b&128))return v;}throw Error('MIDI 可变长度值溢出');};
  if(text(4)!=='MThd')throw Error('不是标准 MIDI 文件');
  const headerSize=u32();if(headerSize<6)throw Error('MIDI 头长度无效');need(headerSize);
  const format=u16(),count=u16(),division=u16();pos+=headerSize-6;
  if(format>1)throw Error('仅支持 MIDI format 0 / 1，暂不支持异步 format 2');
  if(!count||count>512||(format===0&&count!==1))throw Error('MIDI 轨道数量无效');
  if(!division||(division&0x8000))throw Error('暂不支持 SMPTE 时间制，请导出为 PPQ MIDI');
  const tracks=[],tempos=[{beat:0,bpm:120}],report={ignored:0,unmatched:0,closed:0,auxiliary:0};let maxBeat=4;
  for(let ti=0;ti<count;ti++) {
    if(text(4)!=='MTrk')throw Error('缺少 MTrk 轨道');
    const size=u32();need(size);const end=pos+size;let tick=0,running=0,name=`导入轨道 ${ti+1}`;const channels=new Map();
    const trackFor=(ch)=>{if(!channels.has(ch))channels.set(ch,{id:uid(),name,channel:ch,color:COLORS[tracks.length%COLORS.length],muted:false,solo:false,notes:[],events:[],open:new Map()});return channels.get(ch);};
    while(pos<end) {
      tick+=vlq(end);const beat=tick/division;maxBeat=Math.max(maxBeat,beat);
      if(beat>40000 || ++eventsSeen>1000000)throw Error('MIDI 过长或事件过多');
      need(1,end);let status=bytes[pos];
      if(status&128) {pos++;if(status<0xf0)running=status;else running=0;}
      else {status=running;if(!status)throw Error('MIDI running status 缺少状态字节');}
      if(status===0xff) {
        need(1,end);const type=u8(),len=vlq(end);need(len,end);const data=bytes.slice(pos,pos+len);pos+=len;
        if(type===0x2f) {if(len!==0)throw Error('End of track 长度错误');break;}
        if(type===3) name=decoder.decode(data).slice(0,150)||name;
        else if(type===0x51) {if(len!==3)throw Error('速度事件长度错误');const micros=data[0]*65536+data[1]*256+data[2];if(!micros)throw Error('MIDI 速度为零');tempos.push({beat,bpm:60000000/micros});}
        else if(type===0x58) {if(len!==4||data[0]!==4||data[1]!==2)throw Error('当前编辑器仅支持 4/4 拍，请先转换拍号');}
        else report.ignored++;
      } else if(status===0xf0||status===0xf7) {const len=vlq(end);need(len,end);pos+=len;report.ignored++;}
      else if(status<0xf0) {
        const kind=status&0xf0,ch=status&15,n=(kind===0xc0||kind===0xd0)?1:2;need(n,end);const data=Array.from(bytes.slice(pos,pos+n));pos+=n;
        if(data.some(b=>b>127))throw Error('MIDI 数据字节含非法 status');
        const t=trackFor(ch);
        if(kind===0x90&&data[1]>0) {
          const note={id:uid(),pitch:data[0],velocity:data[1],beat,duration:0};
          if(!t.open.has(data[0]))t.open.set(data[0],[]);t.open.get(data[0]).push(note);t.notes.push(note);
        } else if(kind===0x80||kind===0x90) {
          const note=t.open.get(data[0])?.shift();if(note)note.duration=Math.max(1/PPQ,beat-note.beat);else report.unmatched++;
        } else {t.events.push({beat,data:[status,...data]});report.auxiliary++;}
      } else throw Error('SMF 中存在不支持的系统状态');
    }
    pos=end;
    for(const t of channels.values()) {
      for(const notes of t.open.values())for(const n of notes){n.duration=Math.max(1/PPQ,maxBeat-n.beat);report.closed++;}
      maxBeat=t.notes.reduce((end,n)=>Math.max(end,n.beat+n.duration),maxBeat);
      delete t.open;t.name=name+(channels.size>1?` · Ch ${t.channel+1}`:'');tracks.push(t);
    }
  }
  const tempoMap=[...new Map(tempos.sort((a,b)=>a.beat-b.beat).map(t=>[t.beat,t])).values()];
  const project={...blankProject(),name:'导入的 MIDI',tempoMap,bars:Math.max(1,Math.ceil(maxBeat/4)),tracks:tracks.length?tracks:[blankProject().tracks[0]]};
  project.loop.end=project.bars*4;
  return {project:validateProject(project),report};
}
function vlq(v) {if(v<0||v>0xfffffff)throw Error('MIDI delta-time 越界');let bytes=[v&127];while((v=Math.floor(v/128)))bytes.unshift((v&127)|128);return bytes;}
const be16=v=>[v>>8&255,v&255];
const be32=v=>[v>>>24&255,v>>>16&255,v>>>8&255,v&255];
const ascii=s=>Array.from(s).map(c=>c.charCodeAt(0));
function trackChunk(events,endTick) {
  events.sort((a,b)=>a.tick-b.tick||a.order-b.order);const out=[];let tick=0;
  for(const e of events){out.push(...vlq(e.tick-tick),...e.data);tick=e.tick;}
  out.push(...vlq(Math.max(0,endTick-tick)),0xff,0x2f,0);return [...ascii('MTrk'),...be32(out.length),...out];
}
export function writeMidi(project) {
  validateProject(project);
  const conductor=project.tempoMap.map(t=>{const us=Math.round(60000000/t.bpm);return {tick:Math.round(t.beat*PPQ),order:0,data:[0xff,0x51,3,us>>16&255,us>>8&255,us&255]};});
  conductor.push({tick:0,order:0,data:[0xff,0x58,4,4,2,24,8]});
  const result=[...ascii('MThd'),...be32(6),...be16(1),...be16(project.tracks.length+1),...be16(PPQ)];
  const append=arr=>{for(const b of arr)result.push(b);};
  append(trackChunk(conductor,project.bars*4*PPQ));
  for(const t of project.tracks) {
    const name=Array.from(new TextEncoder().encode(t.name));
    const events=[{tick:0,order:0,data:[0xff,3,...vlq(name.length),...name]}];
    for(const n of t.notes) {
      const start=Math.round(n.beat*PPQ),end=Math.max(start+1,Math.round((n.beat+n.duration)*PPQ));
      events.push({tick:start,order:2,data:[0x90|t.channel,n.pitch,n.velocity]},{tick:end,order:0,data:[0x80|t.channel,n.pitch,0]});
    }
    if(t.previewInstrument&&SAMPLE_PROGRAMS[t.previewInstrument]!==undefined)events.push({tick:0,order:1,data:[0xc0|t.channel,SAMPLE_PROGRAMS[t.previewInstrument]]});
    for(const e of t.events){if(t.previewInstrument&&(e.data[0]&0xf0)===0xc0)continue;events.push({tick:Math.round(e.beat*PPQ),order:1,data:[(e.data[0]&0xf0)|t.channel,...e.data.slice(1)]});}
    append(trackChunk(events,project.bars*4*PPQ));
  }
  return Uint8Array.from(result);
}
