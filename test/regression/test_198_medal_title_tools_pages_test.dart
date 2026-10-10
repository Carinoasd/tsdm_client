/// The new medal and title pages of the app API (tsdmapp 1.5.0): title exchange, my medals, sending medals and
/// issuing titles. Each write posts the plugin's own form with the fields the website posts; these tests drive the
/// pages with answers made after the plugin's and check what is posted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/view/medal_grant_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/my_medals_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/title_exchange_page.dart';
import 'package:tsdm_client/features/medal_title_tools/view/title_issue_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _ok = '<div id="messagetext" class="alert_right"><p>操作成功</p></div>';

Map<String, dynamic> _form(String plugin, String action, Map<String, String> fields) => {
  'url': 'plugin.php?id=$plugin&action=$action',
  'fields': {'formhash': 'abcd1234', ...fields},
};

Map<String, dynamic> _exchange() => {
  'ok': 1,
  'installed': 1,
  'uid': 35,
  'query': {'filter': 'all', 'q': '', 'page': 1, 'pages': 1, 'total': 2},
  'filters': [
    {'key': 'all', 'label': '全部', 'count': 2},
    {'key': 'ready', 'label': '可兑换', 'count': 1},
  ],
  'items': [
    {
      'id': 7,
      'name': 'Ready title',
      'medals': [
        {'id': 1, 'name': 'A', 'image': '', 'owned': 1},
      ],
      'ready': 1,
      'consume': 1,
      'owned': 0,
    },
    {
      'id': 8,
      'name': 'Short title',
      'medals': [
        {'id': 2, 'name': 'B', 'image': '', 'owned': 0},
      ],
      'ready': 0,
      'consume': 0,
      'owned': 0,
    },
  ],
  'exchange_form': _form('tsdmtitle:tsdmtitle', 'exchange', {'exchangesubmit': 'true', 'tsdmtitle_return': 'x'}),
};

Map<String, dynamic> _myMedals() => {
  'ok': 1,
  'installed': 1,
  'uid': 35,
  'medals': [
    {'id': 11, 'name': 'Shown medal', 'image': '', 'hidden': 0, 'expiration': 0},
    {'id': 12, 'name': 'Hidden medal', 'image': '', 'hidden': 1, 'expiration': 0},
  ],
  'preview_limit': 30,
  'hide_warning': 'Hiding may lose medals.',
  'log': {
    'page': 1,
    'pages': 1,
    'total': 1,
    'items': [
      {'id': 1, 'medalid': 11, 'name': 'Shown medal', 'image': '', 'kind': 'bought', 'dateline': 1791500000},
    ],
  },
  'hide_form': _form('dsu_medalCenter:memcp', 'sethide', {'dsumcsubmit': '1'}),
};

Map<String, dynamic> _grant({int canGrant = 1, int supported = 1}) => {
  'ok': 1,
  'installed': 1,
  'uid': 79,
  'can_grant': canGrant,
  'supported': supported,
  'limits': {'users': 200, 'medals': 50, 'pairs': 1000, 'reason': 100},
  'revoke_window': 259200,
  'can_revoke_all': 1,
  'medals': [
    {'id': 21, 'name': 'Gift medal', 'image': '', 'expiration_days': 0},
    {'id': 22, 'name': 'Other medal', 'image': '', 'expiration_days': 30},
  ],
  'records': {
    'page': 1,
    'pages': 1,
    'total': 1,
    'batches': [
      {
        'batch': 5,
        'dateline': 1791500000,
        'opuid': 79,
        'opname': 'staff',
        'reason': 'Event prize',
        'users': 2,
        'medals': 1,
        'count': 2,
        'revoked': 0,
        'can_revoke': 2,
        'items': [
          {
            'id': 5,
            'uid': 44,
            'username': 'alice',
            'medalid': 21,
            'name': 'Gift medal',
            'image': '',
            'expiration': 0,
            'revoked': 0,
            'can_revoke': 1,
          },
          {
            'id': 6,
            'uid': 45,
            'username': 'bob',
            'medalid': 21,
            'name': 'Gift medal',
            'image': '',
            'expiration': 0,
            'revoked': 0,
            'can_revoke': 1,
          },
        ],
      },
    ],
  },
  'grant_form': _form('dsu_medalCenter:memcp', 'grantgrid', {'dsumcsubmit': '1', 'grantconfirm': '1'}),
  'revoke_form': _form('dsu_medalCenter:memcp', 'grantrevoke', {'dsumcsubmit': '1'}),
  'revoke_batch_form': _form('dsu_medalCenter:memcp', 'grantrevokebatch', {'dsumcsubmit': '1'}),
  'lookup_url': 'plugin.php?id=dsu_medalCenter:memcp&action=grantlookup',
  'thread_url': 'plugin.php?id=dsu_medalCenter:memcp&action=grantthread',
};

Map<String, dynamic> _issue() => {
  'ok': 1,
  'installed': 1,
  'uid': 79,
  'can_issue': 1,
  'supported': 1,
  'limits': {'users': 200, 'titles': 30, 'days': 36500, 'note': 80},
  'titles': [
    {'id': 31, 'name': 'Event title', 'image': '', 'enabled': 0},
  ],
  'logs': <Object>[],
  'issue_form': _form('tsdmtitle:tsdmtitle', 'issue', {'issuesubmit': 'true'}),
};

/// Answers the API from [answers] and records the posts.
MedalTitleToolsRepository _repo(
  Map<String, Map<String, dynamic>?> answers, {
  List<(String, Map<String, String>)>? posted,
  List<String>? gets,
  Object? json,
}) => MedalTitleToolsRepository(
  ask: (action, _) async => answers[action],
  getJson: (url) async {
    gets?.add(url);
    return json;
  },
  post: (url, data) async {
    posted?.add((url, data));
    return _ok;
  },
);

Future<void> _pump(WidgetTester tester, Widget page) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(TranslationProvider(child: MaterialApp(home: page)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  test('forms are only taken when they post to the plugin and action named', () {
    expect(
      ApiForm.parse(_form('tsdmtitle:tsdmtitle', 'issue', {}), plugin: 'tsdmtitle:tsdmtitle', action: 'issue')?.url,
      '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle&action=issue',
    );
    expect(
      ApiForm.parse(
        {
          'url': 'https://elsewhere.example/plugin.php?id=tsdmtitle:tsdmtitle&action=issue',
          'fields': <String, String>{},
        },
        plugin: 'tsdmtitle:tsdmtitle',
        action: 'issue',
      ),
      isNull,
    );
    expect(
      ApiForm.parse(_form('tsdmtitle:tsdmtitle', 'buy', {}), plugin: 'tsdmtitle:tsdmtitle', action: 'issue'),
      isNull,
    );
  });

  test('UIDs are read as the medal centre reads them', () {
    final r = splitUids('12345,23456，34567、45678;56789\n１２ abc 12345');
    expect(r.uids, [12345, 23456, 34567, 45678, 56789, 12]);
    expect(r.bad, ['abc']);
    expect(threadIdOf('https://www.example.com/forum.php?mod=viewthread&tid=9199264&extra=page%3D1'), 9199264);
    expect(threadIdOf('thread-123-1-1.html'), 123);
    expect(threadIdOf('456'), 456);
    expect(threadIdOf('abc'), isNull);
  });

  test('a 提示信息 page: an error is a refusal, the message is kept', () {
    expect(parseFormResult(_ok).success, isTrue);
    final r = parseFormResult('<div id="messagetext" class="alert_error"><p>没有权限</p></div>');
    expect((r.success, r.message), (false, '没有权限'));
  });

  testWidgets('title exchange: a ready title is exchanged with the plugin’s form', (tester) async {
    final posted = <(String, Map<String, String>)>[];
    await _pump(tester, TitleExchangePage(repository: _repo({'titleexchange': _exchange()}, posted: posted)));
    expect(find.text('Ready title'), findsOneWidget);
    expect(find.text('The medals are taken when exchanged'), findsOneWidget);
    final buttons = find.widgetWithText(FilledButton, 'Exchange');
    expect(tester.widget<FilledButton>(buttons.at(1)).onPressed, isNull, reason: 'medals missing');
    await tester.tap(buttons.first);
    await tester.pumpAndSettle();
    expect(find.textContaining('These medals will be taken'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Exchange')));
    await tester.pumpAndSettle();
    expect(posted.single.$1, '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle&action=exchange');
    expect(posted.single.$2, {
      'formhash': 'abcd1234',
      'exchangesubmit': 'true',
      'tsdmtitle_return': 'x',
      'exchangeid': '7',
    });
  });

  testWidgets('my medals: hiding asks with the warning and posts only the changed medals', (tester) async {
    final posted = <(String, Map<String, String>)>[];
    await _pump(tester, MyMedalsPage(repository: _repo({'mymedals': _myMedals()}, posted: posted)));
    expect(find.text('Hiding may lose medals.'), findsOneWidget);
    expect(find.text('1 shown, 1 hidden'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.text('0 shown, 2 hidden'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.textContaining('These will be hidden'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Save')));
    await tester.pumpAndSettle();
    expect(posted.single.$2, {'formhash': 'abcd1234', 'dsumcsubmit': '1', 'myMedalHide[11]': '1'});
  });

  testWidgets('sending medals: checked first, then the members found get the medals', (tester) async {
    final posted = <(String, Map<String, String>)>[];
    final gets = <String>[];
    await _pump(
      tester,
      MedalGrantPage(
        repository: _repo(
          {'medalgrant': _grant()},
          posted: posted,
          gets: gets,
          json: {
            'ok': 1,
            'users': [
              {
                'uid': 44,
                'name': 'alice',
                'avatar': '',
                'has': [21],
              },
              {'uid': 45, 'name': 'bob', 'avatar': '', 'has': <int>[]},
            ],
            'missing': ['999'],
          },
        ),
      ),
    );
    expect(find.text('Reason: Event prize'), findsOneWidget);
    expect(find.text('Take back all (2)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Member UIDs'), '44，45, 999');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Gift medal'));
    await tester.enterText(find.widgetWithText(TextField, 'Reason (optional)'), 'Thanks');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next: check'));
    await tester.pumpAndSettle();
    expect(gets.single, '$baseUrl/plugin.php?id=dsu_medalCenter:memcp&action=grantlookup&uids=44,45,999&mids=21');
    expect(find.textContaining('1 to send, 1 skipped'), findsOneWidget);
    expect(find.textContaining('UIDs not found (skipped): 999'), findsOneWidget);
    await tester.tap(find.text('Send 1'));
    await tester.pumpAndSettle();
    expect(posted.single.$1, '$baseUrl/plugin.php?id=dsu_medalCenter:memcp&action=grantgrid');
    expect(posted.single.$2, {
      'formhash': 'abcd1234',
      'dsumcsubmit': '1',
      'grantconfirm': '1',
      'grant_users': '44,45',
      'grant_medalids': '21',
      'grant_reason': 'Thanks',
    });
  });

  testWidgets('sending medals: a sending is taken back with its batch', (tester) async {
    final posted = <(String, Map<String, String>)>[];
    await _pump(tester, MedalGrantPage(repository: _repo({'medalgrant': _grant()}, posted: posted)));
    await tester.tap(find.text('Take back all (2)'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Take back')),
    );
    await tester.pumpAndSettle();
    expect(posted.single.$2, {'formhash': 'abcd1234', 'dsumcsubmit': '1', 'batch': '5'});
  });

  testWidgets('sending medals: no permission, or an older medal centre, says so', (tester) async {
    await _pump(tester, MedalGrantPage(repository: _repo({'medalgrant': _grant(canGrant: 0)})));
    expect(find.text('You are not allowed to use this.'), findsOneWidget);
    await _pump(tester, MedalGrantPage(key: UniqueKey(), repository: _repo({'medalgrant': _grant(supported: 0)})));
    expect(find.textContaining('not the new version'), findsOneWidget);
  });

  testWidgets('issuing titles: the plugin’s form with members, titles, days and note', (tester) async {
    final posted = <(String, Map<String, String>)>[];
    await _pump(tester, TitleIssuePage(repository: _repo({'titleissue': _issue()}, posted: posted)));
    expect(find.textContaining('Disabled'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Members (UID or name)'), '44\nalice, 44');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Event title'));
    await tester.enterText(find.widgetWithText(TextField, 'Days (0 for permanent)'), '7');
    await tester.enterText(find.widgetWithText(TextField, 'Note (optional)'), 'Prize');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Give'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 titles for 2 members (7 days)'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Give')));
    await tester.pumpAndSettle();
    expect(posted.single.$2, {
      'formhash': 'abcd1234',
      'issuesubmit': 'true',
      'issueop': 'grant',
      'issuetitles': '31',
      'issueusers': '44\nalice',
      'issuedays': '7',
      'issuenote': 'Prize',
    });
  });
}
