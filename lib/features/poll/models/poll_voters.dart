import 'package:tsdm_client/constants/url.dart';
import 'package:universal_html/parsing.dart';

/// One voter listed by the forum's voters page.
final class PollVoter {
  /// Constructor.
  const PollVoter({required this.uid, required this.name});

  /// User id.
  final int uid;

  /// User name.
  final String name;
}

/// One page of the voters of one poll option.
final class PollVotersPage {
  /// Constructor.
  const PollVotersPage({required this.voters, required this.hasNext});

  /// Voters of this page in the forum's order.
  final List<PollVoter> voters;

  /// The forum links a next page.
  final bool hasNext;
}

/// Whether [url] is the voters page of a thread (`forum.php?mod=misc&action=viewvote&tid=N`) of the forum.
bool isPollVotersUrl(String url) {
  final uri = Uri.tryParse(url);
  final base = Uri.parse(baseUrl);
  return uri != null &&
      uri.origin == base.origin &&
      uri.path == '/forum.php' &&
      uri.queryParameters['mod'] == 'misc' &&
      uri.queryParameters['action'] == 'viewvote' &&
      int.tryParse(uri.queryParameters['tid'] ?? '') != null;
}

/// The url of [page] of the voters of option [optionId] of the poll whose voters page is [votersUrl], as the forum's
/// ajax window asks it. Null when [votersUrl] is not a voters page.
String? pollVotersPageUrl(String votersUrl, String optionId, int page) {
  if (!isPollVotersUrl(votersUrl) || int.tryParse(optionId) == null || page < 1) {
    return null;
  }
  final uri = Uri.parse(votersUrl);
  final tid = uri.queryParameters['tid']!;
  return Uri.parse(baseUrl)
      .replace(
        path: '/forum.php',
        queryParameters: {
          'mod': 'misc',
          'action': 'viewvote',
          'tid': tid,
          'polloptionid': optionId,
          if (page > 1) 'page': '$page',
          'inajax': '1',
        },
      )
      .toString();
}

final _cdata = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true);

/// Parse the voters window [raw] (an ajax xml answer carrying the `ul.voterl` list). Null when the answer is not the
/// voters window (a message, no permission): an empty list is a window without voters.
PollVotersPage? parsePollVoters(String raw) {
  final html = _cdata.firstMatch(raw)?.group(1) ?? raw;
  final document = parseHtmlDocument(html);
  if (document.querySelector('.voterlist') == null) {
    return null;
  }
  final voters = <PollVoter>[];
  for (final link in document.querySelectorAll('ul.voterl li a')) {
    final uid = int.tryParse(RegExp(r'uid=(\d+)').firstMatch(link.getAttribute('href') ?? '')?.group(1) ?? '');
    final name = link.text?.trim() ?? '';
    if (uid != null && uid > 0 && name.isNotEmpty) {
      voters.add(PollVoter(uid: uid, name: name));
    }
  }
  return PollVotersPage(voters: List.unmodifiable(voters), hasNext: document.querySelector('.pg a.nxt') != null);
}
