import { VideoChapter } from '../../api/BiliApi';

export function chapterEnd(chapters: Array<VideoChapter>, index: number, duration: number): number {
  const chapter: VideoChapter = chapters[index];
  if (chapter.to > chapter.from) return Math.min(duration, chapter.to);
  let end: number = duration;
  for (let i: number = 0; i < chapters.length; i++) {
    if (chapters[i].from > chapter.from) end = Math.min(end, chapters[i].from);
  }
  return end;
}

export function chapterIndexAt(chapters: Array<VideoChapter>, seconds: number, duration: number): number {
  let selected: number = -1;
  for (let i: number = 0; i < chapters.length; i++) {
    const end: number = chapterEnd(chapters, i, duration);
    if (seconds >= chapters[i].from && (seconds < end || (seconds === duration && end === duration)) &&
      (selected < 0 || chapters[i].from >= chapters[selected].from)) selected = i;
  }
  return selected;
}

export function chapterTitleAt(chapters: Array<VideoChapter>, seconds: number, duration: number): string {
  const index: number = chapterIndexAt(chapters, seconds, duration);
  return index >= 0 ? chapters[index].title : '';
}
