/**
 * 评论/动态共用的小型展示工具：评论元信息文本（时间 + IP 属地）等。
 */
import { ReplyItem } from '../model/Models';
import { formatRelativeTime } from './Utils';

/** 剥离接口返回的 "IP属地：" 前缀（中英文冒号都可能出现）。 */
export function stripIpLabel(location: string): string {
  return location.replace('IP属地：', '').replace('IP属地:', '').trim();
}

/** 评论元信息：相对时间 + IP 属地（"5分钟前  IP属地：上海"）；属地缺失时只显示时间。 */
export function formatReplyMeta(item: ReplyItem): string {
  const location: string = stripIpLabel(item.location);
  return formatRelativeTime(item.ctime) + (location.length > 0 ? '  IP属地：' + location : '');
}