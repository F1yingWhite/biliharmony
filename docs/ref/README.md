# UI 设计参考截图索引

为 BiliHaromny（HarmonyOS B 站客户端）收集的界面设计参考，分两类：BewlyCat / BewlyBewly 浏览器插件（重做 B 站首页的优秀案例）与 B 站官方手机 App（App Store 国区截图）。

## 1. BewlyCat / BewlyBewly 插件截图（`bewlycat/`）

| 文件 | 来源 | 展示的界面 | 参考价值 |
| --- | --- | --- | --- |
| `home-light.jpg` (3456×1822) | BewlyBewly README 预览图（GitHub assets）：https://github.com/hakadao/BewlyBewly/assets/33394391/951f9e2a-d0e1-452c-83a9-dc6d85c4d441 | 浅色模式首页：顶部搜索栏 + 频道 Tab（For you / Following / Trending / Ranking）+ 宫格视频卡片流，右侧竖排 Dock | 浅色主题配色、卡片信息流密度、右侧 Dock 导航的完整形态，可直接对照设计首页 |
| `home-dark.jpg` (3456×1821) | BewlyBewly README 预览图（GitHub assets）：https://github.com/hakadao/BewlyBewly/assets/33394391/3e75dd20-f60b-4645-b434-23a24c72959c | 与上图同布局的深色模式首页 | 深色主题配色（近黑背景 + 品牌蓝点缀）、深浅两套主题的一致性处理 |
| `home-cn.png` (1280×800) | BewlyCat Firefox Add-ons 官方预览图：https://addons.mozilla.org/user-media/previews/full/320/320657.png | BewlyCat 中文界面首页：「个性推荐 / 热门视频 / 排行 / 直播」Tab + 双列大卡片 + 右侧 Dock（含设置、主题切换入口） | 中文化后的文案与 Tab 结构、Dock 上设置/主题入口的位置，最贴近我们目标形态 |
| `home-dark-en.png` (2400×1501) | BewlyBewly Firefox Add-ons 官方预览图：https://addons.mozilla.org/user-media/previews/full/297/297951.png | BewlyBewly 深色模式首页（英文 UI），右侧 Dock 收起为细条 | 深色模式下 Dock 的收起态与卡片圆角、阴影细节 |

> 说明：BewlyCat / BewlyBewly 仓库内不含 UI 截图（README 预览图托管在 GitHub assets，且 BewlyCat README 未直接展示）；设置面板独立截图在公开渠道未找到，上表 4 张已覆盖首页、深浅色模式与 Dock。

## 2. B 站官方手机 App 截图（`bilibili-app/`）

来源：iTunes Lookup API（`https://itunes.apple.com/lookup?id=736536022&country=cn`）返回的 `screenshotUrls`，取前 6 张，并将尺寸参数替换为 `1290x2796bb` 获取高清版（实际 1242×2208 JPEG）。

| 文件 | 来源 URL（原始 392×696 形式） | 展示的界面 | 参考价值 |
| --- | --- | --- | --- |
| `appstore-1.jpg` | https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/c5/fd/b5/c5fdb5ab-be13-93b7-9ede-690c39574839/1__U51e1_U4eba_U4fee_U4ed9_U4f20.jpg/392x696bb.jpg | 番剧详情页（凡人修仙传）：封面大图、评分、「追番」按钮、点赞/投币/收藏/缓存/分享操作栏、选集列表 | 详情页信息层级与操作栏图标排布，是播放详情页的直接参照 |
| `appstore-2.jpg` | https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/34/25/7d/34257db0-c1af-e527-dd52-c591a8604fa7/2__U662d_U9633_U516c_U4e3b.jpg/392x696bb.jpg | 剧集详情页（昭阳公主）：出品方标签、「追剧」按钮、运营位 banner、榜单入口 | 详情页运营位与榜单模块的插入方式 |
| `appstore-3.jpg` | https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/a3/e2/7a/a3e27a1b-5944-1c78-62ed-124a9db4ab57/3__U6709_U517d_U7109__U7b2c_U516d_U5b63.jpg/392x696bb.jpg | 国创详情页（有兽焉）：评分/在追人数标签、大会员 banner、选集与更新状态 | 会员标识、更新状态文案的呈现方式 |
| `appstore-4.jpg` | https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/0c/17/8c/0c178c06-5cba-d0e5-d24b-1a0122cb292b/4_U77e5_U8bc6.jpg/392x696bb.jpg | 频道页-知识分区：顶部二级 Tab（推荐/科学科普/社科·法律·心理…）+ 双列视频卡片流（播放量、弹幕数、时长角标） | 移动端双列卡片流与分区 Tab 的标准样式，首页推荐流可直接套用 |
| `appstore-5.jpg` | https://is1-ssl.mzstatic.com/image/thumb/PurpleSource221/v4/5a/ff/6b/5aff6b85-ef99-5ddc-63c3-91066dc17240/5_U6e38_U620f.jpg/392x696bb.jpg | 频道页-游戏分区：轮播 banner + 「近期热门」双列卡片流 | 轮播 banner 与卡片流的组合布局 |
| `appstore-6.jpg` | https://is1-ssl.mzstatic.com/image/thumb/PurpleSource211/v4/56/cb/69/56cb6959-6124-21ce-6f9f-cab4e3832f57/6_U8fd0_U52a8.jpg/392x696bb.jpg | 频道页-运动分区：轮播 banner + 双列卡片流（含 UP 主/分区标签行） | 卡片底部标签行与「更多」按钮的样式 |

## 验证

所有文件均经 `file` 命令确认为真实图片（PNG / JPEG），非 404 HTML；尺寸与字节数如上表及目录所列。
