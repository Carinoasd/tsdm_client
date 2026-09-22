import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

export 'package:tsdm_client/features/blocking/utils/forum_url.dart';

/// Whether the content authored by [uid] is hidden for the current account, see [UserBlockList.hides].
///
/// Rebuilds the calling widget when the block state of [uid] changes. Returns false when no [UserBlockCubit] is
/// provided above [context] (previews and isolated widget tests): content is never hidden by accident.
bool isBlockedByCurrentUser(BuildContext context, String? uid) {
  final parsed = uid == null ? null : int.tryParse(uid);
  if (parsed == null || parsed <= 0) {
    return false;
  }
  try {
    return context.select<UserBlockCubit, bool>((c) => c.state.hides(parsed));
  } on ProviderNotFoundException {
    return false;
  }
}

/// The block list of the current account, rebuilding the caller on change when [listen] is true.
///
/// A known empty list when no [UserBlockCubit] is provided above [context].
UserBlockList currentBlockList(BuildContext context, {bool listen = true}) {
  try {
    return listen ? context.watch<UserBlockCubit>().state : context.read<UserBlockCubit>().state;
  } on ProviderNotFoundException {
    return const UserBlockList.empty(null);
  }
}

/// Parse the `pid` of a post that a quote links to, only from the forum's own `findpost` redirect.
///
/// Discuz renders a quote as
///
/// ```html
/// <div class="quote"><blockquote><font size="2"><a href="forum.php?mod=redirect&goto=findpost&pid=1&ptid=2">
/// <font color="#999999">USER 发表于 2026-9-5 17:38</font></a></font><br>...</blockquote></div>
/// ```
///
/// The quoted username is plain text and can be anything, so the author is NEVER taken from it or from other links
/// inside the quote; only the pid is trusted and the caller maps it to a post it already knows the author of.
int? quotedPostId(uh.Element quote) {
  for (final a in quote.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    final uri = Uri.tryParse(href.replaceAll('&amp;', '&'));
    // Relative forum link or the forum host only, and exactly `forum.php` (not `evilforum.php` or `x/forum.php`).
    if (uri == null || !isForumScript(uri, 'forum.php')) {
      continue;
    }
    final q = safeQueryParameters(uri);
    if (q == null || q['mod'] != 'redirect' || q['goto'] != 'findpost') {
      continue;
    }
    final pid = int.tryParse(q['pid'] ?? '');
    if (pid != null && pid > 0) {
      return pid;
    }
  }
  return null;
}

/// Replace quotes of blocked authors in post [html] with [placeholder].
///
/// [authorOfPost] maps a quoted pid to the uid of its author and returns null when unknown (the quoted post is not
/// loaded). Quotes of unknown source are kept as is: the app can not tell who wrote them and does not guess.
///
/// Returns [html] unchanged (same instance) when nothing is replaced.
String redactBlockedQuotes(
  String html, {
  required Set<int> blockedUids,
  required int? Function(int pid) authorOfPost,
  required String placeholder,
}) {
  if (blockedUids.isEmpty || !html.contains('quote')) {
    return html;
  }
  return _redactQuotes(html, (pid) => _isBlockedAuthor(authorOfPost(pid), blockedUids), placeholder).html;
}

/// Same as [redactBlockedQuotes] on the html of [post], remembered with [post].
///
/// Post cards are kept alive on the thread page and rebuilt with it (for example when another page is loaded), and
/// parsing every kept post with a quote on each rebuild costs frames. The html of [post] is parsed once to learn the
/// pids its quotes link to. A later call only maps these pids to their authors: when none is blocked [post]'s html is
/// returned without parsing, and the replacement is redone only when the quotes to replace or [placeholder] changed.
String redactBlockedQuotesOf(
  Post post, {
  required Set<int> blockedUids,
  required int? Function(int pid) authorOfPost,
  required String placeholder,
}) {
  final html = post.data;
  if (blockedUids.isEmpty || !html.contains('quote')) {
    return html;
  }
  bool blocked(int pid) => _isBlockedAuthor(authorOfPost(pid), blockedUids);
  final memo = _quoteMemos[post];
  if (memo == null || !identical(memo.html, html)) {
    final parsed = _redactQuotes(html, blocked, placeholder);
    _quoteMemos[post] = _QuoteMemo(html, parsed.quotedPids)..keep(parsed.replacedPids, placeholder, parsed.html);
    return parsed.html;
  }
  final replace = memo.quotedPids.where(blocked).toSet();
  if (replace.isEmpty) {
    return html;
  }
  if (placeholder != memo.placeholder ||
      replace.length != memo.replacedPids.length ||
      !replace.containsAll(memo.replacedPids)) {
    memo.keep(replace, placeholder, _redactQuotes(html, replace.contains, placeholder).html);
  }
  return memo.result;
}

bool _isBlockedAuthor(int? author, Set<int> blockedUids) => author != null && blockedUids.contains(author);

/// What [redactBlockedQuotesOf] learnt about the html of one post.
final class _QuoteMemo {
  _QuoteMemo(this.html, this.quotedPids);

  /// The html parsed.
  final String html;

  /// Pids the quotes of [html] link to, see [quotedPostId].
  final Set<int> quotedPids;

  /// Pids of the quotes replaced by the last redaction.
  Set<int> replacedPids = const {};

  /// Placeholder of the last redaction.
  String placeholder = '';

  /// Result of the last redaction.
  String result = '';

  void keep(Set<int> replacedPids, String placeholder, String result) {
    this.replacedPids = replacedPids;
    this.placeholder = placeholder;
    this.result = result;
  }
}

/// Kept with the post instance: loading more pages keeps the instances of the posts already loaded.
final _quoteMemos = Expando<_QuoteMemo>('blocked quote memo');

/// Parse [html] once: the pids its quotes link to, the pids of the quotes replaced, and [html] with the quotes whose
/// pid [replace] accepts replaced by [placeholder] ([html] itself when none is).
///
/// The pid of a quote is read before anything inside it is changed, so the result only depends on [html],
/// [placeholder] and which of the quoted pids [replace] accepts.
({Set<int> quotedPids, Set<int> replacedPids, String html}) _redactQuotes(
  String html,
  bool Function(int pid) replace,
  String placeholder,
) {
  final fragment = parseHtmlDocument('<div id="__root">$html</div>');
  final root = fragment.querySelector('div#__root');
  if (root == null) {
    return (quotedPids: const {}, replacedPids: const {}, html: html);
  }
  final quoted = <int>{};
  final replaced = <int>{};
  for (final quote in root.querySelectorAll('div.quote')) {
    final pid = quotedPostId(quote);
    if (pid == null) {
      continue;
    }
    quoted.add(pid);
    if (!replace(pid)) {
      continue;
    }
    final blockquote = uh.Element.tag('blockquote')..text = placeholder;
    quote.nodes
      ..clear()
      ..add(blockquote);
    replaced.add(pid);
  }
  if (replaced.isEmpty) {
    return (quotedPids: quoted, replacedPids: replaced, html: html);
  }
  return (quotedPids: quoted, replacedPids: replaced, html: root.innerHtml ?? html);
}
