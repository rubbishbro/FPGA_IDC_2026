import test from 'node:test';
import assert from 'node:assert/strict';
import {setupGuide} from '../src/guide-ui.mjs';
import {blankProject} from '../src/model.mjs';

class Element extends EventTarget{
  checked=false;disabled=false;open=false;textContent='';
  showModal(){this.open=true;}
  close(){this.open=false;this.dispatchEvent(new Event('close'));}
}
function fixture(){
  const elements=new Map();
  const $=id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);};
  const project=blankProject();project.tracks[0].channel=1;
  project.tracks[0].notes=[{id:'note',pitch:60,velocity:90,beat:0,duration:1}];
  const state={supported:true,source:'有线 MIDI',profile:{channel:1,notes:[60]},
    project,busy:false,playing:false,starts:0,stops:0};
  const link={connected:true,port:{},pendingConfig:null};
  const guide=setupGuide({document:{getElementById:$},getLink:()=>link,
    supported:()=>state.supported,getSourceName:()=>state.source,
    getProfile:()=>state.profile,getProject:()=>state.project,
    isBusy:()=>state.busy,isPlaying:()=>state.playing,
    startPlayback:async()=>{state.starts++;if(state.startError)throw Error(state.startError);state.playing=true;},
    stopPlayback:()=>{state.stops++;state.playing=false;}
  });
  const confirm=()=>{$('guide-confirm').checked=true;$('guide-confirm').onchange();};
  return {$,state,link,guide,confirm};
}

test('guide requires explicit board confirmation and shares the playback start/stop path',async()=>{
  const {$,state,confirm} = fixture();
  $('open-guide').onclick();assert.equal($('guide-dialog').open,true);
  await $('guide-start').onclick();assert.equal(state.starts,0);
  confirm();assert.equal($('guide-start').disabled,false);
  await $('guide-start').onclick();assert.equal(state.starts,1);
  assert.equal($('guide-start').disabled,true);assert.equal($('guide-stop').disabled,false);
  assert.match($('guide-result').textContent,/正在发送 MIDI/);
  $('guide-stop').onclick();assert.equal(state.playing,false);
  await $('guide-start').onclick();assert.equal(state.starts,2);
  $('close-guide').onclick();assert.equal(state.playing,false);
  assert.equal($('guide-dialog').open,false);assert.equal($('guide-confirm').checked,false);
});

test('unsupported protocol, disconnect, configuration and recording block guide playback',async()=>{
  for(const condition of ['protocol','disconnect','config','recording']){
    const {$,state,link,guide,confirm}=fixture();confirm();
    if(condition==='protocol')state.supported=false;
    if(condition==='disconnect')link.connected=false;
    if(condition==='config')link.pendingConfig={};
    if(condition==='recording')state.busy=true;
    guide.render();await $('guide-start').onclick();
    assert.equal(state.starts,0,condition);assert.equal($('guide-confirm').disabled,true,condition);
    assert.match($('guide-check').textContent,/v1|打开串口|等待/);
  }
});

test('guide rejects channel mismatch, unavailable pitches and overlapping same notes',async()=>{
  for(const condition of ['channel','pitch','overlap']){
    const {$,state,guide,confirm}=fixture();
    if(condition==='channel')state.project.tracks[0].channel=0;
    if(condition==='pitch')state.project.tracks[0].notes[0].pitch=61;
    if(condition==='overlap')state.project.tracks[0].notes.push({...state.project.tracks[0].notes[0],id:'overlap'});
    state.project=structuredClone(state.project);
    guide.render();confirm();await $('guide-start').onclick();
    assert.equal(state.starts,0,condition);
    assert.match($('guide-check').textContent,/通道|缺少|重叠/);
  }
});

test('source, channel, keymap and port changes invalidate manual confirmation',()=>{
  for(const condition of ['source','channel','keymap','port','reconnect']){
    const {$,state,link,guide,confirm}=fixture();confirm();
    assert.equal($('guide-start').disabled,false);
    if(condition==='source')state.source='蓝牙 MIDI';
    if(condition==='channel')state.profile.channel=2;
    if(condition==='keymap')state.profile.notes=[60,61];
    if(condition==='port')link.port={};
    if(condition==='reconnect'){link.connected=false;guide.render();link.connected=true;}
    guide.render();assert.equal($('guide-confirm').checked,false,condition);
    assert.equal($('guide-start').disabled,true,condition);
    assert.equal($('guide-source').textContent,state.source);
  }
});

test('guide does not start twice while awaiting the shared player',async()=>{
  const {$,state,confirm}=fixture();confirm();
  const first=$('guide-start').onclick();
  await $('guide-start').onclick();await first;
  assert.equal(state.starts,1);
});

test('playback failure remains visible in the modal and permits retry',async()=>{
  const {$,state,confirm}=fixture();confirm();state.startError='串口写入失败';
  await $('guide-start').onclick();assert.equal(state.playing,false);
  assert.match($('guide-result').textContent,/串口写入失败/);
  assert.equal($('guide-start').disabled,false);
  state.startError='';await $('guide-start').onclick();assert.equal(state.playing,true);
});
