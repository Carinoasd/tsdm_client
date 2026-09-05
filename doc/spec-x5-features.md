# tsdm_client Discuz! X5 修復版 — 功能規格：收藏、好友列表、紅包

分支：`feat/discuz-x5`。對象：天使动漫論壇（Discuz! X5）。本文記錄三個待做功能的論壇端協定、App 端行為與驗收方式，
協定內容皆於 2026-09-05 以測試帳號實際抓取驗證。文中的 `UID`、`TID`、`FAVID` 為佔位符。

優先順序（建議）：1 收藏 → 2 好友列表 → 3 紅包。

---

## 1. 收藏（Favorites）

### 1.1 論壇端協定

**收藏列表** `GET home.php?mod=space&do=favorite&type=thread[&page=N]`

- 容器 `ul#favorite_ul`，每筆 `li#fav_FAVID`：
  - 標題連結 `a[href*="mod=viewthread"]`（`tid` 在網址裡）；
  - 收藏時間 `span.xg1 span[title="YYYY-M-D HH:MM"]`；
  - 備註 `div.quote blockquote#quote_preview`（無備註則沒有這個節點）；
  - 刪除連結 `a[href*="spacecp&ac=favorite&op=delete&favid=FAVID"]`；
  - 勾選框 `input[name="favorite[]"]`，`value` 為 favid，`vid` 屬性為 tid。
- 分頁沿用 Discuz 的 `div.pg`（`a.nxt` 為下一頁）。

**加入收藏** 兩步：
1. `GET home.php?mod=spacecp&ac=favorite&type=thread&id=TID&infloat=yes&handlekey=k_favorite&inajax=1`
   回 XML 包住的表單（取 `formhash`、`referer`）。
2. `POST home.php?mod=spacecp&ac=favorite&type=thread&id=TID&infloat=yes&handlekey=k_favorite&inajax=1&spaceuid=0`
   表單：`favoritesubmit=true`、`referer`、`formhash`、`handlekey=k_favorite`、`description`（備註，可空）。
   - 成功：`succeedhandle_k_favorite('url', '信息收藏成功 ', {'id':'TID','favid':'FAVID'})`
   - 已收藏：`errorhandle_k_favorite('抱歉，您已收藏，请勿重复收藏', {...})` → App 視為已收藏（不當錯誤）。

**取消收藏** 兩步：
1. `GET home.php?mod=spacecp&ac=favorite&op=delete&favid=FAVID&type=thread&infloat=yes&handlekey=favdelete&inajax=1`
   取 `formhash`、`referer`。
2. 同網址 `POST`：`referer`、`deletesubmit=true`、`formhash`、`handlekey=favdelete`。
   成功回 `succeedhandle_favdelete(...)`。

### 1.2 App 端行為

- **收藏列表頁**：入口在個人頁／側欄「我的收藏」。列表卡片顯示標題、收藏時間、備註；點卡片進帖子；左滑或選單「取消收藏」（需確認）。
  下拉刷新、上拉載入下一頁；空列表顯示「還沒有收藏」。
- **帖子頁**：App bar 選單加入「收藏／取消收藏」。收藏時彈出可選的備註輸入框；成功後選單文字切換。
  「已收藏」的錯誤回應視為成功並提示「已在收藏中」。
- 需登入；未登入導向登入頁。
- 收藏狀態不在帖子頁 HTML 裡，App 以「加入時論壇回覆」與本機快取（tid → favid）判斷選單文字；快取以帳號區分。

### 1.3 驗收

- 去識別化 fixture：列表頁、加入對話框、成功／已收藏回應、刪除對話框（樣本已抓）。
- 回歸測試：列表解析（含無備註、分頁）、加入成功／重複、刪除表單參數。
- 測試帳號實測：加入、重複加入、取消各一次。

---

## 2. 好友列表（Friends）— 版面 A「卡片列」

### 2.1 論壇端協定

`GET home.php?mod=space&uid=UID&do=friend[&page=N]`（或 `username=NAME`），自己與別人共用。

- 容器 `ul.buddy`，每位好友 `li.bbda.cl`：
  - 頭像 `div.avt img`（懶載入，網址在 `data-src`；無頭像時為 `./data/avatar/noavatar.svg`）；
  - 用戶名 `h4 > a`（`href` 含 `uid`，`style="color:…"` 為用戶組顏色，可能沒有）；
  - `p.maxh`：`font` 為用戶組名稱（帶顏色）、`img` 為用戶組圖示、文字「积分数: N」；
  - `div.xg1`：互動選單（查看資料、去串個門、打個招呼、發送訊息）、關注TA。App 只用「發送訊息」的 `touid`。
- 每頁 24 人；超過一頁有 `div.pg`。
- 自己的頁面另有分頁籤（全部好友、當前在線的好友、在線成員、我的訪客、我的足跡、我的黑名單）與管理動作
  （加好友、查找、分組），第一版不做。
- 對方把好友列表設為隱私時，回「提示信息」頁；App 顯示該訊息。

### 2.2 App 端行為（版面 A）

- 每位好友一張卡片：44px 圓形頭像；用戶名（套用用戶組顏色）；第二行為「用戶組圖示＋用戶組名稱」標籤與「积分 N」；
  右側「訊息」圖示按鈕直接開與此人的聊天頁。點卡片其他區域進個人頁。
- App bar 標題「好友」，副標「<用戶名> · N 位好友」（N 取自個人頁的好友數）。
- 下拉刷新、上拉載入下一頁；空列表顯示「還沒有好友」。
- 網址分派：`home.php?mod=space&…&do=friend`（`uid=` 或 `username=`）改開此頁；個人頁的好友數按鈕（自己與別人）都走這裡，
  不再丟外部瀏覽器。
- 第一版不做：在線好友／訪客／足跡／黑名單分頁籤、加好友、刪好友、分組。

### 2.3 驗收

- 去識別化 fixture：有好友且有分頁的列表頁（公開頁面樣本已抓）、空列表、隱私提示頁。
- 回歸測試：卡片欄位解析（顏色、組圖示、積分、無頭像）、分頁、隱私訊息。
- 實測需要有好友的帳號：測試帳號目前皆無好友，可讓兩個測試帳號互加一次。

---

## 3. 紅包（hongbao 插件）

### 3.1 論壇端協定（`plugin.php?id=hongbao:`，皆回 JSON，需登入 cookie，不受帖子頁 `_dsign` 影響）

| 端點 | 方法／參數 | 回應 |
|---|---|---|
| `open&tid=TID` | GET | `{ok:true, tid, from, bless, haspw(0/1), cond, appoint, splitmode(1 拼手氣／2 均分), unit, state, is_sender, mine:{claimed, amount, best}}`；無紅包 `{ok:false, error:"這裡沒有紅包"}`；未登入 `{ok:false, need_login:1}` |
| `grab` | POST `tid`、`formhash`、`password`（口令包） | 成功 `{ok:true, amount, iscat, best}`；失敗 `{ok:false, state:"badpw"|"needreply"|"done", error}` |
| `record&tid=TID` | GET | `{ok:true, claimed, shares, unit, recs:[{username, time, amount, isbest}]}`；未開包 `{ok:false, error:"開包後才能看大家的手氣"}` |
| `daily` | POST `formhash` | `{ok:true, amount, unit, redirect}`；已領 `{ok:false, already:1, amount, error:"今天已經領過囉,明天再來"}`；無 formhash `{ok:false, error:"請求已過期,請重新整理頁面"}` |
| `withdraw` | POST `tid`、`formhash` | `{ok:true, refunded}`（發包人限定，App 第一版不做） |

`state` 值：`open`（可領）、`done`（已搶光）、`withdrawn`（已撤回）、`expired`（已過期）、`closed`（已關閉）。

**帖內入口**：1 樓 `div.pct > div.pcb > div.pcbs > div.hb-entry[data-tid]`，子節點 `.t1`（祝福語）、`.t2`（「均分紅包 · 剩 0/25 份 · 已被搶光」）、
`.claimed-mark`；後面跟一段 `<style>`。目前 App 的渲染器對此節點不顯示（`html_muncher.dart` 的 `hb-entry`）。

**每日紅包**：登入後每頁 footer 嵌入
`hongbaoDailyInit({"entry":2,"dateflag":"YYYYMMDD","from":"系統 每日紅包","bless":"…","unit":"天使币"})`；
當天領過就不再輸出。`entry` 為 2 時網頁顯示浮標，1 時自動彈窗。

`formhash` 取自帖子頁既有的回覆參數；首頁亦有（登出連結）。

### 3.2 App 端行為

- **帖內紅包卡片**：取代目前的隱藏。顯示祝福語與第二行狀態；點擊呼叫 `open`：
  - `state=open` 且未領 → 顯示「領取」，口令包顯示口令輸入框；
  - `mine.claimed` → 顯示「已領 N 天使币」（手氣最佳加標記）與「看手氣榜」；
  - 其他狀態 → 顯示對應文字（已搶光／已撤回／已過期／已關閉）與「看手氣榜」（`is_sender` 或已領時才會有資料）。
- **領取**：`grab`；成功顯示金額（`iscat` 為特殊動畫，App 用一般成功提示即可）；`needreply` → 開啟回覆框並提示「需先回帖」；
  `badpw` → 口令錯誤提示留在對話框；`done` → 切換為已搶光。
- **手氣榜**：`record` 列表（用戶名、時間、金額、手氣最佳標記），標題「已領取 claimed/shares 份」。
- **每日紅包**：首頁解析 footer 設定；有設定時在首頁顯示「今日紅包」入口（按鈕），點擊呼叫 `daily`，成功顯示金額後隱藏入口；
  `already` 亦隱藏。是否改為自動彈窗待決定（預設按鈕）。
- 未登入不顯示任何紅包入口。發紅包、撤回不在 App 內。

### 3.3 驗收

- 去識別化 fixture：帖內入口 HTML（已抓）、各端點 JSON 樣本（已抓 open／record／daily 三種）。
- 回歸測試：入口解析、狀態對應、`grab` 錯誤狀態、每日設定解析與「領過即消失」。
- 實測：需要一個可領的測試紅包（由管理員在測試帖 tid 1264975 發一個小額紅包，或給測試帳號一次發包權限）。

---

## 4. 共通規則

- 所有 fixture 去識別化：uid → 1000、用戶名 → Alice/Bob/Carol、formhash → XXXXXXXX、頭像路徑去除真實數字。
- 測試帳號資料只存在本機被 `.gitignore` 排除的檔案，不進 git、fixture、交付檔與文件。
- 每個功能：`dart analyze` 維持既有狀態（僅 Makefile.dart 一個 info）、`flutter test` 全綠、debug APK 交付並更新測試說明。
- 使用者已定案：好友列表採版面 A；帖子頁頂部下拉維持「重新載入回第 1 頁」不改；身分組 @ 不接手機。

---
(C) 2026 Carinoasd
