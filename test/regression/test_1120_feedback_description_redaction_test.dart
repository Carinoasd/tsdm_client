import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_bundle.dart';
import 'package:tsdm_client/features/diagnostics/feedback.dart';
import 'package:tsdm_client/utils/log_redaction.dart';

/// F2-1: what the user wrote on the feedback page went through the redaction of the logs ([redactLogText]), which
/// took a line starting with `message:` or `note:` (a content field of a log line) and turned a version number such as
/// `1.2.3.4` into `1.2.x.x` (an IPv4 address). A description now goes through [redactUserText], only what is surely
/// a secret, the same in `description.txt` and in the reply to the feedback thread; the logs keep the redaction they
/// had.

const _env = 'tsdm_client 1.57.1+173 · android 14 (API 34)';

/// What the user wrote, as `description.txt` of the bundle has it.
String _bundled(String description) {
  final logs = Directory.systemTemp.createTempSync('feedback_redaction_');
  try {
    final archive = ZipDecoder().decodeBytes(
      buildDiagnosticsBundle(
        DiagnosticsRequest(
          info: 'tsdm_client diagnostics\n',
          logDir: logs.path,
          now: DateTime(2026, 11, 16, 10),
          description: description,
        ),
      ),
    );
    return utf8.decode(archive.findFile(diagnosticsDescriptionName)!.content as List<int>);
  } finally {
    logs.deleteSync(recursive: true);
  }
}

/// What the user wrote, as the reply to the feedback thread has it (before the environment line).
String _replied(String description) {
  final reply = feedbackReplyText(description, _env);
  return reply.substring(0, reply.length - '\n\n$_env'.length);
}

const _prose =
    'message: the reply bar disappears after sending\n'
    'note: only in landscape\n'
    'Updated to 1.2.3.4, still the same; worked on 1.56.0.\n'
    'description: blank page\n'
    'subject=the thread title, text=hello\n'
    'my uid: 35, the answer: no, hash: 9f3c\n'
    'data: none';

void main() {
  test('the words of a description stay: no content field, no version number taken', () {
    expect(redactUserText(_prose), _prose);
    expect(_bundled(_prose), _prose);
    expect(_replied(_prose), _prose);
  });

  test('the logs keep their redaction: the same text is redacted there', () {
    final log = redactLogText(_prose);
    expect(log, isNot(contains('the reply bar disappears')));
    expect(log, isNot(contains('only in landscape')));
    expect(log, contains('1.2.x.x'));
  });

  group('secrets are still taken', () {
    const cases = {
      'Cookie: Ystv_2132_auth=a7Fk2QxAuthCookieZ; Ystv_2132_saltkey=Sk9Lm2Np': ['a7Fk2QxAuthCookieZ', 'Sk9Lm2Np'],
      'the request: formhash=f1f2f3f4&password=PwSecret-41aa': ['f1f2f3f4', 'PwSecret-41aa'],
      'password: PwSecret-41aa': ['PwSecret-41aa'],
      '{"token":"tk-9a8b7c6d5e"}': ['tk-9a8b7c6d5e'],
      'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc': ['eyJhbGciOiJIUzI1NiJ9.abc'],
      'proxy https://user:ProxyPw77@proxy.example.org:8080': ['ProxyPw77'],
      '<input type="hidden" name="formhash" value="f1f2f3f4">': ['f1f2f3f4'],
      'Ystv_2132_auth=a7Fk2QxAuthCookieZ': ['a7Fk2QxAuthCookieZ'],
      'mail me at alice.secret@example.org': ['alice.secret@example.org'],
      'newpassword2=Np-55x and secret: s3cr3t-value': ['Np-55x', 's3cr3t-value'],
      // A pasted login request: the security answer and the captcha are secrets as fields of a form.
      'loginsubmit=yes&password=Pw-1&questionid=1&answer=MothersName&seccodeverify=K7Q2': [
        'Pw-1',
        'MothersName',
        'K7Q2',
      ],
      '<input type="text" name="answer" value="MothersName">': ['MothersName'],
      'Ystv_2132_auth=a7Fk2QxAuthCookieZ; Ystv_2132_sid=Sd8Kq2': ['a7Fk2QxAuthCookieZ', 'Sd8Kq2'],
      'https://forum.test/forum.php?mod=rss&fid=4&auth=a1b2c3%2Fxyz': ['a1b2c3'],
      '<input type="hidden" name="auth" value="Au7-abc123">': ['Au7-abc123'],
      'my_session_id=Ss-abc123, user_session_id: Ss-def456': ['Ss-abc123', 'Ss-def456'],
    };
    for (final MapEntry(key: text, value: secrets) in cases.entries) {
      test(text, () {
        for (final out in [redactUserText(text), _bundled(text), _replied(text)]) {
          for (final secret in secrets) {
            expect(out, isNot(contains(secret)), reason: out);
          }
          expect(out, contains(redactionMask));
        }
      });
    }
  });

  test('both places give the same text (before the brackets of the reply)', () {
    const text =
        'note: blank page\n'
        'formhash=f1f2f3f4 on 1.2.3.4\n'
        'mail alice.secret@example.org';
    final once = redactUserText(text);
    expect(_bundled(text), once);
    expect(_replied(text), once);
    expect(redactUserText(once), once, reason: 'idempotent');
    expect(once, startsWith('note: blank page\n'));
    expect(once, contains('1.2.3.4'));
  });

  test('prose with the words of a secret, no value: left alone', () {
    for (final text in [
      'I passed the login',
      'the password is fine',
      'authors list empty',
      'cookies cleared, still blank',
      'auth: failed after the update',
      'my cookies: none, authorid=31',
      'passport: none, the answer: no, seccode: shown twice',
    ]) {
      expect(redactUserText(text), text);
    }
  });
}
