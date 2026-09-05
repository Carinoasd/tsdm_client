import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

/// First post of a priced thread (售价 15 天使币) on Discuz! X5 as seen by a member who has not bought it.
///
/// X5 keeps the pay url in the anchor's `href` and uses `onclick="showWindow('pay', this.href)"`, while X3 kept the
/// url inside `onclick`.
const _fixture = 'test/data/locked_purchase_x5.html';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('X5 purchase block is parsed from the anchor href', () {
    final doc = parseHtmlDocument(File(_fixture).readAsStringSync());
    final locked = Locked.fromLockDivNode(doc.querySelector('div.locked')!);
    expect(locked.isValid(), isTrue);
    expect(locked.lockedWithPurchase, isTrue);
    expect(locked.price, 15);
    expect(locked.purchasedCount, 10);
    expect(locked.tid, '1264966');
    expect(locked.pid, '77983102');
  });

  test('X5 paid post keeps its purchase card', () {
    final doc = parseHtmlDocument(File(_fixture).readAsStringSync());
    final posts = Post.buildListFromThreadDataNode(doc.querySelector('div#postlist'), 1);
    expect(posts, hasLength(1));
    expect(posts.single.locked, hasLength(1));
    expect(posts.single.locked.single.lockedWithPurchase, isTrue);
    expect(posts.single.locked.single.price, 15);
  });

  test('X3 purchase block with the url inside onclick still parses', () {
    final doc = parseHtmlDocument('''
<div class="locked">
  <a href="javascript:;" class="y viewpay" title="购买主题"
     onclick="showWindow('pay', 'forum.php?mod=misc&amp;action=pay&amp;tid=1179745&amp;pid=70986025')">购买主题</a>
  <em class="right">已有 138 人购买</em>
  本主题需向作者支付 <strong>12 天使币</strong> 才能浏览
</div>''');
    final locked = Locked.fromLockDivNode(doc.querySelector('div.locked')!);
    expect(locked.lockedWithPurchase, isTrue);
    expect(locked.price, 12);
    expect(locked.purchasedCount, 138);
    expect(locked.tid, '1179745');
    expect(locked.pid, '70986025');
  });
}
