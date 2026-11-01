export const PPQ=480;
export const COLORS=['#5b9cf8','#80c6b7','#b49be8','#d998ac','#94bb75','#7cb9d2'];
export const LEGACY_NOTES=[40,42,44,46,48,50,52,54,56,58,60,62,64,67,71,76];
export const INSTRUMENTS=['吉他1','钢琴1','小号','小提琴','大提琴','长笛','钢琴2','吉他2'];
export const INSTRUMENT_ICONS=['guitar-1','piano-1','trumpet','violin','cello','flute','piano-2','guitar-2'];
export const uid=()=>globalThis.crypto.randomUUID();
export const clamp=(n,a,b)=>Math.min(b,Math.max(a,n));
export const noteName=n=>['C','C♯','D','D♯','E','F','F♯','G','G♯','A','A♯','B'][n%12]+(Math.floor(n/12)-1);
export function newTrack(index=0) {return {id:uid(),name:`轨道 ${String(index+1).padStart(2,'0')}`,channel:1,color:COLORS[index%COLORS.length],muted:false,solo:false,notes:[],events:[]};}
export function blankProject() {return {version:1,name:'未命名片段',tempoMap:[{beat:0,bpm:110}],timeSignature:[4,4],bars:8,loop:{enabled:true,start:0,end:16},tracks:[newTrack()]};}
export function demoProject() {
  const p=blankProject();p.name='微光 · First light';p.tracks[0].name='钢琴 · 旋律';
  const melody=[60,64,67,64,62,64,67,71,60,64,67,72,71,67,64,62,60,64,67,64,62,64,71,67,64,62,60];
  p.tracks[0].notes=melody.map((pitch,i)=>({id:uid(),pitch,beat:i*.5,duration:i===26?2.75:.42,velocity:78+(i%4)*9}));
  const t=newTrack(1);t.name='钢琴 · 和声';
  [[0,48,52,55],[4,50,54,57],[8,48,52,55],[12,47,50,55]].forEach(([beat,...pitches])=>pitches.forEach(pitch=>t.notes.push({id:uid(),pitch,beat,duration:3.6,velocity:54})));
  p.tracks.push(t);return p;
}
export function validateProject(p) {
  if(!p||p.version!==1||typeof p.name!=='string'||p.name.length>160||!Array.isArray(p.tracks)||!p.tracks.length||p.tracks.length>128) throw Error('不支持的工程文件');
  if(!Number.isInteger(p.bars)||p.bars<1||p.bars>10000||!p.loop||typeof p.loop.enabled!=='boolean'||!Number.isFinite(p.loop.start)||!Number.isFinite(p.loop.end)||p.loop.start<0||p.loop.end<=p.loop.start||p.loop.end>p.bars*4) throw Error('工程长度或循环范围无效');
  if(!Array.isArray(p.timeSignature)||p.timeSignature[0]!==4||p.timeSignature[1]!==4) throw Error('当前版本只支持 4/4 拍');
  if(!Array.isArray(p.tempoMap)||!p.tempoMap.length||p.tempoMap[0].beat!==0) throw Error('缺少初始速度');
  p.tempoMap.forEach((t,i)=>{if(!Number.isFinite(t.beat)||t.beat<0||!Number.isFinite(t.bpm)||t.bpm<4||t.bpm>1000||(i&&t.beat<=p.tempoMap[i-1].beat)) throw Error('速度图无效');});
  let count=0,maxEnd=0;const ids=new Set();
  for(const t of p.tracks) {
    if(typeof t.name!=='string'||t.name.length>160||typeof t.id!=='string'||ids.has(t.id)||!Number.isInteger(t.channel)||t.channel<0||t.channel>15||!/^#[0-9a-f]{6}$/i.test(t.color)||typeof t.muted!=='boolean'||typeof t.solo!=='boolean'||!Array.isArray(t.notes)||!Array.isArray(t.events)) throw Error('轨道数据无效');
    ids.add(t.id);
    for(const n of t.notes) {
      if(typeof n.id!=='string'||ids.has(n.id)||!Number.isInteger(n.pitch)||n.pitch<0||n.pitch>127||!Number.isInteger(n.velocity)||n.velocity<1||n.velocity>127||!Number.isFinite(n.beat)||n.beat<0||!Number.isFinite(n.duration)||n.duration<1/PPQ||n.beat+n.duration>40000) throw Error('音符数据无效');
      ids.add(n.id);count++;maxEnd=Math.max(maxEnd,n.beat+n.duration);
    }
    for(const e of t.events) {
      if(!Number.isFinite(e.beat)||e.beat<0||e.beat>40000||!Array.isArray(e.data)||![2,3].includes(e.data.length)||e.data[0]<0x80||e.data[0]>=0xf0||[0x80,0x90].includes(e.data[0]&0xf0)||e.data.length!==([0xc0,0xd0].includes(e.data[0]&0xf0)?2:3)||e.data.some(b=>!Number.isInteger(b))||e.data.slice(1).some(b=>b<0||b>127)) throw Error('控制事件无效');
      count++;
    }
  }
  if(maxEnd>p.bars*4+1e-8)throw Error('音符超出工程长度');
  if(count>50000) throw Error('事件超过 50,000 上限');
  return p;
}
export function activeTracks(project) {const solo=project.tracks.some(t=>t.solo);return project.tracks.filter(t=>!t.muted&&(!solo||t.solo));}
export function endBeat(p) {return Math.max(p.bars*4,...p.tracks.map(t=>t.notes.reduce((end,n)=>Math.max(end,n.beat+n.duration),0)));}
export function beatToSeconds(beat,map) {let seconds=0; for(let i=0;i<map.length;i++) {const next=Math.min(beat,map[i+1]?.beat??beat);if(next>map[i].beat) seconds+=(next-map[i].beat)*60/map[i].bpm;if(next===beat) break;}return seconds;}
export function secondsToBeat(seconds,map) {for(let i=0;i<map.length;i++) {const d=(map[i+1]?.beat??Infinity)-map[i].beat,span=d*60/map[i].bpm;if(seconds<span)return map[i].beat+seconds*map[i].bpm/60;seconds-=span;}return 0;}
export function compileEvents(project,{hardware=false}={}) {
  const events=[];
  for(const t of activeTracks(project)) {
    for(const n of t.notes) {
      const key=`${t.id}:${n.id}`;
      events.push({beat:n.beat,order:2,key,data:[0x90|t.channel,n.pitch,n.velocity]});
      events.push({beat:n.beat+n.duration,order:0,key,data:[0x80|t.channel,n.pitch,0]});
    }
    for(const [i,e] of t.events.entries()) if(!hardware || ((e.data[0]&0xf0)===0xb0 && [64,120,123].includes(e.data[1]))) events.push({...e,data:[(e.data[0]&0xf0)|t.channel,...e.data.slice(1)],key:`${t.id}:e${i}`,order:1});
  }
  return events.sort((a,b)=>a.beat-b.beat||a.order-b.order).map(e=>({...e,time:beatToSeconds(e.beat,project.tempoMap)}));
}
export function hardwareIssues(project,profile) {
  const tracks=activeTracks(project),issues=[],notes=tracks.flatMap(t=>t.notes.map(n=>({...n,channel:t.channel})));
  if(!notes.length)issues.push('没有可播放的音符');
  if(tracks.some(t=>t.notes.length&&t.channel!==profile.channel))issues.push(`板端只接收通道 ${profile.channel+1}；请调整轨道通道或使用独奏`);
  const unavailable=[...new Set(notes.filter(n=>!profile.notes.includes(n.pitch)).map(n=>n.pitch))];
  if(unavailable.length)issues.push(`当前音组缺少 ${unavailable.length} 个音高：${unavailable.slice(0,8).map(noteName).join('、')}${unavailable.length>8?'…':''}`);
  const groups=new Map();for(const n of notes) {const k=`${n.channel}:${n.pitch}`;if(!groups.has(k))groups.set(k,[]);groups.get(k).push(n);}
  let overlap=false;for(const g of groups.values()) {g.sort((a,b)=>a.beat-b.beat);let end=-1;for(const n of g) {if(n.beat<end-1e-8)overlap=true;end=Math.max(end,n.beat+n.duration);}}
  if(overlap)issues.push('存在同通道同音高重叠；请缩短音符或静音冲突轨道后播放');
  if(profile.notes.length>16||!profile.notes.length)issues.push('当前加载清单必须为 1～16 个有效音高');
  return issues;
}
export class History {
  constructor(project,onChange) {this.current=structuredClone(project);this.undoStack=[];this.redoStack=[];this.onChange=onChange;}
  commit(next) {this.undoStack.push(structuredClone(this.current));if(this.undoStack.length>80)this.undoStack.shift();this.redoStack=[];this.current=structuredClone(next);this.onChange?.();}
  undo() {if(!this.undoStack.length)return;this.redoStack.push(this.current);this.current=this.undoStack.pop();this.onChange?.();}
  redo() {if(!this.redoStack.length)return;this.undoStack.push(this.current);this.current=this.redoStack.pop();this.onChange?.();}
}

export function profileExercise(profile) {
  if(!Number.isInteger(profile.channel)||profile.channel<0||profile.channel>7||!Array.isArray(profile.notes)||!profile.notes.length||profile.notes.length>16||new Set(profile.notes).size!==profile.notes.length||profile.notes.some(n=>!Number.isInteger(n)||n<0||n>127))throw Error('请先填写有效的板端通道及 1～16 音清单');
  const p=blankProject();p.name='当前音组 · UART 测试';p.tempoMap=[{beat:0,bpm:100}];p.bars=Math.max(1,Math.ceil(profile.notes.length/8));p.loop.end=p.bars*4;
  const t=p.tracks[0];t.channel=profile.channel;t.name=INSTRUMENTS[profile.channel]+' · 音组测试';t.notes=profile.notes.map((pitch,i)=>({id:uid(),pitch,beat:i*.5,duration:.4,velocity:90}));return p;
}
