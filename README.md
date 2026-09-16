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

## 这是什么

[天使动漫论坛](https://www.tsdm39.com/) 的跨平台客户端。论坛于 2026 年升级到 Discuz! X5 后，原客户端无法解析新版页面；本项目受站方委托接手维护，
适配 X5 的页面结构并持续加入功能，是站方认可的官方客户端版本。

本项目延续自 [realth000/tsdm_client](https://github.com/realth000/tsdm_client)（MIT），保留其全部历史与版权声明；X5 适配与后续开发由 Carinoasd 负责。

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

### 浏览与互动
- 首页：论坛统计、导读四模块（最新热门／最新精华／最新回复／最新发表）与「抢沙发」入口，每个模块可进入完整列表
- 分区页：各分区的版块列表、分区版主；「我收藏的版块」自动跟随网页端的收藏显示
- 版块与主题：主题列表、楼层、点评、评分、购买、附件、折叠区、@ 提及、回复过的主题有「已回复」标记
- 版块页可「收藏本版／取消收藏本版」；收藏页分「帖子」「版块」两个标签
- 主题页可「分享给好友」：从自己的好友列表选人，把标题与链接以私信发出
- 提醒、私信、聊天、公共消息；提醒里的纯文本网址可点击；好友请求提醒会正常列出
- 普通投票帖可在 App 内单选／多选投票；提交后以论坛重新读取的状态为准，不会自动重复发送
- 首页「活动总览」列出论坛首页活动专区的链接，站内链接在 App 内打开

### 发帖与回复
- BBCode 编辑器、快速回复模板、草稿
- 输入 `@` 自动弹出提醒菜单，列出自己的好友与官方 @ 名单，可实时筛选
- 「我的图片」：把图片网址或图床代码保存在本机，表情面板一键插入；帖内图片长按可直接保存
- 桌面版 Ctrl+Enter／Alt+Enter 直接发送

### 账号
- 多账号切换；自动签到（逐账号、限流时自动重试）；管理账号页显示每个账号今日是否签到
- 一键同步所有账号的提醒与私信，进度页逐账号显示结果
- 登录过期提示：账号失效时标记并可一键重新登录；启动时提醒有几个账号过期
- 账号多选删除、当前账号「从本机移除」，不必联网
- 备份导出／导入（可选择以密码加密账号登录数据，多设备同步不必逐个重新登录）
- 好友列表、发送好友请求；红包领取与每日红包
- 个人资料页的「我的成就」与「勋章中心」：查阅成就内容、勋章分类／分页与获取条件；购买、申请与领取奖励仍在网页端进行

### 通知与设置
- 前台／后台轮询新消息并发送系统通知；应用被清理后从通知冷启动可直接进入消息中心
- 设置页可查看与申请通知权限、忽略电池优化（Android）；Debug 区可发送测试通知、导出日志
- Windows：自动同步到新提醒或私信时弹出系统通知并播放提示音；点击通知会还原窗口并打开消息中心
- 自动拉取的时间边界以论坛时钟为准，设备时钟不准也不会漏掉提醒与私信
- 浅色／深色主题，字号缩放，日志页跟随主题

### 平台
- Android（arm64／armv7／universal）、iOS（未签名侧载）、Windows、macOS、Linux；App 内「检测最新版本」读取本仓库的 `version.json`
- Windows：系统托盘图标与右键菜单（当前账号、历史、收藏、管理账户、退出程序）；窗口最小化时从菜单选择页面会先还原并聚焦窗口

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

发布版本：修改 `pubspec.yaml` 的版本（`x.y.z+N`）与 CHANGELOG 新段 → `dart scripts/write_version_json.dart` → 测试 → 提交并推送 master → `git tag -a vX.Y.Z && git push origin vX.Y.Z`，CI 根据 `.github/workflows/release_build.yml` 构建各平台文件并发布 Release，正文取自 CHANGELOG 对应段落。Android 内部版本号：分包为 N×10＋ABI 码（armv7 2、arm64 3），universal 为 N×10＋9。

## 许可

MIT。原作品 Copyright (c) 2023 realth000；修改部分 (C) 2026 Carinoasd。详见 [LICENSE](./LICENSE)。
