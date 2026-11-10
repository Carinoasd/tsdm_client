/// The moderator's panel: the recycle bins (threads and replies) and the log of the forum's moderation panel, and its
/// entry on the "me" page for an account of a management group.
///
/// The fixtures `test/data/modcp/*` are the test forum's pages (Discuz! X5, plugin tsdmapp 3.6.0) to a moderator and
/// an administrator, cut to the main column as the queue's (`test/data/moderate/queue_*`) and scrubbed:
///
/// * `recyclebin_forums.html`: `forum.php?mod=modcp&action=recyclebin` without a forum, its forum select (the forums
///   the account moderates that keep a bin) and its note 请选择版块进行管理;
/// * `recyclebin_threads.html`, `recyclebin_posts.html`: the thread and reply bins of a forum to a moderator (restore
///   only: the group may not delete for good, `allowclearrecycle`); `recyclebin_threads_admin.html` the thread bin to
///   an administrator, with its 删除 button;
/// * `recyclebin_restore_result.html`: the answer to restoring one of the two threads, the bin again without it (the
///   panel says nothing: `showmessage(..., ['break' => 1])` returns and the list is drawn); the moderator's deletion
///   of the other one got the same page, the thread still listed, nothing done; `recyclebin_delete_result_admin.html`
///   the administrator's deletion for good, the bin empty;
/// * `recyclebin_nobin.html`: a forum asked that keeps no bin, none selected;
/// * `queue_forums.html`: the moderation queue without a forum, its forum select;
/// * `log_empty.html`: the log as X5 prints it (X5 logs the panel to the database, `pre_common_log`, while the page
///   still reads `data/log/*modcp*` files: no line ever); `log_entries.html` the same page with the table its
///   template draws for lines of an older forum's files (`modcp_log.htm`), written by hand.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_log_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/moderate/view/recycle_bin_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/modcp';
const _uid = 31;
const _fid = 15;

String _text(String name) => File(name.contains('/') ? 'test/data/$name' : '$_dir/$name').readAsStringSync();

ModerateResponse _ok(Object? data) => (statusCode: 200, data: data);

RecycleBinList _bin(String name, RecycleBinKind kind, {int fid = _fid, String? html}) =>
    switch (ModcpRepository.recycleBinOf(html ?? _text(name), kind, fid: fid, uid: _uid)) {
      Right(value: ModcpReady(:final value)) => value,
      final other => throw StateError('no bin: $other'),
    };

/// [html] with a link to a next page, as the forum prints it under a list.
String _withNextPage(String html) => html.replaceFirst(
  '</body>',
  '<div class="pg"><strong>1</strong><a href="forum.php?page=2" class="nxt">下一页</a></div>\n</body>',
);

Translations get t => LocaleSettings.instance.currentTranslations;

/// A transport answering each url with the page the test gives, and keeping what was asked and posted.
final class _Forum {
  _Forum(this.pages, {this.postAnswer});

  /// The fixture of each url asked, by a part of the url.
  final Map<String, String> pages;

  /// What a post is answered with.
  ModerateResponse Function(String url, Map<String, String> body)? postAnswer;

  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  ModcpRepository repository() => ModcpRepository(
    get: (url) async {
      gets.add(url);
      for (final MapEntry(:key, :value) in pages.entries) {
        if (url.endsWith(key)) {
          return right(_ok(_text(value)));
        }
      }
      return left(HttpRequestFailedException(404));
    },
    post: (url, body) async {
      posts.add((url, body));
      return right(postAnswer!(url, body));
    },
    currentUid: () => _uid,
  );
}

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: page),
    ),
  );
  await tester.pumpAndSettle();
}

/// No network: images are not loaded.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final class _ProfileAdapter implements HttpClientAdapter {
  _ProfileAdapter(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  final UserLoginInfo? currentUser;
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('pages of the panel', () {
    test('the bin without a forum: the forums offered and the note, no list', () {
      final bin = _bin('recyclebin_forums.html', RecycleBinKind.threads, fid: 0);
      expect(bin.fid, 0);
      expect(bin.forums, const [ModcpForum(fid: 2, name: '公告'), ModcpForum(fid: _fid, name: '测试子版块')]);
      expect(bin.note, '请选择版块进行管理');
      expect(bin.items, isEmpty);
    });

    test('a forum keeping no bin: none selected, the forums offered', () {
      final bin = _bin('recyclebin_nobin.html', RecycleBinKind.threads, fid: 9);
      expect(bin.fid, 0);
      expect(bin.forums.map((e) => e.fid), [2, _fid]);
    });

    test('the thread bin of a moderator: as the forum lists it, restore only', () {
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      expect(bin.fid, _fid);
      expect(bin.uid, _uid);
      expect(bin.canDelete, isFalse);
      expect(bin.hasNext, isFalse);
      expect(bin.fields, {'formhash': 'f1f2f3f4'});
      expect(bin.items.map((e) => e.id), ['9202823', '9202822']);
      final item = bin.items.first;
      expect(item.title, '回收站測試主題 3');
      expect(item.author, '测试版主');
      expect(item.authorUid, _uid);
      expect(item.time, '2026-11-10');
      expect(item.reason, '回收站測試');
      expect((item.replies, item.views), ('0', '0'));
      expect(item.tid, isNull);
    });

    test('the thread bin of an administrator offers deleting for good', () {
      final bin = _bin('recyclebin_threads_admin.html', RecycleBinKind.threads);
      expect(bin.canDelete, isTrue);
      expect(bin.items.map((e) => e.id), ['9202823']);
      expect(bin.forums, hasLength(10));
    });

    test('the reply bin: the text, the author, the time, the thread', () {
      final bin = _bin('recyclebin_posts.html', RecycleBinKind.posts);
      expect(bin.canDelete, isFalse);
      expect(bin.fields, {'formhash': 'f1f2f3f4', 'posttableid': '0'});
      expect(bin.items.map((e) => e.id), ['11269', '11270']);
      final item = bin.items.first;
      expect(item.title, '回收站測試回帖 1，之後會被刪除。');
      expect(item.author, '测试版主');
      expect(item.authorUid, _uid);
      expect(item.time, matches(RegExp(r'^2026-11-10 \d\d:\d\d:\d\d$')));
      expect(item.tid, '9202821');
      expect(item.reason, isEmpty);
    });

    test('a page of the other bin is not this one', () {
      final answer = ModcpRepository.recycleBinOf(
        _text('recyclebin_posts.html'),
        RecycleBinKind.threads,
        fid: _fid,
        uid: _uid,
      );
      expect(answer.isLeft(), isTrue);
    });

    test('the operation: the served fields, the items, no page of the panel but the one shown', () {
      final threads = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      expect(
        threads.submitUrl,
        '$baseUrl/forum.php?mod=modcp&action=recyclebin&fid=$_fid&page=1',
      );
      expect(threads.body(RecycleBinAction.restore, ['9202822', '9202823']), {
        'formhash': 'f1f2f3f4',
        'op': 'restore',
        'oldop': 'list',
        'dosubmit': 'submit',
        'moderate[0]': '9202822',
        'moderate[1]': '9202823',
      });
      final posts = _bin('recyclebin_posts.html', RecycleBinKind.posts);
      expect(posts.submitUrl, '$baseUrl/forum.php?mod=modcp&action=recyclebinpost&fid=$_fid&page=1');
      expect(posts.body(RecycleBinAction.delete, ['11270']), {
        'formhash': 'f1f2f3f4',
        'posttableid': '0',
        'op': 'delete',
        'oldop': 'list',
        'dosubmit': 'submit',
        'moderate[0]': '11270',
      });
    });

    test('the login form, the refusal, another account', () {
      final login = ModcpRepository.recycleBinOf(
        _text('moderate/queue_login.html'),
        RecycleBinKind.threads,
        fid: _fid,
        uid: _uid,
      );
      expect(login.getRight().toNullable(), isA<ModcpNeedsLogin<RecycleBinList>>());
      final refused = ModcpRepository.logOf(_text('moderate/queue_noaccess.html'), uid: _uid);
      expect(
        (refused.getRight().toNullable()! as ModcpRefused).message,
        '抱歉，您没有权限访问管理面板，请重新登录站点，然后重试',
      );
      final other = ModcpRepository.logOf(_text('log_entries.html'), uid: 32);
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test('the log: every column as printed, the next page', () {
      final page = switch (ModcpRepository.logOf(_text('log_entries.html'), uid: _uid)) {
        Right(value: ModcpReady(:final value)) => value,
        final other => throw StateError('no log: $other'),
      };
      expect(page.hasNext, isTrue);
      expect(page.entries, hasLength(3));
      final first = page.entries.first;
      expect(first.time, '26-11-10 10:38');
      expect(first.operator, '测试版主');
      expect(first.group, '版主');
      expect(first.ip, '192.0.2.1');
      expect(first.action, 'recyclebin');
      expect(first.op, 'restore');
      expect(first.forum, '测试子版块');
      expect(first.other, 'fid=15;page=1;oldop=list;dosubmit=submit;moderate={0=1234567;};');
      expect((page.entries[1].action, page.entries[1].op, page.entries[1].forum), ('审核', 'threads', ''));
      expect((page.entries[2].group, page.entries[2].op, page.entries[2].other), ('GID 21', '', ''));
    });

    test('the log of X5: the search form alone', () {
      final page = ModcpRepository.logOf(_text('log_empty.html'), uid: _uid).getRight().toNullable();
      expect((page! as ModcpReady<ModcpLogPage>).value.entries, isEmpty);
      expect(
        ModcpLogPage.url(keyword: '回收 站', page: 2),
        '$baseUrl/forum.php?mod=modcp&action=log&keyword=%E5%9B%9E%E6%94%B6+%E7%AB%99&page=2',
      );
    });

    test('the forums of the moderation queue', () {
      final forums = ModcpRepository.queueForumsOf(parseHtmlDocument(_text('queue_forums.html')), _uid);
      expect(forums!.map((e) => e.fid), [2, 9, 10, _fid]);
      expect(ModcpRepository.queueForumsOf(parseHtmlDocument(_text('log_empty.html')), _uid), isNull);
    });
  });

  group('operations', () {
    test('restored: the bin answered no longer lists it; posted once', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('recyclebin_restore_result.html')));
      final repo = forum.repository();
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await repo.submitRecycleBin(bin, RecycleBinAction.restore, ['9202822']).run();
      expect(outcome.getRight().toNullable(), isA<RecycleBinDone>().having((e) => e.count, 'count', 1));
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.$1, bin.submitUrl);
      expect(forum.gets, isEmpty);
    });

    test('the forum did nothing (no permission to delete for good): still listed, not done', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('recyclebin_restore_result.html')));
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await forum.repository().submitRecycleBin(bin, RecycleBinAction.delete, ['9202823']).run();
      expect(
        outcome.getRight().toNullable(),
        isA<RecycleBinNotDone>().having((e) => e.remaining, 'remaining', ['9202823']).having((e) => e.done, 'done', 0),
      );
    });

    test('the pages up to the last one an item was picked on are read again', () async {
      final forum = _Forum(
        {'fid=$_fid&page=2': 'recyclebin_threads_admin.html'},
        postAnswer: (_, _) => _ok(_withNextPage(_text('recyclebin_restore_result.html'))),
      );
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await forum.repository().submitRecycleBin(bin, RecycleBinAction.delete, [
        '9202822',
        '9202823',
      ], lastPage: 2).run();
      expect(forum.gets, ['$baseUrl/forum.php?mod=modcp&action=recyclebin&fid=$_fid&page=2']);
      expect(
        outcome.getRight().toNullable(),
        isA<RecycleBinNotDone>().having((e) => e.remaining, 'remaining', ['9202823']).having((e) => e.done, 'done', 1),
      );
    });

    test('a later page that can not be read again: not told done', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_withNextPage(_text('recyclebin_restore_result.html'))));
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await forum.repository().submitRecycleBin(bin, RecycleBinAction.restore, [
        '9202822',
      ], lastPage: 3).run();
      expect(forum.gets, ['$baseUrl/forum.php?mod=modcp&action=recyclebin&fid=$_fid&page=2']);
      expect(forum.posts, hasLength(1));
      expect(outcome.getRight().toNullable(), isA<RecycleBinUnknown>());
    });

    test('a later page that can not be read again, an item still listed before it: not done', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_withNextPage(_text('recyclebin_restore_result.html'))));
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await forum.repository().submitRecycleBin(bin, RecycleBinAction.delete, [
        '9202823',
        '1234567',
      ], lastPage: 2).run();
      expect(
        outcome.getRight().toNullable(),
        isA<RecycleBinNotDone>().having((e) => e.remaining, 'remaining', ['9202823']),
      );
    });

    test('the panel failing (its session ended: an error page) is a failure, never sent again', () async {
      final forum = _Forum({}, postAnswer: (_, _) => (statusCode: 503, data: 'System Error'));
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await forum.repository().submitRecycleBin(bin, RecycleBinAction.restore, ['9202822']).run();
      expect(outcome.getLeft().toNullable(), isA<HttpRequestFailedException>());
      expect(forum.posts, hasLength(1));
    });

    test('the login form answered: the session ended', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(_text('moderate/queue_login.html')));
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await forum.repository().submitRecycleBin(bin, RecycleBinAction.restore, ['9202822']).run();
      expect(outcome.getRight().toNullable(), isA<RecycleBinSessionEnded>());
    });

    test('never sent once the account changed', () async {
      final forum = _Forum({}, postAnswer: (_, _) => _ok(''));
      final repo = ModcpRepository(
        get: (_) async => left(HttpRequestFailedException(404)),
        post: (url, body) async {
          forum.posts.add((url, body));
          return right(_ok(''));
        },
        currentUid: () => 32,
      );
      final bin = _bin('recyclebin_threads.html', RecycleBinKind.threads);
      final outcome = await repo.submitRecycleBin(bin, RecycleBinAction.restore, ['9202822']).run();
      expect(outcome.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(forum.posts, isEmpty);
    });
  });

  group('pages', () {
    testWidgets('the panel: the queue, the recycle bin and the log', (tester) async {
      await _pumpPage(tester, ModeratorPanelPage(repository: _Forum({}).repository()));
      for (final key in ['modcp-queue', 'modcp-recycle-bin', 'modcp-log']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the queue: its forums first, the queue of the one chosen', (tester) async {
      final forum = _Forum({
        'op=threads&fid=0&filter=0': 'queue_forums.html',
        'op=threads&fid=$_fid&filter=0': 'moderate/queue_threads.html',
        'op=replies&fid=$_fid&filter=0': 'moderate/queue_replies.html',
      });
      final queueGets = <String>[];
      await _pumpPage(
        tester,
        ModeratorPanelPage(
          repository: forum.repository(),
          queueRepository: ModerateRepository(
            get: (url) async {
              queueGets.add(url);
              return left(HttpRequestFailedException(404));
            },
            post: (_, _) async => left(HttpRequestFailedException(404)),
            currentUid: () => _uid,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('modcp-queue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-forum-9')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('modcp-forum-$_fid')));
      await tester.pumpAndSettle();
      expect(find.text('${t.moderate.queue} · 测试子版块'), findsOneWidget);
      expect(queueGets.first, contains('fid=$_fid'));
    });

    testWidgets('the bin: pick, restore once, the bin read again; no deleting for good when not offered', (
      tester,
    ) async {
      final forum = _Forum(
        {
          'action=recyclebin': 'recyclebin_forums.html',
          'action=recyclebin&fid=$_fid': 'recyclebin_threads.html',
          'action=recyclebinpost&fid=$_fid': 'recyclebin_posts.html',
        },
        postAnswer: (_, _) => _ok(_text('recyclebin_restore_result.html')),
      );
      await _pumpPage(tester, RecycleBinPage(repository: forum.repository()));
      await tester.tap(find.byKey(const ValueKey('modcp-forum-$_fid')));
      await tester.pumpAndSettle();
      expect(find.text('${t.modcp.recycleBin} · 测试子版块'), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-bin-delete')), findsNothing);
      final restore = find.byKey(const ValueKey('modcp-bin-restore'));
      expect(tester.widget<FilledButton>(restore).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('modcp-bin-item-9202822')));
      await tester.pump();
      expect(find.text(t.modcp.selected(count: 1)), findsOneWidget);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.$2, containsPair('moderate[0]', '9202822'));
      expect(forum.posts.single.$2, containsPair('op', 'restore'));
      expect(find.text(t.modcp.done(count: 1)), findsOneWidget);
      expect(forum.gets.where((e) => e.endsWith('action=recyclebin&fid=$_fid')), hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('deleting for good asks first; cancelled, nothing is sent', (tester) async {
      final forum = _Forum(
        {
          'action=recyclebin': 'recyclebin_forums.html',
          'action=recyclebin&fid=$_fid': 'recyclebin_threads_admin.html',
          'action=recyclebinpost&fid=$_fid': 'recyclebin_posts.html',
        },
        postAnswer: (_, _) => _ok(_text('recyclebin_delete_result_admin.html')),
      );
      await _pumpPage(tester, RecycleBinPage(repository: forum.repository()));
      await tester.tap(find.byKey(const ValueKey('modcp-forum-$_fid')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-bin-pick-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('modcp-bin-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-delete-confirm')), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(forum.posts, isEmpty);
      await tester.tap(find.byKey(const ValueKey('modcp-bin-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('modcp-delete-confirm')));
      await tester.pumpAndSettle();
      expect(forum.posts, hasLength(1));
      expect(forum.posts.single.$2, containsPair('op', 'delete'));
      expect(forum.posts.single.$2, containsPair('moderate[0]', '9202823'));
    });

    testWidgets('an empty bin and an empty log are pulled to refresh', (tester) async {
      final forum = _Forum({
        'action=recyclebin': 'recyclebin_forums.html',
        'action=recyclebin&fid=$_fid': 'recyclebin_delete_result_admin.html',
        'action=recyclebinpost&fid=$_fid': 'recyclebin_delete_result_admin.html',
        'action=log': 'log_empty.html',
      });
      await _pumpPage(tester, RecycleBinPage(repository: forum.repository()));
      await tester.tap(find.byKey(const ValueKey('modcp-forum-$_fid')));
      await tester.pumpAndSettle();
      expect(find.text(t.modcp.binEmpty), findsOneWidget);
      await tester.fling(find.text(t.modcp.binEmpty), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(forum.gets.where((e) => e.endsWith('action=recyclebin&fid=$_fid')), hasLength(2));

      await _pumpPage(tester, ModeratorLogPage(repository: forum.repository()));
      expect(find.text(t.modcp.logEmpty), findsOneWidget);
      await tester.fling(find.text(t.modcp.logEmpty), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(forum.gets.where((e) => e.endsWith('action=log')), hasLength(2));
    });

    testWidgets('a forum keeping no bin: back to the forums, none chosen without asking', (tester) async {
      final forum = _Forum({
        'action=recyclebin': 'recyclebin_nobin.html',
        'action=recyclebin&fid=2': 'recyclebin_nobin.html',
        'action=recyclebinpost&fid=2': 'recyclebin_nobin.html',
      });
      await _pumpPage(tester, RecycleBinPage(repository: forum.repository()));
      await tester.tap(find.byKey(const ValueKey('modcp-forum-2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('modcp-forum-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('modcp-forum-$_fid')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the panel asks its password: the login, then the page', (tester) async {
      var loggedIn = false;
      final posts = <Map<String, String>>[];
      final repo = ModcpRepository(
        get: (url) async => right(_ok(_text(loggedIn ? 'log_entries.html' : 'moderate/queue_login.html'))),
        post: (url, body) async {
          posts.add(body);
          loggedIn = true;
          return right((statusCode: 302, data: ''));
        },
        currentUid: () => _uid,
      );
      await _pumpPage(tester, ModeratorLogPage(repository: repo));
      expect(find.text(t.moderate.panelLogin), findsOneWidget);
      await tester.enterText(
        find.descendant(of: find.byType(ModeratePanelLoginView), matching: find.byType(TextField)),
        'secret',
      );
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single, containsPair('cppwd', 'secret'));
      expect(find.text('测试版主 · 版主 · 26-11-10 10:38 · 192.0.2.1'), findsOneWidget);
    });

    testWidgets('the log: the lines, a keyword asked of the forum, the next page', (tester) async {
      final forum = _Forum({
        'action=log': 'log_entries.html',
        'action=log&keyword=restore': 'log_entries.html',
        'action=log&keyword=restore&page=2': 'log_empty.html',
      });
      await _pumpPage(tester, ModeratorLogPage(repository: forum.repository()));
      expect(find.text('recyclebin · restore · 测试子版块'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('modcp-log-keyword')), 'restore');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(forum.gets.last, endsWith('action=log&keyword=restore'));
      await tester.tap(find.text(t.moderate.nextPage));
      await tester.pumpAndSettle();
      expect(forum.gets.last, endsWith('action=log&keyword=restore&page=2'));
      expect(tester.takeException(), isNull);
    });
  });

  group('me page', () {
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhCn);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver());
      await settings.init();
    });

    tearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// The "me" page of account [uid], whose profile is [profile].
    Future<GoRouter> pump(WidgetTester tester, String profile, {required int uid}) async {
      Dio dio() => Dio()..httpClientAdapter = _ProfileAdapter(_text('tsdmapp/$profile'));
      getIt
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(
            NetClientProvider.buildNoCookie(
              dio: Dio()..httpClientAdapter = _OfflineAdapter(),
              cookie: CookieProvider.buildEmpty(),
            ),
          ),
        )
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: dio(), cookie: CookieProvider.buildEmpty()),
        );
      tester.view
        ..physicalSize = const Size(411, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: ScreenPaths.me,
        routes: [
          GoRoute(path: ScreenPaths.me, name: ScreenPaths.me, builder: (_, _) => const MePage()),
          GoRoute(
            path: ScreenPaths.moderatorPanel,
            name: ScreenPaths.moderatorPanel,
            builder: (_, _) => const Text('panel'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(
                value: _Auth(UserLoginInfo(username: 'member', uid: uid)),
              ),
              RepositoryProvider<ProfileRepository>.value(value: ProfileRepository(currentUid: () => uid)),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 60));
      }
      return router;
    }

    testWidgets('an account of a management group: the panel among the services, opening it', (tester) async {
      await pump(tester, 'profile_v4_other_admin.json', uid: 32);
      final entry = find.descendant(
        of: find.byKey(const ValueKey('me-group-services')),
        matching: find.byKey(const ValueKey('me-moderator-panel')),
      );
      await tester.scrollUntilVisible(entry, 200, scrollable: find.byType(Scrollable).first);
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('panel'), findsOneWidget);
    });

    testWidgets('any other account: no panel', (tester) async {
      await pump(tester, 'profile_v4_other_low.json', uid: 31);
      // The profile was read: the account card shows its group.
      expect(find.textContaining('AG低權組'), findsWidgets);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('me-group-services')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const ValueKey('me-moderator-panel')), findsNothing);
    });
  });
}
