// 生成 B 站风格应用图标 PNG（粉色渐变底 + 白色小电视，4x 超采样抗锯齿）
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

// ---------- 像素画布（4x 超采样，出图时盒滤波降采样） ----------
const S = 288;      // 出图尺寸
const SS = 4;       // 超采样倍率
const W = S * SS;   // 内部画布

function newCanvas() {
  return Buffer.alloc(W * W * 4); // 全透明
}

function setPx(buf, x, y, color) {
  if (x < 0 || y < 0 || x >= W || y >= W) return;
  const i = (y * W + x) * 4;
  buf[i] = color[0];
  buf[i + 1] = color[1];
  buf[i + 2] = color[2];
  buf[i + 3] = color[3];
}

// 逻辑坐标（288 空间）→ 画布坐标
const sc = (v) => v * SS;

function inRoundRect(x, y, x0, y0, x1, y1, r) {
  if (x < x0 || y < y0 || x > x1 || y > y1) return false;
  const cx = Math.max(x0 + r, Math.min(x, x1 - r));
  const cy = Math.max(y0 + r, Math.min(y, y1 - r));
  const dx = x - cx, dy = y - cy;
  return dx * dx + dy * dy <= r * r;
}

function fillRoundRect(buf, x0, y0, x1, y1, r, color) {
  const X0 = sc(x0), Y0 = sc(y0), X1 = sc(x1), Y1 = sc(y1), R = sc(r);
  for (let y = Math.floor(Y0 - R); y <= Math.ceil(Y1 + R); y++) {
    for (let x = Math.floor(X0 - R); x <= Math.ceil(X1 + R); x++) {
      if (inRoundRect(x, y, X0, Y0, X1, Y1, R)) setPx(buf, x, y, color);
    }
  }
}

function fillCircle(buf, cx, cy, r, color) {
  const CX = sc(cx), CY = sc(cy), R = sc(r);
  for (let y = Math.floor(CY - R); y <= Math.ceil(CY + R); y++) {
    for (let x = Math.floor(CX - R); x <= Math.ceil(CX + R); x++) {
      const dx = x - CX, dy = y - CY;
      if (dx * dx + dy * dy <= R * R) setPx(buf, x, y, color);
    }
  }
}

// 圆头粗线
function drawLine(buf, x0, y0, x1, y1, w, color) {
  const X0 = sc(x0), Y0 = sc(y0), X1 = sc(x1), Y1 = sc(y1), R = sc(w) / 2;
  const steps = Math.max(Math.abs(X1 - X0), Math.abs(Y1 - Y0)) * 2;
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    fillCircle(buf, (X0 + (X1 - X0) * t) / SS, (Y0 + (Y1 - Y0) * t) / SS, R / SS, color);
  }
}

// 圆环弧（angle 单位度，y 轴向下；180..360 为上半个 ∩）
function drawArc(buf, cx, cy, r, w, a0, a1, color) {
  const CX = sc(cx), CY = sc(cy), R = sc(r), HW = sc(w) / 2;
  for (let y = Math.floor(CY - R - HW); y <= Math.ceil(CY + R + HW); y++) {
    for (let x = Math.floor(CX - R - HW); x <= Math.ceil(CX + R + HW); x++) {
      const dx = x - CX, dy = y - CY;
      const dist = Math.sqrt(dx * dx + dy * dy);
      if (Math.abs(dist - R) > HW) continue;
      let ang = Math.atan2(dy, dx) * 180 / Math.PI;
      if (ang < 0) ang += 360;
      if (ang >= a0 && ang <= a1) setPx(buf, x, y, color);
    }
  }
}

// 竖直渐变底（全幅方形，系统自行裁圆角）
function fillGradient(buf, top, bottom) {
  for (let y = 0; y < W; y++) {
    const t = y / (W - 1);
    const r = Math.round(top[0] + (bottom[0] - top[0]) * t);
    const g = Math.round(top[1] + (bottom[1] - top[1]) * t);
    const b = Math.round(top[2] + (bottom[2] - top[2]) * t);
    for (let x = 0; x < W; x++) setPx(buf, x, y, [r, g, b, 255]);
  }
}

// 盒滤波降采样到 S×S
function downsample(buf) {
  const out = Buffer.alloc(S * S * 4);
  for (let y = 0; y < S; y++) {
    for (let x = 0; x < S; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let dy = 0; dy < SS; dy++) {
        for (let dx = 0; dx < SS; dx++) {
          const i = ((y * SS + dy) * W + (x * SS + dx)) * 4;
          // 预乘 alpha 再平均，避免边缘泛白/泛黑
          const pa = buf[i + 3] / 255;
          r += buf[i] * pa;
          g += buf[i + 1] * pa;
          b += buf[i + 2] * pa;
          a += buf[i + 3];
        }
      }
      const n = SS * SS;
      const o = (y * S + x) * 4;
      const alpha = a / n;
      const k = alpha > 0 ? 255 / alpha : 0;
      out[o] = Math.round(r / n * k);
      out[o + 1] = Math.round(g / n * k);
      out[o + 2] = Math.round(b / n * k);
      out[o + 3] = Math.round(alpha);
    }
  }
  return out;
}

function composite(bg, fg) {
  const out = Buffer.from(bg);
  for (let i = 0; i < out.length; i += 4) {
    const a = fg[i + 3] / 255;
    out[i] = Math.round(fg[i] * a + out[i] * (1 - a));
    out[i + 1] = Math.round(fg[i + 1] * a + out[i + 1] * (1 - a));
    out[i + 2] = Math.round(fg[i + 2] * a + out[i + 2] * (1 - a));
    out[i + 3] = Math.round(fg[i + 3] + out[i + 3] * (1 - a));
  }
  return out;
}

// ---------- 绘制 ----------
const WHITE = [255, 255, 255, 255];
const BG_TOP = [0xff, 0x92, 0xb0];     // #FF92B0
const BG_BOTTOM = [0xf9, 0x5e, 0x8d];  // #F95E8D
const SCREEN = [0xf7, 0x51, 0x84];     // 屏幕用更深一度的粉，压住渐变底

// 背景：全幅竖直渐变
const bg = newCanvas();
fillGradient(bg, BG_TOP, BG_BOTTOM);

// 前景：透明底 + 白色小电视
const fg = newCanvas();
// 天线（先画，压在机身下）
drawLine(fg, 116, 100, 88, 52, 12, WHITE);
drawLine(fg, 172, 100, 200, 52, 12, WHITE);
// 机身
fillRoundRect(fg, 50, 92, 238, 220, 36, WHITE);
// 屏幕（粉色挖出）
fillRoundRect(fg, 72, 112, 216, 200, 24, SCREEN);
// 眼睛：两条上弯弧
drawArc(fg, 110, 152, 13, 8, 195, 345, WHITE);
drawArc(fg, 178, 152, 13, 8, 195, 345, WHITE);
// 微笑
drawArc(fg, 144, 162, 11, 7, 25, 155, WHITE);

// startIcon：渐变底裁圆角 + 叠加前景，供启动窗口直接使用
const iconBg = newCanvas();
fillGradient(iconBg, BG_TOP, BG_BOTTOM);
const iconMasked = newCanvas();
for (let y = 0; y < W; y++) {
  for (let x = 0; x < W; x++) {
    if (inRoundRect(x, y, 0, 0, W - 1, W - 1, sc(60))) {
      const i = (y * W + x) * 4;
      iconMasked[i] = iconBg[i];
      iconMasked[i + 1] = iconBg[i + 1];
      iconMasked[i + 2] = iconBg[i + 2];
      iconMasked[i + 3] = 255;
    }
  }
}
const icon = composite(iconMasked, fg);

const files = [
  // AppScope 分层图标 + 启动图标
  ['AppScope/resources/base/media/background.png', bg],
  ['AppScope/resources/base/media/foreground.png', fg],
  ['AppScope/resources/base/media/startIcon.png', icon],
  // entry 模块在用的分层图标与启动图标
  ['entry/src/main/resources/base/media/background.png', bg],
  ['entry/src/main/resources/base/media/app_icon_20260814.png', fg],
  ['entry/src/main/resources/base/media/app_start_icon_20260814.png', icon],
];
const root = path.join(__dirname, '..');
for (const [rel, buf] of files) {
  fs.writeFileSync(path.join(root, rel), encodePng(S, S, downsample(buf)));
}
console.log('icons generated OK');
