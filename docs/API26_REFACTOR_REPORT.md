# HarmonyOS API 26 规范审计与重构报告

本轮以本机 HarmonyOS SDK `26.0.0.32 Beta2` 的 ArkTS 声明和构建诊断为准，工程最低、编译和目标版本均按 API 26 检查，不再为 API 24 保留兼容分支。

## 已修正的问题

- 工程最低版本由 API 24 调整为 API 26，清理所有“API 26 接口在兼容版本 24 上不可用”的构建告警。
- `TextEncoder.encode` 已按 API 26 弃用标记替换为 `encodeInto`。
- `List.onScroll` 已替换为 `onDidScroll`。
- 全局 `promptAction.showDialog` 已改为从 `UIContext` 获取 `PromptAction`，避免依赖失去页面上下文的全局调用。
- 图片打包由已弃用的 `ImagePacker.packing` 改为 `packToData`，并在 `finally` 中异步释放打包器。
- 保存图片不再直接申请写媒体库权限并调用 `createAsset`。现通过 `showSingleAssetCreationDialogEx` 让用户确认目标，随后写入系统返回的 URI，符合 API 26 媒体库授权模型。
- 移除未实际适配的 `2in1` 设备声明；当前设备范围为 phone/tablet，与播放器、沉浸式窗口和密码学能力的实际使用一致。

## 结构整理

- `model/Models.ets` 从两千余行的实现文件改为稳定导出入口，模型按 video、library、message、reply、user、dynamic、bangumi、discovery 领域拆分。
- 原 `LibraryPages.ets` 拆为 HistoryPage、WatchLaterPage、FavoritesPage。
- `components` 根目录按 player、live、reply、video 分组，根目录仅保留跨领域通用组件。
- API 层新增 `AuthApi`、`BangumiApi`，用户关系、动态发布与历史删除归入现有领域 API；`BiliApi.ets` 只保留视频播放与弹幕职责，行数由 1141 降至约 600。
- 图片媒体库写入集中到 `services/media/PhotoLibrarySaver.ets`。

## 构建诊断说明

API 24 兼容告警、弃用 API 告警和媒体库写权限告警均已消除。剩余诊断主要分两类：

- CryptoFramework、MediaKit 的“并非所有设备都支持”能力告警。工程已限制为 phone/tablet，调用点也有失败处理；这是 SDK 对系统能力覆盖面的静态提示，不是 API 版本错误。
- 少量系统接口的“可能抛出异常”提示。相关关键链路已有 `try/catch` 或 Promise 失败处理；后续应随具体业务错误策略逐项收紧，不能用空捕获批量压掉诊断。

独立 Code Linter CLI 在当前 DevEco 安装中仅返回通用错误且没有诊断明细，因此本轮以 `CompileArkTS` 的严格检查、HAP 打包和模拟器 UI 回归作为可复现验收依据。
