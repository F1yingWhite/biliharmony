# BiliHaromny（哔哩哔哩 · 鸿蒙原生版）

基于开源 Flutter 项目 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 移植的**鸿蒙原生（HarmonyOS NEXT）哔哩哔哩第三方客户端**。

- 语言/UI：ArkTS + ArkUI（声明式）
- 目标 SDK：**HarmonyOS API 26**（HarmonyOS 7.0 / 26.0.0，compatibleSdkVersion / targetSdkVersion = 26.0.0）
- 构建：hvigor + ohpm（零第三方依赖，仅使用系统 Kit）
- 工程根目录即 DevEco Studio 工程，可直接 Open 打开

> 仅供学习交流使用。所有接口均来自 B 站官方公开 API，不提供任何破解内容。

---

## 功能

| 模块 | 说明 |
| --- | --- |
| 首页 | 推荐（app 端 /x/v2/feed/index）+ 热门（/x/web-interface/popular），双列瀑布流、下拉刷新、触底加载 |
| 播放器 | 系统 AVPlayer + XComponent 渲染，进度/暂停、横屏全屏，**Canvas 弹幕引擎**（滚动/顶部/底部弹幕，颜色还原） |
| 视频详情 | 简介（数据/UP主/分P）、评论（游客 /x/v2/reply/main 分页）、相关推荐 |
| 搜索 | 热搜榜、输入联想、综合搜索（WBI 签名 /x/web-interface/wbi/search/all/v2） |
| 动态 | 关注动态 feed（登录后） |
| 登录 | TV 扫码登录（QRCode 组件渲染 + 轮询 + Cookie 保存） |
| 我的 | 用户信息、硬币/关注/粉丝/获赞、设置 |
| 网络层 | 移植 PiliPlus 的 **WBI 签名**（mixinKey 表 + nav 获取 img/sub key）与 **App 签名**（appkey/ts/md5），@ohos.net.http 封装 + Cookie 罐 |

## 沉浸光感效果（重点）

1. **封面取色动态主题**：进入视频详情时下载封面 → PixelMap 采样 → 4bit 量化分桶提取**主色/鲜艳色** → 生成 Material You 风格色调板，全局强调色随封面联动（顶部渐变、按钮、标签、Tab 图标实时变色）。
2. **玻璃拟态（HarmonyOS 7 光感）**：顶部玻璃头栏（backdropBlur + saturate 提纯）悬浮于内容之上，首页/动态/我的列表滚动时画面从毛玻璃下方透出；首页「推荐/热门」切换条同样为玻璃悬浮条；搜索胶囊/头像/播放器按钮均为玻璃材质。
3. **光效辉光**：主题色径向光晕（Logo 光晕、底部导航激活项辉光、视频详情 Tab 发光指示条、播放区封面取色氛围光），柔化阴影的卡片投影，按压反馈动画。
4. **沉浸式布局**：状态栏/导航栏与页面顶底同色一体化（首页状态栏随主题色联动），播放页横屏自动隐藏系统栏。
5. **明暗主题**：深色/浅色模式随主题色生成对应色调板（背景、卡片、文字、分割线全部从种子色派生）。卡片质感参考 BewlyCat 插件风格。

## 目录结构

    entry/src/main/ets/
    ├── entryability/EntryAbility.ets   # 入口：沉浸式系统栏配色
    ├── pages/                          # 路由页
    │   ├── Index.ets                   # 主框架（玻璃头栏 + 光晕导航）
    │   ├── VideoDetail.ets             # 视频详情（取色/播放器/评论/相关）
    │   ├── Search.ets                  # 搜索
    │   └── Login.ets                   # 扫码登录
    ├── views/                          # 主 Tab 视图
    │   ├── HomeView.ets                # 推荐 + 热门
    │   ├── DynamicView.ets             # 动态
    │   └── MineView.ets                # 我的
    ├── components/
    │   ├── PlayerView.ets              # AVPlayer + 弹幕引擎
    │   ├── VideoCard.ets               # 视频卡片（BewlyCat 风格）
    │   └── LoadingView.ets             # 加载/空/错误状态
    ├── api/BiliApi.ets                 # B 站接口层
    ├── model/Models.ets                # 数据模型（字段映射自 PiliPlus）
    ├── common/
    │   ├── WbiSign.ets / AppSign.ets   # WBI / App 签名（MD5 基于 cryptoFramework）
    │   ├── HttpClient.ets              # http 封装 + Cookie 罐
    │   ├── ImageColor.ets              # 封面取色（量化分桶）
    │   ├── ColorUtil.ets               # 色调板 / HSL / 亮度
    │   ├── AppTheme.ets                # 动态主题状态
    │   └── Immersive.ets               # 沉浸式窗口工具（系统栏配色/全屏）
    └── resources/                      # 字符串 / 颜色 / 图标

## 构建

### DevEco Studio

1. 打开工程根目录（本目录），SDK 需含 **HarmonyOS API 26**（工具 → SDK Manager）。
2. File → Sync 后直接 Run（自动签名），或 Build → Build Hap(s)。

### 命令行（macOS，已配置 DevEco Studio）

    export HOME="$PWD/.home"                                  # 将 hvigor/npm 缓存收进工程
    export NODE_HOME="/Applications/DevEco-Studio.app/Contents/tools/node"
    export DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk"
    export HOS_SDK_HOME="$DEVECO_SDK_HOME"
    export JAVA_HOME="/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home"
    export PATH="$NODE_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/ohpm/bin:/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin:$JAVA_HOME/bin:$PATH"
    export npm_config_cache="$HOME/.npm"; export npm_config_prefix="$HOME/.npm-global"

    ohpm install --all
    hvigorw assembleHap --mode module -p product=default
    # 产物: entry/build/default/outputs/default/entry-default-unsigned.hap

> 首次构建需要网络（hvigor 会安装 pnpm）。签名请用 DevEco Studio 的自动签名；命令行产物为未签名 HAP。

## 移植对照（PiliPlus → BiliHaromny）

| PiliPlus (Flutter) | BiliHaromny (ArkTS) |
| --- | --- |
| lib/utils/wbi_sign.dart | common/WbiSign.ets |
| lib/utils/app_sign.dart | common/AppSign.ets |
| lib/http/init.dart + dio | common/HttpClient.ets（@ohos.net.http） |
| lib/http/video.dart rcmdVideoListApp | BiliApi.getRecommendApp |
| lib/http/video.dart hotVideoList | BiliApi.getHot |
| lib/http/video.dart videoUrl（WBI playurl） | BiliApi.getPlayUrl |
| lib/http/reply.dart replyList | BiliApi.getReplies |
| lib/http/search.dart | BiliApi.search / searchSuggest / getHotSearch |
| lib/http/login.dart TV 扫码 | BiliApi.getTVCode / pollTVCode |
| lib/utils/theme_utils.dart（Material You） | common/ColorUtil.ets + AppTheme.ets |
| mpv/media_kit 播放 | 系统 AVPlayer + 自研 Canvas 弹幕引擎 |
| lib/models/* | model/Models.ets |

原始 PiliPlus 工程保留在 PiliPlus/ 目录作为对照参考。

## 待完善（Roadmap）

- [ ] 点赞/投币/收藏三连、关注（需登录 + CSRF）
- [ ] 弹幕 protobuf 接口（x/v1/dm/list.so）替代 XML 接口
- [ ] DASH（fnval=16）音视频分离流与画质切换
- [ ] 稍后再看 / 历史记录 / 私信 / 直播
- [ ] 设置持久化（Preferences）
