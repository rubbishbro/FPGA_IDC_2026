export const CHANNEL_SAMPLES=['guitar','piano','trumpet','violin','cello','flute','piano','guitar'];
export const SAMPLE_NAMES={guitar:'吉他',piano:'钢琴',trumpet:'小号',violin:'小提琴',cello:'大提琴',flute:'长笛',viola:'中提琴',oboe:'双簧管',bass:'低音提琴'};
export const SAMPLE_PROGRAMS={piano:0,guitar:24,trumpet:56,violin:40,cello:42,flute:73,viola:41,oboe:68,bass:43};
export function programInstrument(program){
  if(program>=0&&program<=7)return 'piano';
  if(program>=24&&program<=31)return 'guitar';
  return ({40:'violin',41:'viola',42:'cello',43:'bass',48:'violin',49:'violin',56:'trumpet',57:'trumpet',68:'oboe',73:'flute',74:'flute'})[program];
}
export function trackInstrument(track,beat=0){
  if(track.previewInstrument&&SAMPLE_NAMES[track.previewInstrument])return track.previewInstrument;
  let program,latest=-Infinity;
  for(const e of track.events)if((e.data[0]&0xf0)===0xc0&&e.beat<=beat&&e.beat>=latest){latest=e.beat;program=e.data[1];}
  return programInstrument(program)??CHANNEL_SAMPLES[track.channel]??'piano';
}
export function nearestSample(samples,pitch){
  if(!samples?.length)throw Error('该乐器没有可用录音');
  return samples.reduce((best,s)=>Math.abs(s.pitch-pitch)<Math.abs(best.pitch-pitch)?s:best);
}
