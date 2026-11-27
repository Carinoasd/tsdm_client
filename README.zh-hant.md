<h1 align="center">
    <img src="./assets/images/tsdm_client.svg" width="120px" alt="tsdm_client_logo">
    <br>
    tsdm_client
</h1>

<p align="center">天使动漫论坛官方客户端 · Discuz! X5 版</p>

<p align="center"><a href="./README.md">简体中文</a> | 繁體中文 | <a href="./README.en.md">English</a></p>

<p align="center">
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/release/Carinoasd/tsdm_client?label=release" alt="release"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/releases"><img src="https://img.shields.io/github/downloads/Carinoasd/tsdm_client/total" alt="download_total"></a>
  <a href="https://github.com/Carinoasd/tsdm_client/actions"><img src="https://img.shields.io/github/actions/workflow/status/Carinoasd/tsdm_client/test.yml?label=test" alt="test_ci"/></a>
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.41-blue?logo=flutter" alt="flutter"/></a>
  <a href="./LICENSE"><img src="https://img.shields.io/github/license/Carinoasd/tsdm_client" alt="license"/></a>
</p>

## 最新更新：1.64.0（2026-11-28）

- 更新頁新增「偵測通道」：自動、愛麗絲盤、GitHub 三選一，連不上其中一邊時可以只用另一邊。
- 更新頁新增「從愛麗絲盤下載」，直接打開對應機型的網盤頁面。
- Android 建置編號為 183，可直接覆蓋之前的正式版與測試版。

[下載 1.64.0](https://github.com/Carinoasd/tsdm_client/releases/tag/v1.64.0) · [完整更新日誌](./CHANGELOG.md)

## 這是什麼

[天使动漫论坛](https://www.tsdm39.com/) 的跨平台客戶端。論壇於 2026 年升級到 Discuz! X5 後，原客戶端無法解析新版頁面；本專案受站方委託接手維護，
適配 X5 的頁面結構並持續加入功能，是站方認可的官方客戶端版本。

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

### 瀏覽與閱讀
- 首頁（論壇統計、導讀、搶沙發、活動總覽）、分區與版塊、主題與樓層；回覆過、看過的主題有標記，看過之後有新回覆會顯示 +N
- 帖內搜尋、跳到樓層、只看某位作者、多頁連續載入；記住讀到哪裡，沉浸式閱讀可依版塊自動開啟
- 網盤連結辨識：帖子裡的百度、藍奏、夸克、阿里等網盤連結下方列出網盤名、提取碼與解壓密碼，點一下即複製
- 帖內音訊附件與網易雲音樂連結可直接播放，換頁不停；Android、iOS、macOS 支援背景播放與通知列控制
- 朗讀帖子（TTS）：從目前樓層逐樓念，可換樓、暫停、調語速（Android、iOS、Windows、macOS）
- 簡繁顯示轉換；內文字級、行距、段距與閱讀寬度可調；省流模式
- 離線保存看過的帖子（預設關閉），收藏夾可批次離線下載
- 匯出整帖為純文字、Markdown 或 PDF；樓層可「分享為圖片」，帖子、版塊與個人資料可產生 QR 碼

### 發帖與互動
- BBCode 編輯器、本機草稿與論壇草稿箱、快速回覆與評分範本
- 回覆、多樓引用、點評、評分、投票、購買、檢舉；輸入 `@` 列出好友與官方 @ 名單
- 「我的圖片」與自訂表情包，表情面板直接選用
- 紅包帖、懸賞、活動、辯論等特殊主題用原生卡片顯示並可直接操作
- 附件在 App 內下載，「下載管理」可重試、開啟、分享

### 收藏與追蹤
- 收藏（帖子／版塊）、淘帖、稍後閱讀、樓層書籤（可附備註）、瀏覽歷史
- 追蹤帖子的新回覆；版塊新帖提醒與關鍵字提醒
- 屏蔽使用者、關鍵字與版塊

### 帳號與資料
- 多帳號切換、自動簽到與每日紅包、登入過期提示與一鍵重新登入
- 跨裝置同步：閱讀進度、常用語與屏蔽列表，另可選草稿、書籤、範本、稍後閱讀、追蹤的帖子、「我的圖片」等
- 備份匯出／匯入（帳號登入資料可用密碼加密）、WebDAV 自動備份與還原
- 應用鎖；登入裝置管理、密碼與安全、隱私設定
- 勳章中心、稱號與稱號商店、成就、積分轉帳與兌換、好友與私訊

### 通知
- App 內與背景同步提醒、私訊，發出系統通知；可同時檢查這台裝置上所有已登入的帳號
- 可分別關閉回覆、@、評分／點評、私訊、系統通知等類別，並可設靜音時段
- Android：背景訊息接收（前景服務常駐）、通知列直接回覆
- Windows：系統通知與提示音，點通知還原視窗並開啟訊息中心

### 論壇服務
- 社區銀行、背景商店、寵物中心、任務與道具等做成 App 內頁面
- 遊戲中心、天使裁判所、CP 系統、打工等在內建瀏覽器以目前帳號開啟

### 版主與管理
- 帖子與樓層管理：置頂、高亮、精華、移動、關閉、刪除、屏蔽、警告、撤銷評分、禁言等，依論壇給的權限顯示
- 版主面板：審核、檢舉處理、回收站、管理日誌；批次評分（論壇裝有該插件時）
- 站方人員：發放勳章、頭銜與背景，積分獎懲，用戶組調整

### 平板與桌面
- 寬螢幕雙欄：左邊列表、右邊帖子，右欄可開多個分頁，欄寬可拖動
- `Ctrl+K` 快速跳轉：輸入 tid、連結、版塊名、帖子標題或使用者名稱直接開啟
- 鍵盤快捷鍵（iPad 接實體鍵盤也可用）、`Ctrl+Enter` 送出、系統匣、關閉到系統匣、老闆鍵

### 平台
- Android（arm64／armv7／universal）、iOS（未簽名側載）、Windows、macOS、Linux
- Android 與 Windows 可在 App 內下載並安裝更新，下載後先核對檔案再安裝
- Android：桌面捷徑、把版塊或帖子「加到桌面」、可切換應用圖示；iOS：桌面小工具與圖示快捷操作

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

發版：從合併後的 master 建立發布分支，修改 `pubspec.yaml` 的版本（`x.y.z+N`）、CHANGELOG 新段與三語首頁公告 → `dart scripts/write_version_json.dart` → 測試 → 提交並推送發布分支與 `vX.Y.Z` 標籤。CI 依 `.github/workflows/release_build.yml` 建好各平台檔案並發布 Release，內文取自 CHANGELOG 該段。確認全部平台成功、7 個下載檔齊全後，再將發布提交合入 master，啟用 App 版本提示和首頁公告。Android 內部版本號：分包為 N×10＋ABI 碼（armv7 2、arm64 3），universal 為 N×10＋9。

## 授權

MIT。原作品 Copyright (c) 2023 realth000；修改部分 (C) 2026 Carinoasd。詳見 [LICENSE](./LICENSE)。

## 支持開發

本專案免費開源，歡迎自願贊助，支持客戶端的開發與維護。贊助由維護者 Carinoasd 個人收取，非論壇官方募款；是否贊助不影響功能使用。

使用支付寶掃描下方 QR Code 即可贊助，點擊圖片可查看原圖。

<a href="./doc/pic/alipay-donation.jpg"><img src="./doc/pic/alipay-donation.jpg" width="300" alt="支付寶自願贊助 QR Code，收款人為維護者 Carinoasd"></a>
