/// Deleting an attachment with the form hash of an edit page that expired since (logged in again, or left open long):
/// the forum stops the GET at its start (`discuz_application::_xss_check`, `system_error('request_tainting')`) with
/// HTTP 503 before the deletion runs; nothing was deleted. The app tells the page expired, to open the edit page
/// again, instead of its plain "failed".
///
/// The 503 carries no word the app could match: the forum prints its error page only when `showerror` is on, and the
/// client keeps no body of an error status. A site challenge (`cf-mitigated: challenge`) and other statuses stay
/// failures.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/remove_rate.dart';
import 'package:tsdm_client/features/moderate/repository/floor_ops_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _author = 42;

/// A repository whose one GET that writes answers [answer], recording the urls asked in [asked].
FloorOpsRepository _repo(Either<AppException, ModerateResponse> answer, List<String> asked) => FloorOpsRepository(
  get: (_) async => throw StateError('a deletion is no read'),
  getOnce: (url) async {
    asked.add(url);
    return answer;
  },
  post: (_, _) async => throw StateError('no post'),
  currentUid: () => _author,
);

Future<Either<AppException, FloorOpOutcome>> _delete(FloorOpsRepository repo) =>
    repo.deleteAttachment(tid: '1', pid: '2', aid: 90008, formHash: 'f1f2f3f4', formUid: _author).run();

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  test('a 503 of the forum: the edit page expired, asked once', () async {
    final asked = <String>[];
    final outcome = await _delete(
      _repo(left(HttpHandshakeFailedException('bad response', statusCode: HttpStatus.serviceUnavailable)), asked),
    );
    expect(
      outcome.getRight().toNullable(),
      isA<FloorOpRefused>().having((e) => e.message, 'message', t.moderateFloorOps.formExpired),
    );
    expect(asked, hasLength(1));

    final status = await _delete(_repo(right((statusCode: HttpStatus.serviceUnavailable, data: '')), []));
    expect(
      status.getRight().toNullable(),
      isA<FloorOpRefused>().having((e) => e.message, 'message', t.moderateFloorOps.formExpired),
    );
  });

  test('a site challenge, or another status, stays a failure', () async {
    final challenge = await _delete(
      _repo(
        left(
          HttpHandshakeFailedException(
            'challenge',
            statusCode: HttpStatus.serviceUnavailable,
            headers: Headers.fromMap({
              'cf-mitigated': ['challenge'],
            }),
          ),
        ),
        [],
      ),
    );
    expect(challenge.getLeft().toNullable(), isA<HttpHandshakeFailedException>());

    final internal = await _delete(
      _repo(left(HttpHandshakeFailedException('bad response', statusCode: HttpStatus.internalServerError)), []),
    );
    expect(internal.getLeft().toNullable(), isA<HttpHandshakeFailedException>());

    final offline = await _delete(_repo(left(HttpHandshakeFailedException('offline', connectionFailed: true)), []));
    expect(offline.getLeft().toNullable(), isA<HttpHandshakeFailedException>());
  });
}
