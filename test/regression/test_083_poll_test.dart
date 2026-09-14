import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:universal_html/parsing.dart';

String _fixture(String name) => File('test/data/poll_${name}_x5.html').readAsStringSync();
ForumPoll _parse(String html, {bool loggedIn = true}) => parseForumPoll(parseHtmlDocument(html), loggedIn: loggedIn);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  test('real multi-choice form keeps its limit, hidden results and public-vote notice', () {
    final poll = _parse(_fixture('multiple'));
    expect(poll.availability, PollAvailability.available);
    expect(poll.maxChoices, 2);
    expect(poll.options, hasLength(5));
    expect(poll.options.every((o) => o.result == null), isTrue);
    expect(poll.notice, contains('公开投票'));
    expect(poll.accepts({'40028', '40029'}), isTrue);
    expect(poll.accepts({'40028', '40029', '40030'}), isFalse);
    expect(poll.accepts({'injected'}), isFalse);
  });
  test('real voted page shows only supplied results, no copy-result BBCode', () {
    final poll = _parse(_fixture('voted'));
    expect(poll.availability, PollAvailability.voted);
    expect(poll.options.first.result, '50.00% (1)');
    expect(poll.notice, '您已经投过票，谢谢您的参与');
    expect(poll.accepts({'40028'}), isFalse);
  });
  test('real guest page distinguishes login from account permission', () {
    expect(_parse(_fixture('guest'), loggedIn: false).availability, PollAvailability.loginRequired);
    expect(_parse(_fixture('guest')).availability, PollAvailability.denied);
  });
  test('derived closed and unsupported forms fail closed', () {
    final closed = _fixture('voted').replaceAll('您已经投过票，谢谢您的参与', '投票已经结束');
    expect(_parse(closed).availability, PollAvailability.closed);
    expect(
      _parse(_fixture('multiple').replaceAll('action=votepoll', 'action=delete')).availability,
      PollAvailability.unsupported,
    );
    expect(
      _parse(
        _fixture('multiple').replaceAll('action="forum.php', 'action="https://evil.example/forum.php'),
      ).availability,
      PollAvailability.unsupported,
    );
    expect(_parse(_fixture('multiple').replaceAll('最多可选 2 项', '未知限制')).availability, PollAvailability.unsupported);
    expect(
      _parse(_fixture('multiple').replaceAll('action="forum.php', 'action="javascript:alert(1)//')).availability,
      PollAvailability.unsupported,
    );
    expect(
      _parse(_fixture('multiple').replaceAll('method="post"', 'method="get"')).availability,
      PollAvailability.unsupported,
    );
  });
  test('derived single-choice form replaces selection', () async {
    final html = _fixture('multiple').replaceAll('type="checkbox"', 'type="radio"');
    final repo = PollRepository(getPage: (_) async => html, postForm: (_, _) async => '');
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit
      ..select('40028', selected: true)
      ..select('40029', selected: true);
    expect(cubit.state.choices, {'40029'});
    await cubit.close();
  });
  test('double submit issues one POST, encodes repeated option keys and uses fresh results', () async {
    var gets = 0;
    final sent = <String>[];
    final pending = Completer<String>();
    final repo = PollRepository(
      getPage: (_) async => _fixture(++gets == 1 ? 'multiple' : 'voted'),
      postForm: (_, body) {
        sent.add(body);
        return pending.future;
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit
      ..select('40028', selected: true)
      ..select('40029', selected: true)
      ..select('40030', selected: true);
    expect(cubit.state.choices, hasLength(2));
    final submit = cubit.submit();
    await cubit.submit();
    expect(sent, hasLength(1));
    expect(sent.single, contains('pollanswers%5B%5D=40028&pollanswers%5B%5D=40029'));
    pending.complete('server response');
    await submit;
    expect(cubit.state.poll!.availability, PollAvailability.voted);
    expect(cubit.state.choices, isEmpty);
    expect(gets, 2);
    await cubit.close();
  });
  test('timed-out POST is not retried; a fresh GET can still confirm it', () async {
    var gets = 0;
    var posts = 0;
    final repo = PollRepository(
      getPage: (_) async => _fixture(++gets == 1 ? 'multiple' : 'voted'),
      postForm: (_, _) async {
        posts++;
        throw TimeoutException('response lost');
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit.select('40028', selected: true);
    await cubit.submit();
    expect(cubit.state.poll!.availability, PollAvailability.voted);
    expect(cubit.state.submissionUnconfirmed, isFalse);
    await cubit.load();
    expect(posts, 1);
    await cubit.close();
  });
  test('failed refresh exposes only GET retry, never success or an old submit form', () async {
    var gets = 0;
    var posts = 0;
    final repo = PollRepository(
      getPage: (_) async {
        if (++gets == 2) throw const HttpException('offline');
        return _fixture(gets == 1 ? 'multiple' : 'voted');
      },
      postForm: (_, _) async {
        posts++;
        return 'error';
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit.select('40028', selected: true);
    await cubit.submit();
    expect(cubit.state.failed, isTrue);
    expect(cubit.state.poll, isNull);
    await cubit.submit();
    await cubit.load();
    expect(posts, 1);
    expect(cubit.state.poll!.availability, PollAvailability.voted);
    await cubit.close();
  });
  test('account switch rejects stale responses and old account submissions', () async {
    int? uid = 1000;
    final pending = Completer<String>();
    var posts = 0;
    final repo = PollRepository(
      getPage: (_) => pending.future,
      postForm: (_, _) async {
        posts++;
        return '';
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => uid, repository: () => repo);
    final load = cubit.load();
    uid = 1001;
    cubit.invalidate();
    pending.complete(_fixture('multiple'));
    await load;
    expect(cubit.state.poll, isNull);
    await cubit.submit();
    expect(posts, 0);
    await cubit.close();
  });
  test('session expiration returns a login state', () async {
    final repo = PollRepository(getPage: (_) async => _fixture('guest'), postForm: (_, _) async => '');
    final poll = await repo.fetch('poll', 1000);
    expect(poll.availability, PollAvailability.loginRequired);
  });
  testWidgets('selection limit is visible and submit stays disabled until an explicit choice', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final repo = PollRepository(getPage: (_) async => _fixture('multiple'), postForm: (_, _) async => '');
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PollCard('1', controller: cubit)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.byType(CheckboxListTile).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).at(1));
    await tester.pumpAndSettle();
    expect(find.text('Selected 2 / 2'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).at(2)).onChanged, isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });
}
