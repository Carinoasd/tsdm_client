<h1 align="center">
    <img src="./assets/images/tsdm_client.svg" width="120px" alt="tsdm_client_logo">
    <br>
    tsdm_client
</h1>

<p align="center">天使动漫论坛官方客户端 · Discuz! X5 版</p>

<p align="center">繁體中文 | <a href="./README.en.md">English</a></p>

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

三個 Android 包可以互相升級：universal 的內部版本號永遠高於同一版的分包，下一版的任何包又高於它。只有在同一版裡從 universal 換回分包會被系統當成降版，需要先移除再裝。

Linux 版需要系統已安裝 `libayatana-appindicator3-1`（Debian／Ubuntu 的套件名，其他發行版為對應的 ayatana-appindicator 套件）。這是系統匣元件的執行期依賴，沒有安裝時程式無法啟動。

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
- 一般投票帖可在 App 內單選／多選投票；提交後以論壇重新讀取的狀態為準，不會自動重複送出
- 首頁「活動總覽」列出論壇首頁活動專區的連結，站內連結在 App 內開

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
- 個人資料頁的「我的成就」與「勳章中心」：查閱成就內容、勳章分類／分頁與取得條件；購買、申請與領取獎勵仍在網頁

### 通知與設定
- 前台／背景輪詢新訊息並發系統通知；被清掉後從通知冷啟動直接進訊息中心
- 設定頁可查看與申請通知權限、忽略電池最佳化（Android）；Debug 區可發測試通知、匯出日誌
- Windows：自動同步到新提醒或私訊時彈出系統通知並播放提示音；點通知會還原視窗並開到訊息中心
- 自動抓取的時間界線以論壇時鐘為準，裝置時鐘不準也不會漏掉提醒與私訊
- 淺色／深色主題，字級縮放，日誌頁跟隨主題

### 平台
- Android（arm64／armv7／universal）、iOS（未簽章側載）、Windows、macOS、Linux；App 內「偵測最新版本」讀取本倉庫的 `version.json`
- Windows：系統匣圖示與右鍵選單（目前帳號、歷史、收藏、管理帳戶、結束程式）；視窗最小化時從選單選頁面會先還原並聚焦視窗

## 已知問題

- 部分 Android 裝置旋轉過場會短暫露黑，旋轉完成後排版正常；這個過場問題暫不處理（#28）。
- 版塊列表拿不到外鏈頭像：App 還沒在別處看過該使用者的頭像時，列表顯示文字圓圈。
- 論壇的成就系統目前沒有內容，「我的成就」只會顯示「暫無成就」。
- iOS 版沒有簽章，需要自行側載，也沒有實機測試。

## 回報問題

到 [Issues](https://github.com/Carinoasd/tsdm_client/issues) 開新議題，附上 App 版本、平台與重現步驟；能重現的請一併附「設定 → Debug → 匯出日誌」的日誌，日誌在寫入前已遮蔽登入憑證。安全性問題請用 Security → Report a vulnerability 私下回報，或在論壇私訊站長。

## 建置

```bash
flutter pub get
dart run build_runner build -d   # 產生 mapper 與 i18n
dart run gitsumu                 # 產生版本／變更紀錄資訊
flutter build apk --release      # 需要 android/key.properties 指向你的 keystore
```

Linux 建置需要 `libgtk-3-dev`、`libsqlite3-dev` 與 `libayatana-appindicator3-dev`；測試：`flutter test`。

發版：改 `pubspec.yaml` 的版本（`x.y.z+N`）與 CHANGELOG 新段 → `dart scripts/write_version_json.dart` → 測試 → 提交並推 master → `git tag -a vX.Y.Z && git push origin vX.Y.Z`，CI 依 `.github/workflows/release_build.yml` 建好各平台檔案並發布 Release，內文取自 CHANGELOG 該段。Android 內部版本號：分包為 N×10＋ABI 碼（armv7 2、arm64 3），universal 為 N×10＋9。

## 授權

MIT。原作品 Copyright (c) 2023 realth000；修改部分 (C) 2026 Carinoasd。詳見 [LICENSE](./LICENSE)。
