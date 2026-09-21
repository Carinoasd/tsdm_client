import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/forum_url.dart';
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
  final fragment = parseHtmlDocument('<div id="__root">$html</div>');
  final root = fragment.querySelector('div#__root');
  if (root == null) {
    return html;
  }
  var changed = false;
  for (final quote in root.querySelectorAll('div.quote')) {
    final pid = quotedPostId(quote);
    if (pid == null) {
      continue;
    }
    final author = authorOfPost(pid);
    if (author == null || !blockedUids.contains(author)) {
      continue;
    }
    final blockquote = uh.Element.tag('blockquote')..text = placeholder;
    quote.nodes
      ..clear()
      ..add(blockquote);
    changed = true;
  }
  if (!changed) {
    return html;
  }
  return root.innerHtml ?? html;
}
