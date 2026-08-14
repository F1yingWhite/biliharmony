import fs from 'node:fs';
const b = fs.readFileSync('/tmp/top.bmp');
const off = b.readUInt32LE(10);
const w = b.readInt32LE(18);
const hRaw = b.readInt32LE(22); const h = Math.abs(hRaw); const topDown = hRaw < 0;
const bpp = b.readUInt16LE(28) / 8; const stride = Math.ceil(w*bpp/4)*4;
function px(x,y){ const row = topDown?y:(h-1-y); const i=off+row*stride+x*bpp; return [b[i+2],b[i+1],b[i]]; }
// 扫描粉色/红色系，打印每行是否含接近粉色的像素
const rows=[];
for(let y=0;y<h;y+=10){
  let pink=0, red=0, total=0;
  for(let x=0;x<w;x+=4){ const [r,g,b]=px(x,y); total++;
    if(r>200 && g>90 && g<150 && b>130 && b<190) pink++;
    if(r>180 && g<90 && b<90) red++;
  }
  if(pink>0) rows.push('y='+y+' pink='+pink+'/'+total);
  if(red>0 && y<200) rows.push('y='+y+' RED='+red);
}
console.log(rows.slice(0,60).join('\n') || '(无粉色)');
// 顶部 40 行平均色（左中右）
function avg(y){ let r=0,g=0,bl=0,n=0; for(let x=0;x<w;x+=8){const p=px(x,y);r+=p[0];g+=p[1];bl+=p[2];n++;} return '#'+[r/n,g/n,bl/n].map(v=>Math.round(v).toString(16).padStart(2,'0')).join(''); }
console.log('顶部平均色 y=20:', avg(20), ' y=80:', avg(80), ' y=140:', avg(140));
