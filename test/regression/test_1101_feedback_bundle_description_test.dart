import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_bundle.dart';

/// E: what the user wrote on the feedback page goes into the diagnostics bundle as `description.txt`, its secrets
/// redacted (`redactUserText`, see test 1120); a blank one adds no file.

Archive _bundle(String description, Directory logs) => ZipDecoder().decodeBytes(
  buildDiagnosticsBundle(
    DiagnosticsRequest(
      info: 'tsdm_client diagnostics\n',
      logDir: logs.path,
      now: DateTime(2026, 11, 15, 10),
      description: description,
    ),
  ),
);

void main() {
  late Directory logs;

  setUp(() => logs = Directory.systemTemp.createTempSync('feedback_bundle_'));
  tearDown(() => logs.deleteSync(recursive: true));

  test('the description is in the bundle, redacted', () {
    const email = 'alice.secret@example.org';
    const password = 'PwSecret-41aa';
    const cookie = 'a7Fk2QxAuthCookieZ';
    final archive = _bundle(
      'The thread page goes blank.\n'
      'My mail is $email, the request was formhash=f1f2f3f4&password=$password\n'
      'Cookie: Ystv_2132_auth=$cookie\n',
      logs,
    );
    final file = archive.findFile(diagnosticsDescriptionName);
    expect(file, isNotNull);
    final text = utf8.decode(file!.content as List<int>);
    expect(text, contains('The thread page goes blank.'));
    for (final secret in [email, password, cookie, 'f1f2f3f4']) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
    expect(archive.findFile(diagnosticsInfoName), isNotNull);
  });

  test('a blank description adds no file', () {
    for (final blank in ['', '  \n\t ']) {
      expect(_bundle(blank, logs).findFile(diagnosticsDescriptionName), isNull);
    }
  });
}
