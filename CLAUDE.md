# tsdm_client

天使動漫論壇（TSDM，Discuz! X5）的官方 Flutter 客戶端：Android、iOS、Windows、macOS、Linux 同一份程式碼。
論壇沒有官方 API，資料來自兩條路：論壇的 `tsdmapp` 插件（JSON）與網頁本身（HTML）。

## 指令

```bash
git submodule update --init --recursive   # packages/ 底下都是子模組
flutter pub get
dart ./Makefile.dart                      # build_runner（slang、dart_mappable、drift、gitsumu）＋ drift schema 匯出
dart ./scripts/check_strict_analyzing.dart  # CI 的分析：analysis_options.strict.yaml，warning 與 info 都算失敗
flutter test test/regression/<檔案>_test.dart
```

- `dart ./Makefile.dart` 可帶 `build`／`drift`／`gitsumu` 只跑其中一步。改了 i18n、`@MappableClass`、資料表之後都要重跑。
- CI（`.github/workflows/test.yml`）把 `test/` 分成 4 片平行跑：
  `python3 scripts/ci_test_shard.py list 4 <0..3>` 列出一片的檔案，`check 4` 確認每個檔案恰在一片裡；
  `scripts/ci_test_report.py` 彙整報告。Flutter 版本以該檔的 `CI_FLUTTER_VERSION` 為準。
- 全套測試很重，開發時只跑相關檔案，發版前才跑全套。
- 發版流程見 README 的「发布版本」段；`release_build.yml` 由 `vX.Y.Z` 標籤觸發，建完後 `mirror_release.yml` 把資產同步到鏡像。

## 結構

- `lib/features/<功能>/`：`bloc`／`repository`／`models`／`view`／`widgets`，一個功能一個資料夾。
- `lib/features/tsdmapp/`：插件 API 的唯一入口（`tsdmapp_api.dart`、`v4.dart`、`small_form.dart`）。
- `lib/shared/providers/`：`getIt` 註冊的服務（網路、cookie、儲存、圖片快取），由 `providers.dart` 的 `initProviders` 建立。
- `lib/i18n/`：slang 的三語 JSON 與產生檔。
- `packages/`：子模組（BBCode 解析與編輯器、AVIF、系統代理）。
- `test/regression/test_<編號>_<主題>_test.dart`：回歸測試，樣本在 `test/data/` 與 `test/regression/fixtures/`。

## 鐵律

### 插件 JSON 與網頁解析雙軌

- 每個讀取都要有網頁解析這條路。插件沒裝、被關掉、版本太舊、欄位缺少時，退回解析 HTML，行為不能壞。
- 能力以 `status` 回答的旗標為準（`TsdmAppPluginInfo`、`TsdmAppV4.has(...)`），不要拿版本號比大小來決定用不用某個功能。
- `expectedTsdmAppVersion` 是程式對應的插件版本（設定頁顯示用）；`tsdmAppMinimumVersion` 以下的插件整個不用。
- 插件新增欄位時，舊插件的回答（沒有該欄位）必須有測試。

### `packages/` 子模組

- 不隨意修改。能在 App 這一層處理的（輸入正規化、包一層）就在 App 處理。
- 真的要改，改在子模組自己的倉庫，再更新這裡的指標；不要在本倉庫留未提交的子模組改動。

### Drift 資料庫

- 資料表有變動：`schemaVersion` 加一 → 在 `database.dart` 寫 `fromNToN+1` → `dart ./Makefile.dart drift` 產生
  `schema/migration/drift_schema_vN.json`、`schema_versions.dart` 與 `test/data/generated_migrations/` → 補
  `test_002_database_migration_test.dart`。已發布的遷移步驟不再改。
- Android 的背景服務在自己的 isolate 開同一個資料庫檔，更新後兩邊可能同時跑同一步遷移。每一步都要能重跑：
  加欄位前先查 `PRAGMA table_info`，建表與索引用 `IF NOT EXISTS`，遇到「另一條連線剛做完」的錯誤就略過
  （照 `from13To14`、`from14To15` 的寫法）。

### i18n

- 介面文字一律走 slang：`lib/i18n/en.i18n.json`（基準）、`zh-CN.i18n.json`、`zh-TW.i18n.json` 三份同時改，鍵要一致。
- 改完跑 `dart ./Makefile.dart build`；`strings*.g.dart` 是產生檔，不手改。
- README 也是三語（`README.md` 簡體、`README.zh-hant.md`、`README.en.md`），改一份就三份同步。

### 隱私

- 日誌只能經 `talker`（`RedactingTalker`，`lib/utils/redacting_talker.dart`）輸出，不用 `print`／`debugPrint`。
  cookie、密碼、`formhash`、token、email、私人表單內容由 `lib/utils/log_redaction.dart` 遮蔽；新增帶秘密的欄位名時，
  確認它被 `sensitiveNamePattern` 蓋到，並在 `test_028`／`test_960` 補案例。
- 測試樣本一律去識別化後才提交：uid 改成 1000／1001，使用者名改成 Alice／Bob／Carol，`formhash` 改成 `XXXXXXXX`，
  網址改成 `example.com`，頭像路徑去掉真實數字；測試站的站名與位址、真實 cookie 不得出現。push 前 grep 一次。
- `test/` 底下連不到外網（`test/network_guard.dart`），測試只用假的 client 與錄好的樣本。

## 協作

- 從 `origin/master` 開分支，改動走 PR；CHANGELOG 只在發版時寫。
- 程式內的註解與 doc comment 用英文，說明「為什麼」與邊界情況。
- 不加用不到的抽象；先找既有的 helper 與同類功能的寫法再動手。
