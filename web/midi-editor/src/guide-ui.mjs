import {hardwareIssues} from './model.mjs';

// The deployed v1 protocol has no command to set audio_config_t.guide.
// Board mode is explicitly confirmed by the player; this module sends MIDI
// through the existing playback path and never treats TX as a mode readback.
export function setupGuide({getLink,supported,getSourceName,getProfile,getProject,
  isBusy,isPlaying,startPlayback,stopPlayback,document:doc=globalThis.document}){
  const $=id=>doc.getElementById(id),dialog=$('guide-dialog'),confirm=$('guide-confirm');
  let starting=false,previousPort,previousContext,startError='';
  let checkedProject,checkedProfile,cachedIssues=[];

  function render(){
    const link=getLink(),source=getSourceName();
    let profile,issues=[];
    try{
      profile=getProfile();const project=getProject(),signature=JSON.stringify(profile);
      // History commits replace the project. Avoid rescanning/sorting every
      // note on each serial TX update while the same project is playing.
      if(project!==checkedProject||signature!==checkedProfile){
        cachedIssues=hardwareIssues(project,profile);checkedProject=project;checkedProfile=signature;
      }
      issues=cachedIssues;
    }catch(e){issues=[e.message];}
    const context=JSON.stringify([supported(),source,profile]);
    if(!link.connected||link.port!==previousPort||context!==previousContext)confirm.checked=false;
    previousPort=link.port;previousContext=context;
    $('guide-source').textContent=source;
    $('guide-profile').textContent=profile?`主机核对清单：通道 ${profile.channel+1} · ${profile.notes.length} 个音高（以板端实际配置为准）`:'请先填写板端已加载配置';
    const blocked=!supported()?'请选择当前固件支持的 v1 协议':
      !link.connected?'请先在设备连接中打开串口':
      (link.pendingConfig||isBusy())?'请等待设备配置或演奏录制结束':issues.join('；');
    $('guide-check').textContent=blocked||'通道和音高检查通过；请确认板端已开启引导演奏';
    const playing=isPlaying();
    confirm.disabled=starting||playing||!!blocked;
    $('guide-start').disabled=starting||playing||!!blocked||!confirm.checked;
    $('guide-stop').disabled=!starting&&!playing;
    $('guide-start').textContent=starting?'正在准备提示…':'开始指引播放';
    $('guide-result').textContent=playing?'正在发送 MIDI 提示，请按 LCD 上的目标键演奏':
      starting?'正在准备串口播放…':startError||'提示已停止；板端模式请在设备菜单中确认';
  }

  $('open-guide').onclick=()=>{
    stopPlayback();startError='';confirm.checked=false;dialog.showModal();render();
  };
  $('close-guide').onclick=()=>dialog.close();
  dialog.addEventListener('close',()=>{
    if(starting||isPlaying())stopPlayback();
    confirm.checked=false;render();
  });
  confirm.onchange=render;
  $('guide-start').onclick=async()=>{
    render();if($('guide-start').disabled)return;
    starting=true;startError='';render();
    try{await startPlayback();}catch(e){startError=`未开始提示：${e.message}`;}
    finally{starting=false;render();}
  };
  $('guide-stop').onclick=()=>{stopPlayback();render();};
  render();return {render};
}
