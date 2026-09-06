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
