import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/bank/cubit/bank_cubit.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/features/bank/view/bank_page.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/chat/view/chat_page.dart';
import 'package:tsdm_client/features/chat/widgets/chat_message_card.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/medal_center/cubit/medal_center_cubit.dart';
import 'package:tsdm_client/features/medal_center/view/medal_center_page.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/view/notification_detail_page.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/thread_visit_history/view/thread_visit_history_page.dart';
import 'package:tsdm_client/features/thread_visit_history/widgets/thread_visit_history_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Android tester feedback on preview 109 (PR #135, `work/pr135-feedback110`), on the real pages:
///
/// 1. the category picker of the medal center and the service picker of the bank keep their label inside the field;
/// 2. the landscape navigation rail never scrolls under the status bar and still reaches its nine entries;
/// 3. the account filter of the browsing history stays in the safe area, in line with the list;
/// 4. the reply bar paints its background to the screen edges, its field stays in the safe area;
/// 5. the author dialog shows the second badge of the floor, or the current account's own title on its own floors
///    only, never another account's;
/// 6. the homepage app bar does not flash the old activity entry while the page loads or refreshes;
/// 7. the "unread only" filter of the notifications is in the app bar;
/// 8. the daily red packet entry checks the packet alone, the homepage is not reloaded;
/// 9. the warning icon of the debug section lines up with the other icons of the settings.
/// 10. the author dialog keeps the uid and online pills of its header inside a phone in landscape.
///
/// Synthetic accounts and pages only: no network, no login, nothing is claimed, bought or sent.
Translations get tr => LocaleSettings.instance.currentTranslations;

String _data(String name) => File('test/data/$name').readAsStringSync();

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Every image request fails at once: images are not part of these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A few frames with real time in between, for database and fake network answers.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A [size] window with [padding] insets (status bar, cutout, gesture bar), a [scale] text scale and a software
/// keyboard [keyboard] high (0: hidden).
///
/// As on a device, the keyboard covers the gesture bar: the padding left above it is what the view padding exceeds the
/// keyboard by.
void _window(
  WidgetTester tester,
  Size size, {
  FakeViewPadding padding = FakeViewPadding.zero,
  double scale = 1,
  double keyboard = 0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..viewPadding = padding
    ..viewInsets = FakeViewPadding(bottom: keyboard)
    ..padding = FakeViewPadding(
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: keyboard > 0 ? 0 : padding.bottom,
    );
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Landscape phone with the cutout on the start side, as in the screenshots.
const _landscape = Size(792, 368);
const _landscapeInsets = FakeViewPadding(left: 44, top: 24);

/// Portrait phone with a status bar and a gesture bar.
const _portrait = Size(384, 792);
const _portraitInsets = FakeViewPadding(top: 24, bottom: 24);

// ---------------------------------------------------------------------------------------------------------------------
// 1. Pickers.

const _bank = ForumBank(id: 1, name: 'Synthetic bank', hasAccount: true);

final class _BankRepository extends BankRepository {
  _BankRepository() : super(getPage: (_) async => '', postForm: (_, _) async => '');

  @override
  Future<BankDirectory> fetchDirectory(int uid) async => const BankDirectory(banks: [_bank]);

  @override
  Future<BankSavings> fetchSavings(int bankId, int uid) async => parseBankSavings(
    parseHtmlDocument('''
<div class="tbn"><ul><li><font>Test coins:</font><span><b>800</b></span>(银行货币)</li></ul></div>
<table id="ttt"><tr><th><h2>活期储蓄</h2></th></tr>
<tr><td class="footoperation">您当前的存款金额为 100 ，活期利率为1‰。</td></tr>
<tr><td><form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="1"><input type="hidden" name="action" value="cur">
<input type="hidden" name="formhash" value="synthetic-token"><input type="text" name="banknum">
<input type="radio" name="op" value="in"><input type="radio" name="op" value="out">
<input type="password" name="bankpass"><button type="submit" name="banksubmit" value="true">提交</button>
</form></td></tr></table>
'''),
    bankId: bankId,
  );

  @override
  Future<BankLogs> fetchLogs(int bankId, int uid, {bool received = false, int page = 1}) async =>
      BankLogs(entries: [], hasNext: false);
}

// ---------------------------------------------------------------------------------------------------------------------
// 4. Pages with a reply bar: chat, thread, notice detail. Read only.

const _tid = '1264975';
const _pid = 11;

/// A floor of a thread page as in test_102 (grounded in the Discuz templates).
String _threadFloor({required int pid, required int floor, required int uid, required String name}) =>
    '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=$uid" class="xi2">$name</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text</div></div></div></td>
</tr></tbody></table></div>''';

/// A thread page of board 8 with two floors, as in test_102, open for replies.
///
/// The reply form is the fast post form of a real X5 page (`test/data/fastpostform_open_x5.html`, as in test_059):
/// without `form#fastpostform` the page reads as a thread that accepts no reply (`isThreadClosedForReply`), the bar
/// is locked and a tap opens no editor.
final _threadPage =
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$_tid" /></head><body>
<div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm">Home</a><em>›</em><a href="forum.php">Forum</a>
<em>›</em><a href="forum.php?gid=1">Group</a><em>›</em><a href="forum.php?mod=forumdisplay&fid=8">Board</a>
<em>›</em><a href="forum.php?mod=viewthread&tid=$_tid">Synthetic thread</a></div></div>
<form id="scbar_form"><input type="hidden" name="srhfid" value="8" /></form>
<div id="postlist"><h1 class="ts"><span id="thread_subject">Synthetic thread</span></h1><div class="bm">
${_threadFloor(pid: 10, floor: 1, uid: 1002, name: 'Carol')}
${_threadFloor(pid: _pid, floor: 2, uid: 1002, name: 'Carol')}
</div></div>
<form method="post" id="fastpostform" action="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$_tid&amp;extra=&amp;replysubmit=yes&amp;infloat=yes&amp;handlekey=fastpost">
<div class="area"><textarea rows="6" cols="80" name="message" id="fastpostmessage" class="pt"></textarea></div>
<input type="hidden" name="posttime" id="posttime" value="0" />
<input type="hidden" name="formhash" value="XXXXXXXX" /><input type="hidden" name="usesig" value="1" />
<input type="hidden" name="subject" value="  " />
</form>
</body></html>''';

/// Read-only answers of the pages with a reply bar: the chat dialog of test_067, the thread page above for the thread
/// and for the notice detail (a `findpost` link to floor [_pid]). Anything else, images included, is offline; every
/// request is recorded so a test can check nothing was sent.
final class _PagesAdapter implements HttpClientAdapter {
  final requests = <(String, Uri)>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add((options.method, uri));
    final q = uri.queryParameters;
    if (options.method == 'GET' && q['op'] == 'showmsg') {
      return ResponseBody.fromString(
        _data('chat_dialog_x5.xml'),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
        },
      );
    }
    final threadPage = q['mod'] == 'viewthread' || (q['mod'] == 'redirect' && q['goto'] == 'findpost');
    if (options.method == 'GET' && uri.pathSegments.lastOrNull == 'forum.php' && threadPage) {
      return ResponseBody.fromString(
        _threadPage,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

// ---------------------------------------------------------------------------------------------------------------------
// 6 / 7 / 8. Homepage and notification page, as in test_101.

/// Authentication with a current account the test sets; the homepage checks a fetched page with it.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  /// Nothing is replayed: the stream is a plain broadcast one.
  @override
  AuthStatus? get latestStatus => null;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  @override
  AsyncVoidEither loginWithDocument(uh.Document document, {int? fetchedAs, int? epoch}) =>
      AsyncVoidEither(() async => rightVoid());

  @override
  int get identityEpoch => 0;

  Future<void> close() => _controller.close();
}

/// Notification bloc whose state the test sets; events are recorded, never handled.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this._state);

  NotificationState _state;
  final _controller = StreamController<NotificationState>.broadcast(sync: true);
  final events = <NotificationEvent>[];

  @override
  NotificationState get state => _state;

  @override
  Stream<NotificationState> get stream => _controller.stream;

  void push(NotificationState next) {
    _state = next;
    _controller.add(next);
  }

  @override
  void add(NotificationEvent event) => events.add(event);

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => _controller.close();
}

/// `forum.php` of the account [uid], with today's daily red packet when [packet].
///
/// The owner marks are those of the real X5 page (`test/data/forum_index_x5.html`): `discuz_uid` in the head script
/// and the user node under `div#hd div.wp div.hdc.cl div#um`. The red packet check only trusts a page whose owner it
/// can read (`parseLoggedUidFromDocument`); a bare `div#um` has none, and the check rightly dropped the answer.
String _forumHome({required bool packet, int uid = 1000, String name = 'Alice'}) =>
    '''
<html><head>
<script type="text/javascript">var STYLEID = '42', discuz_uid = '$uid', cookiepre = 'Ystv_2132_';</script>
</head><body>
<div id="hd"><div class="wp"><div class="hdc cl"><div id="um">
<div class="avt y"><a href="home.php?mod=space&amp;uid=$uid"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg" class="_avt user_avatar"></a></div>
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=$uid">$name</a></strong></p>
</div></div></div></div>
<form><input type="hidden" name="formhash" value="XXXXXXXX" /></form>
${packet ? '<script>hongbaoDailyInit({"entry":2,"dateflag":"20260928","unit":"coins"});</script>' : ''}
</body></html>''';

const _profile = '''
<html><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div>
<div id="uhd"><div class="icn avt"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg"></a></div></div>
</body></html>''';

/// Answers `forum.php` (with or without the packet, for [homeUid]), the profile page, an empty page otherwise. A
/// pending [hold] delays the `forum.php` answers.
final class _ForumAdapter implements HttpClientAdapter {
  final requests = <(String, Uri)>[];
  bool packet = false;
  int homeUid = 1000;
  Completer<void>? hold;

  Iterable<Uri> get homeRequests => requests
      .where((e) => e.$2.pathSegments.lastOrNull == 'forum.php' && e.$2.queryParameters['mod'] == null)
      .map(
        (e) => e.$2,
      );

  Iterable<Uri> get profileRequests => requests
      .where((e) => e.$2.pathSegments.lastOrNull == 'home.php' && e.$2.queryParameters['mod'] == 'space')
      .map((e) => e.$2);

  Iterable<Uri> get posts => requests.where((e) => e.$1 == 'POST').map((e) => e.$2);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add((options.method, uri));
    if (uri.path.endsWith('.jpg')) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    final q = uri.queryParameters;
    final isHome = uri.pathSegments.lastOrNull == 'forum.php' && q['mod'] == null;
    if (isHome && hold != null) {
      await hold!.future;
    }
    final body = switch (uri.pathSegments.lastOrNull) {
      'forum.php' when q['mod'] == null => _forumHome(
        packet: packet,
        uid: homeUid,
        name: homeUid == 1000 ? 'Alice' : 'Someone',
      ),
      'home.php' when q['mod'] == 'space' && q['uid'] == '${_alice.uid}' => _profile,
      _ => '<html><body></body></html>',
    };
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// ---------------------------------------------------------------------------------------------------------------------
// 5. Author dialog: the X5 floor of test #011 (author uid 1115, secondary title in its author column).

const _floorTitle = 'https://img.tsdm39.com/img01/title/无职转生.gif';
const _floorAuthor = 1115;

/// Titles the accounts of the dialog tests use, served by [_ImageAdapter] like every other image.
const _ownTitle = 'https://img.tsdm39.com/img01/title/synthetic-own.gif';
const _nextTitle = 'https://img.tsdm39.com/img01/title/synthetic-next.gif';

/// A 1x1 transparent PNG (as in test_078), the bytes of every image of the dialog tests.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Local stand-in of the image hosts: answers [_png] for every url and records the urls (decoded, without query), so
/// the badges of the dialog load and render for real and nothing leaves the test.
final class _ImageAdapter implements HttpClientAdapter {
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requested.add(Uri.decodeFull('${uri.scheme}://${uri.host}${uri.path}'));
    return ResponseBody.fromBytes(
      _png,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

uh.Element _floor(uh.Document doc) => doc.querySelector('div#post_77983102')!;

/// The floor of the fixture as a post; [strip] removes its secondary title block, [linked] wraps the title image in a
/// link. The body is replaced with plain text, only the author column matters here.
Post _post({bool strip = false, bool linked = false}) {
  final doc = parseHtmlDocument(_data('locked_purchase_x5.html'));
  final original = _floor(doc);
  final floor = original.clone(true) as uh.Element;
  if (strip) {
    floor.querySelectorAll('div.tsdmtitle-badges').forEach((e) => e.remove());
  }
  if (linked) {
    final img = floor.querySelector('div.tsdmtitle-title > img')!;
    final link = uh.Element.tag('a')..setAttribute('href', 'plugin.php?id=tsdmtitle:tsdmtitle');
    img.replaceWith(link);
    link.append(img);
  }
  original.parent!.append(floor);
  final post = Post.fromPostNode(floor, 1)!;
  return post.copyWith(data: '<p>floor body</p>', locked: const [], signature: null, pokemon: null, checkin: null);
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('1. pickers keep their label inside the field', () {
    Future<void> pumpBank(WidgetTester tester) async {
      final cubit = BankCubit(currentUid: () => 1000, repository: _BankRepository.new);
      addTearDown(cubit.close);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: BankPage(controller: cubit)),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder bankDecorator() => find
        .ancestor(of: find.byKey(const ValueKey('bank-service-picker')), matching: find.byType(InputDecorator))
        .first;

    void expectFilledStyle(WidgetTester tester, Finder decorator) {
      final border = tester.widget<InputDecorator>(decorator).decoration.border;
      expect(border, isA<UnderlineInputBorder>(), reason: 'the label floats inside the fill, not on an outline');
      expect(border!.borderSide, BorderSide.none);
    }

    for (final (name, size, padding, scale) in [
      ('portrait 384', _portrait, _portraitInsets, 1.0),
      ('portrait 384 with 2x text', _portrait, _portraitInsets, 2.0),
      ('landscape 792x368 with a 44 cutout', _landscape, _landscapeInsets, 1.0),
    ]) {
      testWidgets('bank services, $name: one label as placeholder, then floating inside the field', (tester) async {
        _window(tester, size, padding: padding, scale: scale);
        await pumpBank(tester);

        // Nothing picked: the label is the placeholder, no second copy of the same text as a hint.
        final decorator = bankDecorator();
        expectFilledStyle(tester, decorator);
        expect(find.descendant(of: decorator, matching: find.text(tr.bank.services)), findsOneWidget);

        // A bank with an account picks "savings": the label floats, inside the field and above the value.
        await tester.tap(find.byKey(const ValueKey('bank-1')));
        await tester.pumpAndSettle();
        final box = tester.getRect(bankDecorator());
        final label = tester.getRect(find.descendant(of: bankDecorator(), matching: find.text(tr.bank.services)));
        final value = tester.getRect(
          find.descendant(of: find.byKey(const ValueKey('bank-service-picker')), matching: find.text(tr.bank.savings)),
        );
        expect(label.top, greaterThanOrEqualTo(box.top + 4), reason: 'not on the top edge of the field');
        expect(label.bottom, lessThanOrEqualTo(value.top + 0.5), reason: 'label and value do not overlap');
        expect(value.bottom, lessThanOrEqualTo(box.bottom));
        expect(tester.takeException(), isNull);
      });
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('medal center category at ${scale}x text: the label stays inside the field', (tester) async {
        _window(tester, _portrait, padding: _portraitInsets, scale: scale);
        final cubit = MedalCenterCubit(currentUid: () => null, fetchPage: (_) async => _data('medal_guest_x5.html'));
        addTearDown(cubit.close);
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: MedalCenterPage(controller: cubit, imageBuilder: (_) => const Icon(Icons.broken_image_outlined)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byType(DropdownButtonFormField<String>);
        expect(field, findsOneWidget);
        final decorator = find.descendant(of: field, matching: find.byType(InputDecorator)).first;
        expectFilledStyle(tester, decorator);
        final box = tester.getRect(decorator);
        final label = tester.getRect(find.descendant(of: decorator, matching: find.text(tr.medalCenter.category)));
        expect(label.top, greaterThanOrEqualTo(box.top + 4), reason: 'not on the top edge of the field');
        expect(label.bottom, lessThanOrEqualTo(box.bottom));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  group('2. navigation rail in landscape', () {
    late GoRouter router;
    late HomeCubit cubit;

    Future<void> pumpRail(WidgetTester tester) async {
      cubit = HomeCubit();
      router = GoRouter(
        initialLocation: ScreenPaths.homepage,
        routes: [
          ShellRoute(
            builder: (context, state, child) => Scaffold(
              body: Row(
                children: [
                  const HomeNavigationRail(),
                  Expanded(child: child),
                ],
              ),
            ),
            routes: [
              for (final path in [ScreenPaths.homepage, ScreenPaths.topic, ScreenPaths.notice, ScreenPaths.me])
                GoRoute(
                  path: path,
                  name: path,
                  pageBuilder: (context, state) => NoTransitionPage(child: Center(child: Text('tab $path'))),
                ),
            ],
          ),
          for (final path in [ScreenPaths.login])
            GoRoute(
              path: path,
              name: path,
              builder: (context, state) => Scaffold(appBar: AppBar(), body: Text('pushed $path')),
            ),
        ],
      );
      addTearDown(router.dispose);
      addTearDown(cubit.close);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<HomeCubit>.value(
            value: cubit,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // The four tabs since the navigation rework of 2026-10-23 (nine entries before).
    List<String> labels() => [tr.navigation.homepage, tr.navigation.topics, tr.navigation.notice, tr.navigation.me];

    for (final scale in [1.0, 2.0]) {
      testWidgets('scrolled to the end at ${scale}x text: nothing under the status bar, every entry reachable', (
        tester,
      ) async {
        _window(tester, _landscape, padding: _landscapeInsets, scale: scale);
        await pumpRail(tester);
        final scroll = find.byKey(const ValueKey('home-navigation-rail-scroll'));
        final viewport = tester.getRect(scroll);
        expect(viewport.top, 24, reason: 'the scroll area starts below the status bar');
        expect(viewport.bottom, _landscape.height);
        // Whatever scrolls past the top of that area is clipped there, it is never painted in the status bar band.
        expect(tester.widget<SingleChildScrollView>(scroll).clipBehavior, Clip.hardEdge);

        // Drag the rail as far as it goes, the way the tester did.
        await tester.drag(scroll, const Offset(0, -2000));
        await tester.pumpAndSettle();
        final last = tester.getRect(find.text(tr.navigation.me));
        // The scroll ends with the last entry fully shown at the bottom: no empty room after it, no half clipped entry
        // at the top edge (the height is measured, not estimated). Four entries may fit without scrolling.
        expect(last.top, greaterThanOrEqualTo(24), reason: 'the last entry is not clipped by the top edge');
        expect(last.bottom, lessThanOrEqualTo(_landscape.height));
        if (Scrollable.of(tester.element(find.text(tr.navigation.me))).position.maxScrollExtent > 0) {
          expect(last.bottom, greaterThan(viewport.bottom - 48), reason: 'the scroll ends at the last entry');
        }
        // The status bar strip is the rail's own band, not a destination scrolled under it.
        final railX = tester.getRect(find.byType(NavigationRail)).center.dx;
        await tester.tapAt(Offset(railX, 12));
        await tester.pumpAndSettle();
        expect(routerTopLocation(router), ScreenPaths.homepage, reason: 'a tap on the status bar opens nothing');

        // Every entry can still be scrolled into the area below the status bar, and stays right of the cutout.
        for (final label in labels().reversed) {
          await tester.dragUntilVisible(find.text(label), scroll, const Offset(0, 60));
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.text(label));
          expect(rect.top, greaterThanOrEqualTo(23.5), reason: '$label is shown below the status bar');
          expect(rect.left, greaterThanOrEqualTo(44), reason: '$label is right of the cutout');
        }
        expect(tester.getRect(find.text(tr.navigation.homepage)).top, greaterThanOrEqualTo(24));

        // And they still work.
        final me = find.byIcon(Icons.person_outline);
        await tester.dragUntilVisible(me, scroll, const Offset(0, -60));
        await tester.pumpAndSettle();
        await tester.tap(me);
        await tester.pumpAndSettle();
        expect(routerTopLocation(router), ScreenPaths.me);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('3. browsing history filter in the safe area', () {
    late AppDatabase db;
    late StorageProvider storage;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
    });
    tearDown(() async => db.close());

    Future<void> pumpHistory(WidgetTester tester) async {
      await tester.runAsync(() async {
        for (final (uid, tid, name) in [(11, 100, 'Account A'), (22, 101, 'Account B')]) {
          await storage.updateThreadVisitHistory(
            uid: uid,
            tid: tid,
            fid: 1,
            username: name,
            threadTitle: '$name thread',
            forumName: 'Forum',
            visitTime: DateTime(2026, 9, 10, uid),
          );
        }
      });
      await tester.pumpWidget(
        RepositoryProvider.value(
          value: ThreadVisitHistoryRepo(storage),
          child: TranslationProvider(child: const MaterialApp(home: ThreadVisitHistoryPage())),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }

    for (final (name, size, padding) in [
      ('landscape with a 44 cutout on the left', _landscape, _landscapeInsets),
      ('landscape with the cutout on the right', _landscape, const FakeViewPadding(right: 44, top: 24)),
      ('portrait', _portrait, _portraitInsets),
    ]) {
      testWidgets('$name: the account chip is in line with the cards and still filters', (tester) async {
        _window(tester, size, padding: padding);
        await pumpHistory(tester);
        final chip = tester.getRect(find.byType(ActionChip));
        final card = tester.getRect(find.byType(ThreadVisitHistoryCard).first);
        expect(chip.left, greaterThanOrEqualTo(padding.left), reason: 'out of the cutout');
        expect(chip.left, closeTo(card.left, 1), reason: 'same start as the list');
        expect(card.right, lessThanOrEqualTo(size.width - padding.right));

        await tester.tap(find.byType(ActionChip));
        await tester.pumpAndSettle();
        await tester.tap(
          find.ancestor(
            of: find.descendant(of: find.byType(CheckedPopupMenuItem<int>), matching: find.text('UID 11')),
            matching: find.byType(CheckedPopupMenuItem<int>),
          ),
        );
        await tester.pumpAndSettle();
        final shown = tester.widgetList<ThreadVisitHistoryCard>(find.byType(ThreadVisitHistoryCard));
        expect(shown.map((c) => c.model.uid), [11], reason: 'records of the other account stay out');
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('4. reply bar background to the edges, field in the safe area', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late _PagesAdapter pages;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      pages = _PagesAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = pages),
        )
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      await settingsBloc.close();
      await blocks.dispose();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// Pumps [page] under the providers of the app (as in test_102), Alice logged in.
    Future<void> pumpPage(WidgetTester tester, Widget page) async {
      final auth = AuthenticationRepository(user: _alice);
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
      final blockCubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: const [],
      );
      addTearDown(() async {
        await blockCubit.close();
        await history.close();
        await counts.close();
        await info.dispose();
        await auth.dispose();
      });
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => page)],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: blockCubit),
                BlocProvider<NotificationBloc>.value(
                  value: _Notifications(const NotificationState(status: NotificationStatus.success)),
                ),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      );
      await _settle(tester, rounds: 12);
    }

    Finder background() => find.byKey(const ValueKey('reply-bar-background'));
    Finder field() => find.byKey(const ValueKey('reply-bar-field'));

    /// The buttons of the editor sheet, by name: collapse and send.
    ///
    /// No `.first`: a missing icon fails `findsOneWidget` with its name instead of a bare `Bad state: No element`.
    Map<String, Finder> editorButtons() => {
      for (final (name, icon) in [('collapse', Icons.unfold_less), ('send', Icons.send)])
        name: find.ancestor(of: find.byIcon(icon), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
    };

    test('the thread fixture is a thread open for replies', () {
      expect(isThreadClosedForReply(parseHtmlDocument(_threadPage)), isFalse);
    });

    // The three hosts of the bar, with what they show above it. They keep their height when the keyboard shows
    // (`resizeToAvoidBottomInset: false`, the editor panel handles it); the notice detail resized too until GitHub
    // #235, which lifted its editor twice the keyboard's height.
    final hosts = <(String, Widget Function(), Finder Function(), bool)>[
      ('chat', () => const ChatPage(username: 'Bob', uid: '1000'), () => find.byType(ChatMessageCard), false),
      (
        'thread',
        () => ThreadPage(
          threadID: _tid,
          findPostID: null,
          pageNumber: '1',
          overrideReverseOrder: false,
          overrideWithExactOrder: null,
        ),
        () => find.byType(PostCard),
        false,
      ),
      (
        'notice detail',
        () => NoticeDetailPage(
          url: '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=$_pid&ptid=$_tid',
          noticeType: NoticeType.reply,
        ),
        () => find.byType(PostCard),
        false,
      ),
    ];

    testWidgets('thread: a pull to refresh leaves no blank of the refresh indicator above the title', (tester) async {
      _window(tester, _portrait, padding: _portraitInsets);
      final (_, page, _, _) = hosts[1];
      await pumpPage(tester, page());
      expect(find.byType(PostCard), findsWidgets);
      final appBarBottom = tester.getRect(find.byType(AppBar)).bottom;
      final gapBefore = tester.getRect(find.byType(PostCard).first).top - appBarBottom;
      final reads = pages.requests.length;

      await tester.drag(find.byType(PostCard).first, const Offset(0, 320));
      await _settle(tester, rounds: 30);

      expect(pages.requests.length, greaterThan(reads), reason: 'the thread was reloaded');
      expect(find.byType(RefreshProgressIndicator), findsNothing, reason: 'the refresh indicator is finished');
      final gapAfter = tester.getRect(find.byType(PostCard).first).top - appBarBottom;
      expect(gapAfter, closeTo(gapBefore, 4), reason: 'no blank of the refresh indicator stays above the title');
      expect(tester.takeException(), isNull);
    });

    for (final (host, page, content, _) in hosts) {
      for (final (name, size, padding) in [
        ('landscape, cutout on the left', _landscape, _landscapeInsets),
        ('landscape, cutout on the right', _landscape, const FakeViewPadding(right: 44, top: 24)),
        ('portrait with a gesture bar', _portrait, _portraitInsets),
      ]) {
        testWidgets('$host, $name: background edge to edge, field, content and editor in the safe area', (
          tester,
        ) async {
          _window(tester, size, padding: padding);
          await pumpPage(tester, page());
          expect(background(), findsOneWidget, reason: 'the real $host page shows its reply bar');

          final bar = tester.getRect(background());
          expect((bar.left, bar.right), (0, size.width), reason: 'no blank strip beside the bar');
          expect(bar.bottom, size.height, reason: 'down to the bottom edge');
          final box = tester.getRect(field());
          expect(box.left, greaterThanOrEqualTo(padding.left + 12), reason: 'the field is out of the start inset');
          expect(box.right, lessThanOrEqualTo(size.width - padding.right - 12), reason: 'and out of the end inset');
          expect(box.bottom, lessThanOrEqualTo(size.height - (padding.bottom > 4 ? padding.bottom : 4)));

          // The rest of the page keeps its safe area.
          expect(content(), findsWidgets);
          final shown = tester.getRect(content().first);
          expect(shown.left, greaterThanOrEqualTo(padding.left));
          expect(shown.right, lessThanOrEqualTo(size.width - padding.right));

          // Still the real bar: a tap opens the editor, whose buttons stay out of the insets as well.
          expect(
            tester.widget<TextField>(field()).enabled,
            isTrue,
            reason: 'the $host bar is open for replies (not locked as closed or logged out)',
          );
          await tester.tap(field());
          await _settle(tester);
          for (final MapEntry(key: name, value: button) in editorButtons().entries) {
            expect(button, findsOneWidget, reason: 'the $host editor shows its $name button');
            final rect = tester.getRect(button);
            expect(rect.left, greaterThanOrEqualTo(padding.left), reason: 'editor button out of the start inset');
            expect(rect.right, lessThanOrEqualTo(size.width - padding.right), reason: 'and out of the end inset');
          }
          expect(pages.requests.where((e) => e.$1 != 'GET'), isEmpty, reason: 'nothing is sent');
          expect(tester.takeException(), isNull);
        });
      }
    }

    for (final (host, page, _, resizes) in hosts) {
      for (final (name, size, padding, keyboard) in [
        ('portrait', _portrait, _portraitInsets, 300.0),
        ('landscape, cutout on the left', _landscape, _landscapeInsets, 160.0),
      ]) {
        testWidgets('$host, $name, keyboard up: no gesture bar padding above the keyboard, field still safe', (
          tester,
        ) async {
          _window(tester, size, padding: padding, keyboard: keyboard);
          await pumpPage(tester, page());
          final bar = tester.getRect(background());
          expect((bar.left, bar.right), (0, size.width));
          // No host stands the bar on the keyboard: they leave the room to the editor panel.
          expect(bar.bottom, resizes ? size.height - keyboard : size.height);
          final box = tester.getRect(field());
          // The keyboard covers the gesture bar: under the field only the bar's own 8 and the minimum 4 are left.
          expect(bar.bottom - box.bottom, closeTo(12, 0.5));
          expect(box.left, greaterThanOrEqualTo(padding.left + 12));
          expect(box.right, lessThanOrEqualTo(size.width - padding.right - 12));
          expect(pages.requests.where((e) => e.$1 != 'GET'), isEmpty);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('5. author dialog second badge', () {
    late Directory tmp;
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late _ImageAdapter images;

    // The badges are real images: they go through the image cache of the app, which keeps its files on disk. The
    // cache directories live in a temporary folder, the image hosts are [_ImageAdapter].
    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_feedback110_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
          'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
          'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
          'getApplicationDocumentsPath' || 'getApplicationDocumentsDirectory' => '${tmp.path}/docs',
          _ => null,
        },
      );
      await initCache();
    });

    tearDownAll(() => tmp.delete(recursive: true));

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      images = _ImageAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = images)),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    /// Pumps the floor [post] with [auth] as the current account and [titles] as the app's title holder, then opens
    /// the author dialog from the avatar of the author row, as in the thread.
    Future<void> pumpAndOpen(
      WidgetTester tester,
      Post post, {
      required AuthenticationRepository auth,
      required CurrentTitleCubit titles,
    }) async {
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<CurrentTitleCubit>.value(value: titles),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(body: SingleChildScrollView(child: PostCard(post))),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      // The avatar of the author row opens the dialog, as in the thread.
      await tester.tap(find.byType(HeroUserAvatar).first);
      await _settle(tester, rounds: 12);
      expect(find.text(tr.postCard.profileDialog.badges), findsOneWidget, reason: 'the dialog is open');
    }

    /// The floor [post] read by the account [uid], whose own title (from its titles page) is [accountTitle].
    Future<List<int>> openDialog(WidgetTester tester, Post post, {required int uid, String? accountTitle}) async {
      final reads = <int>[];
      final auth = AuthenticationRepository(
        user: UserLoginInfo(username: 'Reader', uid: uid),
      );
      final status = StreamController<AuthStatus>.broadcast(sync: true);
      final titles = CurrentTitleCubit(
        currentUid: () => uid,
        authStatus: status.stream,
        fetchTitles: () {
          reads.add(uid);
          return TaskEither.right([
            if (accountTitle != null) SecondaryTitle(id: 1, name: 'Own', imageUrl: accountTitle, activated: true),
          ]);
        },
      );
      status.add(AuthStatusAuthed(UserLoginInfo(username: 'Reader', uid: uid)));
      addTearDown(() async {
        await titles.close();
        await status.close();
        await auth.dispose();
      });
      await pumpAndOpen(tester, post, auth: auth, titles: titles);
      return reads;
    }

    Finder floorTitle() => find.byKey(const ValueKey('brief-profile-floor-title'));
    Finder accountTitle() => find.byKey(const ValueKey('brief-profile-account-title'));
    Finder groupBadge() => find.byKey(const ValueKey('brief-profile-group-badge'));

    /// [badge] of the dialog shows the image of [url], decoded from the bytes of the local image host.
    Future<void> expectPainted(WidgetTester tester, Finder badge, String url) async {
      final raw = find.descendant(of: badge, matching: find.byType(RawImage));
      bool painted() => raw.evaluate().isNotEmpty && tester.widget<RawImage>(raw.first).image != null;
      // Loading an image is real async work (cache, file, decoding).
      for (var i = 0; i < 40 && !painted(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(images.requested, contains(url), reason: 'asked from the local image host');
      expect(painted(), isTrue, reason: '$url is decoded and painted in the dialog');
    }

    for (final size in [_landscape, const Size(640, 360)]) {
      testWidgets('landscape ${size.width}x${size.height}: the uid and online pills stay in the header', (
        tester,
      ) async {
        _window(tester, size, padding: _landscapeInsets);
        await openDialog(tester, _post(), uid: 1000, accountTitle: _ownTitle);
        final pills = find.byType(AppInfoPill);
        expect(pills, findsNWidgets(2), reason: '${size.width}x${size.height}: uid and online state');
        final header = find.ancestor(of: pills.first, matching: find.byType(SingleChildScrollView)).first;
        final headerRect = tester.getRect(header);
        for (var i = 0; i < 2; i++) {
          final pill = tester.getRect(pills.at(i));
          expect(
            pill.bottom,
            lessThanOrEqualTo(headerRect.bottom),
            reason: '${size.width}x${size.height}: pill $i is not cut by the title viewport',
          );
          expect(pill.top, greaterThanOrEqualTo(headerRect.top));
        }
      });
    }

    test('the title image is found in its block also when a link wraps it', () {
      expect(_post().secondBadge, _floorTitle);
      expect(_post(linked: true).secondBadge, _floorTitle);
      expect(_post(strip: true).secondBadge, isNull, reason: 'only the level badge: no second badge is made up');
      expect(_post(strip: true).badge, isNotNull);
      expect(_post().userBriefProfile?.uid, '$_floorAuthor');
    });

    testWidgets('a floor with a title shows it next to the level badge, for another reader', (tester) async {
      final reads = await openDialog(tester, _post(), uid: 1000, accountTitle: _ownTitle);
      expect(groupBadge(), findsOneWidget);
      expect(floorTitle(), findsOneWidget);
      expect(tester.widget<SecondaryTitleBadge>(floorTitle()).imageUrl, _floorTitle);
      await expectPainted(tester, floorTitle(), _floorTitle);
      await expectPainted(tester, groupBadge(), _post().badge!);
      expect(accountTitle(), findsNothing);
      expect(reads, isEmpty, reason: 'the reader title is not even read');
      expect(images.requested, isNot(contains(_ownTitle)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an own floor with its title: the floor wins over the account title', (tester) async {
      final reads = await openDialog(tester, _post(), uid: _floorAuthor, accountTitle: _ownTitle);
      expect(tester.widget<SecondaryTitleBadge>(floorTitle()).imageUrl, _floorTitle);
      await expectPainted(tester, floorTitle(), _floorTitle);
      await expectPainted(tester, groupBadge(), _post().badge!);
      expect(accountTitle(), findsNothing);
      expect(reads, isEmpty);
      expect(images.requested, isNot(contains(_ownTitle)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('another author without a title: only the level badge, never the reader title', (tester) async {
      final reads = await openDialog(tester, _post(strip: true), uid: 1000, accountTitle: _ownTitle);
      expect(groupBadge(), findsOneWidget);
      await expectPainted(tester, groupBadge(), _post().badge!);
      expect(floorTitle(), findsNothing);
      expect(accountTitle(), findsNothing);
      expect(find.byType(SecondaryTitleBadge), findsNothing, reason: 'the reader title stays out of this dialog');
      expect(reads, isEmpty);
      expect(images.requested, isNot(contains(_ownTitle)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an own floor without a title in its markup: the title this account uses', (tester) async {
      final reads = await openDialog(tester, _post(strip: true), uid: _floorAuthor, accountTitle: _ownTitle);
      expect(groupBadge(), findsOneWidget);
      expect(floorTitle(), findsNothing);
      expect(accountTitle(), findsOneWidget);
      final badge = find.descendant(of: accountTitle(), matching: find.byType(SecondaryTitleBadge));
      expect(tester.widget<SecondaryTitleBadge>(badge).imageUrl, _ownTitle);
      await expectPainted(tester, accountTitle(), _ownTitle);
      await expectPainted(tester, groupBadge(), _post().badge!);
      expect(reads, [_floorAuthor], reason: 'read once, for this account');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an own floor without a title, and the account uses none: nothing is made up', (tester) async {
      await openDialog(tester, _post(strip: true), uid: _floorAuthor);
      expect(groupBadge(), findsOneWidget);
      await expectPainted(tester, groupBadge(), _post().badge!);
      expect(find.byType(SecondaryTitleBadge), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // The dialog stays open while the account changes (e.g. switched from another window of the app): the badge room
    // of an own floor is tied to the uid of its author, never to "whoever is the reader now".
    for (final viaLoading in [true, false]) {
      testWidgets(
        'account switch while the dialog is open${viaLoading ? '' : ', no loading status in between'}: neither the late '
        "title of the previous account nor the next account's title is shown for the author",
        (tester) async {
          var uid = _floorAuthor;
          final reads = <int>[];
          final answers = <int, Completer<Either<AppException, List<SecondaryTitle>>>>{};
          const author = UserLoginInfo(username: 'Author', uid: _floorAuthor);
          const next = UserLoginInfo(username: 'Next', uid: 1000);
          final auth = AuthenticationRepository(user: author);
          final status = StreamController<AuthStatus>.broadcast(sync: true);
          final titles = CurrentTitleCubit(
            currentUid: () => uid,
            authStatus: status.stream,
            fetchTitles: () {
              final reader = uid;
              reads.add(reader);
              final answer = Completer<Either<AppException, List<SecondaryTitle>>>();
              answers[reader] = answer;
              return TaskEither(() => answer.future);
            },
          );
          status.add(const AuthStatusAuthed(author));
          addTearDown(() async {
            await titles.close();
            await status.close();
            await auth.dispose();
          });

          await pumpAndOpen(tester, _post(strip: true), auth: auth, titles: titles);
          // Own floor without a title: the badge room waits for the title of this account.
          expect(find.descendant(of: accountTitle(), matching: find.byType(SecondaryTitlePlaceholder)), findsOneWidget);
          expect(reads, [_floorAuthor]);

          // The account is switched while the dialog is open.
          uid = next.uid!;
          if (viaLoading) {
            status.add(const AuthStatusLoading());
          }
          status.add(const AuthStatusAuthed(next));
          await _settle(tester);

          // The next account reads its own title (the homepage does), so the app knows it...
          unawaited(titles.ensureLoaded());
          answers[next.uid!]!.complete(
            right([const SecondaryTitle(id: 2, name: 'Next', imageUrl: _nextTitle, activated: true)]),
          );
          // ...and only then the answer for the previous account arrives, late.
          answers[_floorAuthor]!.complete(
            right([const SecondaryTitle(id: 1, name: 'Own', imageUrl: _ownTitle, activated: true)]),
          );
          await _settle(tester);

          expect(titles.state.imageUrlFor(next.uid), _nextTitle, reason: 'the title of the next account is known');
          expect(titles.state.imageUrlFor(_floorAuthor), isNull, reason: 'the late answer was dropped');
          expect(find.text(tr.postCard.profileDialog.badges), findsOneWidget, reason: 'the dialog is still open');
          await expectPainted(tester, groupBadge(), _post().badge!);
          expect(find.byType(SecondaryTitleBadge), findsNothing, reason: 'no title for the author of this floor');
          expect(
            find.descendant(of: accountTitle(), matching: find.byType(SecondaryTitlePlaceholder)),
            findsNothing,
            reason: 'nothing is pending for the author any more',
          );
          expect(images.requested, isNot(contains(_nextTitle)));
          expect(images.requested, isNot(contains(_ownTitle)));
          expect(reads, [_floorAuthor, next.uid]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('6 / 8. homepage', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late _Auth auth;
    late NotificationInfoRepository info;
    late NotificationStateCubit counts;
    late _ForumAdapter adapter;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _ForumAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
        )
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
      await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      auth = _Auth(_alice);
      info = NotificationInfoRepository();
      counts = NotificationStateCubit(info);
    });

    tearDown(() async {
      await info.dispose();
      await counts.close();
      await settingsBloc.close();
      await blocks.dispose();
      await auth.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<void> openHomepage(WidgetTester tester) async {
      _window(tester, _portrait, padding: _portraitInsets);
      final home = HomeCubit();
      final checkin = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: auth,
        settingsRepository: settings,
      );
      final forumHome = ForumHomeRepository();
      final blockCubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: const [],
      );
      addTearDown(() async {
        await blockCubit.close();
        await home.close();
        await checkin.close();
        await forumHome.dispose();
      });
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const HomepagePage())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<NotificationInfoRepository>.value(value: info),
              RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
              RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: blockCubit),
                BlocProvider<NotificationBloc>.value(
                  value: _Notifications(const NotificationState(status: NotificationStatus.success)),
                ),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<HomeCubit>.value(value: home),
                BlocProvider<CheckinBloc>.value(value: checkin),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    HomepageBloc bloc(WidgetTester tester) => BlocProvider.of<HomepageBloc>(tester.element(find.byType(AppBar)));

    Finder inAppBar(Finder finder) => find.descendant(of: find.byType(AppBar), matching: finder);

    Finder redPacketButton() => find.ancestor(
      of: find.text(tr.redPacket.daily.unavailable),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );

    testWidgets('6. loading and refreshing never flash the activity entry in the app bar', (tester) async {
      adapter.hold = Completer<void>();
      await openHomepage(tester);
      expect(bloc(tester).state.status, HomepageStatus.loading);
      expect(inAppBar(find.byIcon(Icons.event_outlined)), findsNothing, reason: 'first load');
      expect(inAppBar(find.byIcon(Icons.search_outlined)), findsOneWidget, reason: 'search stays');

      adapter.hold!.complete();
      adapter.hold = null;
      await _settle(tester);
      expect(bloc(tester).state.status, HomepageStatus.success);
      expect(inAppBar(find.byIcon(Icons.event_outlined)), findsNothing);
      expect(find.byIcon(Icons.event_outlined), findsWidgets, reason: 'the entry of the greeting card');

      // A manual refresh reloads everything, and the app bar stays as it was.
      adapter.hold = Completer<void>();
      bloc(tester).add(HomepageRefreshRequested());
      await _settle(tester);
      expect(bloc(tester).state.status, HomepageStatus.loading);
      expect(inAppBar(find.byIcon(Icons.event_outlined)), findsNothing, reason: 'refresh');
      expect(inAppBar(find.byIcon(Icons.search_outlined)), findsOneWidget);
      adapter.hold!.complete();
      adapter.hold = null;
      await _settle(tester);
      expect(bloc(tester).state.status, HomepageStatus.success);
      expect(tester.takeException(), isNull);
    });

    test('8. the fake forum pages carry the owner and the packet the way the real parsers read them', () {
      final withPacket = parseHtmlDocument(_forumHome(packet: true));
      expect(parseLoggedUidFromDocument(withPacket), 1000);
      expect(parseDailyRedPacketConfig(withPacket)?.dateFlag, '20260928');
      expect(parseFormHash(withPacket), 'XXXXXXXX');
      final without = parseHtmlDocument(_forumHome(packet: false));
      expect(parseLoggedUidFromDocument(without), 1000);
      expect(parseDailyRedPacketConfig(without), isNull, reason: 'no packet today: the forum embeds no config');
      expect(parseLoggedUidFromDocument(parseHtmlDocument(_forumHome(packet: true, uid: 2000))), 2000);
    });

    testWidgets('8. the red packet entry checks the packet alone: no loading, no reload of the page', (tester) async {
      await openHomepage(tester);
      expect(bloc(tester).state.status, HomepageStatus.success);
      expect(redPacketButton(), findsOneWidget);
      final homeBefore = adapter.homeRequests.length;
      final profileBefore = adapter.profileRequests.length;
      final greeting = tester.element(find.byType(HomeGreetingCard));
      final states = <HomepageState>[];
      final sub = bloc(tester).stream.listen(states.add);
      addTearDown(sub.cancel);

      adapter.packet = true;
      await tester.tap(find.text(tr.redPacket.daily.unavailable));
      await _settle(tester);

      expect(adapter.homeRequests.length, homeBefore + 1, reason: 'one read of the forum homepage');
      expect(adapter.profileRequests.length, profileBefore, reason: 'the profile is not read again');
      expect(states.map((s) => s.status), everyElement(HomepageStatus.success), reason: 'never loading');
      expect(states.first.checkingDailyRedPacket, isTrue);
      expect(bloc(tester).state.checkingDailyRedPacket, isFalse);
      expect(bloc(tester).state.dailyRedPacket?.dateFlag, '20260928', reason: "today's packet of this account");
      expect(identical(tester.element(find.byType(HomeGreetingCard)), greeting), isTrue, reason: 'not rebuilt anew');
      expect(find.text(tr.redPacket.daily.tooltip), findsOneWidget, reason: 'the packet is claimable now');
      expect(adapter.posts, isEmpty, reason: 'checking claims nothing');
      expect(tester.takeException(), isNull);
    });

    testWidgets('8. a page of another account is not taken for the current one', (tester) async {
      await openHomepage(tester);
      adapter
        ..packet = true
        ..homeUid = 2000;
      await tester.tap(find.text(tr.redPacket.daily.unavailable));
      await _settle(tester);
      expect(bloc(tester).state.dailyRedPacket, isNull);
      expect(bloc(tester).state.status, HomepageStatus.success);
      expect(find.text(tr.redPacket.daily.unavailable), findsOneWidget);
      expect(adapter.posts, isEmpty);
    });

    testWidgets('8. an account switch during the check drops its answer', (tester) async {
      await openHomepage(tester);
      adapter
        ..packet = true
        ..hold = Completer<void>();
      await tester.tap(find.text(tr.redPacket.daily.unavailable));
      await _settle(tester);
      expect(bloc(tester).state.checkingDailyRedPacket, isTrue);
      final button = tester.widget<ButtonStyleButton>(redPacketButton());
      expect(button.onPressed, isNull, reason: 'one check at a time');

      auth.currentUser = const UserLoginInfo(username: 'Bob', uid: 1001);
      adapter.hold!.complete();
      adapter.hold = null;
      await _settle(tester);
      expect(bloc(tester).state.dailyRedPacket, isNull, reason: 'the answer was for the previous account');
      expect(bloc(tester).state.checkingDailyRedPacket, isFalse);
    });
  });

  group('7. notification page', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;
    late _Auth auth;
    late NotificationInfoRepository info;
    late NotificationStateCubit counts;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      auth = _Auth(_alice);
      info = NotificationInfoRepository();
      counts = NotificationStateCubit(info);
    });

    tearDown(() async {
      await info.dispose();
      await counts.close();
      await settingsBloc.close();
      await blocks.dispose();
      await auth.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    final synced = NotificationState(
      status: NotificationStatus.success,
      noticeList: const [
        NoticeV2(id: 1, timestamp: 1788000001, data: 'unread notice one'),
        NoticeV2(id: 2, timestamp: 1788000002, data: 'read notice two', alreadyRead: true),
      ],
    );

    Future<void> open(WidgetTester tester, {required Size size, double scale = 1}) async {
      _window(tester, size, scale: scale);
      final notifications = _Notifications(const NotificationState(status: NotificationStatus.loading));
      final blockCubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: const [],
      );
      final auto = AutoNotificationCubit(
        authenticationRepository: auth,
        notificationRepository: NotificationRepository(storageProvider: storage),
        storageProvider: storage,
      );
      addTearDown(() async {
        await blockCubit.close();
        await auto.close();
      });
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const NotificationPage())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<NotificationInfoRepository>.value(value: info),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: blockCubit),
                BlocProvider<NotificationBloc>.value(value: notifications),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<AutoNotificationCubit>.value(value: auto),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      );
      await _settle(tester);
      notifications.push(synced);
      await _settle(tester);
    }

    Finder filter() => find.byKey(const ValueKey('notice-unread-filter'));

    for (final (name, size, scale) in [('384', _portrait, 1.0), ('320 with 2x text', const Size(320, 640), 2.0)]) {
      testWidgets('$name: the unread filter is in the app bar, no row of its own, and filters every tab', (
        tester,
      ) async {
        await open(tester, size: size, scale: scale);
        expect(find.descendant(of: find.byType(AppBar), matching: filter()), findsOneWidget);
        expect(find.byType(FilterChip), findsNothing, reason: 'the empty row above the tabs is gone');
        final button = tester.widget<IconButton>(filter());
        expect(button.tooltip, contains(tr.noticePage.appBar.unread));
        expect(button.isSelected, isFalse);
        expect(find.textContaining('read notice two', findRichText: true), findsOneWidget);

        await tester.tap(filter());
        await _settle(tester);
        expect(tester.widget<IconButton>(filter()).isSelected, isTrue);
        expect(find.textContaining('unread notice one', findRichText: true), findsOneWidget);
        expect(find.textContaining('read notice two', findRichText: true), findsNothing);

        // The choice holds on the other tabs.
        await tester.tap(find.text(tr.noticePage.privateMessageTab.title));
        await _settle(tester);
        expect(tester.widget<IconButton>(filter()).isSelected, isTrue);

        await tester.tap(filter());
        await _settle(tester);
        expect(tester.widget<IconButton>(filter()).isSelected, isFalse);
        expect(tester.getRect(filter()).right, lessThanOrEqualTo(size.width));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('9. settings: debug section icon in line', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<AppDatabase>(db)
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('${scale}x text: the warning icon starts where every other row icon starts', (tester) async {
        _window(tester, _portrait, padding: _portraitInsets, scale: scale);
        final theme = ThemeCubit();
        addTearDown(theme.close);
        await tester.pumpWidget(
          MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<ThemeCubit>.value(value: theme),
            ],
            child: TranslationProvider(child: const MaterialApp(home: SettingsPage())),
          ),
        );
        await _settle(tester);
        final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
        final viewport = tester.getRect(list);
        final about = find.text(tr.settingsPage.othersSection.about);
        await tester.scrollUntilVisible(about, 200, scrollable: list);
        await tester.pumpAndSettle();
        expect(about.hitTestable(), findsOneWidget, reason: 'the "about" row is on screen');
        final aboutIcon = tester.getRect(
          find.descendant(
            of: find.ancestor(of: about, matching: find.byWidgetPredicate((w) => w is ListTile)).first,
            matching: find.byIcon(Icons.info_outline),
          ),
        );

        // The debug row is measured and tapped where the user sees it. At 2x text the row sits above the viewport once
        // "about" is in view, so it is scrolled back into view first: a tap offscreen would hit nothing.
        final expansion = find.byKey(const ValueKey('settings-debug-expansion'));
        final tip = find.descendant(of: expansion, matching: find.text(tr.settingsPage.debugSection.tip));
        await tester.ensureVisible(tip);
        await tester.pumpAndSettle();
        final warningIcon = find.descendant(of: expansion, matching: find.byIcon(Icons.warning_amber_outlined)).first;
        expect(warningIcon.hitTestable(), findsOneWidget, reason: 'the warning icon is on screen');
        final warning = tester.getRect(warningIcon);
        expect(warning.top, greaterThanOrEqualTo(viewport.top));
        expect(warning.bottom, lessThanOrEqualTo(viewport.bottom));
        expect(warning.left, closeTo(aboutIcon.left, 0.5), reason: 'same leading start as the other rows');

        // Still an expansion: a tap on the visible row opens it, its rows appear and line up too.
        expect(tip.hitTestable(), findsOneWidget);
        expect(find.byIcon(Icons.developer_board_outlined), findsNothing, reason: 'collapsed by default');
        await tester.tap(tip);
        await tester.pumpAndSettle();
        final debugIcon = find.byIcon(Icons.developer_board_outlined);
        await tester.ensureVisible(debugIcon);
        await tester.pumpAndSettle();
        expect(debugIcon.hitTestable(), findsOneWidget, reason: 'the expanded row is on screen');
        final debugRow = tester.getRect(debugIcon);
        expect(debugRow.left, closeTo(warning.left, 0.5));
        expect(tester.takeException(), isNull);
      });
    }
  });
}
