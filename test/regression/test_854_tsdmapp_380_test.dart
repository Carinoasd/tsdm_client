/// What plugin tsdmapp 3.7.0 and 3.8.0 add to the forum's app API, read where an answer has it, with everything as
/// it was for an answer that has not (the forum runs 3.6.0 until it updates):
///
/// 1. `perms` of the thread page (`schema` 21): the management offered on the thread and on its floors is what the
///    forum says the account may do; without it, what a moderator was offered before. Taking rates back and deleting
///    the attachments of another member's floor have their own flags (`allow_removerate`, `allow_delattach`), where
///    the answer carries them. `perms` of the forum page: the same for several threads picked in its list.
/// 2. `warned` and `can.warn` of a floor.
/// 3. The comments of a floor as fields (`comments`, `comment_more`, `comment_scores`), their pages (`type: comments`,
///    `schema` 22) and the comment window as a small form (`form: comment`).
/// 4. `recommend` of the thread page (`schema` 23): the evaluation of the thread without the page's `document`, the
///    first page asked lean again; the message of a write result with its line breaks.
/// 5. `stick` of a floor: the replies stuck under the first floor, told and no longer guessed from the order.
/// 6. The moderation panel's log as fields (`type: modcp_log`, `schema` 24).
/// 7. `online` and `user.allow_stat` of the homepage.
///
/// The times of a page of comments and of the log are printed with the answer's own `timeoffset` where it names one.
///
/// The fixtures under `test/data/tsdmapp_380` are the test forum's answers (Discuz! X5 with plugin tsdmapp 3.8.0),
/// asked as a guest, members, the thread's author, a moderator of the forum and of another one, a super moderator and
/// an administrator, then scrubbed (host, site name, form hash, clock) and cut: the author column of a floor to the
/// link banning its author, its content without the scripts other plugins print, the panel's pages to their form or
/// message, a forum page to its first threads, a page of comments without its `document`.
///
/// Plugin 3.8.0 was built twice. The fixtures of the first build carry no `timeoffset` in a page of comments and in
/// the log, no `perms` in a forum page, no `allow_removerate` and `allow_delattach`, and its guest's log prompt says
/// `login` 0: they stay as the answers that do not tell. The answers of the final build were asked the same way:
/// `forum_perms_*` (a super moderator, the forum's moderator, a moderator whose group may do none of it, a member, a
/// guest), `thread_stick_*` (asked again: the two flags), `comments_page2_timeoffset` and `modcp_log_timeoffset` (an
/// account whose own time zone is +9), `modcp_log_guest_login`. `comment_form_items` and `thread_comment_scores` are
/// the window and the thread page of a forum set up with two score items for comments, a comment scoring both.
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
import 'package:fpdart/fpdart.dart' show Left, Right, left, right;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/homepage/utils/online_summary.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/models/thread_perms.dart';
import 'package:tsdm_client/features/moderate/repository/floor_ops_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_log_page.dart';
import 'package:tsdm_client/features/moderate/widgets/floor_moderate_dialog.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/features/post/utils/edit_attachments.dart';
import 'package:tsdm_client/features/post/widgets/edit_attachments_button.dart';
import 'package:tsdm_client/features/post_comment/models/post_comment.dart';
import 'package:tsdm_client/features/post_comment/repository/post_comment_repository.dart';
import 'package:tsdm_client/features/post_comment/widgets/post_comment_widgets.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/thread_recommend/repository/thread_recommend_repository.dart';
import 'package:tsdm_client/features/thread_recommend/widgets/thread_recommend_buttons.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';

const _dir = 'test/data/tsdmapp_380';

Translations get t => LocaleSettings.instance.currentTranslations;

/// An answer of plugin 3.8.0 as dio gives it: decoded.
Map<String, dynamic> _json(String name) => jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, dynamic>;

/// An answer of an older plugin, or the forum's own, kept with the tests of the feature it belongs to.
Object? _older(String path) {
  final text = File('test/data/$path').readAsStringSync();
  return path.endsWith('.json') ? jsonDecode(text) : text;
}

ThreadPageInfo _page(String name) => threadPageFromApi(threadApiAnswerOf(_json(name))!, 1);

Map<String, Post> _floors(ThreadPageInfo page) => {for (final p in page.postList) p.postID: p};

/// The thread page of plugin 3.6.0 (`schema` 18) a moderator was served: none of the new fields.
ThreadPageInfo _olderPage() =>
    threadPageFromApi(threadApiAnswerOf(_older('post_comment/thread_api_moderator.json'))!, 1);

/// A forum answering every request with [answer] (JSON), recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final Object answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(answer),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// No network: the card's images do not load.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The forum's page [name] of forum [fid], as the repository builds it from the answer.
ForumPageData _forumPage(String name, String fid, {bool older = false}) => forumPageFromApi(
  forumApiAnswerOf(older ? _older(name) : _json(name))!,
  fid,
);

/// A forum repository answering every page asked with [page].
final class _ForumPages extends ForumRepository {
  _ForumPages(this.page);

  ForumPageData page;

  /// Whether the next request fails.
  bool failing = false;

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) =>
      AsyncEither(() async => failing ? left(HttpRequestFailedException(500)) : right(page));
}

/// The bloc of the thread page a floor is on: the thread, and nothing loading.
final class _ThreadOnScreen extends Fake implements ThreadBloc {
  @override
  ThreadState get state => const ThreadState(tid: '9199345', status: ThreadStatus.success);

  @override
  Stream<ThreadState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.uid);

  int? uid;

  @override
  int? get effectiveCurrentUid => uid;
}

/// The transports of a [PostCommentRepository]: the answers by a part of the url, every request kept.
final class _Comments {
  _Comments({this.reads = const {}, this.answer});

  final Map<String, Object?> reads;
  final Object? answer;
  final readUrls = <String>[];
  final sent = <(String, Map<String, String>)>[];

  PostCommentRepository get repository => PostCommentRepository(
    get: (url) async {
      readUrls.add(url);
      for (final MapEntry(:key, :value) in reads.entries) {
        if (url.contains(key)) {
          return value;
        }
      }
      throw Exception('offline');
    },
    post: (url, fields) async {
      sent.add((url, fields));
      return answer;
    },
  );
}

/// The card shows nothing that needs these.
Post _bare(Post post) => post.copyWith(
  author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
  userBriefProfile: null,
  postMedals: null,
  badge: null,
  secondBadge: null,
  signature: null,
  pokemon: null,
  checkin: null,
);

Future<void> _pumpPage(WidgetTester tester, Widget page) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: page),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('1. what the account may manage', () {
    test('each account as the forum tells it', () {
      final guest = _page('thread_comments_guest.json').perms!;
      expect(guest.isModerator, isFalse);
      expect(guest.threadOperations(moderateOperationsFor(closed: false)), isEmpty);
      expect(guest.floorOperations(), isEmpty);
      expect(guest.allowBanUser, isFalse);

      // The thread's author, a member: nothing but sticking replies of the own thread.
      final author = _page('thread_comments_author.json').perms!;
      expect(author.isModerator, isFalse);
      expect(author.threadOperations(moderateOperationsFor(closed: false)), isEmpty);
      expect(author.floorOperations(), [FloorModerateAction.stick]);

      // A moderator of another forum: no management here, but the group's ban of members.
      final elsewhere = _page('thread_comments_othermod.json').perms!;
      expect(elsewhere.isModerator, isFalse);
      expect(elsewhere.threadOperations(moderateOperationsFor(closed: false)), isEmpty);
      expect(elsewhere.floorOperations(), isEmpty);
      expect(elsewhere.allowBanUser, isTrue);

      // A super moderator in a forum without recommendation, of a group that may not stick replies.
      final superMod = _page('thread_comments_supermod.json').perms!;
      expect(superMod.isModerator, isTrue);
      expect(
        superMod.threadOperations(moderateOperationsFor(closed: false)),
        moderateOperationsFor(closed: false).where((e) => e != ModerateOperation.recommend).toList(),
      );
      expect(superMod.floorOperations(), [
        FloorModerateAction.delete,
        FloorModerateAction.warn,
        FloorModerateAction.ban,
      ]);
      expect((superMod.stickMax, superMod.digestMax), (2, 3));

      // The same account in a forum that recommends threads.
      final recommends = _page('thread_recommend_forum_supermod.json').perms!;
      expect(recommends.allowsThread(ModerateOperation.recommend), isTrue);
      expect(recommends.threadOperations(moderateOperationsFor(closed: false)), moderateOperationsFor(closed: false));

      // The moderator of the forum sticks threads in it only; an administrator everywhere, and sticks replies.
      expect(_page('thread_stick_moderator.json').perms!.maxLevelOf(ModerateOperation.stick), 1);
      final admin = _page('thread_comments_admin.json').perms!;
      expect(admin.maxLevelOf(ModerateOperation.stick), 3);
      expect(admin.maxLevelOf(ModerateOperation.digest), 3);
      expect(admin.maxLevelOf(ModerateOperation.close), isNull);
      expect(admin.floorOperations(), FloorModerateAction.values);
    });

    test('a closed thread: opening it is the same permission', () {
      final perms = _page('thread_warned_supermod.json').perms!;
      final offered = perms.threadOperations(moderateOperationsFor(closed: true));
      expect(offered, contains(ModerateOperation.open));
      expect(offered, isNot(contains(ModerateOperation.close)));
    });

    test("the warning needs the floor's own verdict too", () {
      final page = _page('thread_stick_moderator.json');
      final floors = _floors(page);
      // A member's floor; a super moderator's floor, which a moderator may not warn; the first floor of an admin.
      expect(floors['3940']!.canWarn, isTrue);
      expect(floors['3951']!.canWarn, isFalse);
      expect(floors['3938']!.canWarn, isFalse);
      expect(page.perms!.floorOperations(canWarn: floors['3940']!.canWarn), contains(FloorModerateAction.warn));
      expect(page.perms!.floorOperations(canWarn: floors['3951']!.canWarn), [
        FloorModerateAction.delete,
        FloorModerateAction.ban,
      ]);
    });

    test('an older answer tells nothing: no permissions, as before', () {
      final page = _olderPage();
      expect(page.postList, isNotEmpty);
      expect(page.perms, isNull);
      expect(page.postList.map((p) => p.canWarn).toSet(), {null});
      expect(ThreadPerms.fromApi(null), isNull);
      expect(ThreadPerms.fromApi('1'), isNull);
    });

    test('taking rates back, deleting attachments of other floors: their own flags; the moderators before', () {
      // The forum's moderator, whose group has a rate range; a member.
      final moderator = _page('thread_stick_moderator.json');
      expect(moderator.perms!.allowRemoveRate, isTrue);
      expect(moderator.perms!.allowDeleteAttachments, isTrue);
      final member = _page('thread_stick_member.json');
      expect(member.perms!.allowRemoveRate, isFalse);
      expect(member.perms!.allowDeleteAttachments, isFalse);

      // The first build of plugin 3.8.0 has neither flag: rates are the moderators' as before, attachments not told.
      final before = _page('thread_comments_supermod.json').perms!;
      expect(before.isModerator, isTrue);
      expect(before.allowRemoveRate, isTrue);
      expect(before.allowDeleteAttachments, isNull);
      expect(_page('thread_comments_othermod.json').perms!.allowRemoveRate, isFalse);
      // A moderator whose group has no rate range (no account of the test forum is one): the flag decides.
      final noRange = _json('thread_stick_moderator.json');
      (noRange['perms'] as Map<String, dynamic>)['allow_removerate'] = 0;
      final refused = threadPageFromApi(noRange, 1).perms!;
      expect(refused.isModerator, isTrue);
      expect(refused.allowRemoveRate, isFalse);

      // In the editor: told for the floor of another member only, and only where the page tells.
      final floors = _floors(moderator);
      expect(floors['3940']!.author.uid, '31');
      expect(editedFloorAttachmentDeletion(floors['3940']!, viewerUid: 70, perms: moderator.perms), isTrue);
      expect(editedFloorAttachmentDeletion(floors['3940']!, viewerUid: 35, perms: member.perms), isFalse);
      expect(editedFloorAttachmentDeletion(floors['3940']!, viewerUid: 31, perms: member.perms), isNull, reason: 'own');
      expect(editedFloorAttachmentDeletion(floors['3940']!, viewerUid: 33, perms: before), isNull, reason: 'not told');
      expect(editedFloorAttachmentDeletion(floors['3940']!, viewerUid: 33, perms: null), isNull);
      expect(editedFloorAttachmentDeletion(floors['3940']!, viewerUid: null, perms: member.perms), isNull);
      expect(editAttachmentDeletionOf(const {editAttachmentDeletionQuery: '1'}), isTrue);
      expect(editAttachmentDeletionOf(const {editAttachmentDeletionQuery: '0'}), isFalse);
      expect(editAttachmentDeletionOf(const {'tid': '1'}), isNull);
    });

    test('the forum page tells what may be done with several threads; a guest, an older answer do not', () {
      // A super moderator in a forum that recommends threads: everything, sticking up to the forum's group.
      final superMod = _forumPage('forum_perms_supermod.json', '33');
      expect(superMod.permsUid, 33);
      expect(superMod.perms!.isModerator, isTrue);
      expect(superMod.perms!.threadOperations(moderateBatchOperations), moderateBatchOperations);
      expect(superMod.perms!.allowsThread(ModerateOperation.recommend), isTrue);
      expect((superMod.perms!.stickMax, superMod.perms!.digestMax), (2, 3));

      // The forum's moderator: in the forum only; no recommendation in this forum.
      final moderator = _forumPage('forum_perms_moderator.json', '2');
      expect(moderator.permsUid, 70);
      expect(moderator.perms!.threadOperations(moderateBatchOperations), moderateBatchOperations);
      expect(moderator.perms!.maxLevelOf(ModerateOperation.stick), 1);
      expect(moderator.perms!.allowsThread(ModerateOperation.recommend), isFalse);

      // A moderator of the forum whose group may do none of it; a member.
      final none = _forumPage('forum_perms_moderator_none.json', '25');
      expect(none.perms!.isModerator, isTrue);
      expect(none.perms!.threadOperations(moderateBatchOperations), isEmpty);
      final member = _forumPage('forum_perms_member.json', '33');
      expect(member.permsUid, 35);
      expect(member.perms!.isModerator, isFalse);
      expect(member.perms!.threadOperations(moderateBatchOperations), isEmpty);

      // Nobody to tell: a guest. Nothing told: plugin 3.6.0.
      final guest = _forumPage('forum_perms_guest.json', '33');
      expect((guest.perms, guest.permsUid), (null, null));
      expect(guest.normalThreadList, isNotEmpty);
      final older = _forumPage('tsdmapp/forum_v2_fid2.json', '2', older: true);
      expect((older.perms, older.permsUid), (null, null));
      expect(older.normalThreadList, isNotEmpty);
    });

    test("the forum's page keeps what its latest answer told, for the account it told", () async {
      final repository = _ForumPages(_forumPage('forum_perms_supermod.json', '33'));
      final bloc = ForumBloc(fid: '33', forumRepository: repository)..add(const ForumLoadMoreRequested(1));
      await bloc.stream.firstWhere((e) => e.status == ForumStatus.success);
      expect(bloc.state.permsUid, 33);
      expect(bloc.state.perms!.maxLevelOf(ModerateOperation.stick), 2);

      // Asked again and answered by an older plugin: nothing carried over.
      repository.page = _forumPage('tsdmapp/forum_v2_fid2.json', '2', older: true);
      bloc.add(ForumRefreshRequested());
      await bloc.stream.firstWhere((e) => e.perms == null && !e.refreshing);
      expect((bloc.state.perms, bloc.state.permsUid), (null, null));

      // Told again, then a page that fails to load: nothing left of what the page before told.
      repository.page = _forumPage('forum_perms_supermod.json', '33');
      bloc.add(ForumRefreshRequested());
      await bloc.stream.firstWhere((e) => e.perms != null && !e.refreshing);
      repository.failing = true;
      bloc.add(const ForumJumpPageRequested(2));
      await bloc.stream.firstWhere((e) => e.status == ForumStatus.failure);
      expect((bloc.state.perms, bloc.state.permsUid), (null, null));
      await bloc.close();
    });

    testWidgets('the sheet of a thread lists what the forum allows; every operation without permissions', (
      tester,
    ) async {
      Future<void> open(ThreadPerms? perms) async {
        await _pumpPage(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    showThreadModerateSheet(context, tid: '9202819', fid: 25, closed: false, perms: perms),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      await open(_page('thread_comments_supermod.json').perms);
      expect(find.text(t.moderate.stick), findsOneWidget);
      expect(find.text(t.moderate.recommend), findsNothing, reason: 'the forum does not recommend threads');

      await tester.pumpWidget(const SizedBox());
      await open(null);
      expect(find.text(t.moderate.stick), findsOneWidget);
      expect(find.text(t.moderate.recommend), findsOneWidget);

      // Nothing allowed: said, no sheet at all.
      await tester.pumpWidget(const SizedBox());
      await open(_page('thread_comments_author.json').perms);
      expect(find.text(t.moderate.stick), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text(t.moderate.batch.noOperation), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('several threads: what the forum allows; nothing allowed is said, nothing picked', (tester) async {
      Future<void> open(ThreadPerms? perms) async {
        await _pumpPage(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => showBatchModerateSheet(
                  context,
                  threads: const [('9202819', 'a'), ('9202875', 'b')],
                  fid: 25,
                  perms: perms,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      }

      // What the forum's page told its moderator: every operation on several threads.
      await open(_forumPage('forum_perms_moderator.json', '2').perms);
      for (final operation in [t.moderate.stick, t.moderate.move, t.moderate.delete]) {
        expect(find.text(operation), findsOneWidget, reason: operation);
      }

      // A moderator whose group may only move threads.
      await tester.pumpWidget(const SizedBox());
      await open(ThreadPerms.fromApi(const {'ismoderator': 1, 'allow_move': 1}));
      expect(find.text(t.moderate.move), findsOneWidget);
      expect(find.text(t.moderate.stick), findsNothing);
      expect(find.text(t.moderate.delete), findsNothing);

      // One the forum's page told may do none of the operations on several threads.
      await tester.pumpWidget(const SizedBox());
      await open(_forumPage('forum_perms_moderator_none.json', '25').perms);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text(t.moderate.batch.noOperation), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));

      // No permissions told: every operation, as before.
      await tester.pumpWidget(const SizedBox());
      await open(null);
      for (final operation in [t.moderate.stick, t.moderate.move, t.moderate.delete]) {
        expect(find.text(operation), findsOneWidget, reason: operation);
      }
    });

    testWidgets('a digest no higher than the account may set, the level the thread has kept', (tester) async {
      final window = _older('moderate/window_stick_digest.json');
      ModerateRepository repository() => ModerateRepository(
        get: (_) async => right((statusCode: 200, data: window)),
        post: (_, _) async => right((statusCode: 200, data: '')),
        currentUid: () => 31,
      );
      await _pumpPage(
        tester,
        ModerateDialog(operation: ModerateOperation.digest, tid: '1234567', fid: 10, repository: repository()),
      );
      expect(find.widgetWithText(ChoiceChip, '精华 1'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '精华 3'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _pumpPage(
        tester,
        ModerateDialog(
          operation: ModerateOperation.digest,
          tid: '1234567',
          fid: 10,
          maxLevel: 1,
          repository: repository(),
        ),
      );
      expect(find.widgetWithText(ChoiceChip, '精华 1'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '精华 2'), findsOneWidget, reason: 'the level the thread has now');
      expect(find.widgetWithText(ChoiceChip, '精华 3'), findsNothing);
    });
  });

  group('2. the warning of a floor', () {
    test('told by the answer; not by an older one', () {
      final floors = _floors(_page('thread_warned_supermod.json'));
      expect(floors['3048']!.warned, isTrue);
      expect(floors['3047']!.warned, isFalse);
      expect(floors['3049']!.warned, isFalse);
      expect(_olderPage().postList.where((p) => p.warned), isEmpty);
    });
  });

  group('3. the comments of a floor', () {
    test('as fields: every comment with its id, the time as the page prints it, the forum saying there are more', () {
      final floors = _floors(_page('thread_comments_author.json'));
      final floor = floors['11263']!;
      expect(floor.comments.map((c) => c.id), [22, 21, 20, 16, 15], reason: "a member's comments have ids too");
      expect(floor.moreComments, isTrue);
      final first = floor.comments.first;
      expect(first.authorName, 'ag_t08');
      expect(first.authorUid, 44);
      expect(first.avatarUrl, 'https://forum.test/data/avatar/noavatar.svg');
      expect(first.time, '2026-11-10 10:49');
      expect(first.content, 'CM測試 ag_t08 第一行\n第二行');
      expect(first.canDelete, isFalse);
      expect(floor.comments[3].content, 'CM測試 ag_t04 點評 & <tag> "q"');
      // Not shown twice: the block the page prints is still cut out of the content.
      expect(floor.data, isNot(contains('id="comment_11263"')));
      expect(floor.data, contains('postmessage_11263'));
      expect(floor.timeOffset, 8);
      expect(floor.commentScores, isEmpty);

      expect(floors['11264']!.comments.map((c) => c.id), [27, 19]);
      expect(floors['11264']!.moreComments, isFalse);
      expect(floors['11262']!.comments, isEmpty);
    });

    test("deleting is the forum's verdict of each comment; commenting the floor's own", () {
      final member = _floors(_page('thread_comments_author.json'));
      final superMod = _floors(_page('thread_comments_supermod.json'));
      final guest = _floors(_page('thread_comments_guest.json'));
      expect(member['11263']!.comments.where((c) => c.canDelete), isEmpty);
      expect(superMod['11263']!.comments.every((c) => c.canDelete), isTrue);
      expect(guest['11263']!.comments.where((c) => c.canDelete), isEmpty);

      const window = '$baseUrl/forum.php?mod=misc&action=comment&tid=9202819&pid=11263&extra=&page=1';
      expect(member['11263']!.commentAction, window);
      expect(member['11262']!.commentAction, isNull, reason: 'the first floor, the own floor');
      expect(superMod['11262']!.commentAction, isNull);
      expect(guest.values.map((p) => p.commentAction).toSet(), {null});
      // An administrator's group comments on first floors too: the forum's verdict, not the app's guess.
      expect(_floors(_page('thread_comments_admin.json'))['11262']!.commentAction, isNotNull);
    });

    test('an older answer: read from the block of the content, as before', () {
      final floor = _floors(_olderPage())['11263']!;
      expect(floor.comments, hasLength(5));
      expect(floor.comments.every((c) => c.id != null && c.canDelete), isTrue, reason: 'a moderator sees the ids');
      expect(floor.moreComments, isTrue);
      expect(floor.commentScores, isEmpty);
      expect(floor.data, isNot(contains('id="comment_11263"')));
      final member = threadPageFromApi(threadApiAnswerOf(_older('post_comment/thread_api_member.json'))!, 1);
      expect(_floors(member)['11263']!.comments.map((c) => c.id).toSet(), {null}, reason: 'no id on the page');
    });

    test('the averages of the score items, of a forum whose comments score two', () {
      final floors = _floors(_page('thread_comment_scores.json'));
      final floor = floors['3031']!;
      expect(floor.commentScores, const [
        PostCommentScore(name: '画质', score: 4),
        PostCommentScore(name: '剧情', score: 5),
      ]);
      // As the page prints them above the comments ("4.0", "5.0").
      expect(floor.commentScores.map((e) => e.text), ['4.0', '5.0']);
      // The comment that scored: its scores are the first line of its text, as the forum keeps them.
      expect(floor.comments.first.content, '画质: 4 剧情: 5\n評分項樣本 tsdmapp380-1794294770');
      expect(floor.moreComments, isTrue);
      expect(floor.data, isNot(contains('id="comment_3031"')));
      expect(floor.data, isNot(contains('cmstarv')), reason: 'the averages are not printed twice');
      // A floor commented without scores, a floor without comments: none.
      expect(floors['3025']!.comments, hasLength(2));
      expect(floors['3025']!.commentScores, isEmpty);
      expect(floors['3024']!.commentScores, isEmpty);

      // An item without a name or without a number is left out.
      expect(
        postCommentScoresFromApi(const [
          {'name': '', 'score': 3},
          {'name': '画质'},
          {'name': '剧情', 'score': 4.5},
        ]),
        const [PostCommentScore(name: '剧情', score: 4.5)],
      );
      expect(const PostCommentScore(name: '剧情', score: 4.5).text, '4.5');
    });

    test('a page of comments as fields, asked as a small form; the end told by its pages', () async {
      final forum = _Comments(
        reads: {
          'page=2': _json('comments_page2_member.json'),
          'page=3': _json('comments_page3_past.json'),
          'page=4': _json('comments_closed.json'),
        },
      );
      final page = await forum.repository.fetchMore(tid: '9202819', pid: '11263', page: 2, timeOffset: 8);
      final query = Uri.parse(forum.readUrls.single).queryParameters;
      expect(query, containsPair('action', 'commentmore'));
      expect(query, containsPair('inajax', '1'));
      expect(query, containsPair('tsdmapp', 'json'));
      expect(query, containsPair('tsdmform', '1'));
      expect(page!.comments.map((c) => c.id), [14, 13, 12]);
      expect(page.comments.last.time, '2026-11-10 10:33');
      expect(page.comments.last.avatarUrl, 'https://img.ts-dm.net/images/2024/11/22/2.gif');
      expect(page.hasMore, isFalse, reason: 'page 2 of 2');
      // The floor's page printed its times an hour ahead: so are these.
      final ahead = await forum.repository.fetchMore(tid: '9202819', pid: '11263', page: 2, timeOffset: 9);
      expect(ahead!.comments.last.time, '2026-11-10 11:33');

      final past = await forum.repository.fetchMore(tid: '9202819', pid: '11263', page: 3);
      expect(past!.comments, isEmpty);
      expect(past.hasMore, isFalse);
      // The forum's message instead of a page: not read.
      expect(await forum.repository.fetchMore(tid: '9202819', pid: '11263', page: 4), isNull);

      final moderator = postCommentPageFromApi(_json('comments_page2_moderator.json'));
      expect(moderator!.comments.every((c) => c.canDelete), isTrue);
      final middle = _json('comments_page2_member.json')..['pages'] = 3;
      expect(postCommentPageFromApi(middle)!.hasMore, isTrue);
    });

    test("a page of comments is printed with its own time offset; with the floor's where it names none", () async {
      // Asked by an account whose time zone is +9 (the forum's is +8).
      final own = _json('comments_page2_timeoffset.json');
      expect(own['timeoffset'], 9);
      final forum = _Comments(reads: {'page=2': own});
      final page = await forum.repository.fetchMore(tid: '9202819', pid: '11263', page: 2, timeOffset: 8);
      expect(page!.comments.map((c) => c.time), ['2026-11-10 11:34', '2026-11-10 11:34', '2026-11-10 11:33']);
      expect(postCommentPageFromApi(own)!.comments.last.time, '2026-11-10 11:33');

      // The first build of plugin 3.8.0 names none: the offset of the floor's page, the forum's without one.
      final before = _json('comments_page2_member.json');
      expect(before.containsKey('timeoffset'), isFalse);
      expect(postCommentPageFromApi(before, timeOffset: 9)!.comments.last.time, '2026-11-10 11:33');
      expect(postCommentPageFromApi(before)!.comments.last.time, '2026-11-10 10:33');
    });

    test('a page of comments of an older plugin, of a forum without one: the same request, parsed as before', () async {
      for (final answer in ['post_comment/more_api.json', 'post_comment/more_moderator.xml']) {
        final forum = _Comments(reads: {'action=commentmore': _older(answer)});
        final page = await forum.repository.fetchMore(tid: '1234567', pid: '11263', page: 2);
        expect(forum.readUrls, hasLength(1), reason: answer);
        expect(page!.comments, isNotEmpty, reason: answer);
        expect(postCommentPageFromApi(_older(answer)), isNull, reason: answer);
      }
    });

    test('the window as a small form: where it posts, its fields, the limit; one request', () async {
      const window = '$baseUrl/forum.php?mod=misc&action=comment&tid=9202819&pid=11263&extra=&page=1';
      final forum = _Comments(
        reads: {'action=comment': _json('comment_form.json')},
        answer: _older('post_comment/comment_ok_api.json'),
      );
      final opened = await forum.repository.openComment(window);
      final query = Uri.parse(forum.readUrls.single).queryParameters;
      expect(query, containsPair('infloat', 'yes'));
      expect(query, containsPair('handlekey', 'comment'));
      expect(query, containsPair('inajax', '1'));
      expect(query, containsPair('tsdmapp', 'json'));
      expect(query, containsPair('tsdmform', '1'));
      final form = (opened as PostCommentWindowForm).form;
      expect(
        form.action,
        '$baseUrl/forum.php?mod=post&action=reply&comment=yes&tid=9202819&pid=11263&extra=&page=1'
        '&commentsubmit=yes&infloat=yes&inajax=1',
      );
      expect(form.fields, {'formhash': 'f1f2f3f4', 'handlekey': 'comment', 'commentsubmit': 'true'});
      expect(form.uid, 31);
      expect(form.maxLength, 200);

      expect(await forum.repository.sendComment(form, '好帖'), isA<PostCommentDone>());
      expect(forum.sent.single.$1, form.action);
      expect(forum.sent.single.$2, {...form.fields, 'message': '好帖'});
    });

    test(
      "the window refused in the forum's words; a form of another floor, or one the app cannot send, not taken",
      () async {
        const window = '$baseUrl/forum.php?mod=misc&action=comment&tid=9202819&pid=11263&extra=&page=1';
        final refused = await _Comments(
          reads: {'action=comment': _json('comment_form_refused.json')},
        ).repository.openComment(window);
        expect((refused as PostCommentWindowRefused).message, '抱歉，您不能点评此帖或帖子尚未找到');

        // Served for another floor than the one asked: asked again as before, where nothing answers.
        final other = _Comments(reads: {'tsdmform=1': _json('comment_form.json')});
        expect(
          await other.repository.openComment(window.replaceFirst('pid=11263', 'pid=11264')),
          isA<PostCommentWindowFailed>(),
        );
        expect(other.readUrls, hasLength(2));
        expect(Uri.parse(other.readUrls.last).queryParameters, isNot(contains('tsdmform')));

        // A captcha (`unsupported`): the window of before plugin 3.7.0 is asked and read instead.
        final captcha = _json('comment_form.json')
          ..['seccheck'] = {'seccode': 1, 'secqaa': 0}
          ..['unsupported'] = ['seccheck'];
        final asBefore = _Comments(
          reads: {'tsdmform=1': captcha, 'action=comment': _older('post_comment/window_api.json')},
        );
        expect(await asBefore.repository.openComment(window), isA<PostCommentWindowForm>());
        expect(asBefore.readUrls, hasLength(2));
      },
    );

    test('score items of the window go as served, empty: the comment gives no score', () async {
      const window = '$baseUrl/forum.php?mod=misc&action=comment&tid=9199043&pid=3031&extra=&page=1';
      final answer = _json('comment_form_items.json');
      // Each item with its choices (0 to 5) and the window's "give no score", which is the empty value served.
      final items = (answer['items'] as List).cast<Map<String, dynamic>>();
      expect(items.map((e) => e['label']), ['画质', '剧情']);
      expect(items.map((e) => (e['choices'] as List).length).toSet(), {6});
      expect(items.map((e) => e['value']).toSet(), {''});
      final opened = await _Comments(reads: {'action=comment': answer}).repository.openComment(window);
      final form = (opened as PostCommentWindowForm).form;
      expect(form.fields, {
        'commentitem[画质]': '',
        'commentitem[剧情]': '',
        'formhash': 'f1f2f3f4',
        'handlekey': 'comment',
        'commentsubmit': 'true',
      });
      expect(form.uid, 56);
      expect(
        form.action,
        '$baseUrl/forum.php?mod=post&action=reply&comment=yes&tid=9199043&pid=3031&extra=&page=1'
        '&commentsubmit=yes&infloat=yes&inajax=1',
      );
    });

    test('the window of an older plugin, of a forum without one: the same request, parsed as before', () async {
      const window = '$baseUrl/forum.php?mod=misc&action=comment&tid=1234567&pid=11263&extra=&page=1';
      for (final answer in ['post_comment/window_api.json', 'post_comment/window.xml']) {
        final forum = _Comments(reads: {'action=comment': _older(answer)});
        final opened = await forum.repository.openComment(window);
        expect(opened, isA<PostCommentWindowForm>(), reason: answer);
        expect(forum.readUrls, hasLength(1), reason: answer);
        expect((opened as PostCommentWindowForm).form.fields, containsPair('commentsubmit', 'true'), reason: answer);
      }
      final refused = await _Comments(
        reads: {'action=comment': _older('post_comment/window_refused_api.json')},
      ).repository.openComment(window);
      expect(refused, isA<PostCommentWindowRefused>());
    });
  });

  group('4. the evaluation of the thread', () {
    test('from the answer: the buttons, the counts, the hash of its own links', () {
      final page = _page('thread_recommend_member.json');
      final recommend = page.postList.single.recommend!;
      expect(recommend.tid, 9202875);
      expect(recommend.viewerUid, 35);
      expect(recommend.guest, isFalse);
      expect(recommend.canEvaluate, isTrue);
      expect(recommend.add, const ThreadRecommendButton(label: '支持', count: 1));
      expect(recommend.subtract, const ThreadRecommendButton(label: '踩踩', count: 2));
      expect(
        recommend.url(ThreadRecommendSide.subtract),
        '$baseUrl/forum.php?mod=misc&action=recommend&do=subtract&tid=9202875&hash=f1f2f3f4&inajax=1',
      );
      // On the first floor only, as the page prints it.
      final stuck = _page('thread_stick_member.json');
      expect(stuck.postList.where((p) => p.recommend != null).map((p) => p.postFloor), [1]);
    });

    test("a guest's open the login; the thread's author gets the counts and nothing to send", () {
      final guest = _page('thread_comments_guest.json').postList.first.recommend!;
      expect(guest.guest, isTrue);
      expect(guest.viewerUid, isNull);
      expect(guest.canEvaluate, isTrue);
      final author = _page('thread_comments_author.json').postList.first.recommend!;
      expect(author.guest, isFalse);
      expect(author.canEvaluate, isFalse, reason: 'why: self');
      expect(author.pressed(ThreadRecommendSide.add).canEvaluate, isFalse);
    });

    test('none where the page prints none; a button left without a text', () {
      Map<String, dynamic> answer(void Function(Map<String, dynamic> recommend) change) {
        final json = _json('thread_recommend_member.json');
        change(json['recommend'] as Map<String, dynamic>);
        return json;
      }

      ThreadRecommend? of(Map<String, dynamic> json) => threadPageFromApi(json, 1).postList.single.recommend;
      expect(of(answer((r) => r['shown'] = 0)), isNull);
      expect(
        of(
          answer(
            (r) => r
              ..['add'] = null
              ..['subtract'] = null,
          ),
        ),
        isNull,
      );
      final addOnly = of(answer((r) => r['subtract'] = null))!;
      expect(addOnly.add?.count, 1);
      expect(addOnly.subtract, isNull);
      // The answer's form hash when its links name none.
      expect(of(answer((r) => r.remove('urls')))!.hash, 'f1f2f3f4');
      // Only the forum saying no turns the buttons off: an answer that does not tell leaves them on.
      expect(of(answer((r) => r.remove('can')))!.canEvaluate, isTrue);
      expect(of(answer((r) => r['can'] = 0))!.canEvaluate, isFalse);
      expect(of(_json('thread_recommend_member.json')..remove('recommend')), isNull);
    });

    test('an older answer carries none: nothing is shown', () {
      expect(_olderPage().postList.where((p) => p.recommend != null), isEmpty);
    });

    test('the first page by thread id is asked lean, and its answer is enough', () async {
      getIt.allowReassignment = true;
      getIt
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      final forum = _Forum(_json('thread_recommend_member.json'));
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
      addTearDown(() async {
        await getIt.reset();
        getIt.allowReassignment = false;
      });
      final page = (await ThreadRepository().fetchThreadPage(tid: '9202875').run()).fold((e) => throw e, (v) => v);
      expect(forum.requests.single.uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(forum.requests.single.uri.queryParameters, containsPair('nodoc', '1'));
      expect(page.postList.single.recommend?.subtract?.count, 2);
      expect(page.perms, isNotNull);
    });

    test('the message of a write result: with its line breaks (3.8.0) or without (before), shown the same', () {
      expect(threadRecommendOutcomeOf(_json('recommend_add_succeed.json')), isA<ThreadRecommendDone>());
      String refusal(Object? data) => (threadRecommendOutcomeOf(data) as ThreadRecommendRefused).message;
      expect(_json('recommend_duplicate.json')['message'], '评价指数 1\n您已评价过本主题');
      expect(refusal(_json('recommend_duplicate.json')), '评价指数 1\n您已评价过本主题');
      expect(refusal(_json('recommend_self_disallow.json')), '评价指数 1\n您不能评价自己的帖子');
      // The same refusals of plugin 3.7.0, one line each.
      expect((_older('recommend/result_duplicate.json')! as Map)['message'], isNot(contains('\n')));
      expect(refusal(_older('recommend/result_duplicate.json')), '评价指数 1\n您已评价过本主题');
      expect(refusal(_older('recommend/result_self_disallow.json')), '评价指数 1\n您不能评价自己的帖子');
    });

    testWidgets('buttons the forum would refuse are off; the others send', (tester) async {
      ThreadRecommendMemory.clear();
      addTearDown(ThreadRecommendMemory.clear);
      final sent = <String>[];
      Future<void> pump(ThreadRecommend recommend) => tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: Scaffold(
              body: RepositoryProvider(
                create: (_) => ThreadRecommendRepository(
                  send: (url) async {
                    sent.add(url);
                    return _json('recommend_add_succeed.json');
                  },
                ),
                child: ThreadRecommendButtons(recommend),
              ),
            ),
          ),
        ),
      );

      await pump(_page('thread_comments_author.json').postList.first.recommend!);
      final buttons = tester.widgetList<TextButton>(find.bySubtype<TextButton>());
      expect(buttons, hasLength(2));
      expect(buttons.map((b) => b.onPressed).toSet(), {null});

      await tester.pumpWidget(const SizedBox());
      await pump(_page('thread_recommend_member.json').postList.single.recommend!);
      expect(find.text('支持 1'), findsOneWidget);
      await tester.tap(find.text('支持 1'));
      await tester.pumpAndSettle();
      expect(sent.single, contains('do=add'));
      expect(find.text('支持 2'), findsOneWidget);
    });
  });

  group('5. replies stuck under the first floor', () {
    test('told by the answer: the stuck floor with its own number, nothing guessed', () {
      final page = _page('thread_stick_member.json');
      expect(page.postList.map((p) => p.postFloor), [1, 8, 2, 3, 4, 5, 6, 7, 9]);
      expect(page.postList.where((p) => p.stuck).map((p) => (p.postID, p.postFloor)), [('3954', 8)]);

      // A page whose order alone would mark a floor (8 before 2) but whose answer says none is stuck: none is.
      final none = _json('thread_stick_member.json');
      for (final p in (none['posts'] as List).cast<Map<String, dynamic>>()) {
        p['stick'] = 0;
      }
      expect(threadPageFromApi(none, 1).postList.where((p) => p.stuck), isEmpty);

      // The second floor stuck: the order tells nothing (2 comes before 3 anyway), the answer does.
      final second = _json('thread_stick_member.json');
      final posts = (second['posts'] as List).cast<Map<String, dynamic>>();
      final floor2 = posts.removeAt(2)..['stick'] = 1;
      posts[1]['stick'] = 0;
      posts.insert(1, floor2);
      expect(posts.map((p) => p['position']).take(4), [1, 2, 8, 3]);
      expect(threadPageFromApi(second, 1).postList.where((p) => p.stuck).map((p) => p.postFloor), [2]);
    });

    test('an answer that does not tell (before 3.8.0): by the order of the first page, as before', () {
      final older = _json('thread_stick_member.json');
      for (final p in (older['posts'] as List).cast<Map<String, dynamic>>()) {
        p.remove('stick');
      }
      expect(threadPageFromApi(older, 1).postList.where((p) => p.stuck).map((p) => p.postFloor), [8]);
      // The fixture of plugin 3.7.0 the order was read from first (test_834).
      final captured = threadPageFromApi(_older('moderate/thread_stuck_api.json')! as Map<String, dynamic>, 1);
      expect(captured.postList.where((p) => p.stuck), isNotEmpty);
    });
  });

  group("6. the moderation panel's log", () {
    test('as fields: the lines, the targets and the reason, the next page', () {
      final page = switch (ModcpRepository.logOf(_json('modcp_log_page1.json'), uid: 33, keyword: 'recyclebin')) {
        Right(value: ModcpReady(:final value)) => value,
        final other => throw StateError('no log: $other'),
      };
      expect(page.uid, 33);
      expect(page.keyword, 'recyclebin');
      expect(page.page, 1);
      expect(page.hasNext, isTrue, reason: 'page 1 of 4');
      expect(page.entries, hasLength(6));
      final first = page.entries.first;
      expect(first.operator, 'ag_admin');
      expect(first.group, '论坛管理员');
      expect(first.ip, '192.0.2.1');
      expect(first.action, 'recyclebinpost');
      expect(first.op, 'delete');
      expect(first.forum, 'GLTEST 子版塊（型別 sub）');
      // The first build of plugin 3.8.0 names no time offset: the forum's +8.
      expect(_json('modcp_log_page1.json').containsKey('timeoffset'), isFalse);
      expect(first.time, '26-11-10 10:38');
      expect(first.targets, ['pid 11270']);
      expect(page.entries[1].targets, ['tid 9202823']);
      expect(page.entries[2].targets, isEmpty, reason: 'a page of the panel opened');
      expect(first.other, startsWith('GET={'));

      final byKeyword = ModcpRepository.logOf(_json('modcp_log_keyword.json'), uid: 33).getRight().toNullable();
      final entries = (byKeyword! as ModcpReady<ModcpLogPage>).value.entries;
      expect((byKeyword as ModcpReady<ModcpLogPage>).value.hasNext, isFalse);
      expect(entries.first.action, '用户管理');
      expect(entries.first.reason, '解除測試');
      expect(entries.first.targets, ['mr_alpha'], reason: 'the member named, not listed again by uid');
      expect(entries.last.targets, ['mr_alpha']);
    });

    test("the lines are printed with the answer's own time offset", () {
      // The same lines asked by a moderator whose time zone is +9.
      final answer = _json('modcp_log_timeoffset.json');
      expect(answer['timeoffset'], 9);
      final page = switch (ModcpRepository.logOf(answer, uid: 70, keyword: 'recyclebin')) {
        Right(value: ModcpReady(:final value)) => value,
        final other => throw StateError('no log: $other'),
      };
      expect(page.entries, hasLength(5));
      expect(page.entries.first.targets, ['pid 11270']);
      expect(page.entries.map((e) => e.time).toSet(), {'26-11-10 11:38'});
      expect(page.hasNext, isTrue);
    });

    test("the panel's login form, its refusals, another account", () {
      final login = ModcpRepository.logOf(_json('modcp_log_login.json'), uid: 34).getRight().toNullable();
      expect((login! as ModcpNeedsLogin<ModcpLogPage>).formHash, 'f1f2f3f4');

      final noPermission = ModcpRepository.logOf(_json('modcp_log_noperm.json'), uid: 34).getRight().toNullable();
      expect((noPermission! as ModcpRefused<ModcpLogPage>).message, startsWith('系统错误\n抱歉，您无此权限'));

      final noAccess = ModcpRepository.logOf(_json('modcp_log_noaccess.json'), uid: 35).getRight().toNullable();
      expect((noAccess! as ModcpRefused<ModcpLogPage>).message, '抱歉，您没有权限访问管理面板，请重新登录站点，然后重试');

      // Served to another account, or to a guest (the session expired; the login prompt says `login` 1 since the
      // final build of plugin 3.8.0, 0 before): dropped either way, by the account the answer names.
      expect(_json('modcp_log_guest_login.json'), containsPair('login', 1));
      expect(_json('modcp_log_guest.json'), containsPair('login', 0));
      for (final answer in [
        'modcp_log_page1.json',
        'modcp_log_login.json',
        'modcp_log_guest.json',
        'modcp_log_guest_login.json',
      ]) {
        expect(
          ModcpRepository.logOf(_json(answer), uid: 31),
          isA<Left<AppException, ModcpAnswer<ModcpLogPage>>>().having(
            (e) => e.value,
            'failure',
            isA<IdentityChangedException>(),
          ),
          reason: answer,
        );
      }
      // A JSON answer that is none of these is a failed request.
      expect(
        ModcpRepository.logOf({'ok': 0, 'error': 'internal', 'uid': 31}, uid: 31),
        isA<Left<AppException, ModcpAnswer<ModcpLogPage>>>(),
      );
    });

    test('an older plugin, a forum without one: the web page of the same request, parsed as before', () async {
      final asked = <String>[];
      final repository = ModcpRepository(
        get: (url) async {
          asked.add(url);
          return right((statusCode: 200, data: _older('modcp/log_entries.html')));
        },
        post: (_, _) async => right((statusCode: 200, data: '')),
        currentUid: () => 31,
      );
      final answer = (await repository.fetchLog(keyword: '回收 站', page: 2).run()).getRight().toNullable();
      expect(
        asked.single,
        '$baseUrl/forum.php?mod=modcp&action=log&keyword=%E5%9B%9E%E6%94%B6+%E7%AB%99&page=2&tsdmapp=json&nodoc=1',
      );
      final page = (answer! as ModcpReady<ModcpLogPage>).value;
      expect(page.entries, isNotEmpty);
      expect(page.entries.first.targets, isEmpty);
      expect(page.entries.first.reason, isEmpty);
      expect(modcpLogFromApi(const {'ok': 1, 'type': 'thread', 'schema': 23}), isNull);
    });

    testWidgets('on the page: the lines with what they acted on, the next page, the login first', (tester) async {
      var loggedIn = false;
      final asked = <String>[];
      final posts = <Map<String, String>>[];
      final repository = ModcpRepository(
        get: (url) async {
          asked.add(url);
          if (!loggedIn) {
            // The login form of the panel, as this account is served it.
            final login = _json('modcp_log_login.json');
            return right((
              statusCode: 200,
              data: login
                ..['uid'] = 33
                ..['head'] = (login['head'] as String).replaceFirst("'34'", "'33'"),
            ));
          }
          return right((
            statusCode: 200,
            data: _json(url.contains('page=2') ? 'modcp_log_page2.json' : 'modcp_log_page1.json'),
          ));
        },
        post: (url, body) async {
          posts.add(body);
          loggedIn = true;
          return right((statusCode: 302, data: ''));
        },
        currentUid: () => 33,
      );
      await _pumpPage(tester, ModeratorLogPage(repository: repository));
      expect(find.text(t.moderate.panelLogin), findsOneWidget);
      await tester.enterText(
        find.descendant(of: find.byType(ModeratePanelLoginView), matching: find.byType(TextField)),
        'secret',
      );
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(posts.single, containsPair('cppwd', 'secret'));
      expect(posts.single, containsPair('formhash', 'f1f2f3f4'));

      expect(find.text('recyclebinpost · delete · GLTEST 子版塊（型別 sub）'), findsOneWidget);
      expect(find.text('pid 11270'), findsOneWidget);
      expect(find.text('tid 9202823'), findsOneWidget);
      await tester.dragUntilVisible(find.text(t.moderate.nextPage), find.byType(ListView), const Offset(0, -300));
      await tester.tap(find.text(t.moderate.nextPage));
      await tester.pumpAndSettle();
      expect(asked.last, endsWith('action=log&page=2&tsdmapp=json&nodoc=1'));
      expect(tester.takeException(), isNull);
    });
  });

  group('7. the homepage', () {
    test('the numbers online, and whether the account may see the statistics', () {
      final member = _json('index_online_member.json');
      expect(indexApiAnswerOf(member), isNotNull);
      final state = homepageStateFromApi(member, 'ag_low2');
      expect(
        state.online,
        const HomeOnline(total: 10, members: 8, invisible: 0, guests: 2, record: 24, recordDate: '2026-9-24'),
      );
      expect(state.onlineSummary, isEmpty);

      expect(ForumHomeApiPage(member).allowsSiteStats, isFalse);
      expect(ForumHomeApiPage(_json('index_online_admin.json')).allowsSiteStats, isTrue);
      expect(siteStatsAllowedBy(ForumHomeApiPage(member), uid: 35), isFalse);
      expect(siteStatsAllowedBy(ForumHomeApiPage(_json('index_online_admin.json')), uid: 32), isTrue);
      // Another account's page, a guest's, none: nothing told.
      expect(siteStatsAllowedBy(ForumHomeApiPage(member), uid: 32), isNull);
      expect(siteStatsAllowedBy(ForumHomeApiPage(_json('index_online_guest.json')), uid: 35), isNull);
      expect(siteStatsAllowedBy(null, uid: 35), isNull);
    });

    test('a forum printing no such line (`online` null), an older answer (no such fields): as before', () {
      final off = _json('index_online_member.json')..['online'] = null;
      expect(homepageStateFromApi(off, 'ag_low2').online, isNull);

      final older = _older('tsdmapp/index_v5_member.json')! as Map<String, dynamic>;
      expect(older, isNot(contains('online')));
      expect(homepageStateFromApi(older, 'ag_low').online, isNull);
      expect(ForumHomeApiPage(older).allowsSiteStats, isNull);
      expect(siteStatsAllowedBy(ForumHomeApiPage(older), uid: ForumHomeApiPage(older).servedUid), isNull);
    });

    testWidgets('the block: the numbers in the three languages, the title alone without them', (tester) async {
      const online = HomeOnline(total: 10, members: 8, invisible: 1, guests: 2, record: 24, recordDate: '2026-9-24');
      Future<void> pump(HomeOnline? online) => tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeOnlineCard(summary: const [], online: online),
            ),
          ),
        ),
      );
      for (final (locale, lines) in [
        (AppLocale.zhCn, ['10 人在线', '8 会员（1 隐身），2 位游客', '最高记录 24（2026-9-24）']),
        (AppLocale.zhTw, ['10 人在線', '8 會員（1 隱身），2 位遊客', '最高紀錄 24（2026-9-24）']),
        (AppLocale.en, ['10 online', '8 members (1 invisible), 2 guests', 'Record 24 on 2026-9-24']),
      ]) {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        await pump(online);
        await tester.pump();
        for (final line in lines) {
          expect(find.text(line), findsOneWidget, reason: '$locale');
        }
        await tester.pumpWidget(const SizedBox());
      }
      await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
      await pump(null);
      expect(find.text(t.friendPage.online.title), findsOneWidget);
      expect(find.byType(Text), findsOneWidget);
      // The page's own line wins where there is one (the web page).
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(
              body: HomeOnlineCard(summary: ['7 人在线'], online: online),
            ),
          ),
        ),
      );
      expect(find.text('7 人在线'), findsOneWidget);
      expect(find.text('10 人在线'), findsNothing);
    });
  });

  group('8. on a floor', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhCn);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Future<void> pump(WidgetTester tester, Widget child, {_Comments? forum, int? uid = 31}) async {
      await tester.pumpWidget(
        MultiRepositoryProvider(
          providers: [
            RepositoryProvider<PostCommentRepository>.value(value: (forum ?? _Comments()).repository),
            RepositoryProvider<AuthenticationRepository>.value(value: _Auth(uid)),
          ],
          child: BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                scaffoldMessengerKey: snackbarKey,
                home: Scaffold(body: SingleChildScrollView(child: child)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton));
      await tester.pumpAndSettle();
    }

    testWidgets('the menu offers the operations given; every one the floor takes when none is', (tester) async {
      final floor = _bare(_floors(_page('thread_stick_moderator.json'))['3940']!);
      String name(FloorModerateAction action) => switch (action) {
        FloorModerateAction.delete => t.moderate.deletePost,
        FloorModerateAction.warn => t.moderate.warn,
        FloorModerateAction.ban => t.moderate.ban,
        FloorModerateAction.stick => t.moderateFloorOps.stick,
      };

      // The thread's author, a member: sticking the reply only.
      await pump(tester, PostCard(floor, onModerate: (_) {}, moderateActions: const [FloorModerateAction.stick]));
      await openMenu(tester);
      expect(find.text(name(FloorModerateAction.stick)), findsOneWidget);
      for (final action in [FloorModerateAction.delete, FloorModerateAction.warn, FloorModerateAction.ban]) {
        expect(find.text(name(action)), findsNothing, reason: '$action');
      }

      // No permissions told (an older plugin): as before.
      await tester.pumpWidget(const SizedBox());
      await pump(tester, PostCard(floor, onModerate: (_) {}));
      await openMenu(tester);
      for (final action in floorModerateActionsFor(first: false)) {
        expect(find.text(name(action)), findsOneWidget, reason: '$action');
      }
    });

    testWidgets('taking rates back is on the menu of a rated floor only where allowed', (tester) async {
      final page = _page('thread_stick_moderator.json');
      final rated = _bare(_floors(page)['3940']!);
      expect(rated.rate, isNotNull);
      Widget onThread(Widget child) => BlocProvider<ThreadBloc>.value(value: _ThreadOnScreen(), child: child);

      await pump(
        tester,
        onThread(PostCard(rated, onModerate: (_) {}, canRemoveRate: page.perms!.allowRemoveRate)),
        uid: 70,
      );
      await openMenu(tester);
      expect(find.text(t.moderateFloorOps.removeRate), findsOneWidget);

      // A moderator the forum would refuse (`allow_removerate` 0): not offered.
      await tester.pumpWidget(const SizedBox());
      await pump(tester, onThread(PostCard(rated, onModerate: (_) {}, canRemoveRate: false)), uid: 70);
      await openMenu(tester);
      expect(find.text(t.moderateFloorOps.removeRate), findsNothing);
      expect(find.text(t.moderate.deletePost), findsOneWidget, reason: 'the rest of the management stays');

      // A floor nobody rated has nothing to take back.
      await tester.pumpWidget(const SizedBox());
      final unrated = _bare(_floors(page)['3950']!);
      expect(unrated.rate, isNull);
      await pump(tester, onThread(PostCard(unrated, onModerate: (_) {})), uid: 70);
      await openMenu(tester);
      expect(find.text(t.moderateFloorOps.removeRate), findsNothing);
    });

    testWidgets("the editor's attachments: listed, deleted only where the page of the floor allows", (tester) async {
      final repository = FloorOpsRepository(
        get: (_) async => throw StateError('no read'),
        getOnce: (_) async => throw StateError('no write'),
        post: (_, _) async => throw StateError('no post'),
        currentUid: () => 35,
      );
      Future<void> open({bool? canDelete}) async {
        await pump(
          tester,
          EditAttachmentsButton(
            attachments: editAttachmentsOf(_older('moderate/edit_attach_moderator.json')! as Map<String, dynamic>),
            tid: '9199345',
            pid: '3940',
            formHash: 'f1f2f3f4',
            formUid: 35,
            onDeleted: (_) {},
            canDelete: canDelete ?? true,
            repository: repository,
          ),
          uid: 35,
        );
        await tester.tap(find.byIcon(Icons.attach_file_outlined));
        await tester.pumpAndSettle();
      }

      // The floor of another member, the account no moderator of the forum (`allow_delattach` 0).
      await open(canDelete: false);
      expect(find.text('mx.png'), findsOneWidget);
      expect(find.text('mx.zip'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsNothing);

      // Not told (the own floor, an older plugin): as before.
      await tester.pumpWidget(const SizedBox());
      await open();
      expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    });

    testWidgets('the stuck and the warned floor are marked', (tester) async {
      await pump(tester, PostCard(_bare(_floors(_page('thread_stick_member.json'))['3954']!)));
      expect(find.byTooltip(t.moderateFloorOps.stuck), findsOneWidget);
      expect(find.byTooltip(t.moderate.warned), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, PostCard(_bare(_floors(_page('thread_warned_supermod.json'))['3048']!)));
      expect(find.byTooltip(t.moderate.warned), findsOneWidget);
      // The images of the floors fail to load (no network) before the test ends.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('the comments: more pages by id, none shown twice', (tester) async {
      final json = _json('thread_comments_author.json');
      final floor = _floors(threadPageFromApi(json, 1))['11263']!;
      // The second page as it is when a comment was posted meanwhile: the last of the first page comes again.
      final next = _json('comments_page2_member.json');
      final shown = ((json['posts'] as List)[1] as Map<String, dynamic>)['comments'] as List;
      (next['comments'] as List).insert(0, shown[4]);
      final forum = _Comments(reads: {'page=2': next});
      await pump(
        tester,
        PostCommentSection(floor, tid: '9202819', onReload: () {}),
        forum: forum,
      );
      expect(find.byKey(const ValueKey('post-comment-scores')), findsNothing, reason: 'no score items in this forum');
      expect(find.byType(PostCommentTile), findsNWidgets(5));
      expect(find.byKey(const ValueKey('post-comment-delete-22')), findsNothing, reason: 'a member');

      await tester.tap(find.byKey(const ValueKey('post-comment-more')));
      await tester.pumpAndSettle();
      expect(find.byType(PostCommentTile), findsNWidgets(8), reason: 'the one shown already is not added again');
      expect(find.byKey(const ValueKey('post-comment-more')), findsNothing);
      expect(Uri.parse(forum.readUrls.single).queryParameters, containsPair('tsdmform', '1'));
    });

    testWidgets('the averages of the score items above the comments, as the page prints them', (tester) async {
      final floor = _floors(_page('thread_comment_scores.json'))['3031']!;
      await pump(tester, PostCommentSection(floor, tid: '9199043', onReload: () {}), uid: 56);
      final scores = find.byKey(const ValueKey('post-comment-scores'));
      expect(scores, findsOneWidget);
      expect(find.descendant(of: scores, matching: find.text('画质')), findsOneWidget);
      expect(find.descendant(of: scores, matching: find.text('4.0')), findsOneWidget);
      expect(find.descendant(of: scores, matching: find.text('剧情')), findsOneWidget);
      expect(find.descendant(of: scores, matching: find.text('5.0')), findsOneWidget);
      // Four stars of five, then five of five.
      expect(find.descendant(of: scores, matching: find.byIcon(Icons.star)), findsNWidgets(9));
      expect(find.descendant(of: scores, matching: find.byIcon(Icons.star_border)), findsOneWidget);
      // A half is drawn as one. (The avatars of the comments fail to load, no network, before the test ends.)
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 100));
      await pump(tester, const PostCommentScores([PostCommentScore(name: '剧情', score: 4.5)]));
      expect(find.text('4.5'), findsOneWidget);
      expect(find.byIcon(Icons.star_half), findsOneWidget);
    });
  });
}
