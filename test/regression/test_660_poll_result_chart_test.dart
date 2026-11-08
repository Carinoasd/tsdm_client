/// Poll results drawn as bars (a bar as wide as the share of the votes, the votes at its tail, the account's own
/// choice in the primary color) and the voters of an option read from the forum's voters window.
///
/// The fixture `poll_voters_x5.xml` is the forum's ajax voters window (`forum.php?mod=misc&action=viewvote&inajax=1`,
/// Discuz X5 test forum) with its user names replaced; the next page link is derived from the forum's pager markup.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/models/poll_voters.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:tsdm_client/widgets/card/poll_result_bar.dart';
import 'package:universal_html/parsing.dart';

const _tid = '9200369';
const _votersUrl = '$baseUrl/forum.php?mod=misc&action=viewvote&tid=$_tid';

PollSpecial _special(String name) {
  final json =
      jsonDecode(File('test/data/tsdmapp/special_v15_poll_$name.json').readAsStringSync()) as Map<String, dynamic>;
  return threadPageFromApi(json, 1).special! as PollSpecial;
}

String _voters() => File('test/data/poll_voters_x5.xml').readAsStringSync();

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
  });
  tearDownAll(getIt.reset);
  setUp(PollCubit.forgetVotesSent);

  group('numbers of the options', () {
    test('the app API gives votes and percent; hidden results give none', () {
      final shown = forumPollFromSpecial(_special('multi_voted'), loggedIn: true);
      expect(shown.options.map((e) => e.votes), [1, 1, 1]);
      expect(shown.options.first.percent, 33.33);
      final hidden = forumPollFromSpecial(_special('multi_hidden'), loggedIn: true);
      expect(hidden.options.every((e) => e.votes == null && e.percent == null && e.result == null), isTrue);
    });

    test('the web form is read for the same numbers', () {
      final html = File('test/data/poll_voted_x5.html').readAsStringSync();
      final poll = parseForumPoll(parseHtmlDocument(html), loggedIn: true);
      expect(poll.options.first.result, '50.00% (1)');
      expect(poll.options.first.votes, 1);
      expect(poll.options.first.percent, 50);
      final hiddenForm = File('test/data/poll_multiple_x5.html').readAsStringSync();
      final hidden = parseForumPoll(parseHtmlDocument(hiddenForm), loggedIn: true);
      expect(hidden.options.every((e) => e.votes == null), isTrue);
    });
  });

  group('voters window', () {
    test('lists the voters with their ids and no next page', () {
      final page = parsePollVoters(_voters())!;
      expect(page.voters.map((e) => (e.uid, e.name)), [(31, '测试用户甲'), (35, '测试用户乙')]);
      expect(page.hasNext, isFalse);
    });

    test('a pager with a next link says there is another page', () {
      final withPager = _voters().replaceFirst(
        '<div class="c cl mbn">',
        '<div class="c cl mbn"><div class="pg"><strong>1</strong><a href="forum.php?page=2" class="nxt">下一页</a></div>',
      );
      expect(parsePollVoters(withPager)!.hasNext, isTrue);
    });

    test('an answer that is not the voters window is refused', () {
      expect(parsePollVoters('<?xml version="1.0"?><root><![CDATA[<p>没有权限</p>]]></root>'), isNull);
    });

    test('only the forum voters page of a thread is asked, for a numeric option', () {
      expect(isPollVotersUrl('$baseUrl/forum.php?mod=misc&action=viewvote&tid=1'), isTrue);
      expect(isPollVotersUrl('https://evil.example/forum.php?mod=misc&action=viewvote&tid=1'), isFalse);
      expect(isPollVotersUrl('$baseUrl/forum.php?mod=misc&action=delete&tid=1'), isFalse);
      expect(pollVotersPageUrl(_votersUrl, '263', 2), contains('polloptionid=263'));
      expect(pollVotersPageUrl(_votersUrl, '263', 2), contains('page=2'));
      expect(pollVotersPageUrl(_votersUrl, '263', 1), isNot(contains('page=')));
      expect(pollVotersPageUrl(_votersUrl, '263', 1), contains('inajax=1'));
      expect(pollVotersPageUrl(_votersUrl, 'x', 1), isNull);
      expect(pollVotersPageUrl('https://evil.example/', '263', 1), isNull);
    });
  });

  group('cubit', () {
    PollCubit build({required List<String> asked, int uid = 31}) {
      final repo = PollRepository(
        getPage: (_) async => '',
        postForm: (_, _) async => '',
        getVoters: (url) async {
          asked.add(url);
          return _voters();
        },
      );
      return PollCubit(url: 'poll', currentUid: () => uid, repository: () => repo)
        ..adoptSpecial(_special('multi_voted'));
    }

    test("reading the voters of an option the account is in marks it as the account's own", () async {
      final asked = <String>[];
      final cubit = build(asked: asked);
      expect(cubit.mine, isEmpty);
      final page = await cubit.loadVoters('263');
      expect(page.voters, hasLength(2));
      expect(asked.single, contains('polloptionid=263'));
      expect(cubit.mine, {'263'});
      await cubit.close();
    });

    test('an account that is not listed marks nothing', () async {
      final cubit = build(asked: [], uid: 99);
      // The page was served to uid 31: nothing is adopted for another account, and nothing is read for it.
      expect(cubit.state.poll, isNull);
      await expectLater(cubit.loadVoters('263'), throwsFormatException);
      expect(cubit.mine, isEmpty);
      await cubit.close();
    });

    test('a poll without a voters page reads no voters', () async {
      final cubit = PollCubit(
        url: 'poll',
        currentUid: () => 31,
        repository: () => PollRepository(getPage: (_) async => '', postForm: (_, _) async => ''),
      )..adoptSpecial(_special('single_after_vote'));
      await expectLater(cubit.loadVoters('1'), throwsFormatException);
      await cubit.close();
    });
  });

  group('card', () {
    Future<PollCubit> pump(WidgetTester tester, String name, {List<String>? asked}) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final repo = PollRepository(
        // The card asks for its poll once more when it is given a controller; the same page answers.
        getPage: (_) async => File('test/data/tsdmapp/special_v15_poll_$name.json').readAsStringSync(),
        postForm: (_, _) async => '',
        getVoters: (url) async {
          asked?.add(url);
          return _voters();
        },
      );
      final cubit = PollCubit(url: 'poll', currentUid: () => 31, repository: () => repo)..adoptSpecial(_special(name));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: PollCard('1', controller: cubit)),
            ),
          ),
        ),
      );
      await tester.pump();
      return cubit;
    }

    testWidgets('a poll showing its results draws a bar for each option, with the votes at the tail', (tester) async {
      final cubit = await pump(tester, 'multi_voted');
      expect(find.byType(PollResultBar), findsNWidgets(3));
      expect(find.text('1 · 33.33%'), findsNWidgets(3));
      await tester.pumpWidget(const SizedBox());
      await cubit.close();
    });

    testWidgets('a poll hiding its results draws no bar', (tester) async {
      final cubit = await pump(tester, 'multi_hidden');
      expect(find.byType(PollResultBar), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await cubit.close();
    });

    testWidgets('the bar is as wide as the share and the own option is in the primary color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SizedBox(width: 400, child: PollResultBar(votes: 3, percent: 25)),
                SizedBox(width: 400, child: PollResultBar(votes: 9, percent: 75, mine: true)),
              ],
            ),
          ),
        ),
      );
      final fills = find.byKey(const ValueKey('poll-result-fill'));
      final factors = tester
          .widgetList<FractionallySizedBox>(find.ancestor(of: fills, matching: find.byType(FractionallySizedBox)))
          .map((e) => e.widthFactor)
          .toList();
      expect(factors, [0.25, 0.75]);
      final colors = tester.widgetList<ColoredBox>(fills).map((e) => e.color).toList();
      final scheme = Theme.of(tester.element(fills.first)).colorScheme;
      expect(colors, [scheme.primaryContainer, scheme.primary]);
    });

    testWidgets('tapping an option of a public vote opens its voters; the own option is then marked', (tester) async {
      final asked = <String>[];
      final cubit = await pump(tester, 'multi_voted', asked: asked);
      expect(cubit.mine, isEmpty);
      await tester.tap(find.textContaining('P2 一').first);
      await tester.pumpAndSettle();
      expect(asked.single, contains('polloptionid=263'));
      expect(find.text('测试用户甲'), findsOneWidget);
      expect(cubit.mine, {'263'});
      await tester.pumpWidget(const SizedBox());
      await cubit.close();
    });
  });
}
