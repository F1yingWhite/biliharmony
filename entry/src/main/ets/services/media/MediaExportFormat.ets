import { SubtitleCue, VideoQualityOption } from '../../model/Models';
import { DanmakuItem } from '../../model/video/VideoAuxiliaryModels';

/** 文件内容和名称转换不依赖文件选择器、播放器状态或网络。 */
export class MediaExportFormat {
  static safeName(value: string): string {
    const clean: string = value.replace(/[\\/:*?"'`<>|{}\[\]\x00-\x1F]/g, '_').trim().replace(/[. ]+$/g, '');
    let name: string = clean.length > 0 ? clean : 'BiliHarmony视频';
    if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(name)) name = '_' + name;
    name = name.substring(0, 96);
    const last: number = name.charCodeAt(name.length - 1);
    return last >= 0xD800 && last <= 0xDBFF ? name.substring(0, name.length - 1) : name;
  }

  static title(title: string, part: string): string {
    return part.trim().length > 0 && part.trim() !== title.trim() ? title + ' - ' + part.trim() : title;
  }

  static identity(aid: number, bvid: string): string {
    return bvid.length > 0 ? bvid : 'av' + String(aid);
  }

  static qualities(options: Array<VideoQualityOption>): Array<VideoQualityOption> {
    const seen: Set<number> = new Set<number>();
    return options.filter((option: VideoQualityOption): boolean => {
      if (!option.available || option.qn <= 0 || option.qn > 80 || seen.has(option.qn)) return false;
      seen.add(option.qn);
      return true;
    });
  }

  static qualityValue(options: Array<VideoQualityOption>, selected: number, active: number): number {
    const available: Array<VideoQualityOption> = MediaExportFormat.qualities(options);
    if (available.some((option: VideoQualityOption) => option.qn === selected)) return selected;
    if (available.some((option: VideoQualityOption) => option.qn === active)) return active;
    return available.length > 0 ? available[0].qn : 64;
  }

  static qualityText(options: Array<VideoQualityOption>, quality: number): string {
    const option: VideoQualityOption | undefined = options.find((item: VideoQualityOption) => item.qn === quality);
    return option !== undefined ? option.label : (quality === 80 ? '1080P' : (quality === 64 ? '720P' : String(quality)));
  }

  static srtTime(seconds: number): string {
    const total: number = Number.isFinite(seconds) ? Math.max(0, Math.round(seconds * 1000)) : 0;
    const whole: number = Math.floor(total / 1000);
    return String(Math.floor(whole / 3600)).padStart(2, '0') + ':' +
      String(Math.floor((whole % 3600) / 60)).padStart(2, '0') + ':' +
      String(whole % 60).padStart(2, '0') + ',' + String(total % 1000).padStart(3, '0');
  }

  static subtitle(cues: Array<SubtitleCue>): string {
    return cues.map((cue: SubtitleCue, index: number): string => String(index + 1) + '\n' +
      MediaExportFormat.srtTime(cue.from) + ' --> ' + MediaExportFormat.srtTime(cue.to) + '\n' + cue.content + '\n\n').join('');
  }

  static xmlEscape(value: string): string {
    return value.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '').replace(/&/g, '&amp;')
      .replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
  }

  static danmaku(cid: number, items: Array<DanmakuItem>): string {
    const lines: Array<string> = ['<?xml version="1.0" encoding="UTF-8"?><i><chatserver>chat.bilibili.com' +
      '</chatserver><chatid>' + cid + '</chatid><maxlimit>1500</maxlimit><source>k-v</source>'];
    items.forEach((item: DanmakuItem): void => {
      const attributes: string = item.time.toFixed(2) + ',' + item.mode + ',' + item.fontsize + ',' + item.color +
        ',0,0,0,' + (item.idStr.length > 0 ? item.idStr : String(item.id));
      lines.push('<d p="' + MediaExportFormat.xmlEscape(attributes) + '">' + MediaExportFormat.xmlEscape(item.text) + '</d>');
    });
    lines.push('</i>');
    return lines.join('');
  }

  static danmakuSegments(duration: number): number {
    // 未知时长只能导出有界窗口；调用方必须在结果提示中注明范围。
    return Number.isFinite(duration) && duration > 0 ? Math.max(1, Math.ceil(duration / 360)) : 12;
  }

  static coverExtension(url: string): string {
    const clean: string = url.split('?')[0].split('#')[0].toLowerCase();
    return clean.endsWith('.png') ? '.png' : (clean.endsWith('.webp') ? '.webp' : '.jpg');
  }
}
