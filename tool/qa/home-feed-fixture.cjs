const { createArktsLoader } = require('./arkts-module.cjs');

function homeFeedFixture(hooks = {}) {
  const snapshots = [], calls = [];
  const account = {version:0};
  const load = createArktsLoader({mocks:{
    'api/FeedApi': {FeedApi: {
      getRecommend: reset=>{calls.push(['recommend',reset]);return hooks.recommend ? hooks.recommend(reset) : Promise.resolve([{aid:1,bvid:'BV1'}]);},
      getHot: page=>{calls.push(['hot',page]);return hooks.hot ? hooks.hot(page) : Promise.resolve([]);},
      resetRecommendSession:()=>calls.push(['reset']),
    }},
    'api/LiveApi': {LiveApi: {getLiveRooms:page=>{calls.push(['live',page]);return hooks.live ? hooks.live(page) : Promise.resolve([]);}}},
    'api/UserApi': {UserApi:{loadFeedFollowStates:async()=>{}}},
    'services/auth/UserStore': {UserStore:{ensureLoaded:()=>hooks.login ? hooks.login() : Promise.resolve()}},
    'services/auth/AuthSession': {AuthSession:account},
    'common/LocalVideoFilter': {LocalVideoFilter:{filterVideos:items=>hooks.filter ? hooks.filter(items) : items,
      hide:async aid=>calls.push(['hide',aid])}},
    '@kit.ArkTS':{collections:{Array},util:{},taskpool:{}},
    '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){},debug(){}}},
    '@kit.CryptoArchitectureKit':{cryptoFramework:{}},
  }});
  const {HomeFeedController}=load('components/home/HomeFeedController');
  const ctl=new HomeFeedController(state=>snapshots.push(state));
  return {ctl,account,snapshots,calls,load,state:index=>snapshots.at(-1).channels[index]};
}
module.exports={homeFeedFixture};
