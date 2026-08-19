# ArkUI 官方规范学习笔记（配套重构用）

> 依据 OpenHarmony 官方文档（docs/zh-cn/application-dev/ui/state-management 与
> quick-start/typescript-to-arkts-migration-guide）对照本工程易错清单整理。
> 目的：重构前统一认知，防止"凭经验写"踩官方已明示的坑。
> 官方文档版本以 OpenHarmony master 分支为准（对应 API 26 时代能力）。

---

## 1. 状态管理 V1 装饰器速查（本项目当前全 V1）

### 1.1 观察能力总表（决定"改了能不能刷新"）

| 装饰器                      | 同步方向                    | 能观察到的变化                                                                                   | 典型坑                                                                                                           |
| --------------------------- | --------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `@State`                    | 组件内                      | 自身赋值；class/object 的**第一层属性**赋值；Array 整体赋值 + `push/pop/splice/sort/reverse/...` | **嵌套对象属性赋值观察不到**（`this.title.name.value = 'x'` 不刷新）；必须 @Observed + 逐层 @Prop 或 @ObjectLink |
| `@Prop`                     | 父→子单向                   | 深拷贝快照；父更新覆盖本地                                                                       | **深拷贝丢类型**（PixelMap/RegExp 等 NAPI 类型）；嵌套 >5 层建议换 @ObjectLink；本地修改不同步回父               |
| `@Link`                     | 父子双向                    | 同 @State                                                                                        | 必须由父组件初始化，不能本地初始化                                                                               |
| `@ObjectLink`               | 指向@Observed 实例的"指针"  | **嵌套属性变化都能观察**（通过 @Observed 代理）                                                  | 只读，**禁止整体赋值**（`this.objLink = x` 会切断同步链）；必须由 @Observed 类实例初始化                         |
| `@Provide/@Consume`         | 跨层双向（按同名/别名绑定） | 同 @State                                                                                        | API 20 前 @Consume 必须匹配到某 @Provide，否则 JS ERROR；API 20+ 支持本地默认值兜底                              |
| `@Watch`                    | 监听                        | 被装饰状态变量变化时回调                                                                         | 回调里再改同一变量会递归触发；是**值变化后**触发不是前置钩子                                                     |
| `@StorageProp/@StorageLink` | 与 AppStorage 单向/双向     | Array/class 第一层等同上                                                                         | 键为常量字符串；**@StorageProp 本地改不会回写 AppStorage**；类型需与 AppStorage 中一致否则隐式转换               |

### 1.2 无状态字段 = 创建时快照（易错清单 #2 的官方根据）

`@Component` 内未加装饰器的普通字段只在创建时初始化一次；父组件后续传入新值**不会同步**。凡"外部传入且可能变化"的字段必须 `@Prop`/`@Link`/`@ObjectLink`；只有事件回调函数字段可以裸声明。

### 1.3 @Prop 深拷贝与嵌套观察（易错清单 #3 的官方根据）

- `@Prop` 装饰 class 时深拷贝快照：子组件内 `item.liked = true` 改的是**副本**，数据源没变。
- LazyForEach 以 **key 判等**：key（业务 id）没变 → 不重建该行 → UI 不刷新。
- 官方推荐组合拳 = 数据源更新（clone + 换引用/`updateItem`）+ **列表 key 带上修订号**（项目里 `rev` 机制），与框架行为完全一致。
- 嵌套场景官方推荐 `@Observed` + `@ObjectLink`（子树级观察）；本项目当前用 `@Prop + rev` 平铺，可作为二期演进方向（本次重构不引入 V2，见 §4）。

### 1.4 LazyForEach 约束（易错清单 #15 的官方根据）

1. 必须实现 `IDataSource`（totalCount/getData/register/unregister），本工程 `BasicDataSource<T>` 已满足。
2. **key 必须唯一 + 稳定**：重复 key 行为不可预期（官方安索异常示例）；数据项不变则 key 必须不变。
3. 数据更新分 add/del/change/move 四种通知：`onDataAdd/onDataDelete/onDataChange(index)/onDataMove`；**onDataChange 配合的 key 要变化**才会重建该行（与 #3 的 `rev` 一致）。
4. LazyForEach 必须在 List/Grid/Swiper/WaterFlow 等懒加载容器内使用；容器里只能有一个 LazyForEach（建议不与 ForEach 混用）。（本工程每列表页一个 LazyForEach + ListItemGroup footer，符合规则）
5. **重新赋值 dataSource 参数本身是异常行为**：要全量刷新用 `onDataReloaded()`（本项目 `reset()` 已按此实现）。

### 1.5 AppStorage / PersistentStorage（官方现状）

- `AppStorage`：应用级单例 UI 状态中心，@StorageProp（单向）/@StorageLink（双向）绑定；键为常量字符串。
- **官方已推荐 `PersistenceV2` 替代 PersistentStorage**（后者耦合 AppStorage 且为同步落盘、>2KB 大数据/高频变化会卡 UI）。本项目当前用 PersistentStorage + Preferences 双轨，重构时可评估局部迁移到 `PersistenceV2`（API 26 可用），但不强制本轮做——避免扩大改动面。

---

## 2. @Builder / @BuilderParam 传参规则（易错清单 #1/#9 的官方依据）

1. **按值传参 → 静态快照**：`@Builder` 传参默认按值，状态变化不触发 Builder 内 UI 刷新（官方价值导向 switch 到"按引用"）。
2. **按引用传参**：`@Builder` 只接受**一个对象字面量参数**（例如 `this.Xx({ count: this.count })`）时，状态变化能刷新；多个参数或含按值混传 → 不刷新。
3. **回调闭包传参**是可靠的"体内读状态"写法（官方 UI 刷新章节认可 `@Builder` 内读 `this.xxx`）。
4. `@BuilderParam`：**最多一个可接受尾随闭包，且必须无参数**；组件内有 ≥2 个 `@BuilderParam` 时，调用处必须全部显式命名传参（本项目 `PageHeader(middle/trailing)` 已按此修过，`Messages/` 有注释）。
5. 组件内推荐 `@BuilderParam` 配 `@Builder` 默认占位（如 `this.emptyMiddle`），避免"忘传变空白"。

---

## 3. ArkTS 语言约束（ts2arkts 迁移指南节选，重构时不要越界）

| 不允许                                  | 替代写法                                                                  |
| --------------------------------------- | ------------------------------------------------------------------------- |
| `any` / `unknown` 类型                  | 具体类型/联合类型；catch 子句**不能标类型**                               |
| 对象字面量和属性名非合法标识符          | 用字符串索引 Record                                                       |
| 展开运算符（spread）用于**对象**        | 仅可用在数组剩余参数与数组字面量；（`HttpClient.merge` 手寫循环即此原因） |
| 解构赋值 / 解构变量声明                 | 逐字段临时变量（本工程 `wbi` 等手写即遵此）                               |
| index signature（`{ [k: string]: T }`） | `Record<string, T>`（项目全用 Record，正确）                              |
| `for..in`                               | `Object.keys().for循环` 或 `Object.entries`                               |
| 函数内声明函数（嵌套 function）         | 箭头函数（本工程已用）                                                    |
| `delete obj.prop`                       | 重建对象/数组（`HttpClient.removeCookie` 已按此）                         |
| 使用 `this` 在函数/静态方法里           | 只在类/组件方法中用 `this`                                                |
| 任意使用 `instanceof`                   | 仅 class 间类型收窄可用；接口/联合不适合                                  |
| 运算符 `+ - ~` 作用于非数值             | 显式 `Number()`                                                           |

**可放心用的**：`Array.prototype.map/filter/forEach/find/findIndex/some/every/sort/concat/slice/reduce/join/split`（本项目 `HistoryApi` 已用 map 先例）、可选链 `?.`、空值合并 `??`、rest 参数、`as T` 类型断言。

---

## 4. V1 vs V2 状态管理（本项目定位）

- 官方指引：**新开发推荐 V2**（@Local/@Param/@Event/@ObservedV2/@Trace/Repeat 等），**存量 V1 应用如果 V1 功能性能满足，无需立即迁移**。
- 本工程 30k+ 行全 V1（@State 大量、@Builder 大量、LazyForEach + BasicDataSource），V2 迁移风险面大（@ComponentV2/@Local/@Trace 全量改造 + 混用规则复杂），**本轮重构保持 V1**，重点做"V1 框架内的整洁化"（抽组件、防重复、提工具、去死代码、修 bug），把 V2 列为后续演进项并写进 Roadmap 备注。

---

## 5. 其他对照结论

- toast：官方推荐 `this.getUIContext().getPromptAction().showToast`（UIContext 版本，无全局 deprecation）；**本项目 4 处 `private toast` 递归 bug 即以官方示例为正确写法修复**（见重构清单 P0-1）。
- `PersistentStorage` 官方示例即"PersistProp + AppStorage"，本项目 UserStore/AppTheme 配套 Preferences 权威副本的写法与官方建议一致（且在官方推荐新 PersistenceV2 之前是社区标准做法）。
- 组件生命周期：`aboutToAppear/aboutToDisappear` 等 + `@Watch` 是 V1 标准时机；"销毁后写 @State"用 destroyed 标志（易错 #11）符合官方异步回避建议。

---

## 6. 本工程重构剪枝清单（结合四份审计 + 本文档）

- P0：修复 toast 递归（44 调用点）→ 提取 `common/Toast.ts`，删除 11 处副本中的递归 4 处。
- P0：统一 `ActionResult/getData/actionWithCsrf` 到 `ApiCommon` 单一来源，删 `BiliApi` 88 行副本，解决双类身份。
- P1：`BiliApi` 1430 行剥皮（60+ 一行透传改 direct import / 集中代 -> re-export）。
- P1：`VideoDetail` 2669 行分批抽组件（Reply 区、PlayerProps、Coin/Fav Sheet 等）。
- P2：三处 `PersistedStore` 骨架合一（UserStore/SearchHistoryStore/AppTheme 迁移模板）。
- P2：硬编码色值（~100 处）对齐 `AppTheme` 语义 token。
- P3：手写 `for` 替 to `.map/.filter`、死代码清理（Utils.obj/arr/num/componentRectVp）、`EntryAbility TAG` 拼写。

（完整 审计报告见会话附录；本笔记只收与官方文档对照的部分。）