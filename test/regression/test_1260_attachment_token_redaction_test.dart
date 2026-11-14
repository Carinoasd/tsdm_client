/// The download token of an attachment (`forum.php?mod=attachment&aid=<base64 of aid|key|time|uid|tid>`) downloads
/// the attachment as the account for an hour; it went into the logs, the exported diagnostics and the description of
/// a feedback as it was. Now the value of `aid` is redacted wherever a log line, an old log or a description has it: in
/// a url, url-encoded inside another url (`url=…%26aid%3D…`), as a map entry; the name stays.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

/// A token of attachment 36 of thread 1000 for uid 31, as the forum writes it in a link.
final String _token = Uri.encodeQueryComponent(base64.encode(utf8.encode('36|f1f2f3f4|1700000000|31|1000')));

void main() {
  final link = 'https://www.tsdm39.com/forum.php?mod=attachment&aid=$_token';

  test('a log line with the link of an attachment', () {
    for (final line in [
      'GET $link',
      'dispatch url: forum.php?mod=attachment&aid=$_token&nothumb=yes',
      'failed to fetch $link: DioException [bad response]',
    ]) {
      final out = redactSensitive(line);
      expect(out, isNot(contains(_token)), reason: line);
      expect(out, contains('aid=$redactionMask'), reason: line);
      expect(out, contains('mod=attachment'), reason: line);
    }
  });

  test('the link url-encoded in the link of a page', () {
    final encoded = Uri.encodeQueryComponent('forum.php?mod=attachment&aid=$_token');
    for (final line in [
      'push /openInApp?url=$encoded&autoOpen=false',
      'push /inAppBrowser?url=${Uri.encodeQueryComponent(link)}',
    ]) {
      final out = redactSensitive(line);
      expect(out, isNot(contains(Uri.encodeQueryComponent(_token))), reason: line);
      expect(out, isNot(contains(_token)), reason: line);
      expect(out, contains('aid%3D$redactionMask'), reason: line);
    }
    // What follows the token stays.
    final tail = redactSensitive('url=${Uri.encodeQueryComponent('forum.php?aid=$_token&nothumb=yes')}&autoOpen=x');
    expect(tail, contains('%26nothumb%3Dyes&autoOpen=x'));
  });

  test('as a map entry, in an old log and in an export', () {
    expect(redactSensitive('{mod: attachment, aid: $_token}'), isNot(contains(_token)));
    expect(redactSensitive('{"aid":"$_token"}'), isNot(contains(_token)));
    expect(redactLogText('12:00 | GET $link\n'), isNot(contains(_token)));
  });

  test('a description with a pasted link', () {
    final out = redactUserText('the attachment $link does not open');
    expect(out, isNot(contains(_token)));
    expect(out, contains('aid=$redactionMask'));
    // The word as prose stays: only a field of a link is a token.
    expect(redactUserText('aid: the first one'), 'aid: the first one');
  });

  test('names that only end like it are other fields', () {
    for (final line in ['paid=1', 'said=yes', 'raid%3Dx']) {
      expect(redactSensitive(line), line);
    }
  });

  test('idempotent', () {
    final once = redactSensitive('GET $link');
    expect(redactSensitive(once), once);
  });
}
