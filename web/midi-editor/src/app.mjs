import {History,demoProject,blankProject,newTrack,uid,clamp,noteName,validateProject,hardwareIssues,INSTRUMENTS,endBeat,profileExercise} from './model.mjs';
import {parseMidi,writeMidi} from './midi-file.mjs';
import {PianoRoll} from './piano-roll.mjs';
import {SerialLink} from './serial.mjs';
import {Playback,ReferenceSynth} from './playback.mjs';
const $=id=>document.getElementById(id),DRAFT='fpga-midi-studio:v1';
let toastTimer,autosaveTimer,selectedTrack,clipboard=[],worker,output='local',manifest=null,starting=false,lastTick=0,startGeneration=0;
let project=demoProject();
try{const saved=localStorage.getItem(DRAFT);if(saved)project=validateProject(JSON.parse(saved));}catch{status('本机草稿不可用，已打开示例工程');}
const history=new History(project,()=>{scheduleSave();render();});selectedTrack=project.tracks[0].id;
const synth=new ReferenceSynth();
const serial=new SerialLink(renderSerial,log);
const playback=new Playback({
  send:events=>output==='uart'?serial.send(events.map(e=>e.data)):synth.send(events),
  panic:()=>{synth.panic();if(output==='uart'&&serial.connected)serial.panic([Number($('hw-channel').value)]).catch(e=>log('清音失败',e.message));},
  onPosition:beat=>{roll.cursor=beat;roll.invalidate();renderPosition();if(playback.playing&&roll.x(beat)>roll.width-35){roll.leftBeat=Math.max(0,beat-1);roll.invalidate();}},
  onStop:()=>{worker?.postMessage('stop');renderTransport();},
  onError:e=>{if(!playback.playing)return;stopPlayback();toast(e.message,true);}
});
serial.onFault=e=>{stopPlayback();toast(`串口故障：${e.message}。请检查板端状态。`,true);};
const roll=new PianoRoll($('roll'),$('roll-overlay'),{
  getProject:()=>history.current,getTrack:()=>selectedTrack,
  onCommit:next=>{try{validateProject(next);history.commit(next);}catch(e){toast(e.message,true);roll.invalidate();}renderSelection();},beforeEdit:()=>stopPlayback(),onSelection:renderSelection,
  onSeek:beat=>{stopPlayback();playback.position=Math.min(beat,endBeat(history.current));roll.cursor=playback.position;renderPosition();roll.invalidate();},
  onZoom:value=>$('zoom').value=value,onStatus:status,
  audition:pitch=>{if(output==='local')audition(pitch).catch(e=>toast(e.message,true));else status('UART 键盘试听未启用；请用走带播放已校验片段');},
  onRender:({backend,notes})=>{$('backend').textContent=backend;$('note-count').textContent=notes;}
});
try{worker=new Worker(new URL('./clock-worker.mjs',import.meta.url),{type:'module'});worker.onmessage=()=>{if(playback.playing){if(performance.now()-lastTick>250){stopPlayback();toast('浏览器调度停顿超过 250ms，已停止播放',true);}else{lastTick=performance.now();playback.tick();}}};worker.onerror=()=>{stopPlayback();toast('播放时钟启动失败，请重新打开本地页面',true);};}catch(e){toast(`播放时钟不可用：${e.message}`,true);}
function status(message){$('status').textContent=message;}
function toast(message,error=false){clearTimeout(toastTimer);$('toast').textContent=message;$('toast').classList.toggle('error',error);$('toast').hidden=false;status(message);toastTimer=setTimeout(()=>$('toast').hidden=true,error?10000:4500);}
function log(kind,message){const p=document.createElement('p'),strong=document.createElement('strong');strong.textContent=`${new Date().toLocaleTimeString('zh-CN',{hour12:false})} ${kind} `;p.append(strong,document.createTextNode(message));$('link-log').prepend(p);while($('link-log').children.length>40)$('link-log').lastChild.remove();}
function currentTrack(){return history.current.tracks.find(t=>t.id===selectedTrack)??history.current.tracks[0];}
function scheduleSave(){clearTimeout(autosaveTimer);$('save-state').textContent='保存中…';autosaveTimer=setTimeout(()=>{try{localStorage.setItem(DRAFT,JSON.stringify(history.current));$('save-state').textContent='草稿已保存';$('draft-time').textContent=`保存于 ${new Date().toLocaleTimeString('zh-CN',{hour12:false})}`;}catch{$('save-state').textContent='草稿保存失败';toast('浏览器存储已满或不可用，请保存 JSON 工程',true);}},450);}
function edit(fn){stopPlayback();try{const next=structuredClone(history.current);fn(next);next.bars=Math.max(next.bars,Math.ceil(endBeat(next)/4));validateProject(next);history.commit(next);}catch(e){toast(e.message,true);render();}}
function render(){
  const p=history.current;if(!p.tracks.some(t=>t.id===selectedTrack))selectedTrack=p.tracks[0].id;
  document.title=`${p.name} · FPGA MIDI Studio`;$('project-name').value=p.name;$('track-count').textContent=String(p.tracks.length).padStart(2,'0');$('bar-count').textContent=p.bars;$('tempo').value=Math.round(p.tempoMap[0].bpm*100)/100;$('tempo-unit').textContent=p.tempoMap.length>1?'变速':'BPM';$('tempo').title=p.tempoMap.length>1?'修改后会将整首曲谱设为此固定速度':'每分钟拍数';
  $('loop-start').value=p.loop.start+1;$('loop-end').value=p.loop.end+1;$('bars').value=p.bars;$('loop-toggle').classList.toggle('active',p.loop.enabled);$('loop-toggle').setAttribute('aria-pressed',p.loop.enabled);
  $('undo').disabled=!history.undoStack.length;$('redo').disabled=!history.redoStack.length;$('editing-track').textContent=currentTrack().name;
  const ids=new Set(currentTrack().notes.map(n=>n.id));roll.selection=new Set([...roll.selection].filter(id=>ids.has(id)));
  renderTracks();renderSelection();renderPosition();roll.invalidate();
}
function renderTracks(){
  $('tracks').replaceChildren();
  history.current.tracks.forEach((t,i)=>{
    const row=document.createElement('div');row.className=`track${t.id===selectedTrack?' selected':''}`;row.style.setProperty('--track-color',t.color);row.tabIndex=0;row.setAttribute('aria-label',`选择轨道 ${t.name}`);
    const top=document.createElement('div');top.className='track-top';const index=document.createElement('span');index.className='track-index';index.textContent=String(i+1).padStart(2,'0');const color=document.createElement('span');color.className='track-color';
    const name=document.createElement('input');name.className='track-name';name.value=t.name;name.maxLength=150;name.setAttribute('aria-label',`轨道 ${i+1} 名称`);name.onchange=()=>edit(p=>p.tracks[i].name=name.value.trim()||`轨道 ${i+1}`);
    top.append(index,color,name);const bottom=document.createElement('div');bottom.className='track-bottom-row';const channel=document.createElement('select');channel.setAttribute('aria-label',`轨道 ${i+1} MIDI 通道`);
    for(let ch=0;ch<16;ch++)channel.append(new Option(`Ch ${ch+1}${INSTRUMENTS[ch]?' · '+INSTRUMENTS[ch]:''}`,ch));channel.value=t.channel;channel.onchange=()=>edit(p=>p.tracks[i].channel=Number(channel.value));
    const button=(text,title,on,action)=>{const b=document.createElement('button');b.textContent=text;b.title=title;b.setAttribute('aria-label',`${t.name} ${title}`);b.className=`track-button${on?' on':''}`;b.setAttribute('aria-pressed',on);b.onclick=e=>{e.stopPropagation();edit(p=>action(p.tracks[i]));};return b;};
    const mute=button('M','静音',t.muted,t=>t.muted=!t.muted),solo=button('S','独奏',t.solo,t=>t.solo=!t.solo),del=button('×','删除轨道',false,()=>{});del.classList.add('track-delete');del.onclick=e=>{e.stopPropagation();if(history.current.tracks.length===1){toast('工程至少保留一条轨道');return;}edit(p=>p.tracks.splice(i,1));};
    bottom.append(channel,mute,solo,del);const count=document.createElement('div');count.className='track-notes';count.textContent=`${t.notes.length} 个音符${t.events.length?' · '+t.events.length+' 个控制事件':''}`;
    row.append(top,bottom,count);row.onclick=e=>{if(e.target.closest('button,select'))return;if(selectedTrack!==t.id){selectedTrack=t.id;roll.select([]);render();}};row.onkeydown=e=>{if(e.target===row&&(e.key==='Enter'||e.key===' ')){e.preventDefault();selectedTrack=t.id;roll.select([]);render();}};
    $('tracks').append(row);
  });
}
function renderSelection(){const notes=roll.selected(),n=notes[0];$('selection-count').textContent=notes.length?`${notes.length} 个音符`:'未选择';$('selection-fields').hidden=!n;$('selection-empty').hidden=!!n;if(n){$('note-pitch').value=n.pitch;$('note-name').textContent=noteName(n.pitch);$('note-velocity').value=n.velocity;$('note-beat').value=Number((n.beat+1).toFixed(6));$('note-duration').value=Number(n.duration.toFixed(6));}}
function renderPosition(){const b=Math.max(0,playback.position);$('position').textContent=`${String(Math.floor(b/4)+1).padStart(3,'0')} : ${Math.floor(b%4)+1} : ${String(Math.floor((b%1)*480)).padStart(3,'0')}`;}
function renderTransport(){$('play').classList.toggle('playing',playback.playing);$('play').querySelector('span').textContent=playback.playing?'暂停':'播放';$('play').setAttribute('aria-label',playback.playing?'暂停':'播放');}
function renderSerial(){$('connection-badge').textContent=serial.connected?'串口已连接':'未连接';$('connection-badge').classList.toggle('connected',serial.connected);$('connect').querySelector('span').textContent=serial.connected?'断开串口':'连接串口';$('baud').disabled=!!serial.port;$('tx-frames').textContent=serial.txFrames;$('tx-bytes').textContent=serial.txBytes;$('rx-frames').textContent=serial.rxFrames;}
function hardwareProfile(){const notes=$('hw-notes').value.split(/[\s,，]+/).filter(Boolean).map(Number);if(notes.some(n=>!Number.isInteger(n)||n<0||n>127)||new Set(notes).size!==notes.length)throw Error('已加载音高清单必须是不重复的 0～127 整数');return {channel:Number($('hw-channel').value),notes};}
function stopPlayback(){startGeneration++;playback.stop();worker?.postMessage('stop');renderTransport();}
async function play(){
  if(playback.playing){stopPlayback();return;}if(starting){stopPlayback();return;}starting=true;const generation=++startGeneration;
  try{
    if(!worker)throw Error('播放时钟不可用');validateProject(history.current);
    if(output==='uart') {
      if(!serial.connected)throw Error('请先连接串口');const issues=hardwareIssues(history.current,hardwareProfile());if(issues.length)throw Error(issues.join('；'));await serial.panic([hardwareProfile().channel]);
      const aux=history.current.tracks.reduce((sum,t)=>sum+t.events.filter(e=>!((e.data[0]&0xf0)===0xb0&&[64,120,123].includes(e.data[1]))).length,0);if(aux)toast(`${aux} 个非踏板/清音控制事件保留在工程中，本轮 UART 播放跳过`);
    } else await synth.resume();
    if(generation!==startGeneration||document.hidden)return;
    lastTick=performance.now();playback.start(history.current,playback.position,output==='uart');worker.postMessage('start');renderTransport();status(output==='uart'?'UART 演奏中 · 写入不等于板端确认':'参考试听中 · 三角波音源');
  }catch(e){toast(e.message,true);}finally{starting=false;}
}
async function audition(pitch){await synth.resume();const key=uid(),ch=currentTrack().channel;synth.send([{key,data:[0x90|ch,pitch,90]}]);setTimeout(()=>synth.send([{key,data:[0x80|ch,pitch,0]}]),220);}
function deleteNotes(){const ids=new Set(roll.selection);if(!ids.size)return;edit(p=>{const t=p.tracks.find(t=>t.id===selectedTrack);t.notes=t.notes.filter(n=>!ids.has(n.id));});roll.select([]);}
function copyNotes(){clipboard=structuredClone(roll.selected());if(clipboard.length)toast(`已复制 ${clipboard.length} 个音符`);}
function pasteNotes(atCursor=true){if(!clipboard.length)return;const min=Math.min(...clipboard.map(n=>n.beat)),offset=atCursor?Math.max(0,playback.position)-min:Math.max(...clipboard.map(n=>n.beat+n.duration))-min,copies=clipboard.map(n=>({...n,id:uid(),beat:n.beat+offset}));edit(p=>p.tracks.find(t=>t.id===selectedTrack).notes.push(...copies));roll.select(copies.map(n=>n.id));}
function transformNotes(fn){if(!roll.selection.size)return;edit(p=>p.tracks.find(t=>t.id===selectedTrack).notes.filter(n=>roll.selection.has(n.id)).forEach(fn));}
function download(data,type,name){const url=URL.createObjectURL(new Blob([data],{type})),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}
function safeName(){return history.current.name.replace(/[\\/:*?"<>|]/g,'_')||'untitled';}
$('play').onclick=play;$('stop').onclick=()=>{stopPlayback();playback.position=history.current.loop.enabled?history.current.loop.start:0;roll.cursor=playback.position;renderPosition();roll.invalidate();};$('rewind').onclick=$('stop').onclick;
$('panic').onclick=async()=>{stopPlayback();if(serial.connected){try{await serial.panic();toast('全通道清音请求已写入；板端静音状态需实机确认');}catch(e){toast(`清音写入失败：${e.message}`,true);}}else toast('已停止电脑试听；串口未连接');};
$('loop-toggle').onclick=()=>edit(p=>p.loop.enabled=!p.loop.enabled);
$('output').onchange=()=>{stopPlayback();output=$('output').value;$('output-status').textContent=output==='uart'?'FPGA · 有线 UART':'参考试听 · 三角波';status(output==='uart'?'已选择 UART，播放前将核对硬件配置':'已选择电脑参考试听');};
$('connect').onclick=async()=>{const b=$('connect');b.disabled=true;try{stopPlayback();if(serial.connected){await serial.panic();await serial.disconnect();}else{if(serial.port)await serial.disconnect();await serial.connect(Number($('baud').value));}}catch(e){if(e.name!=='NotFoundError')toast(e.message,true);}finally{b.disabled=false;renderSerial();}};
$('project-name').onchange=()=>edit(p=>p.name=$('project-name').value.trim()||'未命名片段');
$('tempo').onchange=()=>{const bpm=Number($('tempo').value);if(!Number.isFinite(bpm)||bpm<4||bpm>1000){render();return;}const variable=history.current.tempoMap.length>1;edit(p=>p.tempoMap=[{beat:0,bpm}]);if(variable)toast('已将变速图替换为固定速度；可撤销恢复');};
$('snap').onchange=()=>roll.snap=Number($('snap').value);$('note-length').onchange=()=>roll.noteLength=Number($('note-length').value);$('zoom').oninput=()=>{roll.beatWidth=Number($('zoom').value);roll.invalidate();};$('fit').onclick=()=>roll.fit();
for(const b of document.querySelectorAll('[data-tool]'))b.onclick=()=>{roll.tool=b.dataset.tool;for(const t of document.querySelectorAll('[data-tool]')){t.classList.toggle('active',t===b);t.setAttribute('aria-pressed',t===b);}};
$('undo').onclick=()=>{stopPlayback();history.undo();};$('redo').onclick=()=>{stopPlayback();history.redo();};
$('add-track').onclick=()=>{if(history.current.tracks.length>=128){toast('最多 128 轨',true);return;}const t=newTrack(history.current.tracks.length);selectedTrack=t.id;edit(p=>p.tracks.push(t));roll.select([]);};
$('new-project').onclick=()=>{stopPlayback();const p=blankProject();selectedTrack=p.tracks[0].id;history.commit(p);roll.select([]);roll.leftBeat=0;playback.position=0;roll.cursor=0;renderPosition();toast('已新建空白工程；可撤销恢复原工程');};
for(const [id,key] of [['note-pitch','pitch'],['note-velocity','velocity'],['note-beat','beat'],['note-duration','duration']])$(id).onchange=()=>{const value=Number($(id).value)-(key==='beat'?1:0);if(!Number.isFinite(value)){renderSelection();return;}const n=roll.selected()[0];if(!n)return;if(key==='pitch'||key==='beat'){const delta=value-n[key],notes=roll.selected(),min=Math.min(...notes.map(n=>n[key]));if(min+delta<0||(key==='pitch'&&Math.max(...notes.map(n=>n.pitch))+delta>127)){renderSelection();return;}transformNotes(n=>n[key]=key==='pitch'?Math.round(n[key]+delta):n[key]+delta);}else transformNotes(n=>n[key]=key==='velocity'?clamp(Math.round(value),1,127):clamp(value,1/480,40000-n.beat));};
$('delete-note').onclick=deleteNotes;$('duplicate').onclick=()=>{copyNotes();pasteNotes(false);};$('quantize').onclick=()=>transformNotes(n=>{n.beat=roll.quantize(n.beat);n.duration=Math.max(roll.snap,roll.quantize(n.duration));});
for(const id of ['loop-start','loop-end'])$(id).onchange=()=>{const start=Number($('loop-start').value)-1,end=Number($('loop-end').value)-1;if(!Number.isFinite(start)||!Number.isFinite(end)||start<0||end<=start||end>history.current.bars*4){toast('循环范围需位于工程内，且结束拍大于起始拍',true);render();return;}edit(p=>Object.assign(p.loop,{start,end}));};
$('bars').onchange=()=>{const bars=Number($('bars').value),min=Math.max(1,Math.ceil(Math.max(...history.current.tracks.flatMap(t=>[...t.notes.map(n=>n.beat+n.duration),...t.events.map(e=>e.beat)]),4)/4));if(!Number.isInteger(bars)||bars<min||bars>10000){toast(`工程至少需要 ${min} 小节`,true);render();return;}stopPlayback();const next=structuredClone(history.current);next.bars=bars;next.loop.end=Math.min(next.loop.end,bars*4);if(next.loop.start>=next.loop.end)next.loop.start=0;history.commit(next);};
$('import').onclick=()=>$('file-input').click();$('file-input').onchange=async e=>{const file=e.target.files[0];if(!file)return;try{if(file.size>20*1024*1024)throw Error('文件上限 20 MB');let p,report;if(/\.json$/i.test(file.name))p=validateProject(JSON.parse(await file.text()));else({project:p,report}=parseMidi(await file.arrayBuffer()));p.name=/\.json$/i.test(file.name)?p.name:file.name.replace(/\.(mid|midi)$/i,'');stopPlayback();selectedTrack=p.tracks[0].id;history.commit(p);roll.select([]);playback.position=0;roll.cursor=0;roll.fit();renderPosition();toast(`已导入 ${file.name}${report?`；保留 ${report.auxiliary} 个控制事件，跳过 ${report.ignored} 个非编辑元事件 / SysEx，未配对 Off ${report.unmatched}，补结束 ${report.closed}`:''}`);}catch(err){toast(`导入失败：${err.message}`,true);}finally{e.target.value='';}};
$('export-midi').onclick=()=>{try{download(writeMidi(history.current),'audio/midi',safeName()+'.mid');toast('已导出全部轨道及速度图');}catch(e){toast(e.message,true);}};$('save-project').onclick=()=>download(JSON.stringify(history.current,null,2),'application/json',safeName()+'.json');
for(const id of ['hw-channel','hw-notes'])$(id).onchange=()=>{stopPlayback();try{hardwareProfile();status('已更新主机核对清单；请确保与板端实际配置一致');}catch(e){toast(e.message,true);}};
$('hardware-exercise').onclick=()=>{try{const p=profileExercise(hardwareProfile());stopPlayback();selectedTrack=p.tracks[0].id;history.commit(p);playback.position=0;roll.cursor=0;roll.select([]);roll.fit();renderPosition();toast('已生成当前音组测试片段；可撤销恢复，点击播放前先选择输出');}catch(e){toast(e.message,true);}};
$('load-manifest').onclick=()=>$('manifest-input').click();
function applyManifest(){const bank=Number($('manifest-bank').value),notes=manifest.notes??manifest.midi_notes;if(!Array.isArray(notes)||notes.some(n=>!Number.isInteger(n)||n<0||n>127)||new Set(notes).size!==notes.length||![16,32].includes(notes.length))throw Error('manifest 需包含 16 / 32 项 notes 或 midi_notes 清单');const active=notes.slice(bank*16,bank*16+16);if(active.length!==16)throw Error('该清单没有高音组');$('hw-notes').value=active.join(',');stopPlayback();status('已读取资源清单；主机未向板端发送切组命令');}
$('manifest-input').onchange=async e=>{try{if(!e.target.files[0])return;manifest=JSON.parse(await e.target.files[0].text());applyManifest();toast('资源音高清单已载入；请在板端选择对应音组');}catch(err){toast(err.message,true);}finally{e.target.value='';}};$('manifest-bank').onchange=()=>{if(manifest){try{applyManifest();}catch(e){toast(e.message,true);}}else toast('请先载入 Flash manifest');};
$('close-inspector').onclick=()=>{document.querySelector('.inspector').classList.remove('open');$('toggle-inspector').setAttribute('aria-expanded','false');};
$('toggle-inspector').onclick=()=>{const open=document.querySelector('.inspector').classList.toggle('open');$('toggle-inspector').setAttribute('aria-expanded',open);};
$('help').onclick=()=>$('help-dialog').showModal();$('close-help').onclick=()=>$('help-dialog').close();
$('help-dialog').addEventListener('click',e=>{if(e.target===$('help-dialog')){const r=e.target.getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)e.target.close();}});
document.addEventListener('keydown',e=>{
  if(e.key==='Escape'){if($('help-dialog').open)return;$('panic').click();return;}
  if(e.target.closest('input,textarea,select')||$('help-dialog').open)return;
  const mod=e.ctrlKey||e.metaKey,key=e.key.toLowerCase();
  if(e.code==='Space'){e.preventDefault();play();return;}
  if(mod&&key==='z'){e.preventDefault();stopPlayback();e.shiftKey?history.redo():history.undo();return;}
  if(mod&&key==='s'){e.preventDefault();$('save-project').click();return;}
  if(mod&&key==='a'){e.preventDefault();roll.select(currentTrack().notes.map(n=>n.id));return;}
  if(mod&&key==='c'){e.preventDefault();copyNotes();return;}if(mod&&key==='v'){e.preventDefault();pasteNotes();return;}
  if(e.key==='Delete'||e.key==='Backspace'){e.preventDefault();deleteNotes();return;}
  if(e.key.startsWith('Arrow')&&roll.selection.size){e.preventDefault();const db=e.key==='ArrowLeft'?-roll.snap:e.key==='ArrowRight'?roll.snap:0,dp=e.key==='ArrowUp'?(e.shiftKey?12:1):e.key==='ArrowDown'?(e.shiftKey?-12:-1):0;if(roll.selected().some(n=>n.beat+db<0||n.pitch+dp<0||n.pitch+dp>127))return;transformNotes(n=>{n.beat+=db;n.pitch+=dp;});return;}
  if(!mod&&['d','v','e'].includes(key))document.querySelector(`[data-tool="${{d:'draw',v:'select',e:'erase'}[key]}"]`).click();
  if(key==='l'&&!mod)$('loop-toggle').click();if(key==='?')$('help').click();
});
document.addEventListener('visibilitychange',()=>{if(document.hidden&&playback.playing){stopPlayback();status('页面进入后台，已停止走带并请求清音');}});
window.addEventListener('pagehide',()=>{stopPlayback();try{localStorage.setItem(DRAFT,JSON.stringify(history.current));}catch{}});
if(!navigator.serial)$('serial-support').textContent='当前浏览器无 Web Serial。连接硬件请用 Chrome / Edge 打开本地地址。';
log('就绪','v1 协议 · 本地编辑 · 无板端状态查询');render();renderSerial();
requestAnimationFrame(()=>requestAnimationFrame(()=>roll.fit()));
