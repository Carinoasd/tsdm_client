# Draft box (#125)

## User flow

My threads gains a third Drafts tab backed by the signed-in account's forum drafts (`home.php?mod=space&do=thread&view=me&type=thread&filter=save`). It has independent loading, empty, failure, refresh and pagination states. Opening a row rechecks the thread through GET and resolves its first-post edit link. Returning from the existing editor reloads the list.

Saving a new draft offers a direct route to My threads → Drafts. Resaving an existing draft returns to its caller. Publishing remains an explicit separate action. The X5 header's sibling draft marker reaches the first Post model so the existing thread-page edit button also retains draft behavior.

## Integrity and scope

- Bind an editor to one account and network client. Same-account authentication verification must not erase input; actual logout/switch invalidates the old form and pending results.
- Fetch private lists and forms only when the response's logged-in UID matches the owning account. Discard stale refresh, pagination and opening results.
- No `pubsave` GET links are followed. All submissions are explicit, single-attempt URL-encoded POSTs; ambiguous responses do not trigger retries.
- Accept a validated same-forum thread redirect, an explicit successful message forward link, or a verified thread page. HTTP 200 alone is insufficient. Confirm the server draft marker before labelling a draft save successful; moderation or unreadable confirmation receives distinct wording.
- Do not overwrite special first-post fields, classified data, scheduled publication or JSON editor content that this editor cannot preserve. Ordinary text replies inside special threads remain editable. Offer the external website editor for unsupported content.
- Draft titles, content and form tokens are not added to diagnostics or fixtures. Tests use synthetic data.
- No local autosave, offline drafts or batch deletion in this issue.

## Verification

Parser, account/race, submission, and navigation/widget regressions cover supported flows and failures. Live authenticated inspection confirmed the filtered draft endpoint and its empty state. No live save/publish round trip or Android/Windows device validation is claimed; a synthetic private save attempt did not create a confirmed draft. No public test topic was posted.
