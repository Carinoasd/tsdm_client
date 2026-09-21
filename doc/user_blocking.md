# User blocking

Two independent features, shown apart in the UI (`/userBlock` "屏蔽管理", from the own profile menu and the notice
page).

## A. Local silent block

* Stored per account in the settings table, row `userBlockList.<ownerUid>` (json string list of
  `{uid, username, at}`). No new table. Reads always hit the database, so the background service isolate and the
  sync of all accounts use the list of the account they sync.
* A row that can not be read throws `UserBlockStorageException`: it is never treated as empty, so a block after a
  failed read can not overwrite the saved list. Entries this version can not decode are kept
  (`UserBlockList.unreadableEntries`) and written back unchanged.
* Never sends a request: no forum blacklist, no friend removal, no PM rejection, the blocked user is not notified.
  Personal messages are still delivered; only their local alert and unread badge are muted (see "Personal
  messages" below).
* Self block, guests and invalid uids are refused (`UserBlockResult`).
* `UserBlockCubit` follows the current account (`AuthenticationRepository.effectiveCurrentUid`, re-read on every
  auth status event). State has a status: `loading` / `failed` lists are "unknown" and `UserBlockList.hides` holds
  back every identified author until the list is known, so nothing is shown for a moment before its list is read.
  A failed re-read keeps the last known list of the same account. `watch` subscribes to changes before its first
  read, a change saved while that read is pending is not lost.
* Actions bind the account before any dialog (`confirmAndBlockUser`, `showNoticeIgnoreDialog`, `UserBlockPage`):
  the cubit refuses a choice made for another account (`UserBlockResult.accountChanged`), forum actions check the
  current account again before writing and drop late answers.
* `onListChanged` (owned by the cubit, ends with it) reloads notices from storage and recounts the badge on every
  change of the known list, including the first one.
* Topics: `NormalThreadCard`, `SearchedThreadCard`, `LatestThreadCard` and homepage pinned rows (uid from the
  row's forum profile link, never from the name) render nothing for blocked authors; lists, their lengths and
  pagination are unchanged, so a fully hidden page still loads the next one. Guide index module rows carry no author
  uid (in `test/data/guide_index_x5.html` the page header has `uid=` profile links, the module rows do not) and are
  not filtered; the author is never guessed from a name. Favorites, visit history and my threads carry no author
  either; opening one of them is covered by the thread page below.
* Thread opened directly: when the thread author is blocked, the page shows only a notice with back / unblock, no
  title, no floors, and no visit history entry. The author comes from floor 1 when it is on the page, else from
  `ThreadAuthorCache` (filled by list rows and earlier pages), else - only when the current account blocks somebody -
  from one request for page 1 in ascending order (`ordertype=2`, also when the page shown is newest first).
* While the current account blocks somebody and the author is not known, the thread is held back: no title (neither
  the thread's nor the one passed by the caller), no floors, no reply bar, no visit history entry. Loading shows a
  neutral indicator; a failed page, a failed page 1 request, or a page 1 without a floor 1 author shows a neutral
  "failed to load" with back / retry. It is never called blocked unless the author uid is known. Late answers
  (disposed page, retried lookup, another tid) are dropped.
* Replies: `BlockAwarePost` turns a blocked author's floor into a placeholder keeping the floor number, with an
  unblock button only; there is no "show once".
* Quotes: replaced only when the quote carries the forum's exact `forum.php?mod=redirect&goto=findpost&pid=` link
  and that pid is a post loaded on the same page whose author is blocked. The quoted username text and other links
  are never used; quotes of posts on other pages can not be attributed and stay visible.
* Notices: only the author from the notice's own ignore link (`authorId`, see B) is used; author 0 (system) is never
  hidden. Hidden notices stay stored with their read state, are excluded from `fresh` (system notifications,
  foreground and background), from the unread counts, from the notice page and from notice search (the card itself
  also checks), and come back when unblocked. Old rows without metadata are never hidden. A list that can not be read
  holds back attributed notices instead of announcing them.
* Personal messages: a conversation with a blocked peer is muted, not hidden. Only two local things change, both
  decided by the peer uid (`isMutedPersonalMessagePeer`), never by a name:
  * no alert: the conversation is left out of `fresh` (`withoutBlockedNotices` in `persistFetchedNotification`), so
    there is no system notification and no auto sync hint for it, foreground and background;
  * no badge: `countUnreadNotification` does not count it, on every path that publishes the unread badge.

  Everything else stays as it is. Delivery: the forum still accepts and delivers the messages, they are fetched and
  stored like any other, and the conversation stays listed in the personal message tab where it can be opened and
  read by hand at any time. Read state: blocking never marks anything as read; the stored flag is the real one, so a
  conversation read while muted stays read and an unread one counts again after unblocking (`onListChanged` reloads
  from storage and recounts). Rights: no request is sent, so the forum blacklist, the friend relation, the PM
  permissions of both sides and the forum's own unread marker (web and other devices) are unchanged, and the peer
  can not tell. It applies to the account that blocked only: account B on the same device does not inherit the
  list of account A. While the list can not be read every conversation is muted the same way instead of announced.
  The block dialog (`userBlock.blockConfirmContent`) and the card on top of the manager page
  (`userBlock.localHint`) tell the user exactly this.
* Foreground sync publishes the same filtered storage recount as background sync. Both homepage header hints are
  withheld while the local list is nonempty or not known yet (`noticeHintAllowed` guards the two, the name is kept
  from when only the notice count was guarded): the forum notice total has no author information and the PM flag is
  an aggregate that can not tell the sender, so either would bring hidden notices or a muted conversation back into
  the badge until the next sync. `applyServerHint` leaves a count as it is for a null hint. Recounts recheck the
  current account after reading storage, so switching accounts cannot publish the previous account's badge.
* Covered by `test/regression/test_096_blocking_unread_integration_test.dart` (badge, `fresh`, unblock recount,
  accounts apart, header hints).

## B. Forum notice ignore rules (Discuz `filter_note`, not the blacklist)

* Notice metadata: `NoticeV2.ignoreType` / `authorId` parsed from `dt > a[href*="op=ignore"]` (relative or forum
  host on the default port, exactly `home.php`, `mod=spacecp&ac=common&op=ignore`, `authorid >= 0`, safe `type`).
  Stored in nullable `notice.ignore_type` / `notice.author_id` (schema v14). A copy without metadata keeps the stored
  metadata only for the same revision (same time and body); a merged notice with a newer time or another body gets
  null (unknown author) instead of inheriting the old one.
* Entry: a rule is added from a notice only (notifications → notice tab "提醒" → the ⋮ menu of one notice →
  "屏蔽此类提醒（论坛）…", `showNoticeIgnoreDialog`), because the type and the author come from that notice's own
  ignore link. There is no such entry on personal messages: these rules are about notices, muting a peer's messages
  is part of the local block (A). The manager page only lists and removes existing rules; it shows a reminder
  (`userBlock.serverRules.entryHelp`) telling where the entry is, since an empty rule list gives no hint of how to
  add one.
* Add: user picks "this user + type" or "everybody + type" (system notices: everybody only) and confirms; the app
  reads the privacy page (identity check with `parseLoggedUidFromDocument`, falling back to the plain header link),
  returns "already applied" without writing when the rule exists, fetches the ignore form, requires the `ignoresubmit`
  flag and author choices exactly `{author, 0}`, posts once, then re-reads the privacy page to confirm.
* Remove: fresh GET of the full privacy filter form. One form, action exactly the forum's `home.php` with
  `ac=privacy&op=filter`, `formhash`, the `privacy2submit` flag (the template repeats the same button under each
  group: identical buttons are accepted and the flag sent once, conflicting values refused), no multiple selects, and
  a complete page (`</form>`, `</html>`), else fail closed. All checked `filter_note` / `filter_icon` / `filter_gid`
  are kept except the removed rule, posted once, then verified (removed rule gone, every other filter kept).
* Forms are always sent to `https://www.tsdm39.com/home.php?...` (`canonicalForumOperationUrl`): other hosts, ports,
  user info and paths are refused. Malformed pages, urls and bodies give `unknownForm`, never an exception.
* One `NetClientProvider` bound to the account is used for read, write and verification. An explicit refusal of the
  forum is reported as that failure (or `unknownAfterSubmit` when the state changed anyway), never as success. No
  retries, no automatic writes.
* The page layouts used by the tests follow the Discuz source; they are not recorded from the live TSDM deployment.
