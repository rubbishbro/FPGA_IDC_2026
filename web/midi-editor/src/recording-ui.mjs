import {PerformanceRecorder,PERFORMANCE_TYPE,RECORD_START,RECORD_STOP,recordIdBytes} from './performance-recorder.mjs';
export function setupRecording({getLink,supportsRecording,getProject,commitTrack,getPosition,stopPlayback,toast,status,log=()=>{},startFrameTimeoutMs=2000}){
  const button=document.getElementById('record-performance'),label=document.getElementById('record-status');
  let state='idle',recorder=null,limitTimer,startTimer,startedAt=0,finishing=false,startAcknowledged=false,lastTake=null;
  const busy=()=>state!=='idle';
  function render(){
    button.setAttribute('aria-label',state==='recording'?'停止录制演奏':state==='arming'?'准备录制演奏':state==='stopping'?'正在收尾录制':'录制演奏');
    button.classList.toggle('recording',busy());button.setAttribute('aria-pressed',busy());button.textContent=state==='arming'?'准备录制…':state==='stopping'?'收尾中…':state==='recording'?'停止录制':'录制演奏';
    button.disabled=!!getLink().pendingConfig||state==='arming'||state==='stopping'||(!busy()&&(!getLink().connected||!supportsRecording()));
    if(state==='arming')label.textContent=startAcknowledged?'START 已确认 · 等待回传起点':'等待板端确认 START';
    else if(recorder&&busy()){const seconds=Math.min(600,Math.max(recorder.seconds,(performance.now()-startedAt)/1000));label.textContent=`REC ${Math.floor(seconds/60).toString().padStart(2,'0')}:${Math.floor(seconds%60).toString().padStart(2,'0')} · ${recorder.track.notes.length} 音符 · ${lastTake.frames} 回传帧${recorder.incomplete?' · 不完整':''}`;}else label.textContent='PAD → MIDI';
    button.title=(supportsRecording()?'录制板端压力垫演奏，停止后生成新 MIDI 轨道':'演奏录制需要有线 v1 链路')+(busy()?` · ${label.textContent}`:'');
  }
  function lock(value){document.querySelector('.workspace').inert=value;for(const id of ['play','stop','rewind','tempo','output','loop-toggle','project-name'])document.getElementById(id).disabled=value;}
  function finalize(incomplete=false){
    if(!recorder||finishing)return;finishing=true;clearTimeout(limitTimer);clearTimeout(startTimer);
    if(!recorder.ended)recorder.abort();recorder.incomplete ||= incomplete;
    const count=recorder.track.notes.length;
    if(lastTake)Object.assign(lastTake,{started:recorder.started,incomplete:recorder.incomplete,notes:count,phase:'finished'});
    state='idle';lock(false);
    log('录制结束',JSON.stringify(lastTake));
    if(count){commitTrack(recorder.track,recorder.incomplete);toast(`已新增演奏轨道：${count} 个音符${recorder.incomplete?'；录制不完整，已在最后可信时间封口':''}`,recorder.incomplete);}else toast(recorder.started?'收到录制起点，但没有收到音符事件；请按下并松开板端压力垫，导出通信诊断查看回传':'没有收到板端录制起点帧；请导出通信诊断',true);
    recorder=null;finishing=false;render();
  }
  function confirmStream(){
    if(state!=='arming'||!startAcknowledged||!recorder?.started)return;
    clearTimeout(startTimer);state='recording';lastTake.phase=state;
    status('已收到板端录制起点；请演奏压力垫，停止后将生成新轨道');render();
    if(document.hidden){stop();return;}
    limitTimer=setTimeout(()=>stop(),600000);
  }
  async function start(){
    const link=getLink();if(!link.connected||!supportsRecording())return toast('请连接有线 v1 串口',true);
    if(getProject().tracks.length>=128)return toast('轨道数量已达上限',true);
    stopPlayback();
    const id=crypto.getRandomValues(new Uint32Array(1))[0]||1;
    try{recorder=new PerformanceRecorder({id,project:getProject(),insertBeat:getPosition()});}catch(e){toast(e.message,true);return;}
    const current=recorder;startAcknowledged=false;
    lastTake={id,phase:'arming',acknowledged:false,started:false,frames:0,noteOns:0,noteOffs:0,ignoredFrames:0,ended:false,rxAtStart:{bytes:link.rxBytes??0,frames:link.rxFrames??0,errors:link.rxErrors??0}};
    log('录制 START',`ID ${id.toString(16).padStart(8,'0')}`);
    state='arming';startedAt=performance.now();lock(true);render();
    try{
      await link.configure(RECORD_START,recordIdBytes(id));
      if(recorder!==current||state!=='arming')return;
      startAcknowledged=true;lastTake.acknowledged=true;confirmStream();
      if(state==='arming'){
        status('START 已确认，正在等待板端录制起点回传');render();
        startTimer=setTimeout(()=>{
          if(recorder!==current||state!=='arming')return;
          lastTake.failure='missing_start_frame';
          if(link.connected)link.configure(RECORD_STOP,recordIdBytes(id)).catch(()=>{});
          finalize(true);toast('设备已确认 START，但未收到录制起点帧（TYPE82）；请导出通信诊断',true);
        },startFrameTimeoutMs);
      }
    }catch(e){
      if(recorder!==current)return;
      lastTake.failure=e.message;
      // START timeout can mean the device started; best-effort STOP, never auto-start again.
      if(link.connected)link.configure(RECORD_STOP,recordIdBytes(id)).catch(()=>{});
      finalize(true);toast(`无法开始录制：${e.message}`,true);
    }
  }
  async function stop(){
    if(state!=='recording')return;clearTimeout(limitTimer);state='stopping';render();const current=recorder;
    try{await getLink().configure(RECORD_STOP,recordIdBytes(current.id));if(recorder===current){limitTimer=setTimeout(()=>{if(recorder===current)finalize(true);},600);}}
    catch(e){if(recorder===current){lastTake.failure=e.message;finalize(true);toast(`录制收尾异常：${e.message}`,true);}}
  }
  function frame(frame){
    if(!recorder||frame.type!==PERFORMANCE_TYPE)return;
    try{
      if(!recorder.push(frame)){lastTake.ignoredFrames++;lastTake.lastIgnoredId=new DataView(frame.payload.buffer,frame.payload.byteOffset,frame.payload.byteLength).getUint32(4,true);return;}
      lastTake.frames++;lastTake.started=recorder.started;
      if(frame.payload[0]===0)log('录制回传','收到 TYPE82 起点');
      if(frame.payload[0]===1)lastTake.noteOns++;
      if(frame.payload[0]===2)lastTake.noteOffs++;
      if(frame.payload[0]===3)lastTake.ended=true;
      confirmStream();if(recorder?.ended)finalize();
    }
    catch(e){const id=recorder.id;lastTake.failure=e.message;getLink().configure(RECORD_STOP,recordIdBytes(id)).catch(()=>{});finalize(true);toast(`录制流异常：${e.message}`,true);}
  }
  button.onclick=()=>busy()?stop():start();
  const timer=setInterval(render,100);window.addEventListener('pagehide',()=>{clearInterval(timer);clearTimeout(limitTimer);clearTimeout(startTimer);if(recorder&&getLink().connected)getLink().configure(RECORD_STOP,recordIdBytes(recorder.id)).catch(()=>{});});
  document.addEventListener('visibilitychange',()=>{if(document.hidden&&state==='recording')stop();});
  render();return {get busy(){return busy();},get diagnostics(){
    if(!lastTake)return null;
    const link=getLink();return {...lastTake,rxAtStart:{...lastTake.rxAtStart},phase:state==='idle'?'finished':state,notes:recorder?.track.notes.length??lastTake.notes??0,rxSinceStart:{bytes:(link.rxBytes??0)-lastTake.rxAtStart.bytes,frames:(link.rxFrames??0)-lastTake.rxAtStart.frames,errors:(link.rxErrors??0)-lastTake.rxAtStart.errors}};
  },onFrame:frame,onFault:()=>{if(recorder){lastTake.failure='link_fault';finalize(true);}},stop};
}
