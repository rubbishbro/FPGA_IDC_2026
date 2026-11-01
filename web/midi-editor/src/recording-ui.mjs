import {PerformanceRecorder,PERFORMANCE_TYPE,RECORD_START,RECORD_STOP,recordIdBytes} from './performance-recorder.mjs';
export function setupRecording({getLink,supportsRecording,getProject,commitTrack,getPosition,stopPlayback,toast,status}){
  const button=document.getElementById('record-performance'),label=document.getElementById('record-status');
  let state='idle',recorder=null,limitTimer,startedAt=0,finishing=false;
  const busy=()=>state!=='idle';
  function render(){
    button.setAttribute('aria-label',state==='recording'?'停止录制演奏':state==='arming'?'准备录制演奏':state==='stopping'?'正在收尾录制':'录制演奏');
    button.classList.toggle('recording',busy());button.setAttribute('aria-pressed',busy());button.textContent=state==='arming'?'准备录制…':state==='stopping'?'收尾中…':state==='recording'?'■ 停止录制':'● 录制演奏';
    button.disabled=!!getLink().pendingConfig||state==='arming'||state==='stopping'||(!busy()&&(!getLink().connected||!supportsRecording()));
    button.title=supportsRecording()?'录制板端压力垫演奏，停止后生成新 MIDI 轨道':'演奏录制需要有线 v1 链路';
    if(recorder&&busy()){const seconds=Math.min(600,Math.max(recorder.seconds,(performance.now()-startedAt)/1000));label.textContent=`REC ${Math.floor(seconds/60).toString().padStart(2,'0')}:${Math.floor(seconds%60).toString().padStart(2,'0')} · ${recorder.track.notes.length} 音符${recorder.incomplete?' · 不完整':''}`;}else label.textContent='PAD → MIDI';
  }
  function lock(value){document.querySelector('.workspace').inert=value;for(const id of ['play','stop','rewind','tempo','output','loop-toggle','project-name'])document.getElementById(id).disabled=value;}
  function finalize(incomplete=false){
    if(!recorder||finishing)return;finishing=true;clearTimeout(limitTimer);
    if(!recorder.ended)recorder.abort();recorder.incomplete ||= incomplete;
    const count=recorder.track.notes.length;
    state='idle';lock(false);
    if(count){commitTrack(recorder.track,recorder.incomplete);toast(`已新增演奏轨道：${count} 个音符${recorder.incomplete?'；录制不完整，已在最后可信时间封口':''}`,recorder.incomplete);}else toast('没有录到演奏音符；请在板端选择压力垫来源后演奏',true);
    recorder=null;finishing=false;render();
  }
  async function start(){
    const link=getLink();if(!link.connected||!supportsRecording())return toast('请连接有线 v1 串口',true);
    if(getProject().tracks.length>=128)return toast('轨道数量已达上限',true);
    stopPlayback();
    const id=crypto.getRandomValues(new Uint32Array(1))[0]||1;
    try{recorder=new PerformanceRecorder({id,project:getProject(),insertBeat:getPosition()});}catch(e){toast(e.message,true);return;}state='arming';startedAt=performance.now();lock(true);render();
    try{
      await link.configure(RECORD_START,recordIdBytes(id));
      if(state!=='arming')return;
      state='recording';if(document.hidden){stop();return;}status('正在录制板端演奏；停止后将生成新轨道');render();
      limitTimer=setTimeout(()=>stop(),600000);
    }catch(e){
      // START timeout can mean the device started; best-effort STOP, never auto-start again.
      if(link.connected)link.configure(RECORD_STOP,recordIdBytes(id)).catch(()=>{});
      finalize(true);toast(`无法开始录制：${e.message}`,true);
    }
  }
  async function stop(){
    if(state!=='recording')return;clearTimeout(limitTimer);state='stopping';render();const current=recorder;
    try{await getLink().configure(RECORD_STOP,recordIdBytes(current.id));if(recorder===current){limitTimer=setTimeout(()=>{if(recorder===current)finalize(true);},600);}}
    catch(e){if(recorder===current){finalize(true);toast(`录制收尾异常：${e.message}`,true);}}
  }
  function frame(frame){
    if(!recorder||frame.type!==PERFORMANCE_TYPE)return;
    try{recorder.push(frame);if(recorder.ended)finalize();}
    catch(e){const id=recorder.id;getLink().configure(RECORD_STOP,recordIdBytes(id)).catch(()=>{});finalize(true);toast(`录制流异常：${e.message}`,true);}
  }
  button.onclick=()=>busy()?stop():start();
  const timer=setInterval(render,100);window.addEventListener('pagehide',()=>{clearInterval(timer);clearTimeout(limitTimer);if(recorder&&getLink().connected)getLink().configure(RECORD_STOP,recordIdBytes(recorder.id)).catch(()=>{});});
  document.addEventListener('visibilitychange',()=>{if(document.hidden&&state==='recording')stop();});
  render();return {get busy(){return busy();},onFrame:frame,onFault:()=>{if(recorder)finalize(true);},stop};
}
