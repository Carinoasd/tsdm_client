<h1 align="center">
    <img src="./assets/images/tsdm_client.svg" width="120px" alt="tsdm_client_logo">
    <br>
    tsdm_client
</h1>

<p align="center">天使动漫论坛官方客户端 · Discuz! X5 版</p>

<p align="center">
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/release/Carinoasd/tsdm_client?label=release" alt="release"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/downloads/Carinoasd/tsdm_client/total" alt="download_total"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/actions"><img src="https://img.shields.io/github/actions/workflow/status/Carinoasd/tsdm_client/test.yml?label=test" alt="test_ci"/></a>
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.41-blue?logo=flutter" alt="flutter"/></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/Carinoasd/tsdm_client" alt="license"/></a>
</p>

## 這是什麼

[天使动漫论坛](https://www.tsdm39.com/) 的跨平台客戶端。論壇於 2026 年升級到 Discuz! X5 後，原客戶端無法解析新版頁面；本專案受站方委託接手維護，
適配 X5 的頁面結構並持續加入功能，是站方認可的官方客戶端版本。

本專案延續自 [realth000/tsdm_client](https://github.com/realth000/tsdm_client)（MIT），保留其全部歷史與版權聲明；X5 適配與後續開發由 Carinoasd 負責。

## English summary

tsdm_client is the official mobile and desktop client of the 天使动漫 (Angel Anime) forum, a Discuz! X5 community with over two million registered members and several thousand new posts a day. The forum has no public API: the app talks to the same pages a browser does, parses them, and adds what a phone needs on top: multi-account login, check-in, notifications for replies and private messages, favorites, friends, red packets, an offline-friendly BBCode editor, and encrypted backup and restore. Releases for Android, iOS (unsigned), Windows, macOS and Linux are built by GitHub Actions; the in-app update check reads `version.json` from this repository. The project continues [realth000/tsdm_client](https://github.com/realth000/tsdm_client) (MIT) and is maintained by Carinoasd; user feedback arrives through the forum and the issue tracker here.

## 下載

到 [Releases](https://github.com/Carinoasd/tsdm_client/releases/latest) 下載：

| 平台 | 檔案 |
|---|---|
| Android（多數手機） | `tsdm_client-arm64_v8a.apk` |
| Android（舊 32 位元機） | `tsdm_client-armeabi_v7a.apk` |
| Android（不確定機型時用這個，較大） | `tsdm_client-universal.apk` |
| iOS（未簽章，需自行側載） | `tsdm_client.ipa` |
| Windows 10/11（64 位元，解壓即用） | `tsdm_client-windows.zip` |
| macOS | `tsdm_client-universal.dmg` |
| Linux | `tsdm_client-linux.tar.gz` |

不上架任何商店。Android 直接安裝 APK；App 內「偵測最新版本」讀取本倉庫的 `version.json`，「更新日誌」與 Releases 同步。

套件名為 `com.tsdm.tsdm_client`，使用論壇官方的簽章金鑰，可與原作者發布的舊版（`kzs.th000.tsdm_client`）並存。從舊版搬過來：舊版「設定 → 匯出資料」勾選帳號資料並設定密碼 → 安裝本版 → 「匯入資料」輸入同一密碼 → 移除舊版。

## 主要功能

### 瀏覽與互動
- 首頁：論壇統計、導讀四模組（最新熱門／最新精華／最新回覆／最新發表）與「搶沙發」入口，每個模組可進完整列表
- 分區頁：各分區的版塊列表、分區版主；「我收藏的版塊」自動跟著網頁端的收藏出現
- 版塊與主題：主題列表、樓層、點評、評分、購買、附件、折疊區、@ 提及、回覆過的主題有「已回覆」標記
- 版塊頁可「收藏本版／取消收藏本版」；收藏頁分「帖子」「版塊」兩個標籤
- 主題頁可「分享給好友」：從自己的好友列表選人，把標題與連結以私訊送出
- 提醒、私訊、聊天、公共訊息；提醒裡的純文字網址可點；好友請求提醒會正常列出

### 發帖與回覆
- BBCode 編輯器、快速回覆模板、草稿
- 輸入 `@` 自動彈出提醒選單，列出自己的好友與官方 @ 名單，可即時篩選
- 「我的圖片」：把圖片網址或圖床代碼存在本機，表情面板一鍵插入；帖內圖片長按可直接存入
- 桌面版 Ctrl+Enter／Alt+Enter 直接送出

### 帳號
- 多帳號切換；自動簽到（逐帳號、限流時自動重試）；管理帳號頁顯示每個帳號今日是否簽到
- 一鍵同步所有帳號的提醒與私訊，進度頁逐帳號顯示結果
- 登入過期提示：帳號失效時標示並可一鍵重新登入；啟動時提醒有幾個帳號過期
- 帳號多選刪除、當前帳號「從本機移除」，不必聯網
- 備份匯出／匯入（可選擇以密碼加密帳號登入資料，多裝置同步不必逐個重登）
- 好友列表、送出好友請求；紅包領取與每日紅包

### 通知與設定
- 前台／背景輪詢新訊息並發系統通知；被清掉後從通知冷啟動直接進訊息中心
- 設定頁可查看與申請通知權限、忽略電池最佳化（Android）；Debug 區可發測試通知、匯出日誌
- 淺色／深色主題，字級縮放，日誌頁跟隨主題

### 平台
- Android（arm64／armv7／universal）、iOS（未簽章側載）、Windows、macOS、Linux；App 內「偵測最新版本」讀取本倉庫的 `version.json`

## 建置

```bash
flutter pub get
dart run build_runner build -d   # 產生 mapper 與 i18n
dart run gitsumu                 # 產生版本／變更紀錄資訊
flutter build apk --release      # 需要 android/key.properties 指向你的 keystore
```

測試：`flutter test`。發布流程見 `.github/workflows/release_build.yml`。

## 授權

MIT。原作品 Copyright (c) 2023 realth000；修改部分 (C) 2026 Carinoasd。詳見 [LICENSE](./LICENSE)。
