import {KEYMAP_INSTRUMENTS,keymapData,applyKeymap} from './keymap.mjs';
export function setupKeymap({getLink,supported,isBusy,stopPlayback,toast,onApplied}){
  const $=id=>document.getElementById(id),dialog=$('keymap-dialog'),select=$('keymap-instrument'),grid=$('keymap-grid'),result=$('keymap-result');
  let sending=false;
  for(const spec of KEYMAP_INSTRUMENTS)select.add(new Option(spec.name,String(spec.id)));
  for(let i=0;i<16;i++){
    const label=document.createElement('label');label.textContent=`键 ${i+1}`;
    const input=document.createElement('input');input.type='number';input.step='1';input.setAttribute('aria-label',`键 ${i+1} MIDI 音高`);label.append(input);grid.append(label);
  }
  const inputs=[...grid.querySelectorAll('input')];
  const values=()=>inputs.map(input=>input.value.trim()===''?NaN:Number(input.value));
  function defaults(bank=0){
    const spec=KEYMAP_INSTRUMENTS[Number(select.value)];
    inputs.forEach((input,i)=>{input.value=spec.notes[(i+bank*16)%spec.notes.length];input.min=spec.notes[0];input.max=spec.notes.at(-1);});
    $('keymap-range').textContent=`可用 MIDI：${spec.id===7?spec.notes.join('、'):`${spec.notes[0]}–${spec.notes.at(-1)}`} · 接收通道 ${spec.channel}`;
    result.textContent='尚未发送到设备';render();
  }
  function render(){
    let error='';try{keymapData(Number(select.value),values());}catch(e){error=e.message;}
    $('keymap-validation').textContent=error;
    $('keymap-send').disabled=sending||!!error||!supported()||!getLink().connected||!!getLink().pendingConfig||isBusy();
    $('close-keymap').disabled=sending;select.disabled=sending;inputs.forEach(input=>input.disabled=sending);
    for(const id of ['keymap-low','keymap-high'])$(id).disabled=sending;
    $('keymap-send').textContent=sending?'等待设备提交…':'通过串口应用键位';
    $('keymap-connection').textContent=!supported()?'请选择 v1 协议连接设备':getLink().connected?'串口已连接；应用前请松开全部压力垫':'请先在设备连接中打开串口';
  }
  $('open-keymap').onclick=()=>{dialog.showModal();render();};
  $('close-keymap').onclick=()=>{if(!sending)dialog.close();};
  dialog.addEventListener('cancel',e=>{if(sending)e.preventDefault();});
  select.onchange=()=>defaults();grid.oninput=render;
  $('keymap-low').onclick=()=>defaults(0);$('keymap-high').onclick=()=>defaults(1);
  $('keymap-send').onclick=async()=>{
    if(sending||isBusy())return;
    const instrument=Number(select.value),notes=values(),link=getLink();
    if(!supported()||!link.connected)return;
    sending=true;stopPlayback();result.textContent='等待设备验证、装载和提交；请保持松键';render();
    try{
      await applyKeymap(link,instrument,notes);
      result.textContent='设备已确认：自定义键位应用成功';onApplied(KEYMAP_INSTRUMENTS[instrument],notes);toast('设备已确认自定义键位配置');
    }catch(e){result.textContent=e.message;toast(e.message,true);}
    finally{sending=false;render();}
  };
  defaults();return {render,get busy(){return sending;}};
}
