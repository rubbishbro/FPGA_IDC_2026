// Resource-bank interface shared by the hardware-profile UI.
// This reads deployment metadata; it does not pretend to commit hardware state.
const CHANNEL_NAMES=['guitar','piano','trumpet','violin','cello','flute','piano_abc','guitar_abc','oboe','drums','banjo','mandolin'];
export function resourceBank(manifest,channel,bank=0){
  if(![0,1].includes(bank))throw Error('音组必须为低组0或高组1');
  const instrument=CHANNEL_NAMES[channel];
  if(!instrument)throw Error('该通道没有设备音色映射');
  const notes=manifest.note_maps ? manifest.note_maps[instrument] :
    (Array.isArray(manifest.notes)?manifest.notes:manifest.midi_notes??manifest.note_map);
  if(!Array.isArray(notes)||![16,32].includes(notes.length)||
      notes.some(n=>!Number.isInteger(n)||n<0||n>127)||new Set(notes).size!==notes.length)
    throw Error('该音色没有有效的16/32音资源清单');
  const active=notes.slice(bank*16,bank*16+16);
  if(active.length!==16)throw Error('该音色资源没有高音组');
  return {instrument,bank,notes:active,first:active[0],last:active.at(-1),
    // Native LCD frontend sends this held request via cfg_valid/cfg_ready.
    // It is an internal config ID, NOT a new COMMAND on the wire protocol.
    localConfig:{id:0x0300,value:bank}};
}
