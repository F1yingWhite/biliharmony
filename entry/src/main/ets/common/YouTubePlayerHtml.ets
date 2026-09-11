import { YouTubeApi } from '../api/YouTubeApi';

export const YOUTUBE_PLAYER_ORIGIN: string = 'https://com.piliplus.harmony';

export function youtubePlayerHtml(id: string): string {
  if (!YouTubeApi.validId(id)) return '';
  return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="strict-origin-when-cross-origin"><style>
html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style></head><body>
<div id="player"></div><script>
var player; function onYouTubeIframeAPIReady(){player=new YT.Player('player',{
videoId:'${id}',width:'100%',height:'100%',playerVars:{playsinline:1,origin:'${YOUTUBE_PLAYER_ORIGIN}',hl:'zh-CN'},
events:{onReady:function(){document.title='YT_READY';},
onStateChange:function(e){document.title='YT_STATE_'+e.data;},
onError:function(e){document.title='YT_ERROR_'+e.data;}}});}
function pauseVideo(){if(player&&player.pauseVideo)player.pauseVideo();}
document.addEventListener('visibilitychange',function(){if(document.hidden)pauseVideo();});
</script><script src="https://www.youtube.com/iframe_api" onerror="document.title='YT_NETWORK_ERROR'"></script>
</body></html>`;
}

export function youtubePlaybackError(title: string): string {
  switch (title) {
    case 'YT_ERROR_2': return '视频链接无效';
    case 'YT_ERROR_5': return '当前设备暂时无法播放此视频';
    case 'YT_ERROR_100': return '视频已删除、设为私密或不可用';
    case 'YT_ERROR_101':
    case 'YT_ERROR_150': return '作者未允许嵌入播放，可在 YouTube 打开';
    case 'YT_ERROR_153': return 'YouTube 未通过播放器验证，可重试或在 YouTube 打开';
    case 'YT_NETWORK_ERROR': return '播放器连接失败，请确认当前网络能访问 YouTube';
    default: return title.startsWith('YT_ERROR_') ? 'YouTube 暂时无法播放此视频' : '';
  }
}
