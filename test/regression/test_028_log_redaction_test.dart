import 'package:flutter_test/flutter_test.dart';
import 'package:talker/talker.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/redacting_talker.dart';

/// Logs must never carry cookies, passwords, form hashes or private form contents.
void main() {
  group('redactSensitive', () {
    test('http headers', () {
      expect(
        redactSensitive('Cookie: Ystv_2132_auth=abc123; Ystv_2132_saltkey=s4lt'),
        'Cookie: <redacted>',
      );
      expect(redactSensitive('set-cookie: Ystv_2132_sid=xyz; path=/'), 'set-cookie: <redacted>');
      expect(redactSensitive('Authorization: Bearer abc.def'), 'Authorization: <redacted>');
      expect(redactSensitive('headers: {cookie: a=b, accept: text/html}'), contains('accept: text/html'));
      expect(redactSensitive('headers: {cookie: a=b, accept: text/html}'), isNot(contains('a=b')));
    });

    test('discuz cookies printed as maps, urls or form bodies', () {
      expect(
        redactSensitive('{Ystv_2132_auth: 7f2a%7Cabc, Ystv_2132_saltkey: s4lt, Ystv_2132_lastvisit: 1}'),
        '{Ystv_2132_auth: <redacted>, Ystv_2132_saltkey: <redacted>, Ystv_2132_lastvisit: 1}',
      );
      expect(
        redactSensitive('member.php?mod=logging&action=logout&formhash=abcd1234&x=1'),
        'member.php?mod=logging&action=logout&formhash=<redacted>&x=1',
      );
      expect(
        redactSensitive('formhash=abcd1234&password=p%40ss&username=Alice&loginsubmit=true'),
        'formhash=<redacted>&password=<redacted>&username=Alice&loginsubmit=true',
      );
      expect(redactSensitive("'formhash': 'abcd1234'"), "'formhash': <redacted>");
      expect(redactSensitive('formHash: abcd1234, tid: 1'), 'formHash: <redacted>, tid: 1');
      expect(
        redactSensitive('<input type="hidden" name="formhash" value="abcd1234" />'),
        '<input type="hidden" name="formhash" value="<redacted>" />',
      );
    });

    test('private form contents', () {
      expect(
        redactSensitive('{message: hello there, subject: hi, formhash: abcd1234, tid: 5}'),
        '{message: <redacted>, subject: <redacted>, formhash: <redacted>, tid: 5}',
      );
      expect(
        redactSensitive('message=secret+text&pmsubmit=true&description=my+note'),
        'message=<redacted>&pmsubmit=true&description=<redacted>',
      );
      expect(redactSensitive('"message":"private","touid":"1000"'), '"message":<redacted>,"touid":"1000"');
      expect(redactSensitive('answer=42&questionid=3'), 'answer=<redacted>&questionid=<redacted>');
    });

    test('prose and harmless values are left alone', () {
      const prose = 'failed to build chat message: author not found';
      expect(redactSensitive(prose), prose);
      const url = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1264928&page=2';
      expect(redactSensitive(url), url);
      const status = 'reply to thread stored: 1 posts, status code: 200, tid=1, pid=2';
      expect(redactSensitive(status), status);
      expect(redactSensitive(''), '');
      expect(containsSensitive('nothing here'), isFalse);
      expect(containsSensitive('formhash=abcd1234'), isTrue);
    });
  });

  group('RedactingTalker', () {
    late RedactingTalker talker;

    setUp(() => talker = RedactingTalker(settings: TalkerSettings(useConsoleLogs: false)));

    test('messages are redacted before they reach the history', () {
      talker
        ..debug('build cookie: {Ystv_2132_auth: abc123}')
        ..info('POST forum.php formhash=abcd1234 message=hello')
        ..error('Cookie: a=b', Exception('Cookie: c=d'))
        ..log('token=xyz', logLevel: LogLevel.warning);
      final texts = talker.history.map((e) => e.generateTextMessage()).join('\n');
      expect(texts, isNot(contains('abc123')));
      expect(texts, isNot(contains('abcd1234')));
      expect(texts, isNot(contains('hello')));
      expect(texts, isNot(contains('a=b')));
      expect(texts, isNot(contains('c=d')));
      expect(texts, isNot(contains('xyz')));
      expect(texts, contains('<redacted>'));
    });

    test('handled exceptions keep their type name, lose the secret', () {
      talker.handle(const FormatException('bad formhash=abcd1234'), StackTrace.current, 'while posting message=zz9secret');
      final data = talker.history.single;
      final text = data.generateTextMessage();
      expect(text, isNot(contains('abcd1234')));
      expect(text, isNot(contains('zz9secret')));
      expect(text, contains('FormatException'));
      expect(data.exception, isA<RedactedException>());

      talker.handle(const FormatException('nothing secret'));
      expect(talker.history.last.exception, isA<FormatException>(), reason: 'clean exceptions are passed through');
    });
  });
}
