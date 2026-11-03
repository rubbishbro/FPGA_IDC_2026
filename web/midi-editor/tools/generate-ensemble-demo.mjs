import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {validateProject} from '../src/model.mjs';
import {writeMidi,parseMidi} from '../src/midi-file.mjs';

const output=path.resolve(process.argv[2]??'build/web_demo_ensemble');
await mkdir(output,{recursive:true});
const bpm=112,rate=44100,secondsPerBeat=60/bpm,bars=16;
const specs=[
  ['钢琴 · 流动和弦',1,0,'#5b9cf8','piano',-.25,.19],
  ['吉他 · 切分节奏',0,24,'#80c6b7','guitar',.4,.13],
  ['大提琴 · 温暖低声部',4,42,'#b49be8','cello',-.12,.12],
  ['小提琴 · 和声铺底',3,40,'#d998ac','violin',-.45,.052],
  ['长笛 · 主旋律',5,73,'#94bb75','flute',.15,.19],
];
let id=0;
const tracks=specs.map(([name,channel,program,color])=>({id:`ensemble-track-${channel}`,name,channel,color,muted:false,solo:false,notes:[],events:[{beat:0,data:[0xc0|channel,program]}]}));
function note(track,pitch,beat,duration,velocity=80){tracks[track].notes.push({id:`ensemble-note-${id++}`,pitch,beat,duration,velocity});}
const chords=[
 [48,60,64,67,71],[45,57,60,64,67],[41,57,60,65,69],[43,55,59,62,67],
 [48,60,64,67,71],[45,57,60,64,67],[41,57,60,65,69],[43,55,59,62,67],
 [45,57,60,64,67],[40,55,59,64,67],[41,57,60,65,69],[43,55,59,62,67],
 [48,60,64,67,71],[41,57,60,65,69],[43,55,59,62,67],[48,60,64,67,72],
];
for(let bar=0;bar<bars;bar++){
 const base=bar*4,chord=chords[bar],ending=bar===15;
 // Inversions keep the accompaniment above the laptop's weak sub-bass range.
 const bass=chord[0]<43?chord[0]+12:chord[0];
 note(2,bass,base,ending?3.9:1.8,bar<2?66:80);
 if(!ending)note(2,bass+7,base+2,1.7,69);
 const pattern=[1,2,3,4,2,3,1,3];
 for(let step=0;step<(ending?4:8);step++)note(0,chord[pattern[step]],base+step*.5,ending?3-step*.5:.43,72+(step%4===0?12:0)+(bar>=8?4:0));
 if(bar>=1)for(const [offset,velocity] of (ending?[[0,74]]:[[.75,63],[2.5,73]])){
  [chord[1],chord[2],chord[3]].forEach((pitch,i)=>note(1,pitch,base+offset+i*.025,ending?2.9:1.05,velocity-i*3));
 }
 if(bar>=4)for(const pitch of [chord[2]+12,chord[3]+12])note(3,pitch,base+.04,3.8,bar<8?52:64);
}
// Original melody: repeated opening idea followed by a higher answering phrase.
const melody=[
 [2,0,76,.9],[2,1,79,.45],[2,1.5,81,.45],[2,2,79,1.7],
 [3,0,74,.9],[3,1,76,.9],[3,2,74,.45],[3,2.5,71,.45],[3,3,67,.8],
 [4,0,72,.9],[4,1,76,.45],[4,1.5,79,.45],[4,2,83,1.7],
 [5,0,81,1.4],[5,1.5,79,.45],[5,2,76,1.7],
 [6,0,77,.9],[6,1,81,.45],[6,1.5,79,.45],[6,2,77,.9],[6,3,76,.8],
 [7,0,74,1.4],[7,1.5,71,.45],[7,2,74,1.7],
 [8,0,76,.45],[8,.5,79,.45],[8,1,81,.9],[8,2,84,.9],[8,3,83,.8],
 [9,0,83,.9],[9,1,79,.9],[9,2,76,1.7],
 [10,0,81,.9],[10,1,79,.45],[10,1.5,77,.45],[10,2,76,.9],[10,3,72,.8],
 [11,0,74,.9],[11,1,79,.9],[11,2,83,.9],[11,3,86,.8],
 [12,0,84,1.4],[12,1.5,83,.45],[12,2,79,1.7],
 [13,0,81,.9],[13,1,79,.45],[13,1.5,77,.45],[13,2,76,.9],[13,3,72,.8],
 [14,0,74,.9],[14,1,71,.9],[14,2,67,.9],[14,3,71,.8],
 [15,0,72,3.75],
];
melody.forEach(([bar,offset,pitch,duration],i)=>note(4,pitch,bar*4+offset,duration,84+(i%4===0?6:0)));
const project=validateProject({version:1,name:'微光合奏 · 晨风',tempoMap:[{beat:0,bpm}],timeSignature:[4,4],bars,loop:{enabled:false,start:0,end:64},tracks});
const midi=writeMidi(project),roundtrip=parseMidi(midi).project;
const count=p=>p.tracks.reduce((n,t)=>n+t.notes.length,0);
if(count(roundtrip)!==count(project))throw Error('MIDI note roundtrip mismatch');
await writeFile(path.join(output,'微光合奏_晨风.json'),JSON.stringify(project,null,2)+'\n');
await writeFile(path.join(output,'微光合奏_晨风.mid'),midi);

const duration=bars*4*secondsPerBeat+2.2,frames=Math.ceil(duration*rate);
const left=new Float64Array(frames),right=new Float64Array(frames);
const tau=2*Math.PI;
function tone(kind,time,frequency,gate){
 let value=0;
 const fade=Math.min(1,time/(kind==='violin'||kind==='cello'?.13:kind==='flute'?.045:.004));
 const release=Math.exp(-Math.max(0,time-gate)/(kind==='guitar'?.16:kind==='piano'?.22:.12));
 const vibrato=(kind==='flute'||kind==='violin'||kind==='cello')?.0025*Math.sin(tau*5*time)*Math.min(1,time/.35):0;
 const phase=tau*frequency*(time+vibrato/(tau*5));
 if(kind==='piano'){
  for(let h=1;h<=7;h++)value+=Math.sin(phase*h*Math.sqrt(1+.00012*h*h))*Math.exp(-time*(.95+.32*h))/(h**1.65);
 }else if(kind==='guitar'){
  for(let h=1;h<=8;h++)value+=Math.sin(phase*h)*Math.exp(-time*(1.7+.55*h))*Math.sin(h*1.05)/(h**1.2);
 }else if(kind==='flute'){
  value=(Math.sin(phase)+.15*Math.sin(phase*2)+.055*Math.sin(phase*3))*(.94+.06*Math.sin(tau*4.8*time));
 }else{
  const partials=kind==='violin'?8:6;
  for(let h=1;h<=partials;h++)value+=Math.sin(phase*h)/h**(kind==='violin'?1.5:1.8);
  value*=.94+.06*Math.sin(tau*5.2*time);
 }
 return value*fade*release;
}
for(let t=0;t<tracks.length;t++){
 const [, , , ,kind,pan,level]=specs[t],l=Math.cos((pan+1)*Math.PI/4),r=Math.sin((pan+1)*Math.PI/4);
 for(const n of tracks[t].notes){
  const start=Math.round(n.beat*secondsPerBeat*rate),gate=n.duration*secondsPerBeat;
  const length=Math.min(frames-start,Math.ceil((gate+.95)*rate)),frequency=440*2**((n.pitch-69)/12);
  for(let i=0;i<length;i++){
   const value=tone(kind,i/rate,frequency,gate)*(n.velocity/127)*level;
   left[start+i]+=value*l;right[start+i]+=value*r;
  }
 }
}
// Short stereo room reflections, rendered from the dry signal to avoid feedback.
const dryL=left.slice(),dryR=right.slice();
for(const [delay,amount] of [[.071,.12],[.113,.095],[.173,.075],[.239,.06],[.371,.035]]){
 const shift=Math.round(delay*rate);
 for(let i=shift;i<frames;i++){left[i]+=dryR[i-shift]*amount;right[i]+=dryL[i-shift]*amount;}
}
let peak=0;
for(let i=0;i<frames;i++){
 const fade=Math.min(1,(frames-i)/(rate*.8));left[i]*=fade;right[i]*=fade;
 peak=Math.max(peak,Math.abs(left[i]),Math.abs(right[i]));
}
const scale=.89/peak,pcm=Buffer.alloc(frames*4);let square=0;
for(let i=0;i<frames;i++){
 const l=left[i]*scale,r=right[i]*scale;
 if(!Number.isFinite(l+r))throw Error('Non-finite audio sample');
 pcm.writeInt16LE(Math.round(l*32767),i*4);pcm.writeInt16LE(Math.round(r*32767),i*4+2);square+=l*l+r*r;
}
const header=Buffer.alloc(44);header.write('RIFF');header.writeUInt32LE(36+pcm.length,4);header.write('WAVEfmt ',8);header.writeUInt32LE(16,16);header.writeUInt16LE(1,20);header.writeUInt16LE(2,22);header.writeUInt32LE(rate,24);header.writeUInt32LE(rate*4,28);header.writeUInt16LE(4,32);header.writeUInt16LE(16,34);header.write('data',36);header.writeUInt32LE(pcm.length,40);
await writeFile(path.join(output,'微光合奏_晨风.wav'),Buffer.concat([header,pcm]));
const report={durationSeconds:frames/rate,bpm,tracks:tracks.map(t=>({name:t.name,notes:t.notes.length,channel:t.channel+1})),totalNotes:count(project),peakDbFS:20*Math.log10(.89),rmsDbFS:20*Math.log10(Math.sqrt(square/(frames*2))),sampleRate:rate,stereo:true,midiRoundtrip:true};
await writeFile(path.join(output,'verification.json'),JSON.stringify(report,null,2)+'\n');
await writeFile(path.join(output,'README.md'),'# 微光合奏 · 晨风\n\n原创轻快室内合奏，112 BPM，4/4 拍，16 小节。WAV 为五种合成音色的立体声混音，不是 FPGA 实录。\n\n将 JSON 导入上位机可演示五轨编辑与走带。MIDI 带 GM 音色设置，可供通用 MIDI 音源播放。当前上位机电脑试听统一使用参考音源，不会重现 WAV 的五种音色；UART 播放也受板端单音色、通道和音高清单限制。\n');
console.log(JSON.stringify({output,...report},null,2));
