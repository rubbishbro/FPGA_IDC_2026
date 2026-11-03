// Production router_pkg instrument IDs and deployed note ranges.
export const KEYMAP_INSTRUMENTS=[
  ['钢琴 1',44,2],['吉他 1',44,1],['长笛',60,6],['小号',51,3],
  ['大提琴',44,5],['小提琴',55,4],['双簧管',58,9],['鼓组',null,10],
  ['班卓',48,11],['曼陀铃',55,12],['钢琴 2',44,7],['吉他 2',44,8]
].map(([name,first,channel],id)=>({id,name,channel,notes:first===null?[36,38,42,45,49,59]:Array.from({length:32},(_,i)=>first+i)}));
export function keymapData(instrument,notes){
  const spec=KEYMAP_INSTRUMENTS[instrument];
  if(!Number.isInteger(instrument)||!spec)throw Error('请选择有效乐器');
  if(!Array.isArray(notes)||notes.length!==16)throw Error('需要填写完整的 16 个键位');
  return notes.flatMap((note,i)=>{
    if(!Number.isInteger(note)||!spec.notes.includes(note))throw Error(`键 ${i+1} 音高不在该乐器资源范围内`);
    return [instrument,note];
  });
}
export async function applyKeymap(link,instrument,notes){
  const data=keymapData(instrument,notes);
  // Resource loading and release/rollback can exceed ordinary scalar config time.
  return link.configure(0x20,data,{timeoutMs:5000,maxRetries:0});
}
