import {readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {parseMidi,writeMidi} from '../src/midi-file.mjs';
import {compileEvents,validateProject,beatToSeconds} from '../src/model.mjs';

const dir=path.resolve(process.argv[2]??'build/midi_resource_demo');
const original=await readFile(path.join(dir,'score.mid'));
const adapted=Buffer.from(original);
// This source has one 2/2 signature. Both 2/2 and 4/4 span four quarter beats;
// changing the display signature preserves every event tick and its duration.
let index=0,signatures=0;
while((index=adapted.indexOf(Buffer.from([255,88,4,2,1]),index))>=0){adapted[index+3]=4;adapted[index+4]=2;index+=7;signatures++;}
if(signatures!==1)throw Error('Unexpected source meter; inspect the source before adapting');
const {project,report}=parseMidi(adapted);
const roles=[
 ['小号',56,72,64],['长笛',73,95,50],['双簧管',68,70,80],
 ['独奏小提琴',40,84,38],['第一小提琴',40,65,30],['第二小提琴',40,65,48],
 ['中提琴',41,73,85],['低音提琴',43,88,72],['大提琴',42,88,60],
];
if(project.tracks.length!==roles.length)throw Error('Unexpected source orchestration');
const cutoff=64;
project.name='巴赫 · 第二勃兰登堡协奏曲 · 开头演示';
project.tempoMap=[{beat:0,bpm:112}];
project.bars=16;project.loop={enabled:false,start:0,end:cutoff};
for(const [i,track] of project.tracks.entries()){
 const [name,program,volume,pan]=roles[i];track.name=name;
 track.notes=track.notes.filter(n=>n.beat<cutoff).map(n=>({...n,duration:Math.min(n.duration,cutoff-n.beat)}));
 track.events=[{beat:0,data:[0xc0|track.channel,program]},{beat:0,data:[0xb0|track.channel,7,volume]},{beat:0,data:[0xb0|track.channel,10,pan]}];
}
validateProject(project);
const midi=writeMidi(project),back=parseMidi(midi).project;
const count=p=>p.tracks.reduce((sum,t)=>sum+t.notes.length,0);
if(count(back)!==count(project))throw Error('Excerpt MIDI note count failed roundtrip');
await writeFile(path.join(dir,'巴赫_勃兰登堡2_演示.json'),JSON.stringify(project,null,2)+'\n');
await writeFile(path.join(dir,'巴赫_勃兰登堡2_演示.mid'),midi);
const duration=beatToSeconds(cutoff,project.tempoMap);
await writeFile(path.join(dir,'render-events.json'),JSON.stringify({duration,tail:2,events:compileEvents(project).map(e=>({time:e.time,data:e.data})),tracks:project.tracks.map(t=>({name:t.name,channel:t.channel,notes:t.notes.length})),importReport:report},null,2)+'\n');
console.log(JSON.stringify({duration,tracks:project.tracks.map(t=>({name:t.name,notes:t.notes.length})),totalNotes:count(project),roundtrip:true},null,2));
