// 从哔哩哔哩网页使用的 vanfont 中同步 UI 图标到 HarmonyOS media 资源。
// 来源文件由 docs/ref/bilibili-assets/vanfont_iconfont.svg 固化，运行：
// node tool/sync_official_vanfont_icons.js

const fs = require('fs');
const path = require('path');

const projectRoot = path.resolve(__dirname, '..');
const fontPath = path.join(projectRoot, 'docs/ref/bilibili-assets/vanfont_iconfont.svg');
const mediaDir = path.join(projectRoot, 'entry/src/main/resources/base/media');

// 只同步能在官方字库中找到明确语义对应的图标。播放器的暂停、全屏和
// 弹幕开关在这套字库中不存在，继续保留现有资源，避免错误套用相似图形。
const iconMap = {
  ic_back: 'general_back_s',
  ic_arrow_right: 'general_enter_s',
  ic_close: 'guanbi',
  ic_coin: 'videodetails_throw',
  ic_comment: 'pinglun',
  ic_delete: 'lajitong',
  ic_dislike: 'cai',
  ic_emoji: 'biaoqing',
  ic_favorite: 'rate-2',
  ic_favorite_fill: 'videodetails_collec',
  ic_keyboard: 'jianpan',
  ic_like: 'ding',
  ic_like_fill: 'videodetails_like',
  ic_message: 'videodetails_messag',
  ic_more: 'general_moreactions',
  ic_play: 'videodetails_play',
  ic_video_replay: 'info_playnumber',
  ic_search: 'general_search',
  ic_share: 'videodetails_share',
  bilix_icon_like: 'videodetails_like',
  bilix_icon_coin: 'videodetails_throw',
  bilix_icon_fav: 'videodetails_collec',
  bilix_icon_share: 'videodetails_share'
};

const fontSource = fs.readFileSync(fontPath, 'utf8');
const glyphs = new Map();
const glyphPattern = /<glyph\s+glyph-name="([^"]+)"[^>]*\sd="([^"]+)"[^>]*horiz-adv-x="([^"]+)"/g;

for (const match of fontSource.matchAll(glyphPattern)) {
  glyphs.set(match[1], { pathData: match[2], advance: Number(match[3]) });
}

for (const [resourceName, glyphName] of Object.entries(iconMap)) {
  const glyph = glyphs.get(glyphName);
  if (!glyph) {
    throw new Error(`vanfont 中不存在字形：${glyphName}`);
  }

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${glyph.advance} 1024"><path transform="translate(0,896) scale(1,-1)" d="${glyph.pathData}"/></svg>`;
  fs.writeFileSync(path.join(mediaDir, `${resourceName}.svg`), svg);
  console.log(`${resourceName}.svg <- ${glyphName}`);
}
