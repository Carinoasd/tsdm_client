/// The progress of the current account towards the next credit-based user group.
///
/// The forum has no app API for it, so `home.php?mod=spacecp&ac=usergroup` is read as the web page: without `gid` it
/// is about the next group (and says how many credits are missing), with `gid` about that group (and says where it
/// starts). The samples under `test/data/usergroup_progress` are those pages of the test forum with the permission
/// tables cut away (the account is uid 31, the groups of the default forum).
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/user_group_progress.dart';
import 'package:tsdm_client/features/profile/repository/user_group_progress_repository.dart';
import 'package:tsdm_client/features/profile/widgets/user_group_progress_bar.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';

const _dir = 'test/data/usergroup_progress';

String _sample(String name) => File('$_dir/$name.html').readAsStringSync();

/// A forum serving [defaultPage] without `gid` and `gid_<n>.html` with it, recording the requests.
final class _Forum implements HttpClientAdapter {
  _Forum(this.defaultPage);

  final String defaultPage;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final gid = options.uri.queryParameters['gid'];
    return ResponseBody.fromString(
      gid == null ? _sample(defaultPage) : _sample('gid_$gid'),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

_Forum _use(String defaultPage) {
  final forum = _Forum(defaultPage);
  getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );
  return forum;
}

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  tearDown(() async {
    if (getIt.isRegistered<NetClientProvider>()) {
      await getIt.unregister<NetClientProvider>();
    }
  });

  group('the page', () {
    test('of a credit-based group names the next group and the credits missing', () {
      final page = UserGroupPage.parse(_sample('default_member_mid'))!;
      expect(page.uid, 31);
      expect(page.mainGroupName, '高级会员');
      expect(page.credits, 700);
      expect(page.viewedGroupName, '金牌会员');
      expect(page.viewedGid, 14);
      // 700 credits and 300 missing.
      expect(page.viewedThreshold, 1000);
      expect(page.memberGroups.map((g) => g.gid), [9, 10, 11, 12, 13, 14, 15]);
      expect(page.extraGroups, isEmpty);
    });

    test('of a group already reached says where it starts', () {
      expect(UserGroupPage.parse(_sample('gid_13'))!.viewedThreshold, 500);
      expect(UserGroupPage.parse(_sample('gid_9'))!.viewedThreshold, -9999999);
      // The group above still needs credits: 700 + 2300.
      expect(UserGroupPage.parse(_sample('gid_15'))!.viewedThreshold, 3000);
    });

    test('of the highest group or a special one has no group to go to', () {
      for (final name in ['default_member_top', 'default_special']) {
        final page = UserGroupPage.parse(_sample(name))!;
        expect(page.viewedGroupName, isNull, reason: name);
        expect(page.viewedThreshold, isNull, reason: name);
      }
    });

    test('lists the other groups of the member', () {
      final page = UserGroupPage.parse(_sample('default_member_ext'))!;
      expect(page.extraGroups.map((g) => (g.gid, g.name)), [(22, '测试字幕组')]);
    });

    test('whose notice has no unit element is not guessed, nor is one without credits', () {
      final plain = _sample('default_member_mid').replaceAll('<span title="">积分</span>', '积分');
      expect(UserGroupPage.parse(plain)!.viewedThreshold, isNull);
      expect(UserGroupPage.parse(_sample('default_member_mid').replaceAll('积分: 700', '')), isNull);
      // The element gone altogether: the "missing" number of the next group's table is not the credits.
      final gone = _sample(
        'default_member_mid',
      ).replaceAll(RegExp(r'<tr>\s*<th class="alt">.*?</th>\s*</tr>', dotAll: true), '');
      expect(gone, isNot(contains('积分: 700')));
      expect(UserGroupPage.parse(gone), isNull);
    });

    test('that is no user group page is not read', () {
      expect(UserGroupPage.parse('<html><body>login</body></html>'), isNull);
    });
  });

  group('the repository', () {
    test('reads the bar from the next group and the current one', () async {
      final forum = _use('default_member_mid');
      final progress = _right(await UserGroupProgressRepository(currentUid: () => 31).fetchProgress().run())!;
      expect(progress.mainGroupName, '高级会员');
      expect(progress.nextName, '金牌会员');
      expect(progress.currentFrom, 500);
      expect(progress.nextFrom, 1000);
      expect(progress.creditsLeft, 300);
      expect(progress.fraction, closeTo(0.4, 1e-9));
      // The account's page and the one of its group.
      expect(forum.requests.map((r) => r.uri.queryParameters['gid']), [null, '13']);
    });

    test('reads every group for the table', () async {
      final forum = _use('default_member_ext');
      final progress = _right(await UserGroupProgressRepository(currentUid: () => 31).fetchDetail().run())!;
      expect(progress.tiers.map((t) => (t.name, t.creditsFrom)), [
        ('限制会员', -9999999),
        ('新手上路', 0),
        ('注册会员', 50),
        ('中级会员', 200),
        ('高级会员', 500),
        ('金牌会员', 1000),
        ('论坛元老', 3000),
      ]);
      expect(progress.currentFrom, 500);
      expect(progress.extraGroups, ['测试字幕组']);
      expect(forum.requests, hasLength(8));
    });

    test('has no progress for the highest group or a special one', () async {
      for (final name in ['default_member_top', 'default_special']) {
        _use(name);
        final repo = UserGroupProgressRepository(currentUid: () => 31);
        expect(_right(await repo.fetchProgress().run()), isNull, reason: name);
        expect(_right(await repo.fetchDetail().run()), isNull, reason: name);
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('never answers with the page of another account', () async {
      _use('default_member_mid');
      final result = await UserGroupProgressRepository(currentUid: () => 32).fetchProgress().run();
      expect(result.swap().getOrElse((_) => throw StateError('expected a failure')), isA<IdentityChangedException>());
    });

    test('never answers once the account changed meanwhile', () async {
      _use('default_member_mid');
      var uid = 31;
      final future = UserGroupProgressRepository(currentUid: () => uid).fetchProgress().run();
      uid = 32;
      final result = await future;
      expect(result.isLeft(), isTrue);
    });
  });

  group('the bar', () {
    test('stays within the group and is full once the next group is reached', () {
      const base = UserGroupProgress(
        mainGroupName: 'a',
        credits: 700,
        currentFrom: 500,
        nextName: 'b',
        nextFrom: 1000,
      );
      expect(base.fraction, closeTo(0.4, 1e-9));
      const reached = UserGroupProgress(
        mainGroupName: 'a',
        credits: 1200,
        currentFrom: 500,
        nextName: 'b',
        nextFrom: 1000,
      );
      expect(reached.fraction, 1);
      expect(reached.creditsLeft, 0);
      // A group that starts below zero counts from zero.
      const first = UserGroupProgress(
        mainGroupName: 'a',
        credits: 25,
        currentFrom: -9999999,
        nextName: 'b',
        nextFrom: 50,
      );
      expect(first.fraction, closeTo(0.5, 1e-9));
      const unknown = UserGroupProgress(
        mainGroupName: 'a',
        credits: 25,
        currentFrom: null,
        nextName: 'b',
        nextFrom: 100,
      );
      expect(unknown.fraction, closeTo(0.25, 1e-9));
    });

    testWidgets('shows the credits and what is missing', (tester) async {
      const progress = UserGroupProgress(
        mainGroupName: '高级会员',
        credits: 700,
        currentFrom: 500,
        nextName: '金牌会员',
        nextFrom: 1000,
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(home: Scaffold(body: UserGroupProgressBar(progress))),
        ),
      );
      expect(find.text('高级会员'), findsOneWidget);
      expect(find.text('金牌会员'), findsOneWidget);
      expect(find.text('700 / 1000'), findsOneWidget);
      expect(find.text(t.userGroupProgress.creditsLeft(n: 300)), findsOneWidget);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.4, 1e-9));
    });
  });
}
