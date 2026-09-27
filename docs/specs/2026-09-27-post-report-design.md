# 帖子樓層舉報（#127）

從樓層操作選單舉報單一帖子。只沿用論壇實際提供的入口、表單與結果，不猜欄位、不以 HTTP 200 當成功、不自動重送。

## 證據與範圍

- 入口：樓層操作列 `div.po > div.pob` 內的 `href="javascript:;"` 連結，`onclick="showWindow('miscreportPID', 'misc.php?mod=report&rtype=post&rid=PID&tid=TID&fid=FID', 'get', -1);return false;"`；範本只對他人可見帖子輸出，主樓與回覆同為 `rtype=post`。
- 表單：AJAX（`inajax=1&infloat=yes&handlekey=miscreportPID`，`X-Requested-With`）回傳 CDATA，內含唯一 `form#form_miscreportPID`，action `misc.php?mod=report`；hidden `referer/reportsubmit/rtype/rid/fid/url/inajax/handlekey/formhash`，`textarea name=message`，送出鈕無 name。**沒有 tid**；標準表單 `url` 可為空。理由來自 `var reasons = ['广告垃圾', ...];`，最後一項為「其他」（自行輸入）。
- 伺服器：`dhtmlspecialchars(trim(message))` 後 `cutstr(..., 200)`；UTF-8 下 ASCII 計 1、其他 Unicode 純量（含 emoji）計 2。`cutstr` 先把 `&amp;/&quot;/&lt;/&gt;` 包上 chr(1) 哨兵，計數達 200 即停，最後丟掉缺少結尾哨兵的實體：權重剛好 200 且以 `&`、`"`、`<`、`>` 結尾的理由會少掉最後一字。接著 `rtrim` 會移除結尾反斜線，App 也會事先提示修改並保留輸入。重複舉報會累加理由與次數，沒有「已舉報」拒絕，也沒有舉報者可查的狀態端點。
- 成功（`report_succeed`, alert=right, showdialog=1）：`function_message.php` 產生的 CDATA 只有一段 `<script type="text/javascript" reload="1">if(typeof errorhandle_HANDLE=='function') {errorhandle_HANDLE('文字', {});}hideWindow('HANDLE');showDialog('文字', 'right', null, null, 0, null, null, null, null, 3, null);</script>`（關閉秒數為設定值）。values 由 `'{'+valuesjs+'}'` 組成，空值即 `{}`。`errorhandle` 本身不代表失敗；不帶 showDialog 的 callback 為拒絕。
- 未取得真實寫入回應：成功／拒絕樣本為依原始碼結構製作的合成資料；hidden 實值在瀏覽器 DOM 不可見，正式執行只採用當次 HTTP 回應的值。

## 設計

- `Post.reportTarget`（`PostReportTarget`：PID/TID/FID＋看到該頁的 UID）。只從該樓 `table#pidPID` 操作列擷取唯一舉報連結，排除內文、引用、簽名檔；`href` 與 `onclick` 字面比對（不執行 JS），必須是同源 `misc.php`、恰好 `mod/rtype/rid/tid/fid` 各一次，且 TID/FID 等於頁面本身（canonical link、`srhfid`／快速回覆 action）獨立得出的值。自己的帖子、訪客頁、頁面 ID 不明一律沒有目標。執行緒頁與通知詳情頁（另核對 `ptid`）都走同一路徑；通知頁 PostCard 不再強制需要 ThreadBloc。
- 對話框（獨立 route 與 `PostReportCubit`，生命週期不綁 PostCard）：讀取時先 GET 完整樓層頁（`findpost`）核對目前 UID 與該樓仍提供舉報，再取 AJAX 表單並嚴格驗證；驗證碼、未知欄位、非預期 action 或理由格式 → 不送出並提供瀏覽器開啟完整樓層（`openInExternalBrowser`）。
- 送出：選理由（「其他」需非空、不超過 200 權重，且不落在上述實體邊界；不符則拒絕並說明，不截斷、不改字。畫面計數與 `messageFor` 共用 `postReportReasonFits`，只模擬這個已確認的邊界，不模擬 `censor`）→ 最終確認（樓層、作者、理由）→ 重新 GET 樓層頁與表單並核對 → `postForm(singleAttempt: true)` 一次。連點鎖、確認時與每個 await 後檢查世代與 UID；切帳號（含 A→B→A）立即作廢並只移除本對話框擁有的確認窗與對話框 route（`removeRoute`，不 `popUntil`，其上的其他頁面保留）、清除輸入；已在退場動畫中的確認窗依世代立即不再顯示樓層／作者／理由，主對話框也立即隱藏作者。同帳號的驗證事件保留輸入。對話框 route 一被 pop（含忽略 canPop 的命令式 pop）即由 `PopScope.onPopInvokedWithResult` 與 `route.popped` 作廢待送的重新核對，不等 dispose；已發出的請求結果忽略、絕不重送。
- 結果：只讀上述回應 script 的文法（逐 token 比對，不執行 JS、不是通用直譯器）：AJAX 外殼、唯一且位於片段結尾、確實是會執行的 script 元素；內容恰為該 handle 的完整 callback 陳述式，選擇性接著 `hideWindow`＋`showDialog`。callback `{}`＋同文字 `right` 對話框才算成功；只有 callback 為明確拒絕（保留輸入、顯示純文字）；其他（JS 字串或註解、HTML 註解、`<pre>`／textarea 等非執行文字、部分 showDialog、forward／location、其他 alert 模式、其他陳述式、其他 handle、多個呼叫、例外、非 200、空白、無 CDATA）皆為「結果不明」，此對話框不再允許送出，提示到網頁核對，不宣稱 GET 能證明舉報已建立。
- 不記錄理由內容或完整 HTML；介面文字為繁中、簡中、英文。

## 驗證

`test_140`～`test_144`：連結擷取與頁面脈絡、表單／理由／長度邊界／結果判定、repository 與 cubit 流程（單次 POST、無重試、連點、A→B→A、延遲回應、取消）、對話框（確認取消、帳號切換含退場中的確認窗與無關頁面保留、關閉 route 即停止待送核對、瀏覽器失敗、大字體窄螢幕捲動後操作）、非執行文字不得判為成功、200 權重實體邊界。全部使用合成資料，未對真實使用者送出舉報。

補充驗證：底層舉報 route 被移除時，也會作廢並清理它擁有的確認窗；確認窗的隱私狀態保留到 overlay 真正移除。首幀隱私測試先送達非同步帳號事件，再畫第一幀，沒有等待退場動畫結束。正常數字實體文字不解碼，依現站 X5 `dhtmlspecialchars` 的四字元替換規則處理。
