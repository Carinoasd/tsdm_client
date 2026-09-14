# Achievement page observations (2026-09-15)

Source: https://www.tsdm39.com/plugin.php?id=tsdmtitle:achi

Three authorized test accounts independently returned the same authenticated X5 layout:

```html
<div id="ct" class="wp cl">
  <div class="bm">
    <div class="bm_h"><h2>成就列表</h2></div>
    <div class="bm_c"><p class="emp">暂无成就</p></div>
  </div>
</div>
```

The real page has a category row with only 全部. Guests receive 尚未登录 instead.
No achievement names, progress values, conditions, completion states or reward states
are present in the current authenticated responses. Empty is not interpreted as 0%.

This implementation adds a functioning authenticated, read-only page for the current
endpoint. It verifies the server identity, clears content during account changes,
discards stale responses, supports retry and refresh, and reports the explicit empty
state. If the list later contains text, it preserves that text and any explicit HTML
progress values without inferring percentages. Scripts, hidden content and credentials
are excluded; links and buttons are plain text and cannot claim rewards.

Structured achievement cards and completed/incomplete filters require a populated
live response before their selectors and semantics can be validated. The nonempty
test contents are labelled synthetic and test only the read-only fallback, not a
claimed live schema. Issue #44 should remain open for that validation when the forum
publishes achievements. No reward or administrative operations were performed.
