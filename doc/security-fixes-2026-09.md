# tsdm_client Discuz! X5 修復版 — 安全修正摘要（2026-09-06，測試版 v18／v19）

狀態：**測試版**。套件名稱 `kzs.th000.tsdm_client` 與 debug 簽章不變，`versionCode` 55 → 56（v18）→ 57（v19，`pubspec.yaml` `1.15.0+57`）。
正式簽章、Keystore 儲存遷移與 release 發佈設定見 `doc/release-signing-proposal.md`（提案，待本輪測試結果後實作）。

## 1. 修正項目（各為獨立提交，建立在 `4a773943` 之上）

| 提交 | 項目 | 內容 | 測試 |
|---|---|---|---|
| `81005b02` | 匯出備份排除登入憑證 | `BackupRepository.exportSanitized`：以另一條唯讀連線 `VACUUM INTO` 取得一致性複本，清除憑證後再 `VACUUM`，回傳位元組；裝置上的資料庫與已登入帳號完全不動。設定頁「匯出資料」改走此路徑並加副標說明。 | test_026 |
| `4c4a712f` | 匯入前驗證、失敗可恢復、保留帳號清單 | `validate`：SQLite 檔頭、`PRAGMA integrity_check`、`user_version` 介於 1 與目前結構版本、必要資料表（settings/cookie/image_cache）與 settings 欄位；`replaceDatabase`：先關閉連線，準備去除憑證與快取路徑紀錄（image_cache、user_avatar）的匯入複本，備份現有檔為 `mainV2.db.bak`，移除殘留 journal，換檔後再驗證，失敗即還原並提示。備份保留 cookie 資料表的帳號列（username/uid），只清空 cookie／password／question_id／answer 欄位並移除登入帳號設定；還原後帳號仍列在帳號管理頁，各自重新登入。 | test_027 |
| `d3d36924`、`bff6fbfa` | 日誌遮蔽 | `redactSensitive`：Cookie／Set-Cookie／Authorization 標頭、Discuz 會話 cookie（`…_auth`／`…_saltkey`／`…_sid`）與 token、formhash（含 `<input name="formhash">`）、密碼、私人表單欄位（message／subject／description／answer…）於 URL 參數、表單主體、Map／JSON 輸出。`RedactingTalker` 在日誌進入前遮蔽（App 內檢視器、日誌檔、匯出日誌一致），日誌檔寫入與兩種匯出再遮蔽一次（舊檔也乾淨）。移除評分頁記錄完整表單、評分 repository 記錄 formhash、回覆 repository 記錄回覆內文、client 建構時列印 cookie provider 的敘述。 | test_028 |
| `27f07a4b` | 快取檔案操作驗證目錄邊界 | `isSafeFileName`／`fileInside`：只接受單一路徑片段且解析後仍在快取目錄內；`getCacheFile` 回 null 時所有呼叫端視為未快取。表情 id 限制 `[A-Za-z0-9_-]`，快取資訊檔含非法 id 視為無效。 | test_029 |
| `eef8908c` | 防採集重新導向限制 | 只在目標為 https 且主機為 `www.tsdm39.com`／`tsdm39.com` 時重送請求；其他目標記錄並直接回傳挑戰頁。 | test_030 |
| `9e426a96` | 站內路由先驗證網址來源 | `parseUrlToRoute` 只把相對網址或論壇主機的 http/https 網址轉成 App 內路由；外站（含 `user@host` 手法、`javascript:`/`data:`）不路由。會自行抓取網址的路由（最新主題、guide）改用 canonical https 主機，`LatestThreadRepository` 拒絕非論壇網址。 | test_031 |
| `dda576cb`、`17bfda66` | 日誌補強（v19） | 通知自動同步只記錄類型與數量，不再印出通知／私訊摘要文字；私訊、聊天訊息、帖子回覆表單解析失敗時只記錄欄位是否存在，不再印出訊息內容或 formhash。來源：早上測試回報附的裝置日誌。 | 既有解析測試 |
| `499032c5` | 帳號切換時請求身分不混用 | `NetClientProvider.build` 把每個 client 綁定建立當時的帳號：`_IdentityGuard` 在送出前與收到回應後檢查，帳號已切換即以 `IdentityChangedException` 丟棄；`_IdentityScopedStorage` 讓 cookie jar 只在綁定帳號仍為當前帳號時讀寫，A 的遲到回應不會寫進 B 的 cookie。切換本身沿用隔離驗證：候選失敗時維持原帳號；登出只刪除當前帳號的列。 | test_032 |

## 2. 驗證結果

### 2.1 離線
- `dart analyze`：只剩原本的 `Makefile.dart` 一則 info。
- `flutter test`：207 通過／1 略過（新增 test_026–032 共 39 個測試）。

### 2.2 線上（測試帳號 A＝Alice、B＝Bob，2026-09-06）
| 檢查 | 結果 |
|---|---|
| 登入 A、登入 B，兩帳號皆存於裝置 | ✅ |
| 切換回 A（隔離驗證後提交） | ✅ 當前與 cookie provider 皆為 A |
| 切換到不存在的帳號 | ✅ `LoginInvalidCredentialException`，維持 A |
| 登入過期：竄改 B 的本機 auth cookie 後切換 | ✅ `SwitchUserNotAuthedException`，維持 A，B 仍列在帳號清單供重新登入 |
| 登出當前帳號 | ✅ 只移除該帳號，另一帳號仍在 |
| 重新登入 A | ✅ |
| 收藏：加入／重複加入／查找／取消 | ✅ |
| 回覆（tid 1264975） | ✅ 取得新 pid |
| 評分（tid 1264975 1 樓，score2 +1） | ✅ 伺服器接受 |
| 日誌：66 筆記錄比對兩帳號的 auth／saltkey 值（6 個）與 formhash | ✅ 0 洩漏，無未遮蔽的 Cookie 標頭 |
| 附註：以伺服器登出模擬過期不成立 | Discuz 的 `_auth` cookie 不因登出失效，App 切換成功屬正確行為 |

## 3. 未驗證項目（需實機或後續）
- 匯出／匯入在 Android 上的檔案選擇器流程與匯入後 `SystemNavigator.pop` 重啟：離線測試覆蓋 repository 與驗證邏輯，UI 流程待測試者確認。
- 請求進行中切換帳號：以單元測試（假網路層）驗證；實機難以穩定重現。
- 舊日誌檔：磁碟上 v18 之前寫入的檔案內容未改寫，只在檢視／匯出時遮蔽，7 天輪替後消失。
- `mainV2.db.bak`：匯入成功後保留一份匯入前的資料庫（含憑證）於 App 私有目錄作為最後保險。
- 快取路徑邊界與表情 id 限制：單元測試；實機以正常瀏覽確認圖片、頭像、表情不受影響。
- 正式簽章、Keystore 遷移、release 設定：僅提案。

(C) 2026 Carinoasd

## 4. v22 調整：匯出資料可選擇帶帳號登入資料（密碼加密）
- 背景：`81005b02` 起備份一律去除 cookie／密碼／登入帳號設定（預設不變）。多帳號多裝置的測試者以備份同步，每台都要重登，
  要求可帶憑證；使用者決定採「安全密碼」驗證並加密。
- 做法：憑證仍從資料表清空，另以使用者輸入的密碼加密後存於備份檔內 `backup_secrets` 表：PBKDF2-HMAC-SHA256（200,000 次，16B salt）
  → AES-256-GCM（12B nonce、16B tag、固定 AAD）。密碼不儲存、不記錄；匯入時密碼錯在動到任何檔案前就拒絕；即時資料庫永遠不含這張表。
- 不變的保證：沒有密碼的匯出與以前完全相同（test_026／027 照舊通過）；日誌只記帳號數，不記內容；備份檔不含任何明文 token（test_038）。
- 殘餘風險：弱密碼可被離線暴力；請測試者用夠長的密碼，備份檔仍應當成敏感檔案保管。

