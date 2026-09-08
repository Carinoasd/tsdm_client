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

- 論壇瀏覽：版塊、主題、樓層、點評、評分、購買、附件、折疊區、@ 提及
- 發帖與回覆：BBCode 編輯器、快速回覆模板、草稿
- 通知、私訊、聊天、簽到（多帳號）、收藏、好友、紅包
- 多帳號切換；備份匯出／匯入（可選擇以密碼加密帳號登入資料）
- Android / iOS / Linux / macOS / Windows

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
