# ArkUI 易错清单（BiliHaromny 实战总结）

> 本文记录本工程真实踩过的坑。每条含：症状 → 根因 → 正确写法 → 案例文件。
> 新页面/新组件开发前请过一遍；Code Review 时按此清单检查。

---

## 1. @Builder 按值传参 = 静态快照，UI 永不刷新 ★最高发

**症状**：滑条拖动后数值不变化、按钮点击"没反应"、页面卡在加载态转圈。

**根因**：`@Builder` 的参数按值传递时，框架只在首次调用时取一次快照；之后状态变化**不会**重新执行该 Builder。状态明明已经改了（业务逻辑生效），但界面永远停留在第一次渲染的样子。

```ts
// ❌ 错误：value 是按值快照，this.dmOpacity 变了也不刷新
this.DmSliderRow('透明度', this.dmOpacity, 0.2, 1, cb)

// ✅ 正确：闭包让状态在 Builder 体内被读取，刷新订阅才会挂上
this.DmSliderRow('透明度', () => this.dmOpacity, 0.2, 1, cb)
```

**规则**：Builder 里用到的可变状态，必须在 **Builder 体内**读取（直接 `this.xxx` 或闭包 `() => this.xxx`），严禁按值传参。只读一次的静态参数（标题、图标）可以按值传。

**案例**：`components/PlayerSettingsPanel.ets`（弹幕滑条/屏蔽 chips）、`pages/RankPage.ets`（排行榜卡加载态）。两处代码内均有注释。

## 2. 自定义组件字段忘加装饰器，父组件更新不同步

**症状**：父组件状态变了，子组件还显示创建时的内容（如清空列表后重新加载，一直停在"加载中"）。

**根因**：`@Component` 里未加 `@Prop`/`@State` 的普通字段只在创建时初始化一次，父组件后续传新值不会同步。

```ts
// ❌ 错误：父组件 loading 变化后 LoadingView 不更新
loading: boolean = true;

// ✅ 正确
@Prop loading: boolean = true;
```

**规则**：组件所有会被外部传入且可能变化的字段，必须加 `@Prop`（或 `@Link`）。回调函数字段可以不加。

**案例**：`components/LoadingView.ets`（稍后再看清空后卡加载态）。

## 3. @Prop 传对象：深拷贝快照 + LazyForEach 同键不重渲染，乐观更新"没反应" ★最难缠

**症状**：点赞/点踩接口明明成功（code=0），UI 却毫无变化，用户以为功能坏了。

**根因（两重叠加，缺一不可）**：
1. `@Prop item` 拿到的是**深拷贝快照**：在事件回调里 `item.liked = true` 改的是卡片私有的副本，数据源里的"真身"根本没变；
2. 即使把真身改了并克隆换引用，**LazyForEach 以键判等**：键（如 `String(item.rpid)`）没变，框架认为"还是那条数据"，跳过重渲染。

**正确写法**（本工程 `mutateReplyItem` 模式）：
- 事件回调里**不许**改传入的 item，先按 id 找到数据源里的真身再改；
- 克隆真身换引用替换回数据源（`BasicDataSource.updateItem` / @State 数组 `slice()` 重赋值）；
- 模型加本地修订号 `rev`，克隆时 +1，**列表键必须包含 rev**：`String(item.rpid) + '_' + String(item.rev)`。

**案例**：`pages/VideoDetail.ets` / `DynamicDetail.ets` / `BangumiDetail.ets` 的 `mutateReplyItem`、`model/Models.ets` ReplyItem.clone()、`common/BasicDataSource.ets` updateItem()。

## 4. 凭记忆写接口端点 → 404

**症状**：取消收藏报 404。

**根因**：`/x/v3/fav/resource/del` 这个端点根本不存在（凭直觉命名）；PiliPlus 实际用的是 `/x/v3/fav/resource/batch-deal`。

**规则**：接新接口一律以 PiliPlus `lib/http/api.dart` 的端点常量为准，不要按 RESTful 直觉造路径；写完先对照一遍。

**案例**：`api/BiliApi.ets` delFavoriteResources 改走 batch-deal。

## 5. sharedTransition 在 Navigation 下静默失效

**症状**：图片点击后没有"从缩略图放大到全屏"的一镜到底效果，变成默认的右侧滑入。

**根因**：`.sharedTransition()` 是 legacy `router` 时代的 API，只对旧路由生效；本工程用 `Navigation/NavDestination`，该调用被静默忽略，回退默认转场。

**正确写法**：Navigation 下用 **`.geometryTransition(id)`**（API 11+，官方一镜到底能力），且必须三步齐全（[官方 Codelab](https://developer.huawei.com/consumer/cn/codelabsPortal/carddetails/tutorials_Next-TransitionAnimation)）：

1. 源缩略图和目标大图设置**相同且全局唯一**的 id（列表场景带上条目唯一标识，如 `image-viewer-dynamic-{dynId}-{index}`；目标页只对首张图绑定，不绑空 id）；
2. 跳转时**关闭 Navigation 默认转场**并包 animateTo，否则只会看到默认右滑：
   `animateTo({ duration: 300 }, () => AppNavStack.pushPathByName(name, param, false))`；
3. 返回同样处理：`onBackPressed` 拦截后 `animateTo(..., () => AppNavStack.pop(false))` 并 return true；目标 NavDestination 可加 `.transition(TransitionEffect.OPACITY)` 让页面其余部分淡入淡出。

**案例**：`pages/ImageViewer.ets`、`views/DynamicView.ets`、`components/ReplyCard.ets`、`pages/UserSpace.ets`。

## 6. 硬编码颜色 → 深色/浅色模式必有一边不可读

**症状**：浅色模式下按钮白底白字看不清。

**根因**：写死 `'#CCFFFFFF'`（半透明白字）配 `'#33FFFFFF'`（半透明白底），只在深色背景上成立。

**规则**：文字/背景色一律走语义色辅助（`AppTheme` 语义色、`isDark` 条件函数如 `titleColor()/subColor()/unselectedBg()`）；实底主题色上的文字才允许写死 `'#FFFFFF'`。新组件写完**手动切一次深浅色**检查。

**案例**：`components/PlayerSettingsPanel.ets` DmBlockChip、`components/PlayerView.ets` DmFilterPanel chips。

## 7. 废弃 API：全局 promptAction / getContext

**症状**：编译告警 `showToast deprecated`，新代码不断引入旧告警。

**正确写法**：toast/弹窗统一用 UIContext 版：

```ts
this.getUIContext().getPromptAction().showToast({ message: 'xxx' });
```

外层包 try/catch（组件销毁后调用会抛异常，忽略即可）。页面里封装一个 `private toast()` 复用。

**案例**：`pages/BangumiDetail.ets`、`pages/LibraryPages.ets` 的 toast 封装。

## 8. int64 游标用 number 接 → 精度丢失，分页错乱

**根因**：B 站 msgfeed / sys_msg 的分页游标是 int64（含纳秒时间戳），超出 number 安全整数范围，`JSON.parse` 后直接失真。

**正确写法**：游标从**原始响应报文**正则截取为字符串透传，不经 JSON.parse。

**案例**：`api/BiliApi.ets` 的 `fillMsgFeedCursor`、系统通知分页。

## 9. 多个 @BuilderParam 后尾随闭包失效

**症状**：给组件加第二个 @BuilderParam 后，原来尾随闭包写法编译报错/渲染异常。

**规则**：组件有 ≥2 个 @BuilderParam 时，调用处必须全部显式命名传参：

```ts
PageHeader({ title: 'x', trailing: (): void => { this.ClearAction() } })
```

**案例**：`components/PageHeader.ets` 加 `trailing` 后 `pages/Messages.ets` 的连带修复。

## 10. Tabs 内 expandSafeArea 失效

**症状**：Tabs 里的列表 `expandSafeArea` 延伸不到导航条区域。

**正确写法**：Tabs 容器加 `.clip(false)`（已知系统限制）。

**案例**：`pages/Index.ets` 主框架。

## 11. await 之后组件已销毁，写 @State 崩/告警

**正确写法**：页面/播放器持有 `private destroyed: boolean`，`aboutToDisappear` 置 true，所有 async 回调写状态前判空；防重入再加 `inflight` 标志。播放器创建类操作 await 后必须复查 `this.destroyed` 再重建。

**案例**：`components/PlayerView.ets`（changeQuality 等）、`pages/Search.ets`。

## 12. 接口数据主体字段不统一

**根因**：B 站接口有的主体在 `data`（绝大多数），有的在 `result`（PGC `/pgc/view/web/season`、搜索建议等），套同一个 `getData()` 解析会拿到空对象。

**规则**：接新接口前先看 PiliPlus 对应实现/bilibili-API-collect 文档，确认主体字段与分页游标设计，不要盲套现有助手。

**案例**：`api/BiliApi.ets` getBangumiSeason。

## 13. 手势冲突：父容器手势组截获子组件滑动

**症状**：Slider 拖不动、Swiper 和长按互相抢。

**正确写法**：
- 子组件需要优先响应的手势用 `.priorityGesture()`（如图片长按弹菜单）；
- 同组件多手势并存用 `GestureGroup(GestureMode.Parallel, ...)`，互斥用 `Exclusive`；
- 按状态动态关闭手势方向：`PanGesture({ direction: this.zoomed ? PanDirection.All : PanDirection.None })`（原尺寸下不截获横滑，交给外层 Swiper）。

**案例**：`pages/ImageViewer.ets` ZoomableImage、`components/PlayerView.ets` 播放器手势层。

## 14. 弹层/Surface 的层级选择

- 播放器内嵌 UI（竖屏设置）→ `bindSheet`，内容用 `embedded` 模式（透明底、layoutWeight 撑满）；
- 横屏设置 → 自绘右侧抽屉（Stack 内条件渲染 + translate 转场），不要从画面底部弹长条；
- 抽屉/浮层放在带手势的容器内时，注意第 11 条。

**案例**：`components/PlayerView.ets` SideSettingsDrawer / MoreMenuSheetContent。

## 15. LazyForEach 的 key 必须唯一且稳定

重复 key 会导致复用错乱、列表跳动。信息流按业务 id 去重（`aid`/`bvid`），同 id 可能重复出现时在 key 里拼 index。列表数据统一走 `BasicDataSource`（reset/append + 变更通知），不要直接改数组指望刷新。

**案例**：`views/HomeView.ets`、`common/BasicDataSource.ets`。

## 16. 三态（加载/空/错误）条件要写全且互斥

```ts
if (getLoading() && getCount() === 0) { LoadingView({ loading: true }) }
else if (getCount() === 0) { LoadingView({ empty / errorText / onRetry }) }
else { List }
```

- 空数组是**正常结果**不是错误：只有请求失败才置 errorText；
- `loading` 必须在 `finally` 里复位；
- 配合第 1、2 条，保证状态变化能真正驱动 UI。

**案例**：`pages/RankPage.ets`、`pages/LibraryPages.ets`。

## 17. 测试夹具按源码文本切片：CRLF 会让跨行锚点静默失配 ★曾导致 6 个用例集体失效

**症状**：`tool/qa/*.test.cjs` 里 6 个用例同时失败，报 `AssertionError: assert.ok(begin >= 0 && finish > begin)`。看起来像评论换根/换排序的并发回归，实际生产代码完全正常。

**根因（两重）**：

1. `methodHarness(file, start, end)` 靠**源码字符串精确匹配**抽取生产方法，锚点一变就断：`private` 被去掉、参数补了类型注解（`DynTypeChip(label, type)` → `DynTypeChip(label: string, type: string)`）、注释文案改名，都会让 `indexOf` 返回 -1；
2. **最隐蔽的一层**：仓库 `.ets` 是 **CRLF 检出**（`core.autocrlf`），而锚点多行字面量按 `\n` 书写。于是即使文本内容一字不差，跨行锚点照样匹配失败。

**正确写法**：

- `readSource` 一律把源码**归一为 LF** 再切片：`.replace(/\r\n/g, '\n')`，让锚点只依赖内容、不依赖检出时的行尾；
- 锚点**集中成常量**（`lifecycle.test.cjs` 的 `ANCHOR`），不得内联在用例里；
- 断言**带锚点内容**，失败时直接指出漂的是哪一个，而不是一句裸断言。

```js
assert.ok(begin >= 0, `锚点未命中 start（${file}.ets）：${JSON.stringify(start)}`);
assert.ok(finish > begin, `锚点未命中 end（${file}.ets）：${JSON.stringify(end)}`);
```

**规则**：改动被 `methodHarness` 切片的方法签名或紧邻注释时，**必须在同一个提交里同步锚点并重跑该测试文件**。锚点漂移会伪装成功能回归，反过来也会让真实回归被误判为"夹具又断了"而放过。

**遗留风险（待迁移）**：`lifecycle.test.cjs` 有 33 处 `methodHarness` 调用，其中约 20 处仍是**内联硬编码锚点**（已迁入 `ANCHOR` 的只是少数）。单行锚点抗漂移稍好（例如 `'  async loadReplies('` 恰因去掉 `private` 而侥幸存活），但同样是静默失效点。**`ANCHOR` 常量尚未覆盖全部调用点，新增/修改用例时不要再写内联锚点。**

**更彻底的解法（未做）**：把并发决策逻辑抽成不依赖页面类的纯模块（工程已有先例：评论改动已抽到 `common/ReplyMutation.ets`），让测试直接调用模块 API、不再切片页面源码。这是根治方向，比继续维护锚点更划算。

**案例**：`tool/qa/lifecycle.test.cjs`（`ANCHOR` 常量）、`regression.test.cjs` / `danmaku.test.cjs` / `parity.test.cjs` 的 `readSource`。

---

## 18. ArkWeb 不共享应用的网络代理；外部页面还可能按 UA 返回不同结构 ★曾导致播放器空白

两个独立的坑，都在 YouTube 侧踩到，且都会**表现为"功能坏了"而其实不是**。

### 18a. `usingProxy` / 系统代理对 Web 组件无效

`@ohos.net.http` 的 `HttpClient` 设了 `usingProxy`，**只影响应用自身的 HTTP 请求**；
`Web` 组件里的 Chromium 是独立网络栈：

- 它默认走**系统代理**，而模拟器/设备上可能根本没有系统代理参数
  （本环境 `persist.net.http.proxy`、`persist.net.proxy.host` 都不存在）；
- SDK 里确有 `webview.ProxyConfig.applyProxyOverride(proxyConfig, callback)`（API 15+，静态方法）
  可以给 ArkWeb 单独下发代理，但**并非所有 SDK 的类型索引都能取到**：本机 API 26 SDK
  编译报 `Property 'applyProxyOverride' does not exist on type 'typeof ProxyConfig'`，
  尽管它在 `.d.ts` 的 `class ProxyConfig` 内。

**症状**：应用侧搜索/详情一切正常，播放器页面永远停在 `about:blank`，且**没有任何错误回调**
（脚本加载不到 ⇒ `document.title` 信号通道不发火 ⇒ 只能靠超时兜底）。很容易误判成
`loadData` 用法错误或 origin 配置错误。

**排查第一步**：先确认设备到目标域名的可达性，而不是先怀疑代码。

```bash
hdc shell ping -c 2 -W 3 www.youtube.com   # 100% 丢包 ⇒ 网络不通，不是导航问题
hdc shell ping -c 2 -W 3 www.baidu.com     # 正常 ⇒ 设备整体出网没问题
```

**规则**：给 Web 组件接代理必须用 ArkWeb 自己的代理 API，且要**编译期验证该 API 在目标
SDK 上可用**；不可用时不要合入，并如实记录"播放器画面未验收"。

### 18b. 公开网页按 User-Agent 返回不同结构

对同一 URL 实测 YouTube：

| User-Agent | 结果 |
| --- | --- |
| 桌面 Chrome | `ytInitialData` 含 `videoRenderer`，解析出 22 条 |
| 无 UA / 移动 Chrome | 返回验证页或移动版页面，**没有 `videoRenderer`**，解析整体抛错 |

即：**解析器逻辑完全正确，失败根因是请求头。** 这类"字段消失"必须先怀疑服务端按客户端
能力/UA 分叉，再去改解析器。

**规则**：抓取公开页面时显式声明 UA，并写一条**锁定请求头**的回归测试
（`regression.test.cjs` 的 `YouTube: public pages are requested as a desktop client...`），
否则将来有人"顺手清理掉看起来没用的 header"，功能会静默失效。

**案例**：`entry/src/main/ets/api/YouTubeApi.ets`（`DESKTOP_UA`）、
`entry/src/main/ets/pages/YouTubeDetail.ets`、`services/network/HttpClient.ets`（可选代理）。

---

## 附：提交前自检清单

1. Builder/组件参数里的可变状态是否都在体内读取？（第 1、2 条）
2. 深浅色两种模式都看过吗？（第 4 条）
3. 有没有引入废弃 API 告警？`bash tool/build.sh` 新增告警应为 0（第 5 条）
4. 分页游标是不是 int64？（第 6 条）
5. 异步回调有没有 destroyed/防重入守卫？（第 9 条）
6. `bash tool/build.sh` BUILD SUCCESSFUL、0 error。
