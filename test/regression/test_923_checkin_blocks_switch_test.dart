/// No account switch while a check-in of the account in use runs, as none while a reply is sent (1.37.0).
///
/// The check-in is sent with the cookie of the account in use, read anew by each of its requests (the state from the
/// forum's app API, the check-in page, the post of the form). Switched meanwhile, the form and the form hash of one
/// account were posted with the session of the other, and the result was recorded for the first one. The switch is
/// now refused while a check-in runs ([CheckinRepository.checkingInAny]) with a hint that says so, and is let
/// through once it ended, however it ended. The auto check-in sends each account with a client of its own cookie: a switch
/// does not reach it.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

/// A forum holding every answer until [gate] completes, then failing it (the check-in only has to end).
final class _HeldForum implements HttpClientAdapter {
  final gate = Completer<void>();
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    await gate.future;
    return ResponseBody.fromString('', 500);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late _HeldForum forum;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    forum = _HeldForum();
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
  });

  tearDown(() async {
    if (!forum.gate.isCompleted) {
      forum.gate.complete();
    }
    await getIt.reset();
    await db.close();
  });

  testWidgets('a check-in running: the switch is refused and said so, until the check-in ended', (
    tester,
  ) async {
    final bloc = SwitchUserBloc(AuthenticationRepository(user: _alice));
    addTearDown(bloc.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          scaffoldMessengerKey: snackbarKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    final context = tester.element(find.byType(Scaffold));

    expect(CheckinRepository.checkingInAny, isFalse);
    late final Future<CheckinResult> checkin;
    await tester.runAsync(() async {
      checkin = CheckinRepository(storageProvider: storage).checkin(_alice.uid!, CheckinFeeling.happy, 'hello');
      for (var i = 0; i < 100 && forum.requests.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(forum.requests, isNotEmpty, reason: 'the check-in asked the forum and waits for its answer');
    expect(CheckinRepository.checkingInAny, isTrue);

    final refused = await switchAccount(context, bloc: bloc, userInfo: _bob);
    await tester.pump();
    expect(refused, SwitchAccountResult.checkinBusy);
    expect(find.text(t.currentAccount.checkinBusy), findsOneWidget);
    expect(isSwitchingAccount, isFalse);
    expect(bloc.state, isA<SwitchUserInitial>(), reason: 'nothing was tried');

    // The forum answers (a failure here): the check-in ended, nothing holds the switch any more.
    await tester.runAsync(() async {
      forum.gate.complete();
      await checkin;
    });
    expect(CheckinRepository.checkingInAny, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });
  test('counted: held until its body ended, however it ended (the page counts its whole check-in with it)', () async {
    final gate = Completer<void>();
    final running = CheckinRepository.counted(() async {
      await gate.future;
      throw StateError('the check-in failed');
    });
    expect(CheckinRepository.checkingInAny, isTrue);
    gate.complete();
    await expectLater(running, throwsStateError);
    expect(CheckinRepository.checkingInAny, isFalse);
  });
}
