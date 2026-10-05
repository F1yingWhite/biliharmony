/** Public comment/share links, matched by exact host and resource path. */
export class BiliLinkTarget {
  kind: string = '';
  bvid: string = '';
  aid: number = 0;
  epId: number = 0;
  seasonId: number = 0;
  mid: number = 0;
  dynId: string = '';
  roomId: number = 0;
  articleId: number = 0;
  page: number = 1;
  seconds: number = 0;
  hasSeek: boolean = false;
}

export function normalizeBiliWebUrl(value: string): string {
  let link: string = value.trim();
  if (link.startsWith('//')) link = 'https:' + link;
  else if (/^(?:(?:(?:www|m|space|live|t)\.)?bilibili\.com|(?:www\.)?b23\.tv)\//i.test(link)) link = 'https://' + link;
  return /^https?:\/\/[^\s\x00-\x1F\\<>"']+$/i.test(link) ? link : '';
}

function positive(value: string): number {
  if (!/^[1-9][0-9]*$/.test(value)) return 0;
  const result: number = Number(value);
  return Number.isSafeInteger(result) ? result : 0;
}

function queryValue(link: string, key: string): string {
  const query: RegExpExecArray | null = /[?#]([^#]*)/.exec(link);
  if (query === null) return '';
  for (const pair of query[1].split('&')) {
    const equal: number = pair.indexOf('=');
    if (equal < 0) continue;
    try {
      if (decodeURIComponent(pair.substring(0, equal)) === key) return decodeURIComponent(pair.substring(equal + 1));
    } catch (e) { }
  }
  return '';
}

export function isBiliShortLink(value: string): boolean {
  return /^https?:\/\/(?:www\.)?b23\.tv(?:\/[A-Za-z0-9]+)\/?(?:[?#].*)?$/i.test(normalizeBiliWebUrl(value));
}

export function parseBiliLink(value: string): BiliLinkTarget | null {
  const link: string = normalizeBiliWebUrl(value);
  const match: RegExpExecArray | null = /^https?:\/\/([A-Za-z0-9.-]+)(?::(?:80|443))?(\/[^?#]*)?(?:[?#].*)?$/.exec(link);
  if (match === null) return null;
  const host: string = match[1].toLowerCase();
  const path: string = match[2] ?? '/';
  const target: BiliLinkTarget = new BiliLinkTarget();
  let resource: RegExpExecArray | null = null;
  if (host === 'www.bilibili.com' || host === 'm.bilibili.com' || host === 'bilibili.com') {
    resource = /^\/video\/(BV[0-9A-Za-z]{10}|av[1-9][0-9]*)\/?$/i.exec(path);
    if (resource !== null) {
      target.kind = 'video';
      if (/^bv/i.test(resource[1])) target.bvid = 'BV' + resource[1].substring(2);
      else target.aid = positive(resource[1].substring(2));
      if (target.bvid.length === 0 && target.aid <= 0) return null;
      target.page = positive(queryValue(link, 'p')) || 1;
      const time: string = queryValue(link, 't');
      if (/^[0-9]+(?:\.[0-9]+)?$/.test(time)) {
        const seconds: number = Number(time);
        if (Number.isFinite(seconds) && seconds >= 0 && seconds <= 2147483647) {
          target.seconds = seconds;
          target.hasSeek = true;
        }
      }
      return target;
    }
    resource = /^\/bangumi\/play\/(ep|ss)([1-9][0-9]*)\/?$/i.exec(path);
    if (resource !== null) {
      const id: number = positive(resource[2]);
      if (id <= 0) return null;
      target.kind = 'bangumi';
      if (resource[1].toLowerCase() === 'ep') target.epId = id;
      else target.seasonId = id;
      return target;
    }
    resource = /^\/(?:opus|dynamic)\/([1-9][0-9]{0,19})\/?$/i.exec(path);
    if (resource !== null) { target.kind = 'dynamic'; target.dynId = resource[1]; return target; }
    resource = /^\/read\/cv([1-9][0-9]*)\/?$/i.exec(path);
    const article: number = resource !== null ? positive(resource[1]) :
      (/^\/read\/mobile\/?$/i.test(path) ? positive(queryValue(link, 'id')) : 0);
    if (article > 0) { target.kind = 'article'; target.articleId = article; return target; }
  } else if (host === 'space.bilibili.com') {
    resource = /^\/([1-9][0-9]*)(?:\/(?:video|dynamic|opus))?\/?$/i.exec(path);
    if (resource !== null) { target.kind = 'space'; target.mid = positive(resource[1]); return target.mid > 0 ? target : null; }
  } else if (host === 't.bilibili.com') {
    resource = /^\/([1-9][0-9]{0,19})\/?$/.exec(path);
    if (resource !== null) { target.kind = 'dynamic'; target.dynId = resource[1]; return target; }
  } else if (host === 'live.bilibili.com') {
    resource = /^\/(?:blanc\/)?([1-9][0-9]*)\/?$/i.exec(path);
    if (resource !== null) { target.kind = 'live'; target.roomId = positive(resource[1]); return target.roomId > 0 ? target : null; }
  }
  return null;
}
