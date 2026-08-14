// 生成 B 站风格应用图标 PNG（粉色圆角底 + 白色小电视）
// 运行: node tool/gen_icons.js
const zlib = require('zlib');
const fs = require('fs');
const path = require('path');

// ---------- PNG 编码 ----------
const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])));
  return Buffer.concat([len, typeBuf, data, crc]);
}

function encodePng(width, height, rgba) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;  // bit depth
  ihdr[9] = 6;  // RGBA
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (width * 4 + 1)] = 0; // filter none
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  const idat = zlib.deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

// ---------- 像素绘制 ----------
const S = 288; // 尺寸

function newCanvas() {
  return Buffer.alloc(S * S * 4); // 全透明
}

function setPx(buf, x, y, r, g, b, a) {
  if (x < 0 || y < 0 || x >= S || y >= S) return;
  const i = (y * S + x) * 4;
  buf[i] = r;
  buf[i + 1] = g;
  buf[i + 2] = b;
  buf[i + 3] = a;
}

// 圆角矩形（区域内判断）
function inRoundRect(x, y, x0, y0, x1, y1, r) {
  if (x < x0 || y < y0 || x > x1 || y > y1) return false;
  const cx = Math.max(x0 + r, Math.min(x, x1 - r));
  const cy = Math.max(y0 + r, Math.min(y, y1 - r));
  const dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

function drawRoundRect(buf, x0, y0, x1, y1, r, color) {
  for (let y = 0; y < S; y++) {
    for (let x = 0; x < S; x++) {
      if (inRoundRect(x, y, x0, y0, x1, y1, r)) setPx(buf, x, y, color[0], color[1], color[2], color[3]);
    }
  }
}

// 线段（粗线用圆盘叠加）
function drawLine(buf, x0, y0, x1, y1, w, color) {
  const steps = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0)) * 2;
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    const cx = Math.round(x0 + (x1 - x0) * t);
    const cy = Math.round(y0 + (y1 - y0) * t);
    const rad = w / 2;
    for (let dy = -rad; dy <= rad; dy++) {
      for (let dx = -rad; dx <= rad; dx++) {
        if (dx * dx + dy * dy <= rad * rad) setPx(buf, cx + dx, cy + dy, color[0], color[1], color[2], color[3]);
      }
    }
  }
}

// 清空（透明）圆角矩形 —— 用于挖出屏幕
function clearRoundRect(buf, x0, y0, x1, y1, r) {
  for (let y = 0; y < S; y++) {
    for (let x = 0; x < S; x++) {
      if (inRoundRect(x, y, x0, y0, x1, y1, r)) setPx(buf, x, y, 0, 0, 0, 0);
    }
  }
}

const PINK = [0xfb, 0x72, 0x99, 255];
const WHITE = [255, 255, 255, 255];

// background.png：粉色圆角方块（radius 约 64）
const bg = newCanvas();
drawRoundRect(bg, 8, 8, S - 9, S - 9, 64, PINK);

// foreground.png：白色小电视
const fg = newCanvas();
// 机身
drawRoundRect(fg, 56, 88, 232, 214, 30, WHITE);
// 天线
drawLine(fg, 112, 92, 82, 40, 14, WHITE);
drawLine(fg, 176, 92, 206, 40, 14, WHITE);
// 屏幕挖空（透明，露出粉色底）
clearRoundRect(fg, 80, 110, 208, 192, 16);

// startIcon.png：合并后的完整图标
const icon = Buffer.from(bg);
// 叠加 fg（alpha 混合）
for (let i = 0; i < icon.length; i += 4) {
  const a = fg[i + 3] / 255;
  icon[i] = Math.round(fg[i] * a + icon[i] * (1 - a));
  icon[i + 1] = Math.round(fg[i + 1] * a + icon[i + 1] * (1 - a));
  icon[i + 2] = Math.round(fg[i + 2] * a + icon[i + 2] * (1 - a));
  icon[i + 3] = 255;
}

const root = path.join(__dirname, '..');
fs.writeFileSync(path.join(root, 'AppScope/resources/base/media/background.png'), encodePng(S, S, bg));
fs.writeFileSync(path.join(root, 'AppScope/resources/base/media/foreground.png'), encodePng(S, S, fg));
fs.writeFileSync(path.join(root, 'AppScope/resources/base/media/startIcon.png'), encodePng(S, S, icon));
fs.writeFileSync(path.join(root, 'entry/src/main/resources/base/media/background.png'), encodePng(S, S, bg));
fs.writeFileSync(path.join(root, 'entry/src/main/resources/base/media/foreground.png'), encodePng(S, S, fg));
fs.writeFileSync(path.join(root, 'entry/src/main/resources/base/media/startIcon.png'), encodePng(S, S, icon));
console.log('icons generated OK');
