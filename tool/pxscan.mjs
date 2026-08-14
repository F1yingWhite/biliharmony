// 读取 BMP 像素并输出指定行列颜色
import fs from 'node:fs';
const file = process.argv[2] || '/tmp/top.bmp';
const b = fs.readFileSync(file);
const off = b.readUInt32LE(10);
const w = b.readInt32LE(18);
const hRaw = b.readInt32LE(22);
const h = Math.abs(hRaw);
const topDown = hRaw < 0;
const bpp = b.readUInt16LE(28) / 8;
console.log('size', w, 'x', h, 'bpp', bpp, 'topDown', topDown);
const stride = Math.ceil(w * bpp / 4) * 4;
function px(x, y) {
  const row = topDown ? y : (h - 1 - y);
  const i = off + row * stride + x * bpp;
  return '#' + [b[i + 2], b[i + 1], b[i]].map(v => v.toString(16).padStart(2, '0')).join('');
}
const cx = Math.floor(w / 2);
for (let y = 0; y < h; y += 30) {
  console.log('y=' + y, px(cx, y), px(Math.floor(w * 0.05), y), px(Math.floor(w * 0.95), y));
}
