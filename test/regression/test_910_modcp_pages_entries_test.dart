/// The entries of the panel's pages tsdmapp 3.9.0 answers as fields: a tile each on the moderator's panel only when
/// `status.modcp_pages` lists the page (the notes `home`, the threads and the posts `thread`), the members' permissions
/// also only when the panel's menu links them (a group allowed to edit members); what waits on the panel's first page
/// above the tiles, each count opening its page; nothing asked for an account the forum does not answer; a forum the
/// panel does not name (`forum` empty, third round) shown without a name.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/utils/panel_tools_access.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The panel's first page, its menu linking [links].
String _menu(List<String> links) =>
    '<script>var discuz_uid = \'33\';</script><div class="appl"><ul>'
    '${links.map((l) => '<li><a href="forum.php?mod=modcp&action=$l">x</a></li>').join()}</ul></div>';

Future<void> _pump(
  WidgetTester tester, {
  required Set<String> pages,
  List<String> menu = const ['home', 'forumaccess'],
  Object? home,
  List<String>? asked,
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  Future<Either<AppException, ({int statusCode, Object? data})>> get(String url) async {
    asked?.add(url);
    final data = url.contains('tsdmapp=json')
        ? (home ??
              {
                ..._fixture('modcp_home'),
                'counts': {'moderate': 4, 'notes': 2, 'forums': 20},
              })
        : _menu(menu);
    return right((statusCode: 200, data: data));
  }

  Future<Either<AppException, ({int statusCode, Object? data})>> post(String url, Map<String, String> body) async =>
      right((statusCode: 200, data: null));

  final panel = ModcpRepository(get: get, post: post, currentUid: () => 33);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: ModeratorPanelPage(
          key: UniqueKey(),
          repository: panel,
          staffTools: () async => (grant: false, issue: false),
          panelTools: () async => (background: false, modcpReport: false),
          modcpPages: () async => pages,
          pagesRepository: ModcpPagesRepository(panel: panel, get: get, post: post, currentUid: () => 33),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(PanelToolsAccess.reset);

  const notes = ValueKey('modcp-notes');
  const threads = ValueKey('modcp-threads');
  const posts = ValueKey('modcp-posts');
  const access = ValueKey('modcp-forum-access');
  const summary = ValueKey('modcp-home-summary');

  testWidgets('a tile each only for the pages the forum lists', (tester) async {
    await _pump(tester, pages: {'log', 'report', 'thread', 'forumaccess', 'home'});
    for (final key in [notes, threads, posts, access, summary]) {
      expect(find.byKey(key), findsOneWidget, reason: '$key');
    }

    final asked = <String>[];
    await _pump(tester, pages: {'log', 'report'}, asked: asked);
    for (final key in [notes, threads, posts, access, summary]) {
      expect(find.byKey(key), findsNothing, reason: '$key');
    }
    // The first page is not asked in the JSON mode when the forum does not answer it so.
    expect(asked.where((u) => u.contains('tsdmapp=json')), isEmpty);

    await _pump(tester, pages: {'thread'});
    expect(find.byKey(threads), findsOneWidget);
    expect(find.byKey(posts), findsOneWidget);
    expect(find.byKey(notes), findsNothing);
  });

  testWidgets("the members' permissions only when the panel's menu links them", (tester) async {
    await _pump(tester, pages: {'forumaccess', 'thread'}, menu: ['home', 'thread&op=thread']);
    expect(find.byKey(access), findsNothing);
    expect(find.byKey(threads), findsOneWidget);
  });

  testWidgets('what waits, each count opening its page; the moderation count only when the forum counts it', (
    tester,
  ) async {
    await _pump(tester, pages: {'home'});
    expect(find.descendant(of: find.byKey(const ValueKey('modcp-count-moderate')), matching: find.text('4')), findsOne);
    expect(find.descendant(of: find.byKey(const ValueKey('modcp-count-notes')), matching: find.text('2')), findsOne);
    await tester.tap(find.byKey(const ValueKey('modcp-count-notes')));
    await tester.pumpAndSettle();
    expect(find.text('Moderator notes'), findsOneWidget);
    expect(find.byKey(const ValueKey('modcp-note-compose')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await _pump(tester, pages: {'home'}, home: _fixture('modcp_home'));
    expect(find.byKey(summary), findsOneWidget);
    expect(find.byKey(const ValueKey('modcp-count-moderate')), findsNothing);
  });

  testWidgets('no summary while the panel asks its password', (tester) async {
    await _pump(
      tester,
      pages: {'home'},
      home: {..._fixture('modcp_report_login'), 'uid': 33, 'head': "<script>var discuz_uid = '33';</script>"},
    );
    expect(find.byKey(summary), findsNothing);
    expect(find.byKey(notes), findsOneWidget);
  });

  test('the pages listed by status, kept with the panel tools', () async {
    final can = await PanelToolsAccess.check(
      33,
      status: () async => {
        'ok': 1,
        'modcp_report': 1,
        'bggrant': 0,
        'modcp_pages': ['log', 'report', 'thread', 'forumaccess', 'home', 7],
      },
    );
    expect(can, (background: false, modcpReport: true));
    expect(PanelToolsAccess.modcpPages(33), {'log', 'report', 'thread', 'forumaccess', 'home'});
    expect(PanelToolsAccess.modcpPages(34), isNull);

    PanelToolsAccess.reset();
    await PanelToolsAccess.check(35, status: () async => {'ok': 1, 'bggrant': 0});
    expect(PanelToolsAccess.modcpPages(35), isEmpty);
  });

  test('a forum the panel does not name is shown without its name (third round)', () {
    final json = _fixture('modcp_thread_fid2');
    final named = modcpThreadFromApi(json)!;
    expect(named.forumName, '公告与新手报到');
    final other = modcpThreadFromApi({...json, 'fid': 99, 'forum': ''})!;
    expect((other.fid, other.forum, other.forumName), (99, '', ''));
    // Named after the forums offered when the panel lists it there.
    expect(modcpThreadFromApi({...json, 'forum': ''})!.forumName, '公告与新手报到');
  });
}
