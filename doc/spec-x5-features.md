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

## 5. 實作狀態（2026-09-06）

三個功能皆已實作於 `feat/discuz-x5`，以測試帳號實測通過；與上文規格的差異或補充如下。

### 5.1 收藏

- 程式：`lib/features/favorite/`（列表頁 `FavoritePage`、`FavoriteRepository`、`FavoriteBloc`）；帖子頁 App bar 選單新增
  「收藏／取消收藏」（`thread_favorite_action.dart`）；首頁頭像選單新增「收藏」入口；`home.php?mod=space&do=favorite`
  網址改在 App 內開啟。
- 實測發現：對「已收藏」的帖子再按收藏，論壇在**第一步取表單時**就直接回 `errorhandle_k_favorite('抱歉，您已收藏…')`，
  沒有表單；取消一個已不存在的收藏也是在取表單時回 `抱歉，您指定的收藏不存在`。App 對這兩種情況都直接解析對話框內容：
  前者視為已收藏（提示「已在收藏中」並掃描列表補上 favid），後者視為已取消。
- 收藏狀態快取為 App 執行期間的記憶體快取（uid → tid → favid），由列表頁與成功加入時填入；重新啟動 App 後，
  帖子頁選單會先顯示「收藏」，按下後若論壇回已收藏則自動補上狀態並改顯示「取消收藏」。未持久化到資料庫。

### 5.2 好友列表（版面 A）

- 程式：`lib/features/friend/`；網址 `home.php?mod=space&uid=…&do=friend`／`username=…`／不帶參數（自己）皆開此頁；
  個人頁好友數按鈕不再丟瀏覽器。
- 自己的頁面在沒有好友時會列出「在線成員」推薦（`li#friend_UID_li`，無 `bbda` class），App 只取 `li.bbda`，不會誤當好友。
- 隱私限制頁（`div.nfl h2.xs2` 的「抱歉！由于 … 的隐私设置，您不能访问当前内容」）直接顯示原文。
- 好友卡片右側「訊息」按鈕開聊天頁（帶 uid 與用戶名）；點卡片進個人頁。

### 5.3 紅包

- 程式：`lib/features/red_packet/`；帖內 `div.hb-entry` 改為紅包卡片（`RedPacketCard`），點擊開對話框呼叫 `open`，
  依狀態顯示領取按鈕（口令包有口令欄）／已領金額／看手氣榜；`grab` 的 `needreply`、`badpw`、`done` 各有提示。
- 帖內同時發現插件的彈窗骨架 `div#hb_mask`（含「開」「撤回 剩餘」「已存入你的帳戶」「看看大家的手氣 ›」「手 氣 爆 發 !」等文字）
  也在 1 樓 `div.pcbs` 內，先前會被當純文字渲染出來；現已一併隱藏。
- 每日紅包：首頁解析 footer 的 `hongbaoDailyInit({...})` 與登出連結中的 `formhash`，有設定時在首頁 App bar 顯示「今日紅包」
  按鈕（採規格預設的按鈕方案，非自動彈窗）；領取成功或「今天已經領過」後按鈕隱藏。
- `formhash` 錯誤或缺失時論壇回 Discuz! System Error 的 HTML 頁（非 JSON），App 視為一般失敗。
- 2026-09-06 以管理員發的測試紅包（tid 1265042，拼手氣 10 份）實測補充，皆已處理：
  - 可領的入口標記也帶著 `.claimed-mark`（`style="display:none"`，文字「點擊領取」），只有 `hb-entry` 上的 `claimed` class 才代表已領；
    `.t2` 為「拼手氣紅包 · 剩 10/10 份 · 點擊領取」。
  - 領取成功後 `open` 的 `state` 是 **`claimed`**（不是 `open`），`mine` 帶 `claimed/amount/best`；App 新增此狀態，顯示「已領取」。
  - 重複呼叫 `grab` 回 `{ok:true, amount, unit, iscat:false, best, already:true}`，App 依 `already` 顯示「已領取 N」而非「獲得 N」。
  - `record` 的 `time` 為短格式「9-6 03:45」，`isbest` 只標在手氣最佳者。

## 6. 第二輪測試回饋修正（2026-09-06，v20）

### 6.1 未讀紅點時有時無、讀完不消

測試者回報回覆私訊或通知後紅點不消、過一陣子又出現。追查後是同步與標記兩條路徑上的多個問題，已一併修正
（`lib/features/notification/bloc/notification_bloc.dart`、`auto_notification_cubit.dart`、`lib/widgets/card/notice_card_v2.dart`、
`lib/utils/html/html_muncher.dart`、聊天兩頁）：

- 標記已讀時若該項不在 bloc 狀態裡，通知直接放棄、私訊／公共訊息則丟出 RangeError，標記從未寫進資料庫。狀態在同步成功前
  是空的，而聊天頁隨時可從個人頁、好友卡開啟。現在標記一律寫入資料庫（紅點的真實來源），並在每次標記後從資料庫重算未讀數
  發佈到全域狀態；卡片自行 ±1 的暫時值只作即時回饋。
- 私訊、公共訊息重抓時直接用伺服器旗標覆寫（公共訊息甚至一律存成未讀），每逢重新列出最近三天（上次抓取超過三天）就把讀過的
  又變回未讀。現在三類都像通知一樣與本機已存副本對帳：私訊「時間相同且最後一句相同」時兩邊任一方已讀即已讀，較新或內容不同
  才視為新訊息；公共訊息已存者沿用本機旗標。
- 抓取範圍從「上次時間 +1 秒」起算，但論壇的通知時間只有到分：同一分鐘內稍後到達的訊息永遠不會被抓到，於是首頁表頭的未讀提示
  說有、列表卻沒有，紅點閃現又消失。現改為含頭尾（≥）且自動同步記錄的是開始「那一分鐘」；重抓到的舊副本經對帳不會重複，
  也只有真正新到的項目才觸發推播（自己的回覆永不觸發）。
- 卡片在開啟的頁面「彈回來之後」才記錄已讀，若那時卡片已不在畫面（列表刷新、已離開通知頁）標記就丟了；`onUrlLaunched` 也是
  等推入的頁面 pop 才回呼。兩者都改在導頁前記錄。
- 聊天記錄頁與私聊頁開啟即把該對話標為已讀，不管從哪裡進來。
- 同步失敗時發佈資料庫裡的未讀數，首頭表頭提示不會在失敗後殘留。

實測補充：X5 的私訊列表未讀標記確為 `dl#pmlist_UID` 內的 `div.newpm_avt`（`dl` 帶 `newpm` class），時間為 `span[title="2026-9-5 17:38"]`（到分）。
回歸測試 `test/regression/test_033_notification_read_state_test.dart`（對帳函式、標記寫入與重算、同步對帳）。

### 6.2 「檢索該用戶的帖子」搜不到東西

- 個人頁按鈕原本只帶 uid 開搜尋表單，且要自己按搜尋；論壇搜尋接受的是搜尋表單本身送出的作者名稱欄 `srchuname`，
  只給 `srchuid` 找不到東西。現在個人頁同時帶名稱與 uid，搜尋頁開啟即以作者搜尋（關鍵字可空）；作者欄改為「uid 或使用者名稱」
  （純數字視為 uid，其餘為名稱，兩者都送出），關鍵字有作者或版面時可空。查詢組裝抽成 `buildSearchQuery`，
  回歸測試 `test_034_search_author_test.dart`。
- 不採用「開啟該用戶的主題列表」：`home.php?mod=space&uid=U&do=thread&view=me&type=thread`（含 `&from=space`）在本論壇對其他人
  一律回「还没有相关的帖子」，即使對方有八百多篇主題。
- **未能實機驗證伺服器行為**：`search.php` 目前對本機回 Cloudflare 挑戰頁（HTTP 403，瀏覽器 UA 與 App 網路層皆同），
  `srchuname` 搭配空關鍵字的結果需由測試者確認。畫面已以無頭渲染確認（作者帶入、自動搜尋、無結果、收合表單三態）。

### 6.3 聊天送出後鍵盤不收起

- 聊天記錄頁與私聊頁在送出成功時先顯示 snackbar 再 `context.pop()` 關編輯器；測試者日誌顯示 snackbar 在 debug 版觸發 Flutter
  的 ScaffoldMessenger 斷言（某個 Scaffold 正在拆除），例外讓 `pop()` 沒執行，編輯器與鍵盤就留著。而且 sheet 已不在時再 pop
  會把整頁關掉（帖子頁先前同樣的問題）。現改為經 `ReplyBarController.closeEditor()` 關編輯器、取消焦點，最後才顯示 snackbar；
  `showSnackBar` 遇到該斷言改在下一幀重試而不是丟出。

### 6.4 本輪驗證

- `dart analyze`：只剩既有的 `Makefile.dart` document_ignores 提示；`flutter test`：220 通過／1 略過。
- 無頭渲染（手機尺寸 1080×2340@3，正體中文）：搜尋頁「從個人頁開啟自動搜尋出結果」「無結果」「收合表單」三態。
- 現場：以測試帳號抓取私訊列表確認 X5 未讀標記；聊天送出流程與紅點行為需實機回報。

## 7. 第三輪：郵件連結與自動簽到（2026-09-06，v21）

### 7.1 `[email=]` 變成 Cloudflare 保護頁

- 論壇在 Cloudflare 之後，頁面裡所有電子郵件都被「Email Address Obfuscation」改寫：`mailto:` 連結變成
  `/cdn-cgi/l/email-protection#HASH`，連結文字或內文中的地址變成 `<span class="__cf_email__" data-cfemail="HASH">[email&#160;protected]</span>`
  （純文字地址則是同樣屬性的 `<a>`）。App 點下去以瀏覧器開 Cloudflare 提示頁。三種寫法的實際樣本在
  `test/data/email_protection_post_x5.html`（2026-09-06 以測試帳號發在測試帖 tid 1264975，地址皆為 example.com）。
- 解法（`lib/utils/html/cloudflare_email.dart`）：與瀏覽器端腳本相同的 XOR 還原，`munchElement` 進場先把節點改回 `mailto:` 連結
  與可讀地址。解出的文字必須符合 email 格式才採用，否則原樣保留；由它產生的只有 `mailto:地址`，不帶任何參數。
- 點地址不直接跳出：先開底部面板顯示地址，提供「複製地址」「用郵件 App 開啟」（`showEmailBottomSheet`）；長按同樣開這個面板。
- 順手修正：連結訊息面板的「複製連結」原本會先開啟該連結再複製。
- 回歸測試 `test_035_cloudflare_email_test.dart`（真實 hash、任意 key 往返、畸形 hash、非地址內容一律拒絕、DOM 改寫、muncher 渲染）。

### 7.2 自動簽到「签了好几次才签完」

- 日誌顯示：11 個帳號分成每批 4 個同時簽到、批次之間不停，論壇對第一批 POST 回「您需要先登录才能继续本操作」，接著回 HTTP 429；
  失敗的帳號不會記「今天已簽」，下次啟動再跑又只過幾個。另外「您需要先登录」的 XML 回應 App 認不出，整段當錯誤訊息顯示。
- 修正（`auto_checkin_repository.dart`、`do_checkin.dart`、`parse_checkin.dart`）：帳號逐一簽到、之間停 2 秒；遇 429 等 30／60／60 秒
  重試同一帳號最多 3 次，伺服器給 `Retry-After` 且更長時照它（上限 5 分）；簽到頁若是登入表單（`form#lsform` 且無 `div#um`）
  直接判定登入過期、不送 POST；回應含「需要先登录」也判為登入過期。429 不再記成錯誤，訊息改為「論壇限制了請求頻率」。
- 回歸測試 `test_036_auto_checkin_throttle_test.dart`（逐一執行順序、429 重試、重試用盡、Retry-After、登入表單、需要先登录）。

### 7.3 本輪驗證

- `dart analyze` 只剩既有提示；`flutter test` 全數通過（見交付說明的數字）。
- 無頭渲染：含三種郵件寫法的帖子內容、郵件地址面板。
- 現場：測試帖新增一則含 `[email=]`、`[email]`、純文字地址的回覆並抓回頁面，確認 Cloudflare 改寫形式；簽到限流行為需實機（多帳號）回報。

---
(C) 2026 Carinoasd

## 8. v22（1.17.0+60）：折疊標籤、編輯器巢狀修正、帶密碼的帳號資料備份

### 8.1 折疊標籤 `[spoiler]`（測試者回報「折叠标签不行」）
- 論壇端：X5 **仍支援** `[spoiler=標題]…[/spoiler]`，但輸出的 HTML 改了 class 名：
  `div.spoiler > div.spoilerheader > input.spoilerbutton[value=標題]`＋提示文字「（點擊展開 / 收起）」、
  `div.spoilerbody > table > td > 內容`（舊論壇是 `spoiler_control` / `spoiler_btn` / `spoiler_content`）。
- App：`html_muncher.dart` 的 `_buildSpoiler` 只認舊 class，找不到就放棄，X5 上所有折疊都變平文字。改為兩代 selector 都接受，並把
  `table>td` 單格包裝剝掉再 munch，折疊卡只含內容。舊結構仍可用。
- fixture `test/data/spoiler_post_x5.html`：2026-09-06 用測試帳號在測試帖發的回覆（pid 洗成 1000），A 為正確巢狀、B 為編輯器上色後的錯誤巢狀，
  皆為論壇實際輸出。test_037 驗證兩者都成卡、舊結構仍成卡。

### 8.2 編輯器把折疊頭標記寫壞（測試者那帖真正的原因）
- 現象：論壇裡存的是兩個 `[/spoiler]`、沒有開頭標記；論壇對未配對的關閉標籤原樣輸出，App 與網頁都顯示黑字 `[/spoiler]`。
- 機制（往返探針證實）：編輯器把 `[spoiler]`/`[hide]`/`[free]` 當頭尾兩個標記，對含標記的範圍上色時匯出成
  `[color=#0cc][spoiler=X][/color]…[color=#0cc][/spoiler][/color]`（論壇容忍、仍會折疊）。但這段文字再進 `parseBBCodeTextToDelta`
  （編輯帖子、匯入 BBCode、從模板插入都走它）時，**被樣式標籤單獨包住的頭標記會被解析成尾標記**：`heads=0, tails=2`。
  純文字路徑（`initialText`、`setDocumentFromRawText`）不解析 BBCode，不受影響。
- 根因在上游子模組 `dart_bbcode_parser`／`flutter_bbcode_editor`，本分支不動子模組；改在 App 邊界修：
  `lib/utils/bbcode/spoiler_normalizer.dart` 的 `normalizeBlockMarkerNesting` 把「只包著一個頭或尾標記」的樣式標籤
  （color/size/font/backcolor/b/i/u/s，可多層、含空白、不分大小寫）剝掉，其他文字不動、可重複套用。
- 掛載點——進：`post_edit_page`（解析器與純文字兩支）、toolbar 匯入 BBCode、`insertBBCode`×2（模板插入）、`initialText`×3；
  出：`BBCodeEditorController.toForumBBCode()`（`lib/extensions/bbcode_editor_controller.dart`）取代 App 內全部 10 處 `toBBCode()`，
  送論壇、存模板、複製／匯出的 BBCode 都是乾淨巢狀。
- 已壞掉的帖子不會自己好：內容在伺服器端已是兩個 `[/spoiler]`，需重新編輯（開頭 `[spoiler=…]` 放在顏色標籤外）。

### 8.3 匯出資料可帶帳號登入資料（密碼加密）
- 需求：多帳號、多裝置的測試者以備份同步，v18 起備份一律去除憑證後每台都要重登。使用者決定採「安全密碼」方案並加密。
- 格式：仍是單一 SQLite 檔。有密碼時 `cookie` 表四欄（`cookie`/`password`/`question_id`/`answer`）與 `loginUid`/`loginUsername`/`loginEmail`
  設定照樣清空，另存進一張 **`backup_secrets`** 表（單列 `id=1`）：`version=1`、`kdf='pbkdf2-hmac-sha256'`、`iterations`、
  `salt`(16B)、`nonce`(12B)、`mac`(16B)、`ciphertext`。明文為 JSON `{version, accounts:[{uid, username, cookie, password,
  question_id, answer}], login_settings:{…}}`，只收有 cookie 或密碼的帳號。
- 加密：PBKDF2-HMAC-SHA256（預設 200,000 次，成本寫在檔內、匯入照檔內值）→ AES-256-GCM，AAD 固定 `tsdm_client.backup_secrets.v1`。
  套件 `cryptography` 2.9.0（純 Dart）。密碼不存、不寫檔、不進日誌；salt/nonce 每次隨機。
- 匯出（`BackupRepository.exportSanitized(file, secretsPassword:)`）：`VACUUM INTO` 快照 → 讀憑證 → 清空 → 寫加密表 → `VACUUM`。
  即時資料庫不動。檔名 `tsdm_client_data_<ts>_accounts.db`。
- 匯入：`validate` → 若檔內有表則 `unlockSecrets(file, password:)`（唯讀、只解密；密碼錯拋 `BackupSecretsPasswordException`，
  **在關閉資料庫或搬動任何檔案之前**，可重試或略過；版本/演算法不認得 → `unsupported`）→ `replaceDatabase(…, secrets:)`
  在匯入副本清空後套回憑證與登入設定，**一律 `DROP TABLE backup_secrets`**（即時資料庫永遠沒有這張表）→ `VACUUM` → 換檔 → 驗證。
- UI：匯出對話框（開關「包含帳號登入資料」＋密碼、確認密碼，至少 8 字元）；匯入時偵測到表跳「還原帳號登入資料」對話框
  （可略過、密碼錯顯示錯誤重試）；成功訊息區分有無還原帳號。i18n en/zh-CN/zh-TW。
- v22.1（1.17.1+61）裝置回報修正：解鎖對話框在檔案選擇器關閉的瞬間被外圍觸控關掉→靜默略過帳號資料；匯出對話框鍵盤彈出時溢出 20px。
  兩個對話框改為 `barrierDismissible: false`＋`PopScope(canPop: false)`（只能按按鈕）、`AlertDialog(scrollable: true)`；PBKDF2 以 `Isolate.run` 離開 UI isolate。test_039。
- 限制：安全性取決於密碼強度（離線暴力只受 KDF 成本限制）；純 Dart PBKDF2 200k 在手機約 1 秒；不同裝置的 App 版本須都認得 `version=1`。
- 測試 test_038（KDF 1,000 次以加速）：檔內無明文 token／密碼、表與參數正確、密碼對可解、錯拒絕、新版本報 unsupported、
  匯入還原＋表已刪、不解鎖則全部登出＋表已刪。

### 8.4 v21 測試回饋（兩位）
- 全過：email 連結三種形式、面板／複製／開郵件 App；帖內連結、回覆、評分、收藏、私訊。第二位另回報折疊標籤（→ 8.1/8.2），email 已可。
- 通知條目要點「查看」才跳轉：上游原本行為，使用者決定不改。
- 待測：多帳號簽到集中一次跑、網頁登出後「登入已過期」提示（兩位都略過）；紅包未標記。

## 9. v22.2（1.17.2+63）：順暢度

測試者回報「不是加載慢、是幀數低、畫面不流暢」。兩層原因：

### 9.1 建置模式（最主要）
交付的一直是 debug build（JIT、assert、除錯服務、右上角 DEBUG 標）。release build 是 AOT 原生機器碼，差距通常 3–5 倍。
本機 `flutter build apk --release` 在沒有 `key.properties` 時會直接失敗（不會退回 debug 簽章，見 release-signing-proposal §1），
預覽版的做法是臨時放一個指向 `~/.android/debug.keystore` 的 `key.properties`（建完刪除），出「release 模式＋測試簽章」的 APK，
測試者可覆蓋安裝直接比較。注意 `--split-per-abi` 會覆寫 `app-release.apk`（變成 arm64 那份），universal 要單獨建、先複製。
release 版大小：universal 60MB／arm64 30MB（debug 142MB／106MB）。

### 9.2 程式碼（靜態掃描找到、與量測無關的確定問題）
- **HTML 每次 build 重新解析**：`PostCard._buildPostBody`、`NoticeCardV2`（三種卡）、`ChatMessageCard` 都在 `build()` 裡
  `parseHtmlDocument`＋`munchElement`；PostCard 又是 `AutomaticKeepAlive`，頁面任何重建（紅點、回覆列、鍵盤）都讓所有存活樓層重解析。
  新增 `lib/widgets/munched_html.dart` `MunchedHtml`：解析結果快取在 State，只在 html／主題／字級／語言變動時重做
  （`didChangeDependencies` 讀 `Theme.of`、`MediaQuery.textScalerOf`、`Localizations.maybeLocaleOf` 註冊依賴）。
  `MunchOptions` 的 callback 取第一次 build 的，callback 內必須透過 State 讀即時狀態（通知卡 `_onUrlLaunched` 是這樣寫的）。
  主題切換動畫期間每幀 ThemeData 都不同 → 每幀重做一次，與原本行為相同（不劣化）。
- **樓層列表** `post_list.dart` 每項包 `RepaintBoundary`：捲動時移動圖層而不是重繪每張卡。
- **圖片解碼尺寸**：`CachedImage` 用 `ResizeImage.resizeIfNeeded(decodeWidthFor(...))` 把解碼寬度限制在
  min(要求寬, maxWidth, 螢幕寬)×dpr（`allowUpscaling` 預設 false）；`CachedImageProvider.loadImage` 走 `decode` callback 所以生效。
  看圖器 `image_detail_page` 直接用 `PhotoView(CachedImageProvider)`，不受影響（縮放需要全解析度）；`boundDecodeToDisplay` 可關。
- 不動：`_holdTimer`（100ms×最多 20 次、有 cancel）；通知 cubit 的 1 秒 timer 只比時間。
- test_040：父層重建保留同一份 spans；html／主題／字級變動則重做；`decodeWidthFor` 邊界。
- **基準（2026-09-06，`flutter test` 於 WSL2 桌機 CPU、JIT、無 GPU；30 個樓層、每層平均 6.5KB 真實 X5 HTML、去掉 `<img>`）**：
  頁面重建一次的 UI thread 成本——改前 9.2 ms（JIT 冷 14.1 ms），改後 1.5 ms（冷 2.0 ms），**約 6–7 倍**；首次建置 22 ms → 16 ms。
  換算：中階手機單核約慢桌機 3–6 倍，改前一次重建約 30–80 ms＝掉 2–5 幀（60Hz 每幀 16.7 ms），改後 5–12 ms 在預算內。
  此基準不含圖片與 PostCard 外框成本，也量不到真機 fps；真機數據需測試者比較或 `--profile`＋DevTools。

### 9.3 還沒做、要量測才知道
若 release 預覽版仍不順，請測試者說明**哪個頁面、什麼操作**（捲樓層？首頁？通知？開圖？），再用 `--profile` build＋DevTools timeline 找；
可考慮在偵錯選項加「效能疊層」開關讓測試者截圖幀時間。

## 10. v22.3（1.17.3+64）：自己的好友列表、加好友

### 10.1 自己的好友列表顯示為空（測試者 52 位好友卻「还没有好友」）
- 同一個 `home.php?mod=space&uid=U&do=friend` 有兩種版面，**由「誰在看」決定，跟 `view=me` 參數無關**（自己的 uid 不帶 `view=me` 也是自己版面）：
  - 看別人：`p.tbmu` 總數 ＋ `ul.buddy > li.bbda`（`h4 > a` 名字、`p.maxh` 群組名＋圖示＋積分、`div.pg` 分頁）。
  - 看自己：`ul.buddy > li#friend_UID_li`，`h4` 第一個連結是「热度」（`spacecp&ac=friend&op=changenum`），名字連結在後；群組**圖示**在 `h4`、`p.maxh` 空；
    有「管理」選單（`op=changegroup`／`op=editnote`／`op=ignore` 刪除）；`p.tbmu` 有總數。
  - 自己且**沒有好友**：同樣的 `li#friend_UID_li` 形狀列出「在线成员」推薦（`h2.mtw`），每項帶「加为好友」（`ac=friend&op=add`）連結——不是好友。
- 舊解析器只認 `li.bbda`，且 `h4 > a` 會抓到「热度」。改為：走訪所有 `ul.buddy`，收 `li.bbda` 與「`friend_*_li` 且沒有加好友連結」的項目；名字取 `h4 a` 中 href 含 `mod=space&`＋`uid=` 且不含 `spacecp` 者；群組圖示 `p.maxh img ?? h4 img`。
- fixture `friend_list_own_x5.html`：2026-09-06 用測試帳號 A（1000）看自己、好友 B（1001）——為此先由 A 送請求、B 登入同意。test_041；原 test_024 全部照過。

### 10.2 加好友（測試者要求）
- 協定（皆 `inajax=1`，回 XML 包 CDATA）：
  - GET `home.php?mod=spacecp&ac=friend&op=add&uid=U&handlekey=addfriendhk_U` → 表單：`formhash`、`referer`、`addsubmit=true`、`handlekey`、`note`（附言，「最多 10 个字」）、
    `select[name=gid]`（0 其他／1 通过本站认识（預選）／2 通过活动认识／3 通过朋友认识／4 亲人／5 同事／6 同学／7 不认识）。
    已是好友／請求待驗證／加自己時**GET 就直接回** `errorhandle_addfriendhk_U('你们已成为好友'｜'正在等待验证'｜'抱歉，您不能加自己为好友')`。
  - POST 同網址（不帶 handlekey 也可）：成功回 `succeedhandle_addfriendhk_U('url', '好友请求已发送，请等待对方验证', {})`＋`showDialog(..., 'notice')`。
  - 對方同意：`op=add&uid=請求者&handlekey=afrfriendhk_自己` 的表單用 **`add2submit=true`**＋`gid`（radio），成功 `succeedhandle_afrfriendhk_*('…', '您已和X成为好友')`。
    待驗證清單在 `home.php?mod=spacecp&ac=friend&op=request`（批准全部 `op=addconfirm&key=`）。**App 這版只做「送出請求」**，同意流程 fixture 已存（`friend_accept_*_x5.xml`），之後可做。
- App：個人頁（看別人）動作列加「加好友」→ 先 GET 表單（被拒就直接以 snackbar 顯示論壇訊息）→ 對話框（附言 ≤10 字、分組下拉、預選論壇給的）→ POST → snackbar 顯示論壇回覆。
  `FriendRepository.fetchAddFriendForm／addFriend`、`parse_add_friend.dart`、`add_friend_dialog.dart`。i18n `friendPage.addFriend`。
- fixture 皆去識別化（uid 1000/1001、Alice/Bob、example.com、XXXXXXXX）。

## 11. v1.18.0（1.18.0+65）：官方發布——套件名、簽章、檢查更新

- **套件名** `com.tsdm.tsdm_client`（iOS `com.tsdm.tsdmClient`）。上游 `kzs.th000.tsdm_client` 由原作者金鑰簽章，拿不到金鑰就無法就地升級，因此改名讓新舊版並存，使用者以 v22 的加密備份搬帳號。Android `namespace`／Kotlin 套件路徑與 MethodChannel 名稱維持 `kzs.th000.tsdm_client`：它們只是程式內部識別，改了沒有好處。
- **簽章**：論壇官方金鑰（見 doc/release-signing-proposal.md 頂部）。debug 金鑰的測試版（v20–v22.3）與本版套件名不同，測試者需先匯出、裝新版、匯入、再移除測試版。
- **檢查更新**：上游 `UpdateCubit` 讀的是原作者論壇帖（`ptid=1233425&pid=75311834`）裡的 JSON，官方版無法維護那篇帖子。改為讀取本倉庫 `version.json`（`upgradeVersionInfoUrl`），格式與 `LatestVersionInfo` 相同；`scripts/write_version_json.dart` 從 pubspec 與 CHANGELOG 對應版本段產生，`test_042` 保證檔案與 pubspec 一致。解析函式 `parseLatestVersionInfo` 接受字串／已解碼 Map／位元組，其他一律 `FormatException`，被 Cloudflare 擋下回傳 HTML 時只會顯示「檢查失敗」而不會崩潰。
- **更新頁**：F-Droid 提示改為說明正式版來源；「公告帖」連結維持上游 tid=628244，待官方公告帖建立後再改。


## 12. 收藏版塊（GitHub #1、#2，2026-09-09）

### 12.1 論壇端協定（測試帳號實抓，fixture 已去識別化：uid 1000／Alice／XXXXXXXX）
- **首頁收藏面板** `forum.php`：有收藏版塊的會員多出**第一個**分區 `div.bm.bmw.flg.cl`（class 多一個 `flg`、有雙空格，既有選擇器 `div.bm.bmw.cl` 照樣命中），
  標題 `div.bm_h > h2 > a[href="home.php?mod=space&do=favorite&type=forum"]`「我收藏的版块」（一般分區的 h2 連到 `forum.php?gid=N`、bm_h 另有 `span.y` 分区版主），
  內容 `div#category_0.bm_c > table.fl_tb`，每個收藏版塊一列展開式 `tr`（與一般分區相同），尾端一個空的 `tr.fl_row`。沒有收藏時整個面板不存在。
  fixture：`forum_index_x5.html`／`forum_index_nofav_x5.html`。
- **列表** `GET home.php?mod=space&do=favorite&type=forum`：與帖子列表同形，`ul#favorite_ul > li#fav_FAVID`，標題連結 `a[href*="mod=forumdisplay"]`，
  勾選框 `vid` 為 fid，時間 `span.xg1 span[title]`；沒有備註就沒有 `div.quote`。空列表：`p.emp`「您还没有添加任何收藏」、沒有 `ul#favorite_ul`（不是需登入）。
- **加入／取消**與帖子完全同一條路徑，只差 `type=forum`：`GET …ac=favorite&type=forum&id=FID&infloat=yes&handlekey=K&inajax=1` 取表單，
  `POST …&spaceuid=0`（`favoritesubmit`、`referer`、`formhash`、`handlekey`、`description`）；刪除 `op=delete&favid=FAVID`（`type` 可省，App 仍送）。
  **handlekey 由客戶端決定、伺服器原樣回音**：網頁用 `favoriteforum`／`a_delete_FAVID`，回 `succeedhandle_favoriteforum(...)`／`errorhandle_favoriteforum('抱歉，您已收藏…')`；
  App 沿用 `k_favorite`／`favdelete`。解析器改為只認 `succeedhandle_<任意>(`／`errorhandle_<任意>(`。已收藏時同樣在 GET 那步就回錯誤、沒有表單。

### 12.2 App 端行為
- **#1 首頁分區不更新／刷新報錯**：`ForumHomeRepository` 多了 `documentStream`（BehaviorSubject）＋`dispose`，每次抓到 `forum.php` 都廣播；
  `TopicsBloc` 訂閱它（首頁在登入／切換帳號後強制刷新的文件直接重新解析，不多發請求）、訂閱 `AuthenticationRepository.status`
  （登出→靜默重抓訪客首頁；使用者變更但 5 秒內沒有新文件→自己補抓一次）、訂閱 `FavoriteRepository.forumFavoritesChanged`（收藏／取消版塊後靜默重抓）。
  靜默刷新不切到 loading、失敗時保留原分區。`TopicsBloc` 只信任頁首使用者節點（`div#um strong.vwmy a`，與登入解析共用 `parseLoggedUserFromDocument`）等於目前使用者的文件：
  切換帳號／登出後快取與 stream 重播仍是上一個帳號的頁面時，不顯示、不灌收藏快取，改強制重抓一次；每次登入狀態轉換（`TopicsBloc`、`HomepageBloc` 皆）都會 `invalidate()` 共用快取。
  版塊頁「已在收藏中」但列表查到紀錄、或取消時列表已無紀錄，這兩種只改本機已知狀態的結果也經 `FavoriteRepository.notifyForumFavoritesChanged()` 觸發分區頁靜默重抓。
  `TopicsPage` 在分區數改變時重建 `TabController`（釋放舊的、保存的分頁索引夾到範圍內、改用 `TickerProviderStateMixin`），
  原本 `??=` 固定長度導致「Controller's length property (N) does not match the number of tabs (N+1)」；順帶去掉 dispose 裡的重複釋放。收藏面板沿用論壇自己的標題「我收藏的版块」，不另作置頂或改名。
- **#2 收藏版塊**：`FavoriteType {thread, forum}`；模型 `FavoriteItem`（sealed）→ `FavoriteThread`／`FavoriteForum`；`FavoriteRepository`
  `addForumFavorite`／`removeFavorite(type:)`／`findForumFavid`／`fetchListPageOf(type)`，快取改為 type → uid → id → favid（版塊可為 null＝「知道已收藏但不知 favid」），
  `seedForumFavorites` 由分區頁的收藏面板灌入（整組取代、保留已知 favid）。版塊頁 App bar 選單「收藏本版／取消收藏本版」（備註對話框標題改可設定；取消時沒有 favid 就先掃列表補上）。
  收藏頁分成「帖子／版块」兩個分頁（各自一個 `FavoriteBloc(type:)`），路由 `/favorite?type=forum`，`home.php?mod=space&do=favorite&type=forum` 連結直接開版塊分頁。
- 測試：test_043（面板解析、TopicsBloc 三種觸發、TopicsPage 2→3→2 個分頁無例外且索引夾住；把 `_syncTabController` 退回舊行為可重現原錯誤）、
  test_044（版塊列表／空列表／對話框／任意 handlekey、GET→POST 參數、已收藏不 POST、刪除、findForumFavid、seed、網址辨識）。test_023 原樣全過。

- 1.19.1：分區頁解析後記錄分區名、收藏版塊 fid 與「頁面裡是否有收藏面板連結」（`forum index parsed:` 一行），單看日誌即可分辨「論壇沒渲染」與「解析失手」。登入者辨識加上「默认毛坯」風格的 `div.block_name` 名字連結，並以每頁都有的 `discuz_uid` 腳本變數作 uid 後備（`parseLoggedUidFromDocument`）。「我收藏的版块」分頁第一次出現時自動選取它（原本沿用先前的分頁索引，新分頁可能在可捲動分頁列的畫面外）；TabBarView 以控制器為 key 重建，避免舊頁面位置把新控制器的索引拖回去。

- **1.19.2 真因**：Discuz `forum_index.php` 有 `if($_G['uid'] && empty($_G['cookie']['nofavfid']))`：某 session 第一次列首頁時帳號沒有收藏版塊，伺服器種 `<prefix>_nofavfid=1`（一年），之後該 session 一律不輸出「我收藏的版块」；只有在同一 session 收藏才會清掉。App 的 session 在網頁收藏後因此永遠看不到面板，重新登入（新 session）才正常——測試帳號實測重現。修法：`_DropServerFlagCookies` 攔截器在 CookieManager 之前把 `Set-Cookie` 的 `*_nofavfid` 丟掉；`stripServerFlagCookies` 在 CookieProvider 載入／寫入時清掉舊資料裡的旗標（test_058）。

## 13. 自動簽到提示列、各帳號今日簽到狀態、刪除帳號（GitHub #4、#9、#6，2026-09-09）

### 13.1 論壇端事實
- 沒有新協定。簽到協定見 §7.2；「今天是否已簽到」App 端只用本機資料判定：`Cookie.lastCheckin`（每帳號一欄，簽到成功或論壇回「已經簽到」時寫入），不向論壇探測（每帳號一個請求且會 429，決定不做）。
- 登出：`GET home.php?mod=spacecp` 若已不見登入者節點（`div#um p strong.vwmy a`／`div#inner_stat > strong > a`）＝論壇端 session 已失效，沒有東西可登出。

### 13.2 App 端行為
- **#4 提示列兩行**：Flutter `SnackBar` 在「動作＋關閉鈕」寬度超過提示列 25%（`actionOverflowThreshold`）時把動作移到第二行；「查看详情」＋關閉鈕在 360dp 手機約 27%，於是變兩行。改為不放關閉鈕（下滑、點動作、4 秒逾時都能關），`showSnackBar` 新增 `actionOverflowThreshold` 透傳、App 層傳 0.6。test_045 在 320×640、字級 1.5 驗證單行且無關閉鈕。`RootSingleton` 裡的重複監聽器是死碼，未動。
- **#9 各帳號簽到狀態**：`isCheckedInToday(last, now:)`（`lib/features/checkin/utils/checkin_day.dart`）＝裝置本地同一日曆日；`AutoCheckinBloc` 的略過判定改用同一函式（原本 `now.day > last.day` 逐欄比較）。
  `StorageProvider.allUsersWithTimeStream()`（drift `watchAll`，`updateLastCheckinTime` 後會重發）；管理帳號頁每列副標題：uid、圖示＋「今日已簽到／今日未簽到」，
  若本次啟動的自動簽到對該帳號失敗（且不是「已經簽到」）再多一行 `CheckinResult.message`（例如登入已失效、429）；「在线」chip 仍在 trailing。
  `AutoCheckinRepository._updateSuccess` 原本建了 `VoidTask` 沒 `run()`，寫入實際上沒發生；現在每個帳號成功（或「已經簽到」）後由 repository 當下寫入，bloc 收尾不再整批重寫（整批結束時間跨日會把早簽到的帳號標成隔天已簽到）。
  限制：本機日曆日與論壇 UTC+8 換日可能差幾小時；備份還原或從未在本機簽到的帳號 `lastCheckin` 為 null，顯示「未簽到」直到第一次簽到。
- **#6 刪除帳號**：
  - 管理帳號頁新增 `ManageAccountBloc`（`selecting`、`selectedUids`、`status idle/deleting/deleted/failed`、`deletedCount`）：長按帳號或 App bar「選擇」進入選取模式，點按切換、App bar 顯示數量、全選、刪除；關閉鈕／返回鍵離開選取模式（`PopScope`）。
    刪除前 `showQuestionDialog(dangerous)`，訊息說明只刪本機登入記錄、不向論壇登出；包含目前帳號時加註「本機將退出登入狀態」。完成後 snackbar 顯示刪除數量並離開選取模式。
  - 非目前帳號：`StorageProvider.deleteCookiesByUids`（先清 `_cookieCache`、一個 transaction，stream 只發一次）；目前帳號：`AuthenticationRepository.forgetCurrentUser()`（清 CookieProvider、刪列、`_markUnauthenticated`，不連網）。
    「目前帳號」取 `AuthenticationRepository.effectiveCurrentUid`（`currentUser` → 全域 `CookieProvider.userLoginInfo.uid` → settings `loginUid`），離線啟動或 session 已過期、`currentUser` 仍為 null 時，在線 chip 與刪除路徑仍把它當目前帳號；刪除中忽略返回鍵的清除選取，選取快照在第一個 await 之前取得。
  - 單帳號對話框：原「清除登录记录」改名為「刪除帳號」（i18n `switchAccount.dialog.deleteAccount`），加確認與 snackbar；目前帳號多一個「從本機移除」（`forgetCurrentUser`），與連網「退出登入」並列。
  - `logout()`：論壇回訪客頁（有 `form#lsform`、無 `div#um`，與簽到／通知同一規則）時也清 CookieProvider、刪列再 `_markUnauthenticated`（原本只標記、列留著，帳號卡在「在线」無法刪除）；其他認不出的 200 頁（維護頁、攔截頁）只 `_markUnauthenticated`、列保留；改走可注入的 `currentUserClientFactory`（預設仍是 `NetClientProvider.build(userLoginInfo:)`），離線可測。
  - 復活防護：`CookieProvider` 記住自己是否由 `loadCookieFromStorage` 或 `CookieProvider.build()` 載入（`_mirrorsStoredRow`）；是的話 `_syncCookie` 在 `getCookieByUidSync(uid) == null`（列已被刪）時不再 upsert，避免自動簽到進行中收到 Set-Cookie 把剛刪的帳號寫回。`updateUserInfo`（登入取得身分）與 `clearUserInfoAndCookie` 會重設旗標，登入建列不受影響。
- 測試：test_045（#4）、test_046（同日判定邊界、stream 重發、repository 立即寫入、bloc＋頁面顯示已簽到／未簽到／失敗原因）、test_047（批次刪除、`forgetCurrentUser`、訪客頁 `logout()` 刪列、Set-Cookie 不復活但登入仍建列、頁面長按→計數→刪除→確認→列消失、全選／關閉／返回）。

## 14. 通知權限與電池最佳化（GitHub #13、#3，2026-09-09）

### 14.1 平台端事實（Android，不涉及論壇協定）
- `targetSdk 36`：Android 13+ 的 `POST_NOTIFICATIONS` 是執行期權限，未取得前 `NotificationManager.notify` 是**無聲的 no-op**——flutter_local_notifications 的 `show()` 不檢查、不拋錯、不記 log。連續拒絕兩次後系統不再彈框（permanently denied），只能到 App 設定頁手動開。
- 原本只在 `main.dart` 開機時、且當時 `autoSyncNoticeSeconds > 0` 才呼叫一次 `requestNotificationsPermission()`，結果丟棄不記；在設定頁把自動同步從「從不」改成有值時不會再問。App 內沒有任何地方顯示或重讀權限狀態。
- 「忽略電池最佳化」對話框（`Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`）：permission_handler 只在 merged manifest 含 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 時才會啟動，否則直接回 `denied`。此權限 Google Play 列為受限，App 走 GitHub release 不受影響。
- 背景模型：自動同步是 UI isolate 裡的 `Timer.periodic`，返回鍵只 `moveTaskToBack`，沒有 WorkManager／AlarmManager／前景服務。Android 12+ 的 cached-app freezer（16 更積極）與各廠牌省電管理會在離開前景後不久凍結進程，計時器就停了；忽略電池最佳化只解除 Doze／App Standby 一類限制，**不阻止凍結、也不等於廠牌的自啟動／背景限制開關**。不承諾背景推播可靠。

### 14.2 讀 log 時的判定
- `fetched notification since …: notice=N pm=N bm=N`（`NotificationRepository`）數的是 since 視窗（最多 3 天）內的**全部**項目，不是新項目；有這行只證明抓取跑了。
- 推播要 `freshNotifications(fetched, stored)` 非空才會走到 `NotificationInfoRepository.updateAutoSyncInfo`，那裡才有 `update auto sync info: NotificationAutoSyncInfo… notice=… pm=… bm=…`——**這行才代表嘗試推播**；沒有它＝沒有新東西，屬設計行為（§6.1）。
- 新增兩行：開機 `boot notification permission granted=true/false/null`（null＝平台 plugin 未解析）；每次推播前 `push local notification enabled=true/false: NotificationAutoSyncInfoXxx`（`areNotificationsEnabled()`），`show()` 例外改由 `talker.handle` 記錄。有 `update auto sync info` 又有 `enabled=false`＝被權限／系統擋下。

### 14.3 App 端行為
- Manifest 明寫 `POST_NOTIFICATIONS`（原本只靠 plugin manifest 合併）與 `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`（#3 的前提）。
- `AndroidPermissionCubit`（`lib/features/settings/bloc/`）：state `{notification, ignoreBattery}`（`PermissionStatus?`，null＝尚未讀）；`refresh()`、`requestNotification({openSettingsWhenPermanentlyDenied})`（永久拒絕→`openAppSettings()`，否則 `Permission.notification.request()`；request 回 denied 且 `shouldShowRequestRationale` 為 false＝系統沒彈也不會再彈框——Android < 13、兩次都在開機提示拒絕、系統設定關掉通知——此後一律視為永久拒絕，state 直接發 `permanentlyDenied` 並在 refresh 時維持，直到讀到 granted；`isClosed` 後不再 emit）、`requestIgnoreBattery()`（`Permission.ignoreBatteryOptimizations.request()`）。`enabled` 預設 `isAndroid`，非 Android 全部 no-op；透過 `AndroidPermissionGateway` 注入假的 permission_handler 以便在 Linux 測試（`permission_handler_platform_interface` 是間接依賴，`depend_on_referenced_packages: error` 禁止直接 import）。
- 設定頁持有該 cubit（`BlocProvider.value`），`initState` 讀一次，`WidgetsBindingObserver` 在 `resumed` 時重讀，從系統對話框／App 設定頁回來列即更新。
- 行為區「自動同步訊息」之後（Android 才顯示）兩列 `AndroidPermissionTiles`：「通知權限」trailing 已允許／未允許／已永久拒絕（永久拒絕時先 `showQuestionDialog` 說明再跳 App 設定頁；未允許時先 request，若 cubit 因此翻成永久拒絕，同一輪點按接著出說明框再跳設定頁）；「忽略電池最佳化」trailing 已忽略／未忽略，副標題明說只在 App 留在背景時有幫助、廠牌開關另計、不保證背景推播。
- 設定頁把自動同步設為 >0 時同時 `requestNotification(openSettingsWhenPermanentlyDenied: false)`：會彈系統框就彈，永久拒絕只記 log 不跳頁（旁邊那列會顯示狀態）。
- Debug 區新增「發送測試通知」（Android）：以合成的 `NotificationAutoSyncInfoNotice` 呼叫 `showLocalNotification`，用來分辨「系統擋掉」與「沒有新訊息」。
- `showLocalNotification` 移到 `lib/features/local_notice/show.dart`（App 層與 Debug 鈕共用）；`home_page.dart` 裡從未被呼叫的複本刪除。
- 通知 channel 換成 `newNoticeChannelV2`（`Importance.high`／`Priority.high`，`buildLocalNotificationDetails` 純函式組出 `NotificationDetails`，小圖示照舊用 `initialize` 給的）：測試者的華為機 `notify()` 成功卻看不到任何東西，而原 channel `newNoticeChannel` 是以預設 importance 建立、Android 不允許程式碼事後調高，只能換 id。舊 id 保留為 `legacyLocalNoticeChannelId`，開機 `flnp.initialize` 之後（Android）呼叫 `deleteNotificationChannel` 刪掉，try/catch 記 log 不擋開機；每次推播前多記 `id=0 channel=newNoticeChannelV2`。
- 冷啟動（GitHub #14 後半）：App 沒在跑時點通知，`onDidReceiveNotificationResponse` 不會被叫，開機改讀 `getNotificationAppLaunchDetails()`，`didNotificationLaunchApp` 且 payload 為 `openNotification` 時先存進 `stream.dart` 的 pending 槽，`HomePage` 第一幀後（`addPostFrameCallback`）用與 stream 事件相同的處理函式（同樣需已登入）消費一次，落到 `/notice`；取走即清空，頁面重建不會再推第二次。
- 測試：test_053（channel 常數不同、`NotificationDetails` 用新 id 與 high importance／priority）、test_054（pending payload 只被處理一次、handler 丟例外也清空）。
- 點通知只到首頁（GitHub #14，1.21.1 日誌）：`RootPage` 從不送 `RootLocationEventLeave`，位置堆疊只增不減，離開過 `/notice` 之後 `isIn(notice)` 永遠為真，回到首頁點通知被記成 `do not push to notice page already in it`（日誌 18:56:33、19:04:20 兩次）。修法兩層：`RootPage.dispose` 補送 Leave（shell 三頁除外，cubit 對非頂端路徑刪最後一筆，1.21.1 已含）；`HomePage` 的判斷改問 router（`tap.dart` 的 `routerTopLocation` 取 `currentConfiguration.lastOrNull?.matchedLocation`，會走進 shell、`pushNamed` 的頁回自己、對話框不算頁），`decideLocalNoticeTap` 純函式決定 needLogin／alreadyOnNoticePage／openNoticePage。診斷：`onLocalNotificationOpened` 記 `local notification tapped: id type payload listened`（沒這行＝點擊沒到 Dart）、`App` 記 `app lifecycle: resumed/paused/…`、resumed 時記 `auto sync notification in shade: true/false`（`getActiveNotifications`）、handler 記 `notification tap: action top location`；原本三句 `push to notice page`／`do not push…`／`refuse to push…` 保留。日誌裡另有幾次「resume 之後 1 秒內手動進 /notice、沒有任何 handler 行」的情況無法分辨是沒點還是系統沒送 intent；新日誌能縮小範圍但不能完全判定：有 `local notification tapped`＝點擊到了 App；沒有這行且 `in shade: true`＝沒點；沒有這行且 `in shade: false`＝使用者清掉了通知或點擊沒送到，兩者日誌分不出，要靠回報者描述操作。測試：test_073（決策函式、callback 進 stream、真 GoRouter：shell 分支／pushNamed／pop 回首頁／對話框之下）。
- 測試：test_048（manifest 含兩個權限字串；cubit refresh／denied→request／permanentlyDenied→openAppSettings／不跳頁模式／denied+rationale=false→permanentlyDenied+openAppSettings 且 refresh 後維持／首次真拒絕 rationale=true 不跳頁／plugin 自己回 permanentlyDenied 不再多跳／close 後 refresh 不 emit／battery request／disabled no-op；兩列 tile 顯示已允許／未允許／已永久拒絕／已忽略／未忽略、點按觸發 request、永久拒絕先出對話框取消不跳、確定才 openAppSettings）。

## 15. 編輯器打 `@` 彈出提醒選單、選單列自己的好友（GitHub #8，2026-09-09）

### 15.1 論壇端事實
- 官方 `@` 名單：`GET misc.php?mod=getatuser&inajax=1` → `<root><![CDATA[Alice,Bob]]></root>`，只有名字、逗號分隔（§既有 `parseAtUserList`）。測試帳號（梦幻组，「允许 @ 的人数」＝0）拿到**空名單**，而測試者有 52 位好友——名單是否被身分組設定閘住無法離線驗證，所以 App **不依賴它**。
- 自己的好友：`home.php?mod=space&uid=SELF&do=friend`（§10.1 的自己版面），24 位一頁、`div.pg > a.nxt` 下一頁；有 uid／頭像／群組；隱私或要求登入時是 `div.nfl h2.xs2`／`div#messagelogin`。
- 送出格式不變：編輯器 chip `[@]name[/@]` → 發帖前 `toOfficialMentions` → 官方 `@name `（§既有）；身分組 allowat＝0 的帳號送出去仍是純文字、對方不會收到通知，App 無法改變。
- 沒有做：站上的 `plugin.php?id=atgroup` 身分組 @（使用者定案不接手機）。

### 15.2 App 端行為
- `MentionRepository`（`lib/features/editor/repository/`）：同時抓自己的好友列表（`FriendRepository.listUrl(uid: selfUid)`，最多跟 5 頁、依 uid 去重；第 1 頁隱私／登入提示 → `friendsMessage`，後面某頁失敗保留已抓到的）與 getatuser；`loadCandidates({selfUid, force})` 回 `{friends: List<Friend>, others: List<String>（不在好友裡的名字，不分大小寫）, friendsMessage}`，**一邊失敗不算整體失敗**，兩邊都失敗（或未登入且 getatuser 失敗）才 Left。未登入（`selfUid == null`）只抓 getatuser。結果依 uid 快取在實例內，只有兩邊都成功才快取；`mention_picker.dart` 持有一個全 App 共用實例，所以重開選單不重抓，選單的重新整理鈕 `force: true`。getatuser 名單是每個帳號各自的（未登入為空），實例另記它是為哪個 uid 抓的，換帳號／登出後再開一律重抓，不會把上一個帳號的名單拿給下一個看；cubit `load()` 等待期間表被關掉就不再 emit。
- `UserMentionCubit` 改為本地篩選：`load({force})`、`setKeyword()`；state `{recommendStatus, friends, others, keyword, friendsMessage}` ＋ `visibleFriends／visibleOthers／hasExactMatch`；換關鍵字不碰網路。舊的 `searchUserByName／randomFriend／formHash` 全刪（`EditorRepository.searchUserByName` 保留給 repository 內部與 test_022）。
- 選單 `showMentionPicker`（`mention_picker.dart`）：`showCustomBottomSheet` 底部表，取代舊的 `CustomAlertDialog`；搜尋欄（150 ms debounce，Enter 直接用輸入的字）、「好友」區（頭像＋名字＋群組，右側開個人頁；載入中／失敗／`friendsUnavailable(message)`／`noFriends`／`noMatch`）、「其他 @ 名單」區、以及關鍵字沒有**完全相同**的候選時的「提醒 “關鍵字”」列（任何使用者名稱都還能打）。`showUsernamePickerDialog` 變成薄轉呼叫，工具列 `@` 鈕與點既有 chip（帶原名字進搜尋欄）都走同一張表；舊對話框刪除。
- 打 `@` 觸發 `MentionTrigger`（`lib/features/editor/utils/mention_trigger.dart`）：flutter_quill 的 `characterShortcutEvents` 只吃實體鍵盤，所以改監聽 controller（`addListener`，換整份文件也還活著）。文件長度**恰好 +1** 才排 250 ms 計時；只改選取範圍不動計時器、長度變其他數字取消。到時再檢查：可編輯、編輯器有焦點、游標收合且前一字是 `@`、`@` 在文首或前面是空白（`a@b` 不觸發、貼上不觸發、250 ms 內接著打字不打斷）。選到名字：`replaceText(at, 1, '')` 刪掉 `@` 再 `insertMention(name)`（`BBCodeEditorControllerForum.insertMention`＝直接把 `bbcodeUserMention` embed 寫進 delta（同工具列 `@` 鈕，不經 BBCode 解析器，所以 `[TSDM]Alice`、`a]b`、`x[y` 這類名字也完整成一個 chip；`toOfficialMentions` 的正則同樣允許名字帶方括號）＋游標移到 chip 後）；取消保留 `@`。`RichEditor` 改成 StatefulWidget，有 focusNode 且非唯讀就掛 trigger，表關掉後 `requestFocus()` 把鍵盤叫回來；三個編輯器（回覆列、發帖／編輯、快速回覆範本）都自動得到。沒有設定開關（先不做）。
- i18n `bbcodeEditor.userMention.{filterHint, others, useTyped(name), friendsUnavailable(message)}`。
- 測試 test_049：repository 合併（自己版面 fixture、翻頁去重、getatuser 500 仍有好友且不快取、好友列表 500 仍有名單、隱私 fixture → message、未登入只抓 getatuser、雙失敗才 Left）；cubit 篩選不碰網路；MentionTrigger 在真 controller 上（文首／空白後觸發一次且 offset 正確、`a@b`／多字元／無焦點不觸發、取消保留 `@`、debounce 內續打不打斷、`toForumBBCode()=='hi [@]Alice[/@]'`、`toOfficialMentions`→`'hi @Alice '`、換文件後仍有效）；底部表 widget 測試（Bob 在好友區、點了回 'Bob'、關鍵字 zz 出「提醒 “zz”」、`showMentionPicker` 無登入也能開）。手機 IME 實機行為無法在此驗證。

## 16. 一鍵同步所有帳號的通知（GitHub #10，2026-09-09）

### 16.1 論壇端事實
- 沒有新協定。三個頁面與 §6.1 相同：`home.php?mod=space&do=notice`（`div.nts > dl[id^=notice_]`，未讀＝`dd.ntc_body` 粗體）、`do=pm&filter=privatepm`（`dl[id^=pmlist_]`，未讀＝`div.newpm_avt`）、`do=pm&filter=announcepm`（`dl[id^=gpmlist_]`）；三頁的解析都不看目前帳號，用別的帳號的 cookie 抓回來就是該帳號的資料。
- 列出一次就消耗論壇端的「新」標記（§6.1）：一鍵同步後其他帳號在網頁上也不再顯示「新」，只有 App 內的副本記得。
- 登入過期：通知頁是登入表單（`form#lsform` 且無 `div#um`）→ 該帳號判定需要重新登入（與 §7.2 簽到相同規則）。
- 429：每帳號三個 GET 同時發、帳號之間停 2 秒（比照 §7.2）；通知頁的限流門檻沒有實測數據。伺服器給 `Retry-After` 就等它（上限 60 秒）重試一次，沒給或重試仍 429 → 該帳號回報「限制了請求頻率」，下一個帳號照跑。

### 16.2 App 端行為
- `NotificationRepository.fetchNotificationWith(client, {timestamp})`：把原本 `fetchNotificationV2` 的抓取邏輯抽出來、不碰 status 串流；`fetchNotificationV2` 改為呼叫它，串流事件順序不變（Loading → Failure／Success）。
- `persistFetchedNotification(storage, uid, fetched)`（`notification_bloc.dart` 頂層函式）：原 `NotificationBloc._onNoticeInfoFetched` 的「讀舊副本→`freshNotifications`→三類對帳→`saveNotification`」抽成共用，回傳 `{fresh, reconciled, unread}`；bloc 與一鍵同步走同一段，存法完全一致（test_033 不動）。`countUnreadNotification` 為從資料庫重算未讀的共用函式。
- `NotificationSyncAllRepository`：每個帳號用 `ServiceKeys.empty` 的 `CookieProvider` `loadCookieFromStorage` ＋ `NetClientProvider.buildNoCookie(cookie:)` 建自己的 client（不碰全域 cookie、不切帳號）；逐一執行、間隔 2 秒；進度走 `BehaviorSubject`（同 `AutoCheckinRepository`）；結果 `Success{newNotice,newPm,newBm,unread×3}`／`NotAuthorized`／`RateLimited`／`Failed(message)`；`lastFetchNotice` 寫「開始那一分鐘」（同自動同步）；抓完發現該帳號已從本機刪除則不寫入（並靠 `CookieProvider` 的「已刪除不回寫」守門）。
- `NotificationSyncAllCubit`（`app.dart` 頂層，離開頁面不中斷）：`start()` 防重入；先用切換帳號同一套 `pause('sync all accounts')` 握手暫停自動同步（最多等 10×300 ms，仍佔用就照跑並記 warning）；帳號清單＝`getAllUsers()` 過濾 uid>0 且有名字，**含目前帳號**，全部走 per-uid 路徑；跑完只為「當下」的目前帳號從資料庫重算未讀並 `NotificationInfoRepository.updateInfo`（不用 `applyServerHint`、不發其他帳號的數字），再送 `NotificationReloadFromStorageRequested` 讓 `NotificationBloc` 從資料庫重建列表（不再打網路；bloc 正在 loading 則跳過）；`resume` 自動同步；`Finished`。其他帳號的新訊息**不**發本機推播（推播固定開目前帳號的通知頁）。執行途中拋出例外（資料庫錯誤等）也以 `Finished`（到當時為止的結果）收尾並釋放鎖，按鈕不會永久停用；單一帳號的 cookie 載入／寫入失敗記為 `Failed(message)`，批次照跑下一個。`AutoNotificationCubit` 的暫停鎖是「理由集合」：登入（`'login'`，表單的 resume 也改用同一理由）、切換帳號、全帳號同步各自持有，最後一個 `resume` 才重啟計時，`start()`／`stop()` 清空；`NotificationBloc` 的 `NotificationRecordFetchTimeRequested` 只在比已存的 `lastFetchNotice` 晚時才寫，從資料庫重載或標記已讀時重發的舊 `latestTime` 不會把開始分鐘往回推。
- 進入點：管理帳號頁 app bar 的同步鈕（切換中／刪除中／已在跑／沒有帳號時停用）與通知頁右上選單「同步所有帳號」，兩者都啟動 cubit 並推入進度頁 `ScreenPaths.notificationSyncAll`（`/notice/syncAll`，`NotificationSyncAllPage`，複製 `AutoCheckinPage`：進行中／等待中／完成卡，成功卡文字「新提醒 N，新私訊 M，新公用訊息 K；未讀 a/b/c」）。完成時全域 snackbar「所有帳號的通知同步已完成」＋「查看詳情」（已在進度頁則不帶按鈕）。
- 沒有做：自動排程、設定鍵（issue 只要求按鈕）。
- i18n：`manageAccountPage.syncAll.title`、`noticePage.syncAllPage.*`、`globalStatePage.syncAllFinished`。
- 測試 test_050：Alice（全域 CookieProvider）＋ Bob、Carol（只在資料庫）三帳號、腳本化 adapter 分頁面佇列——嚴格 Alice→Bob→Carol 各 3 個 GET、每帳號的請求帶自己的 `Ystv_2132_auth`、Bob 的通知／私訊／公用訊息以伺服器未讀旗標落在 uid 2000、`lastFetchNotice` 已寫、Carol（登入表單）→ NotAuthorized、全域 cookie 仍是 Alice；對帳一致（預存已讀副本再抓仍已讀，`new` 不計）；429 無 Retry-After → RateLimited 且下一帳號照跑；429 帶 Retry-After 1 秒 → 等 1 秒重試一次成功；cubit 只發佈一筆＝Alice 的資料庫重算（Bob 的 1/1/1 不混入）、無目前帳號不發佈、執行中再 start 忽略；`fetchNotificationV2` 串流仍 Loading→Success／Failure；bloc `NotificationReloadFromStorageRequested` 不打網路；儲存 Bob 時拋例外 → Bob `Failed`、Alice 照抓；`getAllUsers` 拋例外 → Preparing→Finished（空）且自動同步恢復、可再 start；全帳號同步暫停中切換帳號 pause／resume 不重啟計時，sync-all resume 後才 Ticking；同一理由 pause 兩次 resume 一次即恢復；`NotificationRecordFetchTimeRequested` 較早的時間不覆寫、較晚的才寫。真實的 `pmlist_`／`gpmlist_` 列表頁 fixture 仍缺，測試用依選擇器合成的最小 HTML。

## 17. 首頁改顯示論壇導讀首頁的四個模組（GitHub #12，2026-09-09）

### 17.1 論壇端事實
- `forum.php?mod=guide&view=index`（訪客也看得到）依序列四個模組：最新热门（`view=hot`）、最新精华（`view=digest`）、最新回复（`view=new`）、最新发表（`view=newthread`）；頁首導覽 `ul#thread_types > li > a` 另有 抢沙发（`view=sofa`）與 我的帖子（`view=my`）。
- 每個模組是 `div.bm.bmw`：`div.bm_h` 內 `<a href="forum.php?mod=guide&view=hot" class="y xi2">更多 »</a>` ＋ `<h2>最新热门</h2>`；內容 `div.bm_c > div.xl.xl2.cl` **直接**放 `<li>`（沒有 `<ul>`，偶數列 `li.xl2_r`）。每列：`<em>`（模組不同：hot＝`<span class="xi1">N人参与</span>`、new＝時間或 `<span title="2026-9-9 20:25">7&nbsp;秒前</span>`、newthread＝空白）、`<i>· <a href="forum.php?mod=viewthread&tid=TID&extra=" [style="font-weight: bold;color: #EE1B2E;"]>標題</a></i>`、`<span class="xg1"><a href="forum.php?mod=forumdisplay&fid=FID">版塊</a></span>`。
- 抓到的頁面每個模組 30 列（不是 10）；最新精华目前沒有帖子：`div.xl` 內只有 `<p class="emp">暂时还没有帖子</p>`，完整頁 `view=digest` 也是 0 列（`tbody.bw0_all > tr > th > p.emp`）。
- 完整頁 `view=hot`（47 列，`div.pg > a.nxt` 分頁 `view=hot&page=2`）與 `view=new` 的列都是 §（既有）`tbody#normalthread_TID` 格式，`LatestThread.fromTBody` 直接可用；hot 的標題後多一個 `<span class="xi1">N人参与</span>`，解析器忽略。`view=sofa` 沒有抓樣本（假設同格式）。

### 17.2 App 端行為
- `guideIndexUrl`、`guideUrl(view)`（`constants/url.dart`）；模型 `GuideModule{title, view, moreUrl, items, emptyMessage}`、`GuideItem{tid, title, url, fid, forumName, extra, highlighted}`（`features/homepage/models/guide_index.dart`）；解析 `parseGuideIndex(document)`（`features/homepage/utils/parse_guide_index.dart`）依頁面順序回傳，缺標題或 更多 連結的區塊跳過，訪客登入頁／無關頁面回 `[]`；`extra` 收斂空白（含 nbsp），空則 null；`highlighted`＝標題 `<a>` 帶 `style`。
- `GuideIndexRepository.fetchGuideIndex()`（AsyncEither）＋ `GuideIndexCubit`（loading → success／failure；失敗保留舊模組）；`GuideSection` 取代原 `LatestReplySection`（已刪除；`latestReplyUrl` 改為 `guideUrl('new')`），跟原本一樣自己持有 cubit，首頁下拉更新時整段重建＝一起重抓。
- 版面：論壇狀態卡之下先一列 chip（每個模組一顆＋固定的 抢沙发，對應頁首導覽），再每個模組一張卡：標題＋「更多」（`ScreenPaths.latestThread`，帶 `url`＝模組的 更多 連結、`title`＝模組名）、最多 10 列（頁面給 30）；每列標題（有 style 的用 error 色＋粗體）、版塊小標籤（可點進版塊）、右側 `extra`；點列開帖子（`ScreenPaths.threadV1`，`tid`＋`appBarTitle`）；空模組顯示頁面自己的 `p.emp` 文字（沒有則 i18n `homepage.guide.empty`）；載入失敗顯示重試列（chip 列仍在）。已回覆標記（#21）沿用 `isThreadReplied`。
- `LatestThreadPage` 新增可選 `title`（路由 query `title`）與空清單提示（`latestThreadPage.empty`）；`view=hot|digest|sofa` 走同一頁。
- i18n：`homepage.guide.{more, sofa, failed, empty}`、`latestThreadPage.empty`；移除 `homepage.latestReplySection.*`。
- 測試 test_064（解析：四模組順序／view／更多 url、30/0/30/30 列、第一列 hot 內容、缺模組容錯、空頁；repository＋cubit 用假 adapter；widget：模組卡、更多、chip、點列到 threadV1、點更多／chip 到 latestThread、失敗重試列）、test_065（`fromTBody` 解析 hot 47 列、digest 0 列 bloc 仍 success、分頁 url、repository 接受五種 view、`LatestThreadPage` 標題與空提示）。

## 18. 瀏覽紀錄依帳號篩選（GitHub #19，2026-09-10）

### 18.1 範圍
- 使用者定案：加帳號篩選、保留「全部帳號」、重新整理時維持篩選。首版由 Codex 建立（PR #39），本輪接續完善，不另外拆帳號分頁。

### 18.2 App 端行為
- `ThreadVisitHistoryPage`：篩選在已載入的紀錄上做（`state.history.where(uid)`），不走 `ThreadVisitHistoryFetchByUserRequested`，所以下拉刷新／重試後選擇不變；帳號清單從紀錄本身取（`putIfAbsent(uid, username)`，最近瀏覽的帳號在前），已從 App 移除的帳號仍可選；選中的帳號在刷新後紀錄全沒了也留在清單裡（記住 `_selectedUsername`），並顯示 `emptyForAccount`。
- 觸發器是 `ActionChip`（漏斗圖示＋目前選擇），點下去用 `GlobalKey<PopupMenuButtonState<int>>.showButtonMenu()` 開同一個 `PopupMenuButton`（漣漪維持 chip 形狀、選單可捲動）；「全部帳號」用哨兵值 `-1`（`PopupMenuItem` 值為 null 時 `onSelected` 不會被叫）。選單用 `CheckedPopupMenuItem`：名字一行＋ `UID n` 小字，選中的打勾；chip 上只在名字與其他帳號重複時才附 UID（`accountWithUid`），名字超過 220 邏輯像素省略。
- 空狀態：沒有任何紀錄顯示 `empty`，篩選後沒有紀錄顯示 `emptyForAccount`；都放在 `ListView` 裡，下拉刷新仍可用。
- i18n `threadVisitHistoryPage.{filterAccount, allAccounts, accountUid, accountWithUid, empty, emptyForAccount}`。
- 測試 test_072：選單列每個帳號一次＋UID、打勾跟著選擇、同名帳號 chip 帶 UID、不同名不帶；刷新保留篩選並顯示新紀錄；選中帳號的紀錄刪光後仍選中、顯示空提示、選單仍列該帳號；完全沒有紀錄時只有「全部帳號」一項。

## 19. 帖子置中失效（GitHub #47，2026-09-10）

### 19.1 論壇端事實

- Discuz! X5 把 `[align=center]…[/align]` 輸出成 `<div align="center">…</div>`（`right`／`left` 同理），與 X3 相同；樣本為回報者影片中的活動帖第 1 樓（tid 1263228），
  標題、圖片、副標各是一個 `<div align="center">`，其後的活動規則沒有對齊標籤。去識別化樣本：`test/data/post_div_align_x5.html`（圖片網址改成 example.com）。
- 編輯頁走 BBCode（編輯器自己處理 `[align]`），所以回報者看到「編輯介面正常、帖子頁不置中」。

### 19.2 App 端行為

- `html_muncher.dart`：原本只有 `<p align>` 會包成滿寬的 `Text.rich(textAlign: …)`，`<div align>` 走一般的 div 處理、`<center>` 只是往下解析。
  現在三者共用 `_munchAligned`：對齊值來自 `align` 屬性（`_blockAlign`），內容包在一個滿寬的 `Text.rich` 裡，區塊結束後還原原本的對齊，
  後續正文不受影響；div 的特殊 class（`blockcode`、`locked`、`modact`…）照舊由各自的 builder 處理，再套對齊。
- 沒有處理 `style="text-align: …"`：論壇目前不輸出這種寫法，樣本裡也沒有。

### 19.3 驗收

- `test/regression/test_074_post_div_align_test.dart`：真實樣本的標題與副標被置中、規則段落維持靠左；`div`／`p`／`center` 三種標籤與巢狀內容都對齊，
  對齊不外漏到後面的正文。拿掉修正後第一個測試會失敗。
- 實機：回報者開 tid 1263228 或任何用了置中的舊帖確認。

## 20. 「權限不足的連結跳到瀏覽器」（GitHub #46，2026-09-10）

### 20.1 影片與實抓對照出的真正觸發點

- 影片：第二個帳號在「通知 → 私人消息」列表裡點了「分享帖子 … https://www.tsdm39.com/forum.php?mod=viewthread&tid=1263647」的文字，
  App 同時開了交談記錄頁並跳到瀏覽器，瀏覽器落在論壇首頁。第一個帳號是在交談記錄頁裡點連結，正常開帖子頁。
- 用測試帳號互發同格式的私訊實抓：私人消息列表（`home.php?mod=space&do=pm&filter=privatepm`）的摘要裡，網址的 `&` 被論壇去掉，
  變成 `forum.php?mod=viewthreadtid=1264975`；交談記錄頁（`subop=view`）的訊息是完整的純文字網址（`&amp;`）。
  fixture：`pm_list_bare_url_x5.html`、`chat_history_bare_url_x5.html`（uid→1000/1001、Alice/Bob、formhash→XXXXXXXX）。
- App 端：`PersonalMessageCardV2` 用 `MunchedHtml` 顯示摘要，muncher 會把純文字網址做成可點連結（#24）；殘缺網址 `parseUrlToRoute()` 認不出，
  `dispatchAsUrl` 走「不支援的網址開瀏覽器」的後備。手機上連結用的是 `LongPressGestureRecognizer`，一般點擊不會搶走卡片的點擊，所以卡片與連結同時觸發。
- 和權限無關：同一個帳號從交談記錄頁點完整連結會正常開帖子頁。

### 20.2 論壇端的權限回應（實抓，去識別化）

| 情境 | fixture | 論壇回應 | App |
| --- | --- | --- | --- |
| 訪客開需要閱讀權限的帖 | `thread_readperm_guest_x5.html` | `#messagetext.alert_info`「抱歉，本帖要求阅读权限高于 130 才能浏览」＋ `#messagelogin` | `needLogin` → `NeedLoginPage` |
| 會員開限制版塊裡的帖 | `thread_restricted_board_member_x5.html` | `#messagetext.alert_error`「本版块只有特定用户可以访问」 | `ErrorCard` 顯示論壇原句 |
| `redirect&goto=findpost` 指到不存在的帖 | `thread_findpost_missing_x5.html` | `alert_error`「抱歉，指定的主题不存在或已被删除或正在被审核」 | 同上 |
| 會員開限制版塊 | `forum_restricted_board_member_x5.html` | `alert_error`「本版块只有特定用户可以访问」 | 版塊頁 `ErrorCard` |

帖子與版塊連結都是 App 內路由，這些回應本來就不會開瀏覽器；`viewthread&tid=` 指到不存在的 tid 時，論壇會回一個標題為空、內容不相干的帖子頁（站方行為），App 不特別處理。

### 20.3 App 端行為

- `MunchOptions.renderUrl = false` 現在也不把純文字網址做成連結（原本只擋 `<a>`）。
- 私人消息與公共消息列表卡片的摘要改用 `renderUrl: false`：摘要只顯示文字，點卡片進交談記錄／詳情，那裡的完整連結照常在 App 內開。
- 沒有攔截其他連結：無法辨識的網址（論壇工具、外站）仍照原本方式開瀏覽器。

### 20.4 驗收

- `test_075`：列表摘要確實沒有 `&`、殘缺網址不是 App 路由；預設 muncher 會把它做成連結並開瀏覽器（用 url_launcher 的方法通道 mock 記錄）；
  卡片改後沒有可點的 span，點網址文字進交談記錄、瀏覽器沒有被叫。
- `test_076`：四個權限／不存在頁的解析結果與 `ErrorCard` 顯示論壇原句；帖子與版塊連結是 App 內路由。
- 實機：回報者用原本的兩個帳號重做影片裡的操作；順便確認有權限的帳號從列表點卡片進交談記錄後點連結能開帖。
## 21. 視窗尺寸變化後畫面沿用舊尺寸（GitHub #28，2026-09-10）

### 21.1 回報內容與影片判讀

- 平板（華為 M6 高能版／MatePad mini，鴻蒙 2＝Android 10、鴻蒙 7 的卓易通＝Android 16）：小窗切全螢幕後，畫面以左上角為起點沿用小窗尺寸，其餘留白；
  小窗裡回覆（鍵盤出入）後畫面下方留白。手機（鴻蒙 4.2＝Android 12）影片：橫豎切換後有約 3 秒仍顯示舊方向的排版（旋轉後的舊畫面、其餘黑色），之後才正常。
- 兩張平板截圖裡「沿用舊尺寸的內容」是**舊尺寸的排版**（窄版面），不是新排版被裁切：Flutter 端當時的排版尺寸就是舊的，或畫面停在最後一張成功送出的幀。
- 1.21.0 小窗回覆截圖：內容是回覆**之後**才進入的首頁，卻只佔視窗上半，下方是視窗背景（白）——Flutter 端在鍵盤收起後仍以縮小後的高度排版，
  且 Flutter 的 surface 也只有那麼大（否則留白會是 Scaffold 底色）。
- 回報者說自 r0 某版開始；上游 1.11.0（2025-07-26）起在 Android 啟用 Impeller（`c339d1f6`），是時間上最接近的渲染層變更，但沒有證據直接指向它。

### 21.2 已排除／已驗證

- AOSP 14 模擬器（docker `budtmo/docker-android`，arm64 轉譯裝 PR 測試包）：橫豎切換、freeform 視窗全螢幕↔小窗（`am task resize`）排版都正確。
  模擬器的 Impeller 走 GLES 後端，不能代表華為 Vulkan 驅動；華為小窗的視窗管理也不是 AOSP freeform。
- Flutter 3.41.2 嵌入層讀碼：`FlutterView.onSizeChanged` → `sendViewportMetricsToFlutter`（未 attach 時丟棄）；`onStop` 把 view 設 GONE、`onStart` 還原；
  `SurfaceView.surfaceChanged` → `FlutterRenderer.surfaceChanged`；framework `handleMetricsChanged` → `scheduleForcedFrame`。標準流程沒有漏洞，
  問題只可能出在 OEM 視窗管理沒有重新排版 view、engine 端 metrics 被丟、或渲染層（swapchain）沒跟上尺寸。
- Codex 先前的 viewport／鍵盤 inset widget 測試通過：framework 收到新尺寸就會重排。

### 21.3 根因（模擬器重現＋嵌入層原始碼）

- 用 §21.4 的診斷 debug 包在 AOSP 14 模擬器跑「新程序 → 旋轉兩次 → 進 freeform 小窗 → 縮小 → 放大到全螢幕」，8 輪有 2 輪放大後畫面停在舊尺寸（左上角、其餘白色，
  與回報者的平板截圖一樣）。開 verbose 嵌入層日誌後，失敗那一步只有一行差別：
  `FlutterView: Size changed ... FlutterView was 880 x 1200, it is now 1440 x 3040` 之後緊接 `Resize was in response to the engine resizing the view. Not sending viewport metrics.`
  ——FlutterView 把真實的視窗縮放當成引擎自己要求的縮放，跳過送 metrics；Dart 端因此停在 880x1200，SurfaceView 也被引擎先前的縮放要求釘在舊尺寸（沒有 `surfaceChanged`）。
- 這個旗標（`shouldSendViewportMetrics`）只會被 content sizing 的 `FlutterUiResizeListener.resizeEngineView` 設起來。Flutter **3.41.1** 的 `FlutterView.attachToFlutterEngine`
  無條件註冊這個監聽器（content sizing 預設關閉也註冊），引擎每次 `maybeResizeSurfaceView` 都會把旗標設為 false；Activity 裡的 FlutterView 是 MATCH_PARENT，
  引擎要求的縮放不會改變它的尺寸，旗標就一直留到下一次真實縮放，然後把那次吞掉。之後有沒有 inset 更新（狀態列、鍵盤）決定會不會補送，所以時有時無；
  華為小窗切換若沒有 inset 變化就一直停在舊尺寸。
- Flutter 3.41.2 起修正：`[CP-stable] Ensure resize listener is not added if content sizing is not turned on`（flutter/flutter#182320，2026-02-17）；3.41.3–3.41.5 都是 hotfix。
  時間線也吻合：content sizing 於 2025-12-08 進主線、隨 3.41.0 發布；上游 1.14.0（2026-02-14）升到 3.41.0、1.15.0 升到 3.41.1，就是回報者說「r0 某版之後」的時間。
- 修法：CI 與 `.fvmrc` 改用 Flutter 3.41.5（3.41 系列最後一個 hotfix，含上述修正）。App 程式碼不需要改；診斷日誌保留，供實機確認。

### 21.4 這一輪同時加入的診斷（保留）

- Android（`MainActivity.kt`）經 `kzs.th000.tsdm_client/windowChannel` 送到 Dart 記錄：`configurationChanged`／`multiWindowModeChanged`／`pictureInPictureModeChanged`
  （螢幕 dp、方向、密度）、`flutterViewLayout`（FlutterView 排版尺寸、visibility）、`surfaceCreated`／`surfaceChanged`／`surfaceDestroyed`（繪圖表面尺寸），
  每筆都附視窗 decor 尺寸、display 尺寸與是否多視窗。
- Dart（`lib/utils/window_events.dart`、`app.dart`）：`didChangeMetrics` 時記 `view metrics`（physical、dpr、logical、鍵盤高度、padding），下一幀後再記一行
  `frame painted`；回前景時再記一次。鍵盤動畫只記出現／消失，不記每一步（`ViewMetricsLogGate`）。
- 讀 log 的判法（尺寸變化後）：
  1. 沒有 `configurationChanged`／`flutterViewLayout`、`view metrics` 也沒變 → 系統沒把新尺寸給 App（OEM 視窗管理）。
  2. 有 `flutterViewLayout` 新尺寸但沒有 `view metrics` 新尺寸 → engine 端沒把 metrics 送進 framework。
  3. `view metrics` 與 `frame painted` 都是新尺寸、畫面卻仍是舊的 → framework 已重排並出幀，卡在渲染／合成層（Impeller、驅動、SurfaceFlinger）；
     下一步試 `io.flutter.embedding.android.ImpellerBackend=opengles`（或關 Impeller）的對照包。
  4. `surfaceChanged` 尺寸與 `flutterViewLayout` 不一致 → SurfaceView 沒跟上，考慮 TextureView 模式（`getRenderMode`）。

### 21.5 驗收

- `test_077`：事件格式化、metrics 行、記錄閘門（鍵盤出現／消失才記）。
- 模擬器（AOSP 14，docker，arm64 轉譯）：3.41.1 建的 debug 包跑 8 輪「旋轉→小窗→縮小→放大」失敗 2 輪；換 3.41.5 重建後同樣迴圈 8 輪全部正常，verbose 嵌入層日誌裡沒有再出現 `Resize was in response to the engine resizing the view`（3.41.1 那輪 8 個日誌有 4 個出現、共 9 次）。
- 實機：回報者裝 3.41.5 建的測試包重做平板的小窗／全螢幕／回覆與手機的橫豎切換；若仍出現，匯出日誌依 §21.4 判法看是哪一層。

### 21.6 第二輪：手機旋轉過場露黑（2026-09-10 下午）

**回報**：PR #51（Flutter 3.41.5）之後，鴻蒙 2 平板沒再出現；鴻蒙 4.2 手機旋轉**完成後**排版正確，但**過場**異常，豎轉橫最明顯；同一支手機上另一個 Flutter App（Kazumi）的旋轉沒有問題。
附新影片（外拍，60 fps）與日誌 `log_1789017760605.txt`。

**日誌**：四次旋轉都是 `configurationChanged` → 新尺寸的 `view metrics`（+25～40 ms）→ `surfaceChanged`／`flutterViewLayout` → `frame painted`（+35～55 ms），沒有再出現尺寸被吞掉；
`frame painted` 只代表 framework 出了一幀，不代表畫面已經顯示。

**影片逐格**（30 fps 取樣）：顯示方向切換後，系統的旋轉動畫把舊畫面截圖轉過去，截圖底下露出的是**黑色**（約 4～5 格，130～170 ms），之後才換成新方向的排版。
黑色不是視窗背景（`NormalTheme` 的 `windowBackground` 是 `?android:colorBackground`，淺色主題下是白的），而是 SurfaceView 的黑色背景層——新尺寸的第一個 buffer 還沒送出時露出來的東西。

**目前的繪圖設定**（master）：Impeller 預設開啟、後端由引擎依裝置選（Vulkan，不支援時 GLES）；`FlutterActivity` 預設 opaque → SurfaceView 繪圖；
`hardwareAccelerated=true`；`configChanges` 含 orientation／screenSize（不重建 Activity）；`NormalTheme` 淺色背景；core-splashscreen。manifest 沒有任何 Impeller／content sizing 旗標。

**對照 App（Kazumi，`Predidit/Kazumi` main）**：manifest 明確 `io.flutter.embedding.android.EnableImpeller=false`（Skia），其餘（theme、configChanges、adjustResize、hardwareAccelerated、SurfaceView）與本 App 相同；Flutter 3.47.2。
兩個 App 在同一支手機上的差異裡，與旋轉過場有關的只有繪圖後端。

**對照包（PR #52，只改一個變因）**：manifest 加 `EnableImpeller=false`，其他完全不動（Flutter 3.41.5 仍支援這個 opt-out：`FlutterLoader` 會加 `--enable-impeller=false`，Android shell 仍有 `android_surface_gl_skia`）。
模擬器確認：logcat 出現引擎的 opt-out 訊息、旋轉／freeform 縮放正常。請回報者在同一支鴻蒙 4.2 手機、同一個頁面、同樣的豎轉橫做對照。

**判讀**：
- 過場乾淨 → 變因是繪圖後端。下一步再做第二個單變因包 `ImpellerBackend=opengles`（保留 Impeller 只換 GPU API）決定正式修法：GLES 也乾淨就用 GLES，否則先用 Skia（Kazumi 的做法；Skia 在 Android 上是即將移除的 opt-out，之後要跟著 Flutter 版本重新評估）。
- 仍露黑 → 與繪圖後端無關，下一個單變因是 SurfaceView → TextureView（`getRenderMode`），再不行就是系統的旋轉動畫本身（同機其他非 Flutter App 對照）。


## 22. 版塊帖子列表的作者頭像（2026-09-10）

**需求**：版塊頁「置頂／帖子」列表裡，作者名字旁的圓圈顯示該作者的論壇頭像；維持原本的圓形大小與版面，沒有有效頭像或載入失敗時保留文字圓圈。

### 22.1 論壇端事實（實抓驗證）

- **列表本身沒有頭像**。`forum.php?mod=forumdisplay&fid=16` 的 49 個 `tbody` 裡，`div#threadlist` 一張 `<img>` 都沒有；作者資訊只有
  `<td class="by"><cite><a href="home.php?mod=space&uid=UID">名字</a></cite>`。所以頭像網址只能由 UID 生成，論壇自己也是這樣做的。
- **論壇自己的規則**：`static/js/common.js` 的 `loadAvatar()`——UID 補零到 9 位，切成 3／2／2 三層目錄，檔名是最後兩位，
  `size` 預設 `middle`，網址前綴取自 `DEFAULTAVATAR`（`./data/avatar/noavatar.svg` → `./data/avatar/`），載入失敗時 `onerror` 換成預設頭像。
  也就是 `data/avatar/${uid[0:3]}/${uid[3:5]}/${uid[5:7]}/${uid[7:]}_avatar_${size}.jpg`。
- **與帖子頁一致**：帖子頁對「上傳過頭像」的用戶輸出的正是同一個網址（實測一位有上傳頭像的作者，樓層的 `data-src` 是
  `./data/avatar/…_avatar_middle.jpg`，經 `prependHost()` 後與本次生成的字串完全相同），所以列表與帖子頁共用同一筆頭像快取，不會重抓。
- **三種尺寸**：`small` 48×48（約 2 KB）、`middle` 140×140（約 20 KB）、`big` 200×200。選 `middle`：與帖子頁同一份快取，且列表圓圈為 40 dp，
  高密度螢幕上要到 120 px。
- **頭像外鏈**：TSDM 的頭像可以填外部網址（`home.php?mod=spacecp&ac=avatar`，欄位 `headedit`）。這種用戶論壇端沒有檔案，生成的網址回 404；
  論壇自己的頁面同樣會 404 再由 JS 換成預設頭像。實測事務所版第 1 頁（含置頂）45 位不重複作者：20 位有上傳頭像（載入成功，共 749 KiB）、25 位回 404（抽驗其中 8 位，一半是外鏈頭像、一半根本沒設）。
- 沒有批次查頭像的端點；要拿到外鏈頭像只能逐位開個人頁，一頁列表會多出數十個請求，因此不做。

### 22.2 App 端行為

- `avatarUrlOfUid()`（`lib/constants/url.dart`）依上述規則生成網址，UID 不是正整數（匿名、已註銷、只有 `username=` 的連結）時回 null。
- `NormalThread.fromTBody` 把它填進作者的 `avatarUrl`；置頂帖走 `StickThread.fromTBody` → 同一份解析，所以兩個分頁一致。
  卡片本身沒有改動：`HeroUserAvatar` 照舊拿 `author.avatarUrl`，載入、快取與失敗時的文字圓圈都是既有機制，點擊行為不變。
- `ImageCacheProvider.getOrMakeCache`：使用者頭像抓取失敗時，改用該使用者名下已快取的頭像（`UserAvatar` 表以 username 為主鍵，
  本來就是「一旦快取過，全 App 都能用」的設計）再退回文字圓圈。網路仍然先試，快取只在抓不到時補位，所以換過頭像的用戶不會被舊圖卡住；
  外鏈頭像的用戶只要 App 在別處看過，列表也顯示得出來。
- 回退成功時把「這個網址在伺服器上沒有檔案」記在記憶體裡（`_avatarWithoutFile`，網址 → 使用者名稱），之後同一個網址直接用該使用者已快取的頭像，不再問伺服器。
  **這一段是必要的**：頭像送達時元件會 `evict()` 自己的圖片再載入一次，沒有這個記錄的話每次重新載入都會再打一次 404，卡片一進一出就無限重複
  （審查時用「移除卡片再顯示」的測試量到同一個網址被請求 6 次）。記錄只存在記憶體：重開 App 會再試一次，而且每次都解析成當下快取的頭像，
  不會把使用者換過的新頭像擋在舊圖後面；清除圖片快取時一併清掉；`force` 重新下載不受影響。
- 結果：每位作者最多一次圖片請求，之後走快取；沒有頭像的作者在一次執行期間只會得到一次 404（1.2 KB 的錯誤頁），與瀏覽器開同一個版塊的行為相同。

### 22.3 未改動

- 搜尋結果（`SearchedThread`，X5 版面有 uid）、最新回覆（`LatestThread`，只有 `username=` 連結）、我的帖子（`MyThread`，同樣沒有 uid）維持原狀。
- 沒有改頭像圓圈的大小、版面與點擊行為。

### 22.4 驗收

- `test/regression/test_078_thread_card_author_avatar_test.dart`：網址生成規則與無效 UID 的守衛；去識別化樣本
  `test/data/forum_thread_list_authors_x5.html` 解析後兩位有 UID 的作者拿到對應網址、匿名那列沒有頭像（不會借用別人的）；
  卡片把網址交給頭像元件、每位作者只請求一次、沒有頭像的作者留著文字圓圈、沒有 UID 的作者完全不發請求；
  已快取的外鏈頭像在生成網址 404 後仍然顯示；**卡片移除再顯示三輪，沒有檔案的那個網址仍然只被請求一次**（拿掉記錄後這條會失敗，量到 6 次），
  完全沒有頭像的作者同樣只請求一次（那條路徑不會 evict，靠 Flutter 的圖片快取）。
- 桌面實測：Linux 建置跑起來後開版塊列表確認頭像、捲動與快取。
