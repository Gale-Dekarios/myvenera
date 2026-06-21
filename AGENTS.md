# AGENTS.md

本文件面向后续接手此仓库的编码代理。目标不是重复 Flutter 常识，而是快速说明这个项目的关键结构、开发约束和下一步优先事项。

## 项目概览

Venera 是一个 Flutter 漫画阅读器，支持：

- 本地漫画导入与阅读
- 基于 JavaScript 的网络漫画源
- 收藏、历史、下载队列
- 阅读器多模式、评论、图片收藏
- WebDAV 数据同步
- Android / iOS / Windows / macOS / Linux 多端运行

当前阶段的重点不是大改架构，而是补齐阅读器交互、修复设置联动问题、提升下载与本地库体验，并补上基本测试覆盖。

## 关键入口

- `lib/main.dart`：应用入口，包含普通模式和 `--headless` 分支
- `lib/init.dart`：初始化流程
- `lib/pages/main_page.dart`：主导航壳
- `lib/pages/reader/`：阅读器核心逻辑
- `lib/pages/comic_details_page/`：详情页、章节、评论、操作区
- `lib/pages/favorites/`：本地/网络收藏
- `lib/pages/downloading_page.dart`：下载队列 UI
- `lib/pages/local_comics_page.dart`：本地漫画库
- `lib/foundation/comic_source/`：JS 漫画源能力解析与调用
- `lib/foundation/appdata.dart`：设置、持久化、同步相关数据
- `doc/comic_source.md`、`doc/js_api.md`：漫画源协议文档

## 开发约定

- 所有用户可见文本都要走翻译：使用 `.tl`
- 配置统一写入 `appdata.settings`
- 阅读器相关配置不要直接假设全局设置生效，优先使用 `getReaderSetting` / `setReaderSetting`
- 网络请求优先走 `AppDio`
- JS 漫画源能力新增时，需要同步更新 Dart 侧 parser / models / types，以及相关文档
- 改动完成后，至少执行一次 `flutter analyze` 和 `flutter test`

常用命令：

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

## 当前状态

以 2026-06-21 的仓库状态为准：

- `flutter test`：通过
- `flutter analyze`：存在 8 个 `deprecated_member_use` 提示
- 当前测试覆盖很薄，只有 `test/channel_test.dart`

已确认的静态检查问题主要集中在：

- `lib/components/image.dart`
- `lib/pages/reader/comic_image.dart`
- `lib/utils/io.dart`

## 下一步操作

### P0：优先修复

1. 修复阅读设置页的“生效配置”读取不一致
   - 相关文件：`lib/pages/settings/reader.dart`
   - 现状：部分显示条件和联动逻辑直接读取 `appdata.settings[...]`，没有统一走漫画专属 / 设备专属设置的最终生效值
   - 目标：抽出统一的 effective-setting 读取方法，所有可见性判断、联动和写入都使用同一套逻辑
   - 验收：开启 comic-specific 或 device-specific 设置后，`readerMode`、`showSingleImageOnFirstPage`、`showChapterCommentsAtEnd` 等选项显示与实际行为一致

2. 修复边缘返回手势误触
   - 相关文件：`lib/components/navigation_bar.dart`
   - 现状：`_NaviPopScope.onPanEnd` 对任意水平滑动速度都会触发返回
   - 目标：仅在左缘开始、且向右滑达到阈值时触发返回；左滑和普通横向拖动不应退出页面
   - 验收：大屏 iOS/桌面场景下不再误返回，原有边缘返回能力保留

3. 去掉搜索语言过滤的页面层硬编码
   - 相关文件：`lib/pages/search_result_page.dart`、`lib/foundation/comic_source/`、`doc/js_api.md`
   - 现状：`checkAutoLanguage()` 把 `nhentai` / `ehentai` 写死在页面层
   - 目标：改为由 source capability 或配置声明是否支持自动追加 `language:` 过滤
   - 验收：页面层不再维护站点名单，新源可通过能力配置接入

### P1：交互与功能补强

4. 补齐阅读器交互配置
   - 相关目录：`lib/pages/reader/`
   - 建议项：点击翻页热区可配置、桌面快捷键帮助、连续模式和图库模式的滚轮行为统一、评论页和正文切换提示更明确
   - 验收：至少落地 1 个可配置入口和 1 个桌面帮助入口

5. 增强下载队列的可观测性
   - 相关文件：`lib/pages/downloading_page.dart`、`lib/network/download.dart`、`lib/foundation/local.dart`
   - 建议项：区分“暂停 / 等待槽位 / 下载中 / 失败需手动重试”，补充失败原因、总进度、批量重排能力
   - 验收：用户能直接看懂每个任务当前状态和下一步操作

6. 完善本地漫画库维护能力
   - 相关文件：`lib/pages/local_comics_page.dart`、`lib/utils/import_comic.dart`、`lib/foundation/local.dart`
   - 建议项：增量扫描、失效文件清理、重复导入检测、损坏压缩包提示
   - 验收：目录变化后本地库状态可以自洽，不依赖频繁全量重扫

7. 优化首页与搜索流程
   - 相关文件：`lib/pages/home_page.dart`、`lib/pages/search_page.dart`、`lib/pages/search_result_page.dart`
   - 建议项：统一空态/错误态表现，搜索建议支持键盘选择，过滤项记住最近一次选择
   - 验收：桌面端仅靠键盘即可完成一次搜索和结果打开

### P2：工程治理

8. 清理过时 API
   - `TickerMode.of` 替换为新 API
   - `Share.share*` 替换为 `SharePlus.instance.share()`
   - 验收：`flutter analyze` 不再出现当前 8 个 deprecation 提示

9. 补测试
   - 优先补：`ReaderSettings` 生效逻辑、阅读器分页和方向切换、下载队列状态流转
   - 目标：新增可维护的 widget test 或 pure Dart test，不要只补表面快照

10. 补文档
   - 更新 `README.md` 的功能列表和开发说明
   - 如果新增 source capability，同步更新 `doc/comic_source.md` / `doc/js_api.md`
   - 为阅读器设置和下载队列补一份简短维护说明

## 建议执行顺序

1. 先做 P0-1 和 P0-2，这两项收益最高、风险最低
2. 然后处理 P2-8，尽快清掉当前 deprecated API
3. 再推进 P1 的阅读器和下载队列增强，并同步补测试
4. 最后更新 README 和文档，确保行为与说明一致
