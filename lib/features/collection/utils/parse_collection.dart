import 'package:collection/collection.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

// The forum's app API (plugin 3.7.0) has no answer of its own for the collection pages (`mod=collection`): asked in
// its JSON mode they come back as the web page. They are parsed from the web page of the forum's template
// (`template/default/forum/collection_*.php`), which the production forum uses unchanged.

final _discuzUidRe = RegExp(r"discuz_uid\s*=\s*'(\d+)'");
final _formHashRe = RegExp('formhash=([0-9a-zA-Z]+)');
final _numberRe = RegExp(r'\d+');
final _starRe = RegExp(r'\bstar(\d)\b');
final _dateRe = RegExp(r'\d{4}-\d{1,2}-\d{1,2}(?:\s+\d{1,2}:\d{2})?');

/// The account the page [document] was served to (its `discuz_uid`, 0 for a guest), null when it names none.
int? collectionViewerUid(uh.Document document) {
  for (final script in document.querySelectorAll('script')) {
    final match = _discuzUidRe.firstMatch(script.text ?? '');
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
  }
  return null;
}

/// The form hash of the session in [root]: a hidden `formhash` input, else the one a link carries (the logout link,
/// the keyword links); empty when there is none.
String collectionFormHash(uh.Element? root) {
  if (root == null) {
    return '';
  }
  final input = root.querySelector('input[name="formhash"]')?.attributes['value']?.trim() ?? '';
  if (input.isNotEmpty) {
    return input;
  }
  for (final anchor in root.querySelectorAll('a[href*="formhash="]')) {
    final hash = _formHashRe.firstMatch(anchor.attributes['href'] ?? '')?.group(1);
    if (hash != null) {
      return hash;
    }
  }
  return '';
}

/// The forum's message instead of the page (`div#messagetext`: the collections are switched off, no such collection,
/// no permission), thrown as [ServerRespondedErrorException] when [document] has it but not [content].
void _throwForumMessage(uh.Document document, uh.Element? content) {
  if (content != null) {
    return;
  }
  final message = document.querySelector('#messagetext p')?.innerText.trim() ?? '';
  if (message.isNotEmpty) {
    throw ServerRespondedErrorException(message);
  }
}

String _text(uh.Element? element) => (element?.innerText ?? '').replaceAll(' ', ' ').trim();

int? _int(String? text) => int.tryParse((text ?? '').trim());

int? _idIn(String? href, String name) => _int(href?.replaceAll('&amp;', '&').uriQueryParameter(name));

/// The rows of a collection list page [document] (`forum.php?mod=collection`, with `op=all` or `op=my`, or `tid=N`
/// for the collections holding a thread), each `div.clct_list > div.xld`:
///
/// ```html
/// <dl>
///   <dd class="m hm"><a href="…action=view&ctid=2"><strong class="xi2">3</strong><span>主题</span></a></dd>
///   <dt class="xw1"><span class="ctag ctag2">我订阅的</span>
///     <div><a href="…action=view&ctid=2" class="xi2" style='color:red;'>Name</a>
///       <span class="ctag_keyword"><a>tag</a>, <a>tag</a></span></div></dt>
///   <dd><p>description ...</p><p>订阅 1, 评论 0</p>
///     <p class="xg1"><a href="home.php?mod=space&uid=33">creator</a> 创建, 最后更新 2026-9-12 06:53</p>
///     <p>最新主题 <a href="forum.php?mod=viewthread&tid=9">subject</a></p></dd>
/// </dl>
/// ```
///
/// The big number is the count the list is ordered by ([order]: threads, comments or subscribers; threads for the
/// lists without an order) and the line under the description the other two, in the template's order; read by
/// their place, never by their labels.
CollectionListResult parseCollectionList(uh.Document document, {CollectionOrder? order}) {
  final list = document.querySelector('div.clct_list');
  final empty = document.querySelector('#ct div.emp');
  _throwForumMessage(document, list ?? empty);
  final items = <CollectionSummary>[];
  for (final row in list?.querySelectorAll('div.xld') ?? const <uh.Element>[]) {
    final link = row.querySelector('dt a[href*="action=view"]');
    final ctid = _idIn(link?.attributes['href'], 'ctid');
    if (link == null || ctid == null) {
      continue;
    }
    final big = _int(row.querySelector('dd.m strong')?.innerText);
    final details = row.querySelectorAll('dl > dd').where((e) => !e.classes.contains('m')).firstOrNull;
    final paragraphs = details?.querySelectorAll('p') ?? const <uh.Element>[];
    final creatorLine = details?.querySelector('p.xg1');
    final latestLink = details?.querySelector('a[href*="mod=viewthread"]');
    final countLine = paragraphs
        .where((p) => p != creatorLine && !p.contains(latestLink) && paragraphs.indexOf(p) > 0)
        .firstOrNull;
    final line = _numberRe.allMatches(countLine?.innerText ?? '').map((m) => int.parse(m.group(0)!)).toList();
    final (threads, follows, comments) = switch (order) {
      CollectionOrder.commentnum => (line.elementAtOrNull(1), line.elementAtOrNull(0), big),
      CollectionOrder.follownum => (line.elementAtOrNull(0), big, line.elementAtOrNull(1)),
      _ => (big, line.elementAtOrNull(0), line.elementAtOrNull(1)),
    };
    final creator = creatorLine?.querySelector('a[href*="uid="]');
    final creatorText = _text(creatorLine);
    final latestTid = _idIn(latestLink?.attributes['href'], 'tid');
    final tag = row.querySelector('dt span.ctag');
    items.add(
      CollectionSummary(
        ctid: ctid,
        name: _text(link),
        description: paragraphs.isEmpty || paragraphs.first == creatorLine ? '' : _text(paragraphs.first),
        keywords: row.querySelectorAll('span.ctag_keyword a').map(_text).where((e) => e.isNotEmpty).toList(),
        threadCount: threads,
        followCount: follows,
        commentCount: comments,
        creatorUid: _idIn(creator?.attributes['href'], 'uid'),
        creatorName: _text(creator),
        lastUpdate: _dateRe.allMatches(creatorText).lastOrNull?.group(0) ?? '',
        latestThread: latestTid == null ? null : (tid: latestTid, subject: _text(latestLink)),
        relation: switch (tag?.classes) {
          final c? when c.contains('ctag0') => CollectionRelation.created,
          final c? when c.contains('ctag1') => CollectionRelation.team,
          final c? when c.contains('ctag2') => CollectionRelation.subscribed,
          _ => null,
        },
        updated: (link.attributes['style'] ?? '').replaceAll(' ', '').contains('color:red'),
      ),
    );
  }
  return CollectionListResult(
    items: items,
    currentPage: document.currentPage() ?? 1,
    totalPages: document.totalPages() ?? 1,
    canCreate: document.querySelector('#ct div.tb li a[href*="action=edit"]') != null,
    formHash: collectionFormHash(document.documentElement),
    viewerUid: collectionViewerUid(document),
  );
}

/// The page of one collection [document] (`forum.php?mod=collection&action=view&ctid=N`): its head (`div.bm.bml`:
/// name, subscribers and the subscription link `a#followlink`, the links of its managers, rating, keywords, creator
/// and the members maintaining it, description), its threads (`div.tl`, each row a `tr` with the thread's link
/// `a.xst`, the reason as the title of its cell) and its counts (the side column `div.tns`).
CollectionDetail parseCollectionDetail(uh.Document document) {
  final head = document.querySelector('#ct div.mn div.bm.bml');
  _throwForumMessage(document, head);
  if (head == null) {
    throw HttpRequestFailedException(200);
  }
  final title = head.querySelector('div.bm_h h1 a');
  final ctid = _idIn(title?.attributes['href'], 'ctid') ?? 0;
  final body = head.querySelector('div.bm_c');
  final follow = head.querySelector('a#followlink');
  final rating = body?.querySelector('div.cl > div[title]');
  final rated = rating?.querySelector('span.clct_ratestar') != null;
  final people = body?.querySelector('div.mbn');
  final creatorLink = people?.querySelectorAll('p a[href*="mod=space"]').where((a) {
    final id = a.parent?.id ?? '';
    return !id.startsWith('k_worker_uid_');
  }).firstOrNull;
  final creatorUid = _idIn(creatorLink?.attributes['href'], 'uid');
  final description = body?.children.where((e) => e.localName == 'div' && e.className.isEmpty).lastOrNull;
  final threads = <CollectionThread>[];
  for (final row in document.querySelectorAll('#ct div.tl div.bm_c tr')) {
    final link = row.querySelector('th a.xst');
    final tid = _idIn(link?.attributes['href'], 'tid');
    if (link == null || tid == null) {
      continue;
    }
    final reasonTitle = row.querySelector('th')?.attributes['title'] ?? '';
    final colon = reasonTitle.indexOf(RegExp('[:：]'));
    final by = row.querySelector('td.by');
    final author = by?.querySelector('cite a[href*="uid="]');
    final num = row.querySelector('td.num');
    threads.add(
      CollectionThread(
        tid: tid,
        subject: (link.attributes['title'] ?? '').trim().isNotEmpty ? link.attributes['title']!.trim() : _text(link),
        reason: colon < 0 ? '' : reasonTitle.substring(colon + 1).trim(),
        authorUid: _idIn(author?.attributes['href'], 'uid'),
        authorName: author != null ? _text(author) : _text(by?.querySelector('cite')),
        date: _text(by?.querySelector('em')),
        replies: _int(num?.querySelector('a')?.innerText),
        views: _int(num?.querySelector('em')?.innerText),
      ),
    );
  }
  final counts = document.querySelectorAll('#ct div.sd div.tns th p');
  return CollectionDetail(
    ctid: ctid,
    name: _text(title),
    description: _text(description),
    keywords: (people?.querySelectorAll('a[href*="source=collectionsearch"]') ?? const <uh.Element>[])
        .map(_text)
        .where((e) => e.isNotEmpty)
        .toList(),
    creator: creatorUid == null ? null : (uid: creatorUid, name: _text(creatorLink)),
    teamworkers: [
      for (final span in people?.querySelectorAll('span[id^="k_worker_uid_"]') ?? const <uh.Element>[])
        if (span.querySelector('a[href*="mod=space"]') case final a?)
          if (_idIn(a.attributes['href'], 'uid') case final uid?) (uid: uid, name: _text(a)),
    ],
    followCount: _int(head.querySelector('#follownum_display')?.innerText) ?? 0,
    followState: switch (follow) {
      null => CollectionFollowState.none,
      final link when link.querySelector('i.u') != null => CollectionFollowState.following,
      _ => CollectionFollowState.canFollow,
    },
    threadCount: _int(counts.elementAtOrNull(0)?.innerText) ?? threads.length,
    commentCount: _int(counts.elementAtOrNull(1)?.innerText) ?? 0,
    averageRate: rated ? double.tryParse(rating?.attributes['title'] ?? '') : null,
    rateCount: rated ? (_int(_numberRe.firstMatch(_text(rating))?.group(0)) ?? 0) : 0,
    canManage:
        head.querySelector('a[href*="op=edit"][href*="ctid="]') != null ||
        head.querySelector('a[href*="op=remove"][href*="ctid="]') != null,
    threads: threads,
    currentPage: document.currentPage() ?? 1,
    totalPages: document.totalPages() ?? 1,
    formHash: collectionFormHash(document.documentElement),
    viewerUid: collectionViewerUid(document),
  );
}

/// The comments page of a collection [document] (`action=view&op=comment&ctid=N`): each comment a `dl` of
/// `div.xld` (the author's link and time in `dt`, the rating's stars `span.starN` in a `dd.cl`, the text in the last
/// `dd`), then the comment form, with the rating's input `ratescore` only while the account has not rated yet (else
/// the stars it gave, "您已评分").
CollectionCommentPage parseCollectionComments(uh.Document document) {
  final head = document.querySelector('#ct div.bm.bml');
  _throwForumMessage(document, head);
  if (head == null) {
    throw HttpRequestFailedException(200);
  }
  final title = head.querySelector('h1 a');
  final comments = <CollectionComment>[];
  for (final dl in document.querySelectorAll('#ct div.xld dl')) {
    final author = dl.querySelector('dt a[href*="uid="]');
    final dds = dl.querySelectorAll('dd').where((e) => !e.classes.contains('m')).toList();
    final star = dds.where((e) => e.classes.contains('cl')).firstOrNull?.querySelector('span.star');
    final message = dds.where((e) => !e.classes.contains('cl')).lastOrNull;
    final time = dl.querySelector('dt span.xg1');
    comments.add(
      CollectionComment(
        uid: _idIn(author?.attributes['href'], 'uid'),
        username: _text(author),
        time: _text(time),
        message: _text(message),
        rate: _int(_starRe.firstMatch(star?.className ?? '')?.group(1)),
      ),
    );
  }
  final form = document.querySelector('#ct form[action*="action=comment"] textarea[name="message"]')?.parent;
  final commentForm = document
      .querySelectorAll('#ct form[action*="action=comment"]')
      .where((f) => f.querySelector('textarea[name="message"]') != null)
      .firstOrNull;
  final mayRate = commentForm?.querySelector('input[name="ratescore"]') != null;
  return CollectionCommentPage(
    ctid: _idIn(title?.attributes['href'], 'ctid') ?? 0,
    name: _text(title),
    comments: comments,
    currentPage: document.currentPage() ?? 1,
    totalPages: document.totalPages() ?? 1,
    canComment: form != null,
    myRate: commentForm == null || mayRate
        ? null
        : _int(_starRe.firstMatch(commentForm.querySelector('span.star')?.className ?? '')?.group(1)),
    formHash: collectionFormHash(document.documentElement),
    viewerUid: collectionViewerUid(document),
  );
}

/// The forum's window to put thread [tid] in a collection, its html [html] (`action=edit&op=addthread`): the
/// account's collections that do not hold the thread yet (the `option`s of `select#selectCollection`), how many more
/// it may create (`var remaincreateable = N;`) and the form hash; null when [html] is no such window.
CollectThreadForm? parseCollectThreadForm(String html, {required int tid, required int viewerUid}) {
  final fragment = parseHtmlDocument('<div>$html</div>');
  final form = fragment.querySelector('form#form_addcollectionthread');
  if (form == null) {
    return null;
  }
  final remaining = _int(RegExp(r'remaincreateable\s*=\s*(-?\d+)').firstMatch(html)?.group(1)) ?? 0;
  return CollectThreadForm(
    tid: tid,
    choices: [
      for (final option in form.querySelectorAll('select[name="ctid"] option'))
        if (_int(option.attributes['value']) case final ctid? when ctid > 0) (ctid: ctid, name: _text(option)),
    ],
    remainingCreate: remaining,
    formHash: collectionFormHash(form),
    viewerUid: viewerUid,
  );
}
