/// The pages added in 1.54.0 and after, laid out on a tablet and a desktop window (1280×800, 2560×1600) and a narrow
/// tablet held upright (600×960): nothing overflows, and the forms, lists, dialogs and sheets keep a readable width
/// instead of the whole window.
///
/// Each page is the real one, fed the answers its own test reads (the test forum's, scrubbed).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:smooth_sheets/smooth_sheets.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/account_security/repository/account_security_repository.dart';
import 'package:tsdm_client/features/account_security/view/account_security_page.dart';
import 'package:tsdm_client/features/account_security/view/privacy_settings_page.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_ban_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_credit_page.dart';
import 'package:tsdm_client/features/admin_tools/view/admin_group_page.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_store.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_fetcher.dart';
import 'package:tsdm_client/features/attachment_download/view/attachment_downloads_page.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/background_grant/repository/background_grant_repository.dart';
import 'package:tsdm_client/features/background_grant/view/background_grant_page.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_batch_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_confirm_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_list_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_run_page.dart';
import 'package:tsdm_client/features/collection/repository/collection_repository.dart';
import 'package:tsdm_client/features/collection/view/collection_detail_page.dart';
import 'package:tsdm_client/features/collection/view/collection_list_page.dart';
import 'package:tsdm_client/features/collection/widgets/collect_thread_sheet.dart';
import 'package:tsdm_client/features/doing/view/doing_page.dart';
import 'package:tsdm_client/features/follow/view/follow_feed_page.dart';
import 'package:tsdm_client/features/follow/view/follow_members_page.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/widgets/thread_filter_chip.dart';
import 'package:tsdm_client/features/friend/view/friend_page.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/widgets/widgets.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/view/modcp_forum_access_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_notes_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_posts_page.dart';
import 'package:tsdm_client/features/moderate/view/modcp_threads_page.dart';
import 'package:tsdm_client/features/moderate/view/moderate_queue_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_log_page.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/moderate/view/recycle_bin_page.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/features/report_handling/view/report_handling_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/share_qr/share_qr_dialog.dart';
import 'package:tsdm_client/features/site_stats/repository/site_stats_repository.dart';
import 'package:tsdm_client/features/site_stats/view/site_stats_page.dart';
import 'package:tsdm_client/features/space/view/space_page.dart';
import 'package:tsdm_client/features/space/view/space_poke_page.dart';
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
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

import 'admin_tools_fakes.dart';

typedef _Answer = Either<AppException, ({int statusCode, Object? data})>;

/// The window sizes: a desktop window, a large desktop, a narrow tablet upright.
const _sizes = <Size>[Size(1280, 800), Size(2560, 1600), Size(600, 960)];

String _name(Size size) => '${size.width.toInt()}x${size.height.toInt()}';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _api(String name, {int uid = 33}) => {..._json('tsdmapp_390/$name.json'), 'uid': uid};

String _text(String path) => File('test/data/$path').readAsStringSync();

/// The forum the app's client asks: each url answered by the first route it contains, pictures never.
final class _Forum implements HttpClientAdapter {
  _Forum(this.routes);

  /// A part of the url and the sample answering it (under `test/data/`).
  final Map<String, String> routes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    for (final MapEntry(:key, :value) in routes.entries) {
      if (url.contains(key)) {
        final body = _text(value);
        return ResponseBody.fromString(
          body,
          200,
          headers: {
            Headers.contentTypeHeader: [
              if (value.endsWith('.json')) 'application/json; charset=utf-8' else 'text/html; charset=utf-8',
            ],
          },
        );
      }
    }
    throw DioException.connectionError(requestOptions: options, reason: 'offline');
  }

  @override
  void close({bool force = false}) {}
}

/// A forum page loaded: its filter chips can be pressed.
final class _ReadyForumBloc extends ForumBloc {
  _ReadyForumBloc() : super(fid: '2', forumRepository: ForumRepository()) {
    emit(state.copyWith(status: ForumStatus.success));
  }
}

/// No attachment is downloaded here.
final class _NoFetcher implements AttachmentFetcher {
  const _NoFetcher();

  @override
  Future<AttachmentFetchAnswer> fetch(
    String url,
    String savePath, {
    required int uid,
    required CancelToken cancelToken,
    void Function(int received, int? total)? onProgress,
  }) => throw const AttachmentFetchException('offline');

  @override
  Future<String> fetchPage(String url, {required int uid}) => throw const AttachmentFetchException('offline');
}

/// The panel's pages answering [answer] for every url.
ModcpPagesRepository _pages(Object? Function(String url) answer) {
  Future<_Answer> get(String url) async => right((statusCode: 200, data: answer(url)));
  Future<_Answer> post(String url, Map<String, String> body) async => right((statusCode: 302, data: null));
  return ModcpPagesRepository(
    panel: ModcpRepository(get: get, post: post, currentUid: () => 33),
    get: get,
    post: post,
    currentUid: () => 33,
  );
}

/// The panel's web pages, by the end of their url.
ModcpRepository _panel(Map<String, String> pages) => ModcpRepository(
  get: (url) async {
    final asked = url.replaceFirst('&tsdmapp=json&nodoc=1', '');
    for (final MapEntry(:key, :value) in pages.entries) {
      if (asked.endsWith(key)) {
        return right((statusCode: 200, data: _text(value)));
      }
    }
    return left(HttpRequestFailedException(404));
  },
  post: (url, body) async => left(HttpRequestFailedException(404)),
  currentUid: () => 31,
);

BatchRateRepository _batchRate({Object? Function(String url)? get, Future<Object?> Function()? post}) =>
    BatchRateRepository(
      ask: (_) async => null,
      get: (url) async => get?.call(url) ?? _api('batchrate_detail', uid: 31),
      post: (url, data) async => post == null ? _api('batchrate_confirm_range', uid: 31) : post(),
      currentUid: () => 31,
    );

/// One page of the audit: what it is called, how it is built, what to do once it is shown.
typedef _Page = ({
  String name,
  Widget Function() build,
  Future<void> Function(WidgetTester tester)? open,
  double maxWidth,
});

_Page _page(
  String name,
  Widget Function() build, {
  Future<void> Function(WidgetTester tester)? open,
  double maxWidth = appListMaxWidth,
}) => (name: name, build: build, open: open, maxWidth: maxWidth);

/// Lets the page load and its animations end, a bounded number of frames (a progress indicator never settles).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

final _auth = AuthenticationRepository(user: const UserLoginInfo(username: 'alice', uid: 31));

/// [child] as a page of the app, its theme included, in a window of [size].
Future<void> _pump(WidgetTester tester, Size size, Widget child) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  await tester.pumpWidget(
    TranslationProvider(
      child: Builder(
        builder: (context) => MaterialApp(
          scaffoldMessengerKey: snackbarKey,
          theme: AppTheme.makeLight(context, seedColor: null, fontFamily: ''),
          home: RepositoryProvider<AuthenticationRepository>.value(value: _auth, child: child),
        ),
      ),
    ),
  );
  await _settle(tester);
}

/// The dialog or the sheet shown over the page.
List<Finder> _overlay() => [
  find.descendant(of: find.byType(Dialog), matching: find.byType(Material)),
  find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)),
  find.byType(Sheet),
];

/// The content of the page: its surfaces, fields, list tiles and buttons.
List<Finder> _content() => [
  find.byType(Card),
  find.byType(InputDecorator),
  find.byType(ListTile),
  find.byType(FilledButton),
];

/// The widest of the boxes [finders] find.
double _widest(List<Finder> finders) {
  var widest = 0.0;
  for (final finder in finders) {
    for (final element in finder.evaluate()) {
      final box = element.renderObject;
      if (box is RenderBox && box.hasSize && box.attached) {
        widest = widest < box.size.width ? box.size.width : widest;
      }
    }
  }
  return widest;
}

/// What the app's client is answered, by a part of the url.
const _routes = <String, String>{
  'do=wall': 'space_social/wall_own.html',
  'ac=poke': 'space_social/poke_list.html',
  'do=follower': 'space_social/follow_follower.html',
  'do=following': 'space_social/follow_following.html',
  'mod=follow': 'space_social/feed_follow.html',
  'do=doing': 'space_social/doing_all.html',
  'view=online': 'site_stats/online_v10.json',
  'ac=privacy': 'account/privacy_base_x5.html',
  'ac=account': 'account/account_center_x5.html',
};

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late AppDatabase db;
  late SettingsRepository settings;

  late Directory downloads;

  setUp(() async {
    AdminAccessCache.reset();
    downloads = Directory.systemTemp.createTempSync('tsdm_945_');
    final done = File('${downloads.path}/done.zip')..writeAsStringSync('done');
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    final forum = _Forum(_routes);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<NetClientProvider>(() => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = forum))
      ..registerSingleton<AttachmentDownloadManager>(
        AttachmentDownloadManager(
          fetcher: const _NoFetcher(),
          store: AttachmentDownloadStore.memory({
            AttachmentDownloadStore.rowKeyOf(31): jsonEncode([
              AttachmentDownload(
                id: 'failed',
                uid: 31,
                url: '$baseUrl/forum.php?mod=attachment&aid=1',
                filename: '很长很长很长很长很长很长很长很长很长很长很长很长很长很长很长的附件名称.zip',
                createdAt: DateTime(2026, 11, 10, 9),
                status: AttachmentDownloadStatus.failed,
                message: '抱歉，只有特定用户可以下载本站附件',
                tid: '1000',
                threadTitle: '附件帖',
              ).toJson(),
              AttachmentDownload(
                id: 'done',
                uid: 31,
                url: '$baseUrl/forum.php?mod=attachment&aid=2',
                filename: 'done.zip',
                createdAt: DateTime(2026, 11, 10, 8),
                status: AttachmentDownloadStatus.completed,
                path: done.path,
                total: 4,
                received: 4,
                tid: '1000',
              ).toJson(),
            ]),
          }),
          directory: () async => downloads,
          partDirectory: () async => Directory('${downloads.path}/parts'),
        ),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum(const {}))),
      );
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    downloads.deleteSync(recursive: true);
    await settings.dispose();
    await db.close();
  });

  final pages = <_Page>[
    _page(
      'moderator panel',
      () {
        Future<_Answer> get(String url) async => right((
          statusCode: 200,
          data: url.contains('tsdmapp=json')
              ? {
                  ..._api('modcp_home'),
                  'counts': {'moderate': 4, 'notes': 2, 'forums': 20},
                }
              : '<script>var discuz_uid = \'33\';</script><div class="appl"><ul>\n'
                    '<li><a href="forum.php?mod=modcp&action=home">x</a></li>\n'
                    '<li><a href="forum.php?mod=modcp&action=forumaccess">x</a></li></ul></div>',
        ));
        Future<_Answer> post(String url, Map<String, String> body) async => right((statusCode: 200, data: null));
        final panel = ModcpRepository(get: get, post: post, currentUid: () => 33);
        return ModeratorPanelPage(
          repository: panel,
          staffTools: () async => (grant: true, issue: true),
          panelTools: () async => (background: true, modcpReport: true),
          adminAccess: () async => AdminAccess.fromJson(adminFixture('admin_founder')),
          batchRate: () async => BatchRateInfo.fromJson(_api('batchrate_info_can', uid: 31)),
          modcpPages: () async => {'home', 'thread', 'forumaccess'},
          pagesRepository: ModcpPagesRepository(panel: panel, get: get, post: post, currentUid: () => 33),
        );
      },
    ),
    _page(
      'moderation queue',
      () => ModerateQueuePage(
        fid: 10,
        title: '测试子版块',
        repository: ModerateRepository(
          get: (url) async => right((
            statusCode: 200,
            data: _text(url.contains('op=replies') ? 'moderate/queue_replies.html' : 'moderate/queue_threads.html'),
          )),
          post: (_, _) async => left(HttpRequestFailedException(404)),
          currentUid: () => 31,
        ),
      ),
    ),
    _page(
      'recycle bin',
      () => RecycleBinPage(
        repository: _panel({
          'action=recyclebin': 'modcp/recyclebin_forums.html',
          'action=recyclebin&fid=15': 'modcp/recyclebin_threads.html',
        }),
      ),
      open: (tester) async {
        await tester.tap(find.byKey(const ValueKey('modcp-forum-15')));
        await _settle(tester);
      },
    ),
    _page('moderator log', () => ModeratorLogPage(repository: _panel({'action=log': 'modcp/log_entries.html'}))),
    _page(
      'moderator notes',
      () => ModcpNotesPage(
        repository: _pages(
          (_) => {
            ..._api('modcp_home'),
            'counts': {'moderate': null, 'notes': 2, 'forums': 20},
            'notes': [
              for (final id in [1, 2])
                {
                  'id': id,
                  'admin': 'ag_mid',
                  'adminid': 2,
                  'dateline': 1700000000,
                  'expiration': 1702592000,
                  'days': 30,
                  'message': '第 $id 则\n第二行',
                  'message_html': '第 $id 则<br />第二行',
                  'to_supermod': 1,
                  'to_moderator': 1,
                  'can_delete': 1,
                },
            ],
          },
        ),
      ),
    ),
    _page('thread management', () => ModcpThreadsPage(repository: _pages((_) => _api('modcp_thread_fid2')))),
    _page(
      'thread management lookup',
      () => ModcpThreadsPage(repository: _pages((_) => _api('modcp_thread_fid2'))),
      open: (tester) async {
        await tester.tap(find.byIcon(Icons.search).first);
        await _settle(tester);
      },
      maxWidth: appSheetMaxWidth,
    ),
    _page('post management', () => ModcpPostsPage(repository: _pages((_) => _api('modcp_post_search')))),
    _page(
      'forum access',
      () => ModcpForumAccessPage(
        repository: _pages(
          (_) => {
            ..._api('modcp_access_fid2'),
            'list': [
              for (final (uid, name) in [(35, 'ag_low2'), (36, '很长很长很长很长很长很长的用户名')])
                {
                  'uid': uid,
                  'username': name,
                  'fid': 2,
                  'forum': '公告与新手报到',
                  'view': 0,
                  'post': -1,
                  'reply': -1,
                  'getattach': 1,
                  'getimage': 0,
                  'postattach': 0,
                  'postimage': 0,
                  'adminuid': 33,
                  'admin': 'ag_mid',
                  'dateline': 1700000000,
                },
            ],
            'count': 2,
          },
        ),
      ),
    ),
    _page(
      'reports',
      () {
        Future<_Answer> get(String url) async => right((statusCode: 200, data: _api('modcp_report_fid25')));
        Future<_Answer> post(String url, Map<String, String> body) async =>
            right((statusCode: 200, data: _api('modcp_report_result_success')));
        return ReportHandlingPage(
          source: ModcpReportSource(
            panel: ModcpRepository(get: get, post: post, currentUid: () => 33),
            get: get,
            post: post,
            currentUid: () => 33,
          ),
        );
      },
    ),
    _page(
      'admin credits',
      () => AdminCreditPage(
        repository: FakeAdminForum({
          'GET:admin': [adminFixture('admin_member_manager')],
          'GET:admincredit': [adminFixture('credit_members')],
        }).repository(),
        initialMembers: '101\n103\nnobody_x',
        writable: true,
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'admin user group',
      () => AdminGroupPage(
        repository: FakeAdminForum({
          'GET:admin': [adminFixture('admin_member_manager')],
          'GET:admingroup': [adminFixture('group_member')],
        }).repository(),
        initialMember: '101',
        writable: true,
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'admin spammer',
      () => AdminBanPage(
        repository: FakeAdminForum({
          'GET:admin': [adminFixture('admin_member_manager')],
          'GET:adminban': [adminFixture('ban_member')],
        }).repository(),
        initialMember: '99',
        writable: true,
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'admin login dialog',
      () => Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => unawaited(
                showAdminLoginDialog(
                  context,
                  FakeAdminForum().repository(),
                  const AdminLoginInfo(secques: true),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      open: (tester) async {
        await tester.tap(find.text('open'));
        await _settle(tester);
      },
      maxWidth: appSheetMaxWidth,
    ),
    _page(
      'background grant',
      () => BackgroundGrantPage(
        repository: BackgroundGrantRepository(
          ask: (_) async => _api('bggrant_can', uid: 31),
          post: (_, _) async => _api('bggrant_result_success', uid: 31),
          currentUid: () => 31,
        ),
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'batch rate confirm',
      () => BatchRateConfirmPage(
        info: BatchRateInfo.fromJson(_api('batchrate_info_can', uid: 31))!,
        selection: const BatchRateSelection.floors(fid: 2, tid: 1019, floors: '2~4 7 9~'),
        repository: _batchRate(),
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'batch rate run',
      () => BatchRateRunPage(
        start: BatchRateBatchPage.fromJson(_api('batchrate_batch_made', uid: 31))!,
        repository: _batchRate(post: () => Completer<Object?>().future),
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'batch rate result',
      () => BatchRateBatchView(
        url: '$baseUrl/plugin.php?id=batchrate:list&bract=detail&batchid=10',
        repository: _batchRate(),
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'batch rate records',
      () => BatchRateListPage(
        listUrl: '$baseUrl/plugin.php?id=batchrate:list',
        repository: _batchRate(get: (_) => _api('batchrate_list', uid: 31)),
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'site stats',
      () => SiteStatsPage(
        repository: SiteStatsRepository(
          fetchText: (url) => TaskEither.right(_text('site_stats/${url.contains('op=') ? 'forumstat' : 'basic'}.html')),
        ),
      ),
    ),
    _page(
      'share qr',
      () => Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => showShareQrDialog(context, url: 'https://forum.test/x', title: '测试标题'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      open: (tester) async {
        await tester.tap(find.text('open'));
        await _settle(tester);
      },
      maxWidth: appSheetMaxWidth,
    ),
    _page(
      'collect to a collection',
      () => Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => showCollectThreadSheet(
                context,
                tid: 9199035,
                repository: CollectionRepository(
                  get: (url, {write = false}) async => right(
                    url.contains('op=addthread')
                        ? jsonDecode(_text('collection/dialog.json'))
                        : _text('collection/list_related.html'),
                  ),
                  post: (url, body) async => left(HttpRequestFailedException(404)),
                  currentUid: () => 31,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      open: (tester) async {
        await tester.tap(find.text('open'));
        await _settle(tester);
      },
      maxWidth: appSheetMaxWidth,
    ),
    _page(
      'forum filter',
      () => BlocProvider<ForumBloc>(
        create: (_) => _ReadyForumBloc(),
        child: Scaffold(
          body: Center(
            child: ThreadChip(
              chipLabel: '全部',
              chipSelected: false,
              sheetTitle: '分类',
              sheetItemBuilder: (_, _) => [
                for (final name in ['全部', '公告', '很长很长很长很长很长很长很长很长很长很长很长很长的分类名称']) ListTile(title: Text(name)),
              ],
            ),
          ),
        ),
      ),
      open: (tester) async {
        await tester.tap(find.byType(FilterChip));
        await _settle(tester);
      },
      maxWidth: appSheetMaxWidth,
    ),
    _page('downloads', () => const AttachmentDownloadsPage()),
    _page(
      'collections',
      () => CollectionListPage(
        repository: CollectionRepository(
          get: (url, {write = false}) async => right(_text('collection/list_recommended.html')),
          post: (url, body) async => left(HttpRequestFailedException(404)),
          currentUid: () => 31,
        ),
      ),
    ),
    _page(
      'collection',
      () => CollectionDetailPage(
        ctid: 3,
        repository: CollectionRepository(
          get: (url, {write = false}) async => right(_text('collection/view_other.html')),
          post: (url, body) async => left(HttpRequestFailedException(404)),
          currentUid: () => 31,
        ),
      ),
    ),
    _page('wall', () => const SpacePage(uid: 35, username: 'ag_low2', initialTab: SpaceTab.wall)),
    _page('greetings', () => const SpacePokePage()),
    _page('broadcasts', () => const FollowFeedPage()),
    _page('following', () => const FollowMembersPage()),
    _page('followers', () => const FollowMembersPage(followers: true)),
    _page('records', () => const DoingPage()),
    _page('members online', () => const FriendPage(online: true)),
    _page(
      'account security',
      () => AccountSecurityPage(
        repository: AccountSecurityRepository(
          buildClient: (_) => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum(_routes)),
        ),
      ),
      maxWidth: appFormMaxWidth,
    ),
    _page(
      'privacy',
      () => PrivacySettingsPage(
        repository: AccountSecurityRepository(
          buildClient: (_) => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Forum(_routes)),
        ),
      ),
      maxWidth: appFormMaxWidth,
    ),
  ];

  for (final page in pages) {
    group(page.name, () {
      for (final size in _sizes) {
        testWidgets(_name(size), (tester) async {
          addTearDown(tester.view.reset);
          // Layout errors only: the avatars and pictures fail to load without a network, which is no concern here.
          final errors = <String>[];
          final reported = FlutterError.onError;
          FlutterError.onError = (details) {
            if (details.library != 'image resource service') {
              errors.add(details.exceptionAsString());
            }
          };
          try {
            await _pump(tester, size, page.build());
            await page.open?.call(tester);
          } finally {
            FlutterError.onError = reported;
          }
          expect(errors, isEmpty);
          final overlay = _widest(_overlay());
          final widest = overlay > 0 ? overlay : _widest(_content());
          expect(widest, greaterThan(0), reason: 'the page shows its content');
          expect(widest, lessThanOrEqualTo(page.maxWidth));
          // A sheet's rows fill the sheet, not a sliver of it.
          final sheets = [find.byType(BottomSheet), find.byType(Sheet)];
          final rows = _widest([
            for (final sheet in sheets)
              for (final content in _content()) find.descendant(of: sheet, matching: content),
          ]);
          if (_widest([for (final sheet in sheets) find.descendant(of: sheet, matching: find.byType(Material))]) > 0) {
            expect(rows, greaterThan(widest / 2), reason: 'the rows of the sheet');
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
        });
      }
    });
  }

  testWidgets('a sheet centered on a wide window still closes on a tap beside it', (tester) async {
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      const Size(2560, 1600),
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => showCustomBottomSheet<void>(
                context: context,
                title: '分类',
                childrenBuilder: (_) => [const ListTile(title: Text('公告'))],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    final sheet = tester.getRect(find.byType(Sheet));
    expect(sheet.width, appSheetMaxWidth);
    expect(sheet.center.dx, closeTo(1280, 0.5));
    await tester.tapAt(Offset(sheet.left / 2, sheet.center.dy));
    await _settle(tester);
    expect(find.byType(Sheet), findsNothing);
  });

  testWidgets("the thread management's lookup: a gap between the fields, the numbers in the columns of the dates", (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await _pump(tester, const Size(1280, 800), ModcpThreadsPage(repository: _pages((_) => _api('modcp_thread_fid2'))));
    await tester.tap(find.byIcon(Icons.search).first);
    await _settle(tester);
    Rect field(String key) => tester.getRect(find.byKey(ValueKey('modcp-threads-$key')));
    final users = field('users');
    final keywords = field('keywords');
    expect(keywords.top - users.bottom, greaterThanOrEqualTo(8), reason: 'no field right under another');
    final start = field('starttime');
    final end = field('endtime');
    for (final (left, right) in [('viewsmore', 'viewsless'), ('repliesmore', 'repliesless')]) {
      expect(field(left).left, closeTo(start.left, 0.5), reason: left);
      expect(field(left).width, closeTo(start.width, 0.5), reason: left);
      expect(field(right).left, closeTo(end.left, 0.5), reason: right);
      expect(field(right).width, closeTo(end.width, 0.5), reason: right);
    }
    expect(field('noreplydays').left, closeTo(start.left, 0.5));
    expect(field('noreplydays').width, closeTo(start.width, 0.5));
    expect(field('viewsmore').top - start.bottom, greaterThanOrEqualTo(8));
    expect(field('repliesmore').top - field('viewsmore').bottom, greaterThanOrEqualTo(8));
  });

  testWidgets("the user group's expiry is as tall as the dropdowns around it, set and cleared", (tester) async {
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      const Size(1280, 800),
      AdminGroupPage(
        repository: FakeAdminForum({
          'GET:admin': [adminFixture('admin_member_manager')],
          'GET:admingroup': [adminFixture('group_member')],
        }).repository(),
        initialMember: '101',
        writable: true,
      ),
    );
    double heightOf(Finder child) =>
        tester.getSize(find.ancestor(of: child, matching: find.byType(InputDecorator)).first).height;
    final main = tester.getSize(find.byKey(const ValueKey('admin-group-main'))).height;
    expect(heightOf(find.byKey(const ValueKey('admin-group-expiry'))), closeTo(main, 0.5));
    await tester.tap(find.byKey(const ValueKey('admin-group-expiry-pick')));
    await _settle(tester);
    await tester.tap(find.text(MaterialLocalizations.of(tester.element(find.byType(DatePickerDialog))).okButtonLabel));
    await _settle(tester);
    expect(find.byKey(const ValueKey('admin-group-expiry-clear')), findsOneWidget);
    expect(heightOf(find.byKey(const ValueKey('admin-group-expiry'))), closeTo(main, 0.5));
    await tester.tap(find.byKey(const ValueKey('admin-group-expiry-clear')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('admin-group-expiry-pick')), findsOneWidget);
  });

  group('the navigation rail (GitHub #236)', () {
    Future<void> pumpRail(WidgetTester tester, Size size) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cubit = HomeCubit();
      addTearDown(cubit.close);
      final router = GoRouter(
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
                  pageBuilder: (context, state) => NoTransitionPage(child: Center(child: Text(path))),
                ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
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

    final logo = find.byKey(const ValueKey('home-navigation-rail-logo'));

    /// The rect of the destinations of the rail, the first to the last.
    Rect destinations(WidgetTester tester) {
      final tr = LocaleSettings.instance.currentTranslations.navigation;
      final labels = [
        for (final label in [tr.homepage, tr.topics, tr.notice, tr.me])
          tester.getRect(find.descendant(of: find.byType(NavigationRail), matching: find.text(label))),
      ];
      return labels.reduce((a, b) => a.expandToInclude(b));
    }

    testWidgets('the app icon heads the rail, small', (tester) async {
      await pumpRail(tester, const Size(1024, 768));
      expect(logo, findsOneWidget);
      final rect = tester.getRect(logo);
      expect(rect.width, lessThanOrEqualTo(40));
      expect(rect.top, lessThan(24));
      expect(rect.bottom, lessThan(destinations(tester).top));
      final rail = tester.getRect(find.byType(NavigationRail));
      expect(rect.center.dx, closeTo(rail.center.dx, 1));
    });

    testWidgets('the destinations sit in the middle of the room below the icon, not against the top', (tester) async {
      await pumpRail(tester, const Size(1024, 768));
      final rail = tester.getRect(find.byType(NavigationRail));
      final items = destinations(tester);
      final below = tester.getRect(logo).bottom;
      expect(items.top - below, greaterThan(100), reason: 'room between the icon and the destinations');
      expect(items.center.dy, closeTo((below + rail.bottom) / 2, 48));
    });

    testWidgets('a short window with large text: nothing overflows, the icon stays, the last destination reachable', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpRail(tester, const Size(915, 412));
      expect(tester.takeException(), isNull);
      expect(logo, findsOneWidget);
      final me = find.byIcon(Icons.person_outline);
      await tester.dragUntilVisible(me, find.byType(HomeNavigationRail), const Offset(0, -80));
      await tester.pumpAndSettle();
      await tester.tap(me);
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 3);
      expect(tester.takeException(), isNull);
    });
  });
}
