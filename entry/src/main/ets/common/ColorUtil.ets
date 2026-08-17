/**
 * 颜色工具：hex/rgb/hsl 转换、亮度、混合、Material You 风格色调板
 * 用于"沉浸光感"动态取色主题
 */

export class RGB {
  r: number = 0;
  g: number = 0;
  b: number = 0;

  constructor(r: number, g: number, b: number) {
    this.r = Math.min(255, Math.max(0, Math.round(r)));
    this.g = Math.min(255, Math.max(0, Math.round(g)));
    this.b = Math.min(255, Math.max(0, Math.round(b)));
  }
}

export class HSL {
  h: number = 0;
  s: number = 0;
  l: number = 0;

  constructor(h: number, s: number, l: number) {
    this.h = ((h % 360) + 360) % 360;
    this.s = Math.min(1, Math.max(0, s));
    this.l = Math.min(1, Math.max(0, l));
  }
}

function hexToRgb(hex: string): RGB {
  let h: string = hex.replace('#', '').trim();
  if (h.length === 3) {
    h = h.charAt(0) + h.charAt(0) + h.charAt(1) + h.charAt(1) + h.charAt(2) + h.charAt(2);
  }
  if (h.length < 6) {
    return new RGB(0, 0, 0);
  }
  const r: number = parseInt(h.substring(0, 2), 16);
  const g: number = parseInt(h.substring(2, 4), 16);
  const b: number = parseInt(h.substring(4, 6), 16);
  return new RGB(isNaN(r) ? 0 : r, isNaN(g) ? 0 : g, isNaN(b) ? 0 : b);
}

export function rgbToHex(rgb: RGB): string {
  const to2 = (n: number): string => {
    const s: string = Math.min(255, Math.max(0, Math.round(n))).toString(16);
    return s.length === 1 ? '0' + s : s;
  };
  return '#' + to2(rgb.r) + to2(rgb.g) + to2(rgb.b);
}

function rgbToHsl(rgb: RGB): HSL {
  const r: number = rgb.r / 255;
  const g: number = rgb.g / 255;
  const b: number = rgb.b / 255;
  const max: number = Math.max(r, g, b);
  const min: number = Math.min(r, g, b);
  const l: number = (max + min) / 2;
  let h: number = 0;
  let s: number = 0;
  if (max !== min) {
    const d: number = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === r) {
      h = (g - b) / d + (g < b ? 6 : 0);
    } else if (max === g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    h /= 6;
  }
  return new HSL(h * 360, s, l);
}

function hslToRgb(hsl: HSL): RGB {
  const h: number = hsl.h / 360;
  const s: number = hsl.s;
  const l: number = hsl.l;
  if (s === 0) {
    const v: number = Math.round(l * 255);
    return new RGB(v, v, v);
  }
  const q: number = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p: number = 2 * l - q;
  const hue2rgb = (t: number): number => {
    let tt: number = t;
    if (tt < 0) {
      tt += 1;
    }
    if (tt > 1) {
      tt -= 1;
    }
    if (tt < 1 / 6) {
      return p + (q - p) * 6 * tt;
    }
    if (tt < 1 / 2) {
      return q;
    }
    if (tt < 2 / 3) {
      return p + (q - p) * (2 / 3 - tt) * 6;
    }
    return p;
  };
  return new RGB(hue2rgb(h + 1 / 3) * 255, hue2rgb(h) * 255, hue2rgb(h - 1 / 3) * 255);
}

/** 感知亮度 0-1（越大越亮） */
function luminance(hex: string): number {
  const rgb: RGB = hexToRgb(hex);
  return (0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b) / 255;
}

export function isDarkColor(hex: string): boolean {
  return luminance(hex) < 0.5;
}

/** 与白色混合（amount 0-1 为白色占比） */
function mixWithWhite(hex: string, amount: number): string {
  const rgb: RGB = hexToRgb(hex);
  return rgbToHex(new RGB(
    rgb.r + (255 - rgb.r) * amount,
    rgb.g + (255 - rgb.g) * amount,
    rgb.b + (255 - rgb.b) * amount,
  ));
}

/** 与黑色混合（amount 0-1 为黑色占比） */
function mixWithBlack(hex: string, amount: number): string {
  const rgb: RGB = hexToRgb(hex);
  return rgbToHex(new RGB(
    rgb.r * (1 - amount),
    rgb.g * (1 - amount),
    rgb.b * (1 - amount),
  ));
}

/** 调节饱和度 */
export function withSaturation(hex: string, sat: number): string {
  const hsl: HSL = rgbToHsl(hexToRgb(hex));
  hsl.s = sat;
  return rgbToHex(hslToRgb(hsl));
}

/**
 * 从种子色生成 Material You 风格色调板
 * @param seed 种子色（一般取封面主色）
 * @param dark 是否深色模式
 */
export function tonalPalette(seed: string, dark: boolean): Record<string, string> {
  const palette: Record<string, string> = {};
  const base: RGB = hexToRgb(seed);
  const maxC: number = Math.max(base.r, base.g, base.b);
  const minC: number = Math.min(base.r, base.g, base.b);
  const saturated: number = (maxC - minC) / 255;
  // 低饱和的种子色提升饱和度，保证主题色观感
  const vivid: string = saturated < 0.25 ? withSaturation(seed, 0.6) : seed;
  const lumi: number = luminance(seed);

  palette['primary'] = vivid;
  // 主色上的文字/图标恒为白（品牌主色均为中深色调，白字对比度足够）
  palette['onPrimary'] = '#FFFFFF';
  if (dark) {
    // 深色模式：主色提亮
    const p: string = lumi < 0.3 ? mixWithWhite(vivid, 0.2) : vivid;
    palette['primary'] = p;
    palette['surface'] = mixWithBlack(seed, 0.88);
    palette['surfaceAlt'] = mixWithBlack(seed, 0.8);
    palette['background'] = mixWithBlack(seed, 0.95);
    palette['onSurface'] = mixWithWhite(seed, 0.9);
    palette['onSurfaceSub'] = mixWithWhite(seed, 0.55);
    palette['line'] = mixWithWhite(seed, 0.12);
    palette['coverTint'] = mixWithBlack(seed, 0.75);
  } else {
    palette['surface'] = mixWithWhite(seed, 0.94);
    palette['surfaceAlt'] = mixWithWhite(seed, 0.86);
    palette['background'] = mixWithWhite(seed, 0.97);
    palette['onSurface'] = mixWithBlack(seed, 0.85);
    palette['onSurfaceSub'] = mixWithBlack(seed, 0.45);
    palette['line'] = mixWithBlack(seed, 0.12);
    palette['coverTint'] = mixWithWhite(seed, 0.82);
  }
  return palette;
}
