<h1 align="center">
    <img src="./assets/images/tsdm_client.svg" width="120px" alt="tsdm_client_logo">
    <br>
    tsdm_client
</h1>

<p align="center">天使动漫论坛官方客户端 · Discuz! X5 版</p>

<p align="center">简体中文 | <a href="./README.zh-hant.md">繁體中文</a> | <a href="./README.en.md">English</a></p>

<p align="center">
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/release/Carinoasd/tsdm_client?label=release" alt="release"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/downloads/Carinoasd/tsdm_client/total" alt="download_total"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/actions"><img src="https://img.shields.io/github/actions/workflow/status/Carinoasd/tsdm_client/test.yml?label=test" alt="test_ci"/></a>
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.41-blue?logo=flutter" alt="flutter"/></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/Carinoasd/tsdm_client" alt="license"/></a>
</p>

## 最新更新：1.64.0（2026-11-28）

- 更新页新增「检测通道」：自动、爱丽丝盘、GitHub 三选一，连不上其中一边时可以只用另一边。
- 更新页新增「从爱丽丝盘下载」，直接打开对应机型的网盘页面。
- Android 构建编号为 183，可直接覆盖之前的正式版与测试版。

[下载 1.64.0](https://github.com/Carinoasd/tsdm_client/releases/tag/v1.64.0) · [完整更新日志](./CHANGELOG.md)

## 这是什么

[天使动漫论坛](https://www.tsdm39.com/) 的跨平台客户端。论坛于 2026 年升级到 Discuz! X5 后，原客户端无法解析新版页面；本项目受站方委托接手维护，
适配 X5 的页面结构并持续加入功能，是站方认可的官方客户端版本。

## 下载

到 [Releases](https://github.com/Carinoasd/tsdm_client/releases/latest) 下载：

| 平台 | 文件 |
|---|---|
| Android（多数手机） | `tsdm_client-arm64_v8a.apk` |
| Android（旧 32 位机型） | `tsdm_client-armeabi_v7a.apk` |
| Android（不确定机型时用这个，较大） | `tsdm_client-universal.apk` |
| iOS（未签名，需自行侧载） | `tsdm_client.ipa` |
| Windows 10/11（64 位，解压即用） | `tsdm_client-windows.zip` |
| macOS | `tsdm_client-universal.dmg` |
| Linux | `tsdm_client-linux.tar.gz` |

三个 Android 包可以互相升级：universal 的内部版本号永远高于同一版的分包，下一版的任何包又高于它。只有在同一版里从 universal 换回分包会被系统当成降版，需要先卸载再安装。

Linux 版需要系统已安装 `libayatana-appindicator3-1`（Debian／Ubuntu 的软件包名，其他发行版为对应的 ayatana-appindicator 软件包）。这是系统托盘组件的运行时依赖，没有安装时程序无法启动。

不上架任何商店。Android 直接安装 APK；App 内「检测最新版本」读取本仓库的 `version.json`，「更新日志」与 Releases 同步。

包名为 `com.tsdm.tsdm_client`，使用论坛官方的签名密钥，可与原作者发布的旧版（`kzs.th000.tsdm_client`）并存。从旧版迁移过来：旧版「设置 → 导出数据」勾选账号数据并设置密码 → 安装本版 → 「导入数据」输入同一密码 → 卸载旧版。

## 主要功能

### 浏览与阅读
- 首页（论坛统计、导读、抢沙发、活动总览）、分区与版块、主题与楼层；回复过、看过的主题有标记，看过之后有新回复会显示 +N
- 帖内搜索、跳到楼层、只看某位作者、多页连续加载；记住读到哪里，沉浸式阅读可按版块自动开启
- 网盘链接识别：帖子里的百度、蓝奏、夸克、阿里等网盘链接下方列出网盘名、提取码与解压密码，点一下即复制
- 帖内音频附件与网易云音乐链接可直接播放，换页不停；Android、iOS、macOS 支持后台播放与通知栏控制
- 朗读帖子（TTS）：从当前楼层逐楼念，可换楼、暂停、调语速（Android、iOS、Windows、macOS）
- 简繁显示转换；正文字号、行距、段距与阅读宽度可调；省流模式
- 离线保存看过的帖子（默认关闭），收藏夹可批量离线下载
- 导出整帖为纯文本、Markdown 或 PDF；楼层可「分享为图片」，帖子、版块与个人资料可生成二维码

### 发帖与互动
- BBCode 编辑器、本机草稿与论坛草稿箱、快速回复与评分模板
- 回复、多楼引用、点评、评分、投票、购买、举报；输入 `@` 列出好友与官方 @ 名单
- 「我的图片」与自定义表情包，表情面板直接选用
- 红包帖、悬赏、活动、辩论等特殊主题用原生卡片显示并可直接操作
- 附件在 App 内下载，「下载管理」可重试、打开、分享

### 收藏与追踪
- 收藏（帖子／版块）、淘帖、稍后阅读、楼层书签（可附备注）、浏览历史
- 追踪帖子的新回复；版块新帖提醒与关键字提醒
- 屏蔽用户、关键字与版块

### 账号与数据
- 多账号切换、自动签到与每日红包、登录过期提示与一键重新登录
- 跨设备同步：阅读进度、常用语与屏蔽列表，另可选草稿、书签、模板、稍后阅读、追踪的帖子、「我的图片」等
- 备份导出／导入（账号登录数据可用密码加密）、WebDAV 自动备份与还原
- 应用锁；登录设备管理、密码与安全、隐私设置
- 勋章中心、称号与称号商店、成就、积分转账与兑换、好友与私信

### 通知
- App 内与后台同步提醒、私信，发出系统通知；可同时检查这台设备上所有已登录的账号
- 可分别关闭回复、@、评分／点评、私信、系统通知等类别，并可设静音时段
- Android：后台消息接收（前台服务常驻）、通知栏直接回复
- Windows：系统通知与提示音，点击通知还原窗口并打开消息中心

### 论坛服务
- 社区银行、背景商店、宠物中心、任务与道具等做成 App 内页面
- 游戏中心、天使裁判所、CP 系统、打工等在内置浏览器以当前账号打开

### 版主与管理
- 帖子与楼层管理：置顶、高亮、精华、移动、关闭、删除、屏蔽、警告、撤销评分、禁言等，按论坛给的权限显示
- 版主面板：审核、举报处理、回收站、管理日志；批量评分（论坛装有该插件时）
- 站方人员：发放勋章、头衔与背景，积分奖惩，用户组调整

### 平板与桌面
- 宽屏双栏：左边列表、右边帖子，右栏可开多个标签页，栏宽可拖动
- `Ctrl+K` 快速跳转：输入 tid、链接、版块名、帖子标题或用户名直接打开
- 键盘快捷键（iPad 接实体键盘也可用）、`Ctrl+Enter` 发送、系统托盘、关闭到托盘、老板键

### 平台
- Android（arm64／armv7／universal）、iOS（未签名侧载）、Windows、macOS、Linux
- Android 与 Windows 可在 App 内下载并安装更新，下载后先核对文件再安装
- Android：桌面快捷方式、把版块或帖子「添加到桌面」、可切换应用图标；iOS：桌面小组件与图标快捷操作

## 已知问题

- 部分 Android 设备旋转过渡时会短暂出现黑屏，旋转完成后排版正常；这个过渡问题暂不处理（#28）。
- 版块列表无法获取外链头像：App 还没在别处见过该用户的头像时，列表显示文字圆圈。
- 论坛的成就系统目前没有内容，「我的成就」只会显示「暂无成就」。
- iOS 版没有签名，需要自行侧载，也没有真机测试。

## 反馈问题

到 [Issues](https://github.com/Carinoasd/tsdm_client/issues) 创建新议题，附上 App 版本、平台与复现步骤；能复现的请一并附上「设置 → Debug → 导出日志」的日志，日志在写入前已屏蔽登录凭据。安全问题请用 Security → Report a vulnerability 私下反馈，或在论坛私信站长。

## 构建

```bash
flutter pub get
dart run build_runner build -d   # 生成 mapper 与 i18n
dart run gitsumu                 # 生成版本／变更记录信息
flutter build apk --release      # 需要 android/key.properties 指向你的 keystore
```

Linux 构建需要 `libgtk-3-dev`、`libsqlite3-dev` 与 `libayatana-appindicator3-dev`；测试：`flutter test`。

发布版本：在合并后的 master 上创建发布分支，修改 `pubspec.yaml` 的版本（`x.y.z+N`）、CHANGELOG 新段与三语首页公告 → `dart scripts/write_version_json.dart` → 测试 → 提交并推送发布分支与 `vX.Y.Z` 标签。CI 根据 `.github/workflows/release_build.yml` 构建各平台文件并发布 Release，正文取自 CHANGELOG 对应段落。确认全部平台成功、7 个下载文件齐全后，再将发布提交合入 master，启用 App 版本提示和首页公告。Android 内部版本号：分包为 N×10＋ABI 码（armv7 2、arm64 3），universal 为 N×10＋9。

## 许可

MIT。原作品 Copyright (c) 2023 realth000；修改部分 (C) 2026 Carinoasd。详见 [LICENSE](./LICENSE)。

## 支持开发

本项目免费开源，欢迎自愿赞助，支持客户端的开发与维护。赞助由维护者 Carinoasd 个人收取，非论坛官方募款；是否赞助不影响功能使用。

使用支付宝扫描下方二维码即可赞助，点击图片可查看原图。

<a href="./doc/pic/alipay-donation.jpg"><img src="./doc/pic/alipay-donation.jpg" width="300" alt="支付宝自愿赞助二维码，收款人为维护者 Carinoasd"></a>
