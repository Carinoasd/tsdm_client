/// The reply typed in a notification (Android): the notification of a single reply, quote, mention or private message
/// offers a "reply" action with a text input; the text is sent in the plugin's own isolate as the account the
/// notification is about, through the app's reply and message code; the outcome is a notification of its own, the
/// text kept as the draft of the floor or the conversation when it was not sent.
///
/// Measured on the test forum (Discuz X5, plugin 3.7.0): the reply window of a floor asked without its forum names it
/// (`submit.url`), its post is `post_reply_succeed`; a second reply within the interval is `post_flood_ctrl`, a closed
/// thread refuses the window (`post_thread_closed`), a guest gets `replyperm_login_nopermission`; a private message
/// through the chat dialog is `do_success`, a second one too soon `message_can_not_send_2` (the fixtures
/// `write_v13_reply_flood.json`, `post_v16_msg_reply_closed.json`, `post_v16_msg_reply_guest.json`, `write_v13_pm_flood.json`).
///
/// Synthetic accounts and recorded answers only: nothing reaches a forum.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_notice.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_notice.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _dir = 'test/data/tsdmapp';

/// The login prompt the forum answers the chat dialog with when the session expired (test forum, trimmed).
// The XML declaration has to come first.
// ignore: leading_newlines_in_multiline_strings
const _loginPrompt = '''<?xml version="1.0" encoding="utf-8"?>
<root><![CDATA[
<div id="main_messaqge_Ab1Cd">
<div id="layer_login_Ab1Cd">
<h3 class="flb">
<em id="returnmessage_Ab1Cd">
您需要先登录才能继续本操作</em>
</h3>
<form method="post" autocomplete="off" name="login" id="loginform_Ab1Cd" action="member.php?mod=logging&amp;action=login&amp;loginsubmit=yes&amp;handlekey=showmsg_1000">
<input type="hidden" name="formhash" value="f1f2f3f4" />
</form>
</div>
</div>
]]></root>''';

String _fixture(String path) => File(path).readAsStringSync();

/// The account of the recorded reply window (`post_v16_reply_float.json`).
const _windowUid = 31;

/// Answers the reply window of a floor ([window]), its post ([reply]), the chat dialog (`chat_dialog_x5.xml`) and the
/// message ([message]); records every request with its form. [offline] fails every request.
final class _Forum implements HttpClientAdapter {
  _Forum({
    String? window,
    String? reply,
    String? message,
    this.chat,
    this.offline = false,
  }) : window = window ?? _fixture('$_dir/post_v16_reply_float.json'),
       reply = reply ?? _fixture('$_dir/write_v13_reply_ok.json'),
       message = message ?? _fixture('$_dir/write_v13_pm_ok.json');

  final String window;
  final String reply;
  final String message;

  /// The chat dialog, `chat_dialog_x5.xml` when null.
  final String? chat;
  final bool offline;

  final requests = <({String method, Uri uri, Map<String, String> form})>[];

  List<({String method, Uri uri, Map<String, String> form})> get posts => [
    for (final r in requests)
      if (r.method == 'POST') r,
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    final uri = options.uri;
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)));
    }
    requests.add((method: options.method, uri: uri, form: body.isEmpty ? {} : Uri.splitQueryString(body)));
    if (offline) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    final q = uri.queryParameters;
    final String answer;
    if (options.method == 'POST') {
      answer = q['ac'] == 'pm' ? message : reply;
    } else if (q['action'] == 'reply') {
      answer = window;
    } else if (q['ac'] == 'pm' && q['op'] == 'showmsg') {
      answer = chat ?? _fixture('test/data/chat_dialog_x5.xml');
    } else {
      throw DioException.connectionError(requestOptions: options, reason: 'unexpected');
    }
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: [if (answer.startsWith('{')) 'application/json' else 'text/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A storage over a database in memory, closed after the test.
StorageProvider _storage() {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  return StorageProvider(db, {}, {});
}

NetClientProvider _clientOf(_Forum forum) => NetClientProvider.buildNoCookie(
  dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
  cookie: CookieProvider.buildEmpty(),
);

/// The id of the notification offering the direct reply to the target of [payload].
int? _pinnedIdOf(String? payload) {
  final uid = LocalNoticeKeys.parseOpenNotification(payload)?.uid;
  final target = LocalNoticeKeys.parseTarget(payload);
  final key = uid == null || target == null ? null : directReplyTargetKey(uid, target);
  return key == null ? null : directReplyNoticeIdOf(key);
}

/// The response of the reply action of a notification: by default from the notification its payload was posted as.
NotificationResponse _action({
  int? id,
  String? actionId = directReplyActionId,
  String? input,
  String? payload,
}) => NotificationResponse(
  notificationResponseType: NotificationResponseType.selectedNotificationAction,
  id: id ?? _pinnedIdOf(payload) ?? localNoticeId,
  actionId: actionId,
  input: input,
  payload: payload,
);

String _floorPayload(int uid, {int tid = 9600001, int pid = 9700002, int? nid = 5}) => LocalNoticeKeys.withTarget(
  LocalNoticeKeys.openNotificationOf(uid),
  LocalNoticeTarget(nid: nid, tid: tid, pid: pid),
);

String _pmPayload(int uid, {int peer = 1000}) =>
    LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotificationOf(uid), LocalNoticeTarget(peerUid: peer));

NotificationAutoSyncInfoNotice _notice({
  String? type = 'post',
  String? fromIdType = 'post',
  int? tid = 1,
  int? pid = 2,
}) => NotificationAutoSyncInfoNotice(
  msg: 'A 回复了您的帖子',
  notice: 1,
  personalMessage: 0,
  broadcastMessage: 0,
  timestamp: 1700000000,
  nid: 5,
  author: 'A',
  noticeType: type,
  fromIdType: fromIdType,
  threadTitle: 'T',
  tid: tid,
  pid: pid,
);

NotificationAutoSyncInfoPm _pm({int? peerUid = 1000, int count = 1}) => NotificationAutoSyncInfoPm(
  user: 'Bob',
  msg: 'hi',
  notice: 0,
  personalMessage: count,
  broadcastMessage: 0,
  timestamp: 1700000000,
  peerUid: peerUid,
);

typedef _Shown = ({int id, String? title, String? body, NotificationDetails? details, String? payload});

/// Records what is shown, and keeps the shade as Android does: a notification is (id, tag), shown again under the same
/// pair it is replaced. The extras of an action's PendingIntent are kept by request code as the plugin makes them
/// (`id * 16` as a Java int, `FLAG_UPDATE_CURRENT`): a notification posted under the same request code rewrites them.
final class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  final shown = <_Shown>[];
  final shade = <(int, String?), _Shown>{};
  final cancelled = <(int, String?)>[];

  /// The payload the reply action under each request code sends.
  final actionExtras = <int, ({int id, String? payload})>{};

  static int requestCodeOf(int id) => (id * 16).toSigned(32);

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    final n = (id: id, title: title, body: body, details: notificationDetails, payload: payload);
    shown.add(n);
    shade[(id, notificationDetails?.android?.tag)] = n;
    if (notificationDetails?.android?.actions?.isNotEmpty ?? false) {
      actionExtras[requestCodeOf(id)] = (id: id, payload: payload);
    }
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelled.add((id, tag));
    shade.remove((id, tag));
  }

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => [
    for (final (id, tag) in shade.keys) ActiveNotification(id: id, tag: tag),
  ];

  /// What the reply typed in notification [n] sends: the extras its action carries now.
  NotificationResponse replyTo(_Shown n, String text) {
    final extras = actionExtras[requestCodeOf(n.id)]!;
    return NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      id: extras.id,
      actionId: directReplyActionId,
      input: text,
      payload: extras.payload,
    );
  }
}

void main() {
  late Translations tr;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tr = await AppLocale.zhCn.build();
  });

  setUp(() {
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
  });

  tearDown(() async {
    TsdmAppApi.reset();
    await getIt.reset();
  });

  group('A. which notifications offer the reply', () {
    test('a single reply, quote or mention naming its floor, a single message naming its peer', () {
      expect(directReplyFits(_notice()), isTrue, reason: 'reply');
      expect(directReplyFits(_notice(fromIdType: 'quote')), isTrue, reason: 'quote');
      expect(directReplyFits(_notice(type: 'at', fromIdType: null)), isTrue, reason: 'mention');
      expect(directReplyFits(_pm()), isTrue);
    });

    test('not a rate, a notice without its floor, a message without its peer, several items, a broadcast', () {
      expect(directReplyFits(_notice(type: 'rate', fromIdType: null)), isFalse);
      expect(directReplyFits(_notice(pid: null)), isFalse);
      expect(directReplyFits(_pm(peerUid: null)), isFalse);
      expect(directReplyFits(_pm(count: 2)), isFalse);
      expect(
        directReplyFits(
          const NotificationAutoSyncInfoBm(
            msg: 'm',
            notice: 0,
            personalMessage: 0,
            broadcastMessage: 1,
            timestamp: 1700000000,
          ),
        ),
        isFalse,
      );
    });

    test(
      'the notification carries the action only when offered, for a known account, with the content shown',
      () async {
        Future<List<AndroidNotificationAction>?> actionsOf({
          bool directReply = true,
          bool hideContent = false,
          LocalNoticeAccount? account = const LocalNoticeAccount(uid: 1000),
          NotificationAutoSyncInfo? info,
        }) async {
          final plugin = _Plugin();
          await showLocalNotificationWith(
            plugin: plugin,
            translations: tr,
            info: info ?? _notice(),
            account: account,
            hideContent: hideContent,
            directReply: directReply,
            storage: _storage(),
            android: true,
          );
          return plugin.shown.single.details!.android!.actions;
        }

        final actions = await actionsOf();
        expect(actions, hasLength(1));
        final action = actions!.single;
        expect(action.id, directReplyActionId);
        expect(action.title, tr.localNotification.directReply.action);
        expect(action.inputs, hasLength(1));
        expect(action.showsUserInterface, isFalse, reason: "handled in the plugin's isolate, the app is not opened");
        expect(action.cancelNotification, isTrue, reason: 'the outcome is a notification of its own');
        expect(await actionsOf(info: _pm()), hasLength(1));

        expect(await actionsOf(directReply: false), isNull, reason: 'the setting off or the app locked');
        expect(await actionsOf(hideContent: true), isNull, reason: 'nothing shown to reply to');
        expect(await actionsOf(account: null), isNull, reason: 'the payload must name the account');
        expect(await actionsOf(info: _notice(type: 'rate', fromIdType: null)), isNull);
      },
    );

    test('the setting is on by default and is read from the storage', () async {
      expect(SettingsKeys.notificationDirectReply.defaultValue, isTrue);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      expect(await directReplyEnabled(storage), isTrue);
      await storage.saveBool(SettingsKeys.notificationDirectReply.name, value: false);
      expect(await directReplyEnabled(storage), isFalse);
    });

    test('offered only on Android', () async {
      // The tests run on the host: no notification offers it there, whatever the setting.
      expect(await directReplyOffered(locked: () async => false), isFalse);
    });
  });

  group('B. the request of the action', () {
    test('the account, the floor and the text come from the notification', () {
      final r = DirectReplyRequest.of(_action(input: '  好的  ', payload: _floorPayload(1000)))!;
      expect(r.uid, 1000);
      expect(r.target.tid, 9600001);
      expect(r.target.pid, 9700002);
      expect(r.target.nid, 5);
      expect(r.toConversation, isFalse);
      expect(r.message, '好的');
    });

    test('a private message goes to the peer of the conversation', () {
      final r = DirectReplyRequest.of(
        _action(input: 'hi', payload: _pmPayload(1000)),
      )!;
      expect(r.uid, 1000);
      expect(r.target.peerUid, 1000);
      expect(r.toConversation, isTrue);
    });

    test('nothing for another action, no text, a payload without an account or a target', () {
      expect(DirectReplyRequest.of(_action(actionId: 'other', input: 'x', payload: _floorPayload(1))), isNull);
      expect(DirectReplyRequest.of(_action(input: '   ', payload: _floorPayload(1))), isNull);
      expect(DirectReplyRequest.of(_action(input: 'x', payload: LocalNoticeKeys.openNotification)), isNull);
      expect(DirectReplyRequest.of(_action(input: 'x', payload: LocalNoticeKeys.openNotificationOf(1))), isNull);
      expect(
        DirectReplyRequest.of(
          _action(
            input: 'x',
            payload: LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotificationOf(1), const LocalNoticeTarget(tid: 3)),
          ),
        ),
        isNull,
        reason: 'a thread without its floor',
      );
    });

    test('never for the notifications of a watched forum, a keyword or a followed thread', () {
      for (final id in [forumWatchForumNoticeId(8), forumWatchKeywordNoticeId(1000), followedThreadNoticeId(9)]) {
        expect(
          DirectReplyRequest.of(_action(id: id, input: 'x', payload: _floorPayload(1000))),
          isNull,
          reason: '$id',
        );
      }
    });

    test('the outcome notifications have ids of their own', () {
      final floor = DirectReplyRequest.of(_action(input: 'x', payload: _floorPayload(1000)))!;
      final pm = DirectReplyRequest.of(_action(input: 'x', payload: _pmPayload(1000)))!;
      for (final id in [floor.resultNoticeId, pm.resultNoticeId]) {
        expect(isDirectReplyResultNoticeId(id), isTrue);
        expect(isLocalNoticeId(id), isFalse);
        expect(isForumWatchNoticeId(id), isFalse);
      }
      expect(floor.resultNoticeId, isNot(pm.resultNoticeId));
    });
  });

  group('C. sending', () {
    Future<(DirectReplyOutcome, _Forum, List<int>)> run(
      DirectReplyRequest request, {
      _Forum? forum,
      bool enabled = true,
      bool locked = false,
      bool accountKept = true,
      bool pinned = true,
      DirectReplySend send = sendDirectReplyWith,
    }) async {
      final f = forum ?? _Forum();
      final asked = <int>[];
      final outcome = await runDirectReply(
        request,
        translations: tr,
        enabled: () async => enabled,
        locked: () async => locked,
        clientOf: (uid) async {
          asked.add(uid);
          return accountKept ? _clientOf(f) : null;
        },
        pinned: () async => pinned,
        send: send,
      );
      return (outcome, f, asked);
    }

    DirectReplyRequest floor(int uid, [String text = '好的']) =>
        DirectReplyRequest.of(_action(input: text, payload: _floorPayload(uid)))!;

    test('the reply window of the floor and its post, once, as the account of the notification', () async {
      final (outcome, forum, asked) = await run(floor(_windowUid, '收到 @Bob'));
      expect(outcome, isA<DirectReplySent>());
      expect(asked, [_windowUid], reason: "the notification's account, not the one in use");
      final window = forum.requests.first;
      expect(window.uri.queryParameters['action'], 'reply');
      expect(window.uri.queryParameters['tid'], '9600001');
      expect(window.uri.queryParameters['repquote'], '9700002');
      expect(window.uri.queryParameters['tsdmapp'], 'json', reason: 'asked as the post form of the app API');
      final post = forum.posts.single;
      expect(post.uri.queryParameters['replysubmit'], 'yes');
      expect(post.uri.queryParameters['fid'], '2', reason: 'the forum named by the window');
      expect(post.uri.queryParameters['inajax'], '1');
      expect(post.form['reppid'], '9700002');
      expect(post.form['message'], contains('收到'));
    });

    test('a window served to another account is not posted', () async {
      final (outcome, forum, _) = await run(floor(1000));
      expect(outcome, isA<DirectReplyNotSent>());
      expect(forum.posts, isEmpty);
    });

    test("a refusal says the forum's words: the interval, a closed thread, a guest", () async {
      final (flood, floodForum, _) = await run(
        floor(_windowUid),
        forum: _Forum(reply: _fixture('$_dir/write_v13_reply_flood.json')),
      );
      expect((flood as DirectReplyNotSent).reason, '抱歉，您两次发表间隔少于 15 秒，请稍候再发表');
      expect(floodForum.posts, hasLength(1), reason: 'posted once, never again by itself');

      final (closed, closedForum, _) = await run(
        floor(_windowUid),
        forum: _Forum(window: _fixture('$_dir/post_v16_msg_reply_closed.json')),
      );
      expect((closed as DirectReplyNotSent).reason, '抱歉，本主题已关闭，不再接受新内容');
      expect(closedForum.posts, isEmpty);

      final (guest, guestForum, _) = await run(
        floor(_windowUid),
        forum: _Forum(window: _fixture('$_dir/post_v16_msg_reply_guest.json')),
      );
      expect((guest as DirectReplyNotSent).reason, contains('尚未登录'));
      expect(guestForum.posts, isEmpty);
    });

    test('a captcha, a security question or a window the app can not fill is for the app', () async {
      final (outcome, _, _) = await run(
        floor(_windowUid),
        send: (_, _) async => left(ReplyNeedsBrowserException(url: 'u', verification: true)),
      );
      expect((outcome as DirectReplyNotSent).reason, tr.localNotification.directReply.openApp);
    });

    test('offline: a failure of its own', () async {
      final (outcome, _, _) = await run(floor(_windowUid), forum: _Forum(offline: true));
      expect((outcome as DirectReplyNotSent).reason, tr.localNotification.directReply.error);
    });

    test('a private message through the chat dialog of the peer', () async {
      final request = DirectReplyRequest.of(_action(input: '在的', payload: _pmPayload(2000)))!;
      final (outcome, forum, asked) = await run(request);
      expect(outcome, isA<DirectReplySent>());
      expect(asked, [2000]);
      expect(forum.requests.first.uri.queryParameters['op'], 'showmsg');
      expect(forum.requests.first.uri.queryParameters['touid'], '1000');
      final post = forum.posts.single;
      expect(post.uri.queryParameters['op'], 'send');
      expect(post.form['touid'], '1000');
      expect(post.form['message'], '在的');

      final (flood, _, _) = await run(request, forum: _Forum(message: _fixture('$_dir/write_v13_pm_flood.json')));
      expect((flood as DirectReplyNotSent).reason, '两次发送短消息太快，请稍候再发送');
    });

    test("a private message with an expired login says the forum's prompt, nothing posted", () async {
      final request = DirectReplyRequest.of(_action(input: '在的', payload: _pmPayload(2000)))!;
      final (outcome, forum, _) = await run(request, forum: _Forum(chat: _loginPrompt));
      expect((outcome as DirectReplyNotSent).reason, '您需要先登录才能继续本操作');
      expect(forum.posts, isEmpty);
    });

    test('an app lock file that can not be read counts as locked', () async {
      final dir = Directory.systemTemp.createTempSync('direct_reply_lock_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/app_lock.json');
      final store = AppLockStore(file: () async => file);
      expect(await appLocked(store: store), isFalse, reason: 'no file: no lock');
      file.writeAsStringSync('{broken');
      expect(await appLocked(store: store), isTrue);
      file.writeAsStringSync('{"v": 999}');
      expect(await appLocked(store: store), isTrue);
      expect(await appLocked(store: AppLockStore(file: () async => throw const FileSystemException('no dir'))), isTrue);
    });

    test('nothing is sent with the setting turned off, the app locked or the account gone', () async {
      final (off, offForum, _) = await run(floor(_windowUid), enabled: false);
      expect((off as DirectReplyNotSent).reason, tr.localNotification.directReply.openApp);
      expect(offForum.requests, isEmpty);

      final (locked, lockedForum, _) = await run(floor(_windowUid), locked: true);
      expect((locked as DirectReplyNotSent).reason, tr.localNotification.directReply.locked);
      expect(lockedForum.requests, isEmpty);

      final (gone, goneForum, _) = await run(floor(_windowUid), accountKept: false);
      expect((gone as DirectReplyNotSent).reason, tr.localNotification.accountGone);
      expect(goneForum.requests, isEmpty);
    });
  });

  group('D. the outcome', () {
    test('sent: quiet, gone after a while, a tap opens the floor', () async {
      final request = DirectReplyRequest.of(_action(input: '好的', payload: _floorPayload(1000)))!;
      final plugin = _Plugin();
      await showDirectReplyOutcome(
        plugin: plugin,
        translations: tr,
        request: request,
        outcome: const DirectReplySent(),
      );
      final shown = plugin.shown.single;
      expect(shown.id, request.resultNoticeId);
      expect(shown.title, tr.localNotification.directReply.sent);
      expect(shown.body, '好的');
      expect(shown.details!.android!.silent, isTrue);
      expect(shown.details!.android!.timeoutAfter, directReplySentShownFor.inMilliseconds);
      expect(shown.details!.android!.actions, isNull);
      expect(LocalNoticeKeys.parseTarget(shown.payload)!.draft, isNull);
      expect(LocalNoticeKeys.parseOpenNotification(shown.payload)!.uid, 1000);
    });

    test("not sent: the reason, and the text in the payload for the app's draft", () async {
      const text = '回复 & 引用 #1 = 50%\n第二行';
      final request = DirectReplyRequest.of(_action(input: text, payload: _pmPayload(1000)))!;
      final plugin = _Plugin();
      await showDirectReplyOutcome(
        plugin: plugin,
        translations: tr,
        request: request,
        outcome: const DirectReplyNotSent('两次发送短消息太快，请稍候再发送'),
      );
      final shown = plugin.shown.single;
      expect(shown.title, tr.localNotification.directReply.failed);
      expect(shown.body, '两次发送短消息太快，请稍候再发送');
      expect(shown.details!.android!.silent, isFalse);
      expect(shown.details!.android!.timeoutAfter, isNull);
      expect(LocalNoticeKeys.parseOpenNotification(shown.payload)!.uid, 1000);
      final target = LocalNoticeKeys.parseTarget(shown.payload)!;
      expect(target.peerUid, 1000);
      expect(target.draft, text);
      expect(
        LocalNoticeKeys.loggable(shown.payload),
        isNot(contains('%E7%AC%AC')),
        reason: 'the text stays out of logs',
      );
      expect('$target', isNot(contains('%E7%AC%AC')));
    });

    test('a tap keeps the text as the draft of the floor, the one there moved aside', () async {
      final store = LocalDraftStore.memory();
      final key = LocalDraftKey.floorReply('9600001', '9700002');
      store.save(1000, LocalDraft(key: key, body: '旧的', updatedAt: DateTime(2026)));
      final target = LocalNoticeKeys.parseTarget(
        DirectReplyRequest.of(_action(input: '新的', payload: _floorPayload(1000)))!.failedPayload,
      )!;
      await keepDirectReplyDraft(1000, target, store: store, now: DateTime(2026, 11, 10));
      final drafts = await store.list(1000);
      expect(drafts.firstWhere((e) => e.key == key).body, '新的');
      expect(drafts.firstWhere((e) => e.key == key).replyAction, directReplyActionUrl(tid: 9600001, pid: 9700002));
      expect(drafts.where((e) => e.key.isBackup).single.body, '旧的');

      await keepDirectReplyDraft(
        1000,
        LocalNoticeKeys.parseTarget(
          DirectReplyRequest.of(_action(input: '在的', payload: _pmPayload(1000, peer: 2000)))!.failedPayload,
        )!,
        store: store,
      );
      expect((await store.load(1000, LocalDraftKey.message('2000')))!.body, '在的');
    });
  });

  group('F. the target of a notification offering the reply never changes', () {
    const account = LocalNoticeAccount(uid: 1000);
    const named = LocalNoticeAccount(uid: 1000, named: true);

    Future<_Shown> post(
      _Plugin plugin,
      StorageProvider storage,
      NotificationAutoSyncInfo info, {
      LocalNoticeAccount account = account,
    }) async {
      await showLocalNotificationWith(
        plugin: plugin,
        translations: tr,
        info: info,
        account: account,
        directReply: true,
        storage: storage,
        android: true,
      );
      return plugin.shown.last;
    }

    /// Run the reply [response] as the isolate of the plugin does, with the pins of [storage]; what was posted, if
    /// anything, is in the forum's requests.
    Future<(DirectReplyOutcome?, _Forum)> reply(NotificationResponse response, StorageProvider storage) async {
      final forum = _Forum();
      final request = DirectReplyRequest.of(response);
      if (request == null) {
        return (null, forum);
      }
      final outcome = await runDirectReply(
        request,
        translations: tr,
        enabled: () async => true,
        locked: () async => false,
        clientOf: (_) async => _clientOf(forum),
        pinned: () => DirectReplyPins(storage).holds(request.noticeId, request.targetKey),
      );
      return (outcome, forum);
    }

    NotificationAutoSyncInfoPm pmFrom(int peer, {String msg = 'hi'}) => NotificationAutoSyncInfoPm(
      user: 'P$peer',
      msg: msg,
      notice: 0,
      personalMessage: 1,
      broadcastMessage: 0,
      timestamp: 1700000000,
      peerUid: peer,
    );

    test('a newer item of another target, posted while a reply is typed: the reply still goes to the first', () async {
      final storage = _storage();
      final plugin = _Plugin();
      final first = await post(plugin, storage, pmFrom(1000));
      expect(isDirectReplyNoticeId(first.id), isTrue, reason: 'its own id, not the shared one');
      expect(first.id, isNot(localNoticeId));

      // While the user types in the first notification, the next sync brings a reply to a floor of the same account.
      final second = await post(plugin, storage, _notice(tid: 9600001, pid: 9700002));
      expect(second.id, isNot(first.id));
      expect(_Plugin.requestCodeOf(second.id), isNot(_Plugin.requestCodeOf(first.id)));
      expect(plugin.shade.keys.map((e) => e.$1), [second.id], reason: 'still one notification for the slot');

      // The reply typed in the first one is sent with what its action carries now: the first target, never the floor.
      final (outcome, forum) = await reply(plugin.replyTo(first, '在的'), storage);
      expect(outcome, isA<DirectReplySent>());
      expect(forum.posts.single.uri.queryParameters['ac'], 'pm');
      expect(forum.posts.single.form['touid'], '1000');
      expect(forum.posts.where((e) => e.uri.queryParameters['replysubmit'] == 'yes'), isEmpty);
    });

    test('a newer item of the same target updates the same notification', () async {
      final storage = _storage();
      final plugin = _Plugin();
      final first = await post(plugin, storage, pmFrom(1000));
      final again = await post(plugin, storage, pmFrom(1000, msg: 'still there?'));
      expect(again.id, first.id);
      expect(plugin.shade, hasLength(1));
      expect(plugin.shade.values.single.body, 'still there?');
      final (outcome, forum) = await reply(plugin.replyTo(first, '在'), storage);
      expect(outcome, isA<DirectReplySent>());
      expect(forum.posts.single.form['touid'], '1000');
    });

    test('a single item then several: the summary replaces it, a reply typed in it still goes to its target', () async {
      final storage = _storage();
      final plugin = _Plugin();
      final first = await post(plugin, storage, pmFrom(1000));
      final several = await post(plugin, storage, _pm(count: 2));
      expect(several.id, localNoticeId, reason: 'several items keep the shared id');
      expect(several.details!.android!.actions, isNull);
      expect(plugin.shade.keys, [(localNoticeId, null)], reason: 'the single one is taken back');
      expect(plugin.cancelled.map((e) => e.$1), contains(first.id));
      final (outcome, forum) = await reply(plugin.replyTo(first, '在'), storage);
      expect(outcome, isA<DirectReplySent>());
      expect(forum.posts.single.form['touid'], '1000');
    });

    test('several items then a single one: the summary is taken back', () async {
      final storage = _storage();
      final plugin = _Plugin();
      await post(plugin, storage, _pm(count: 2));
      final single = await post(plugin, storage, pmFrom(1000));
      expect(plugin.shade.keys.map((e) => e.$1), [single.id]);
    });

    test('every account named: each account keeps its own slot', () async {
      final storage = _storage();
      final plugin = _Plugin();
      final mine = await post(plugin, storage, pmFrom(1000), account: named);
      final other = await post(
        plugin,
        storage,
        pmFrom(1000),
        account: const LocalNoticeAccount(uid: 2000, named: true),
      );
      expect(plugin.shade.keys.map((e) => e.$1).toSet(), {mine.id, other.id});
      final several = await post(plugin, storage, _pm(count: 2), account: named);
      expect(several.id, localNoticeIdOf(1000));
      expect(plugin.shade.keys.map((e) => e.$1).toSet(), {other.id, localNoticeIdOf(1000)});
    });

    test('an action carrying another target than its notification was made for is never sent', () async {
      final storage = _storage();
      final plugin = _Plugin();
      final first = await post(plugin, storage, pmFrom(1000));
      // As if the extras of the first notification had been rewritten with the floor's payload.
      final swapped = NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotificationAction,
        id: first.id,
        actionId: directReplyActionId,
        input: '在的',
        payload: _floorPayload(1000),
      );
      final (outcome, forum) = await reply(swapped, storage);
      expect(outcome, isNull);
      expect(forum.requests, isEmpty);
    });

    test('an id is never given to a second target, nor while another notification under it is shown', () async {
      final storage = _storage();
      final pins = DirectReplyPins(storage);
      expect(await pins.claim(42, '1000:m:1'), isTrue);
      expect(await pins.claim(42, '1000:m:1'), isTrue, reason: 'the same target');
      expect(await pins.claim(42, '1000:m:2'), isFalse);
      expect(await pins.holds(42, '1000:m:1'), isTrue);
      expect(await pins.holds(42, '1000:m:2'), isFalse);

      final later = DirectReplyPins(storage, now: () => DateTime.now().add(DirectReplyPins.keepFor * 2));
      expect(
        await later.claim(42, '1000:m:2', shown: [(id: 42, tag: directReplyTag(0, '1000:m:1'))]),
        isFalse,
        reason: 'the first notification is still in the shade',
      );
      expect(await later.claim(42, '1000:m:2', shown: const []), isTrue, reason: 'long gone: the id is free again');
      expect(await later.holds(42, '1000:m:1'), isFalse);
    });

    test('a reply the pins do not hold is not sent', () async {
      final storage = _storage();
      final request = DirectReplyRequest.of(_action(input: 'x', payload: _pmPayload(1000)))!;
      final (outcome, forum) = await reply(_action(input: 'x', payload: _pmPayload(1000)), storage);
      expect((outcome! as DirectReplyNotSent).reason, tr.localNotification.directReply.openApp);
      expect(forum.requests, isEmpty);
      expect(await DirectReplyPins(storage).holds(request.noticeId, request.targetKey), isFalse);
    });

    test('without the shade or the storage, no action is offered', () async {
      final plugin = _Plugin();
      await showLocalNotificationWith(
        plugin: plugin,
        translations: tr,
        info: pmFrom(1000),
        account: account,
        directReply: true,
        storage: _storage(),
        android: false,
      );
      expect(plugin.shown.single.details!.android!.actions, isNull);
      expect(plugin.shown.single.id, localNoticeId);
    });
  });

  group('G. a reply whose result is unknown', () {
    test('a timeout after the post says the result is unknown, not "not sent"', () async {
      final request = DirectReplyRequest.of(_action(input: '好的', payload: _floorPayload(1000)))!;
      Future<DirectReplyOutcome> run(AppException e) => runDirectReply(
        request,
        translations: tr,
        enabled: () async => true,
        locked: () async => false,
        clientOf: (_) async => _clientOf(_Forum()),
        pinned: () async => true,
        send: (_, _) async => left(e),
      );
      expect(await run(HttpRequestFailedException(null)), isA<DirectReplyUnconfirmed>());
      expect(await run(HttpHandshakeFailedException('timeout', timedOut: true)), isA<DirectReplyUnconfirmed>());
      expect(await run(HttpRequestFailedException(502)), isA<DirectReplyUnconfirmed>());
      expect(await run(HttpHandshakeFailedException('offline', connectionFailed: true)), isA<DirectReplyNotSent>());
      expect(await run(ReplyWindowFetchFailedException(noNetwork: true)), isA<DirectReplyNotSent>());
      expect(await run(HttpRequestFailedException(403)), isA<DirectReplyNotSent>());

      final content = directReplyOutcomeContentOf(tr, request, const DirectReplyUnconfirmed());
      expect(content.title, tr.localNotification.directReply.unconfirmed);
      expect(content.body, tr.chatPage.maybeSent);
      final target = LocalNoticeKeys.parseTarget(content.payload)!;
      expect(target.draft, '好的');
      expect(target.maybeSent, isTrue);

      final store = LocalDraftStore.memory();
      await keepDirectReplyDraft(1000, target, store: store);
      expect((await store.load(1000, LocalDraftKey.floorReply('9600001', '9700002')))!.maybeSent, isTrue);
    });
  });

  group('E. wiring', () {
    test('the action receiver of the plugin is declared, nothing else of the activities changes', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"'));
      expect(RegExp('<activity-alias').allMatches(manifest), hasLength(4));
    });

    test('the app and the background service hand the plugin the callback of the reply', () {
      expect(File('lib/main.dart').readAsStringSync(), contains('onNotificationActionInBackground'));
      expect(
        File('lib/features/background_sync/background_sync_entry.dart').readAsStringSync(),
        contains('onDidReceiveBackgroundNotificationResponse: onNotificationActionInBackground'),
      );
    });

    test('the settings are read by the settings repository', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      await storage.saveBool(SettingsKeys.notificationDirectReply.name, value: false);
      final settings = SettingsRepository(storage);
      await settings.init();
      addTearDown(settings.dispose);
      expect(settings.currentSettings.notificationDirectReply, isFalse);
    });
  });
}
