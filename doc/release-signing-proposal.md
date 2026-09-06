# tsdm_client Discuz! X5 修復版 — Keystore 儲存、正式簽章與發佈設定方案（提案，尚未實作）

狀態：提案。目前仍是測試階段（v18 起），APK 沿用 debug 簽章與套件名稱 `kzs.th000.tsdm_client`，每次交付提高 `versionCode`。
以下方案待本輪測試結果確認後再實作。

## 1. 現況

- `android/app/build.gradle` 的 `signingConfigs.release` 讀取 `keystoreProperties`（`key.properties`），檔案不存在時 `storeFile` 為 null，
  **release build 直接失敗**（`SigningConfig "release" is missing required property "storeFile"`，2026-09-06 實測）——不會退回 debug 簽章，
  3.2 要求的「缺 keystore 就失敗」已經成立，gradle 不必改。要用 debug 金鑰出 release 模式的預覽版時，臨時放一個指向 `~/.android/debug.keystore`
  的 `key.properties`（`android`/`androiddebugkey`/`android`），建完刪掉。
- 測試 APK 一律 `flutter build apk --debug`，測試者靠同一把 debug 憑證覆蓋安裝。
- `versionCode` 來自 `pubspec.yaml` 的 `version: x.y.z+N`；分 ABI 建置時 gradle 以 `N*10 + abi` 覆寫。

## 2. 目標

1. 正式簽章金鑰與密碼不進 git、不放在建置機的 repo 目錄內，也不進任何交付檔。
2. 本機（WSL，無 sudo）與日後 CI 都能用同一套設定建 release。
3. 測試者可從 debug 簽章的測試版平順過渡到正式版（簽章不同無法覆蓋安裝，需說明重裝一次）。

## 3. 方案

### 3.1 金鑰產生與保存

- 用 JDK 的 `keytool` 產生 PKCS12 keystore（RSA 2048 以上、有效期 25 年以上），別名建議 `tsdm_client_x5`。
- 保存位置：建置機 `~/.tsdm_client_keys/upload.jks`（權限 600），另外離線備份一份（密碼管理器＋加密硬碟）。
  金鑰遺失即無法再更新既有安裝，備份是必要項。
- 密碥不寫在任何檔案內容裡，由 `key.properties`（放 `~/.tsdm_client_keys/`，不放 repo）或環境變數提供：
  ```
  storeFile=/home/<user>/.tsdm_client_keys/upload.jks
  storePassword=<…>
  keyAlias=tsdm_client_x5
  keyPassword=<…>
  ```
- `android/key.properties` 已在 `.gitignore`？需確認；若無則加入，並在 gradle 改為讀取 `TSDM_KEY_PROPERTIES` 環境變數指定的路徑，
  預設 `android/key.properties`。

### 3.2 gradle 調整（實作時）

- `signingConfigs.release` 缺少任何一項時直接讓建置失敗並印出提示，而不是靜默退回 debug 簽章。
- `buildTypes.release` 啟用 `minifyEnabled`/`shrinkResources` 前先確認 `proguard` 規則涵蓋 drift、dio、flutter_avif 等套件；先以不混淆版本驗證。
- 保留 `abiFilters arm64-v8a`（現行），universal 另建。

### 3.3 版本號規則

- `pubspec.yaml`：`1.15.0+N`，每次對外交付（含測試版）N 加 1；正式版時同步提高 `x.y.z`。
- 分 ABI APK 由 gradle 覆寫為 `N*10 + abi`，維持不變。

### 3.4 CI（可選，之後）

- GitHub Actions：keystore 以 base64 放 repository secret，建置時解回 `~/.tsdm_client_keys/upload.jks`；密碼以 secret 注入環境變數。
- 產物：release arm64 與 universal APK、SHA-256 清單、變更摘要。iOS 需 macOS runner 與 Apple 憑證，另案。

### 3.5 測試者過渡

- 正式簽章第一版需先移除 debug 簽章的測試版再安裝（資料會清空；提醒先用「匯出資料」備份，匯入後重新登入各帳號）。
- 之後的正式版可覆蓋安裝。

## 4. 待決定

- 金鑰持有人與備份地點。
- 是否啟用混淆（影響除錯堆疊）。
- 是否同時發佈到 F-Droid 類通道（版本號規則已相容 `abiCodes`）。

(C) 2026 Carinoasd
