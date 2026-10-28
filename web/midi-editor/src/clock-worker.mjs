// Wake-ups are independent of rendering. UART events are never sent ahead of time.
let timer;
onmessage=({data})=>{clearInterval(timer);if(data==='start')timer=setInterval(()=>postMessage('tick'),5);};
