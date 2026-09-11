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

/**
 * QA 专用：全屏联动探针页。
 *
 * YouTube 播放层可能被出口 IP 风控挡住（「请登录，以便我们确认你不是聊天机器人」），
 * 此时官方控件里的全屏按钮点不到，`onFullScreenEnter/Exit`、横竖屏切换和返回键联动
 * 就失去了验证路径。这个页面只做一件事：放一个按钮调用标准 Fullscreen API，
 * 用来验证应用侧的这段管线本身。**只在启动参数 ytPlayerProbe 打开时加载**，
 * 默认路径永远走真实播放器；它不解析、不请求任何远端内容。
 */
export function youtubeFullscreenProbeHtml(): string {
  return `<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;height:100%;background:#101010;color:#EEE;font:14px sans-serif}
#probe{position:absolute;left:0;top:0;width:100%;height:100%;border:0;background:#1B5E20;color:#FFF;font-size:16px}
</style></head><body><button id="probe" onclick="document.documentElement.requestFullscreen()">
全屏探针</button></body></html>`;
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
