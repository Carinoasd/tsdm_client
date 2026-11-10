import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/app_lock/repository/app_lock_store.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/thread/v1/repository/share_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// The reply typed in a notification (Android): the notification of a single new reply, quote or mention, or of a
/// single new private message, offers a "reply" action with a text input; what is typed is sent in the background as
/// the account the notification is about (`direct_reply_entry.dart`), through the app's own reply and message code.
///
/// The notification plugin hands the action to an isolate of its own (its `ActionBroadcastReceiver` starts an engine
/// for it, whether the app runs or not): neither the app's isolate nor the background message service sees it.
///
/// Measured on the test forum (Discuz X5, plugin 3.7.0): the reply window of a floor asked without its forum
/// (`mod=post&action=reply&tid=…&repquote=…&infloat=yes&handlekey=reply`, JSON mode) names the forum in its form and
/// in `submit.url`; the reply posted there is stored (`post_reply_succeed`) and marked as sent from the app like any
/// reply of the app. A second reply within the forum's interval is refused (`post_flood_ctrl`), a closed thread
/// refuses the window (`post_thread_closed`), a guest gets the login message (`replyperm_login_nopermission`); a
/// private message sent through the chat dialog is `do_success`, a second one too soon `message_can_not_send_2`.

/// Id of the action of the direct reply.
const directReplyActionId = 'directReply';

const _resultIdBase = 0x50000000;
const _resultIdMask = 0x07FFFFFF;
const _resultConversationBit = 0x08000000;

/// Base of [directReplyNoticeIdOf]. The request codes of the actions' PendingIntents (`id * 16` as a Java int) only
/// tell the ids apart by their low 28 bits: these notifications are the only ones carrying an action, so they can not
/// share one with another kind. Giving an action to any other notification needs a request code apart from these.
const _pinnedIdBase = 0x60000000;
const _pinnedIdMask = 0x0FFFFFFF;

/// The target a notification offering the direct reply answers: account [uid] and the floor (`<uid>:p:<tid>:<pid>`) or
/// the conversation (`<uid>:m:<peer>`) of [target]; null when it names neither.
String? directReplyTargetKey(int uid, LocalNoticeTarget target) {
  final tid = target.tid;
  final pid = target.pid;
  final peer = target.peerUid;
  if (tid != null && pid != null) {
    return '$uid:p:$tid:$pid';
  }
  if (peer != null) {
    return '$uid:m:$peer';
  }
  return null;
}

/// Id of the notification offering the direct reply to the target [key] ([directReplyTargetKey]): its own, derived
/// from the target alone (FNV-1a), so a newer item of the same target updates it and an item of any other target never
/// does.
///
/// Why its own: the plugin makes the request code of an action's PendingIntent from the notification id
/// (`id * 16`, `FLAG_UPDATE_CURRENT`), so a notification posted under the id of another one rewrites the extras of the
/// other's action: a reply typed in the older one would go to the newer one's target. A notification carrying the
/// action is therefore never posted under an id that holds another target ([DirectReplyPins]).
int directReplyNoticeIdOf(String key) {
  var hash = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return _pinnedIdBase | (hash & _pinnedIdMask);
}

/// Whether [id] is the id of a notification offering the direct reply ([directReplyNoticeIdOf]).
bool isDirectReplyNoticeId(int? id) => id != null && (id & ~_pinnedIdMask) == _pinnedIdBase;

/// Tag of the notification offering the direct reply to the target [key], announced in the auto sync [slot] (the
/// account of a notification naming its account, 0 for the one of the account in use): the auto sync takes back the
/// notifications of its slot it replaces by tag ([replaceDirectReplySlot]).
String directReplyTag(int slot, String key) => '$_tagPrefix$slot:$key';

const _tagPrefix = 'dr:';

/// Which target each id of the notifications offering the direct reply was given to, kept in the settings table so the
/// app and the background message service (which both post them) and the isolate of the reply (which checks them)
/// read the same: an id holds one target as long as its notification may still be in the shade ([keepFor]) or is shown.
///
/// The name of the setting is [settingsKey]; the value is `{"<id>": {"k": "<target key>", "at": <ms>}}`.
final class DirectReplyPins {
  /// Constructor.
  DirectReplyPins(this._storage, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final StorageProvider _storage;
  final DateTime Function() _now;

  /// Name of the setting.
  static const settingsKey = 'directReplyPinnedNotices';

  /// How long an id stays given to its target after its last notification. A reply typed in a notification older than
  /// that is not sent ([holds] says no): the text goes to the app.
  static const keepFor = Duration(days: 7);

  Future<Map<String, ({String key, int at})>> _read() async {
    final raw = await _storage.getString(settingsKey);
    final pins = <String, ({String key, int at})>{};
    if (raw == null || raw.isEmpty) {
      return pins;
    }
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        final oldest = _now().subtract(keepFor).millisecondsSinceEpoch;
        for (final MapEntry(:key, :value) in json.entries) {
          if (value is Map<String, dynamic> && value['k'] is String && value['at'] is int) {
            final at = value['at'] as int;
            if (at >= oldest) {
              pins[key] = (key: value['k'] as String, at: at);
            }
          }
        }
      }
    } on Object catch (e) {
      talker.warning('direct reply: pinned notices unreadable, started over: $e');
    }
    return pins;
  }

  /// Give [id] to the target [key] when it holds no other one, neither here nor as a notification still shown
  /// ([shown]: the ids and tags in the shade, none read when null). False when it holds another target: the
  /// notification is then posted without the action, as any other one.
  Future<bool> claim(int id, String key, {List<({int? id, String? tag})>? shown}) async {
    final pins = await _read();
    final held = pins['$id'];
    if (held != null && held.key != key) {
      return false;
    }
    final other = shown?.any((e) => e.id == id && e.tag != null && !e.tag!.endsWith(':$key')) ?? false;
    if (other) {
      return false;
    }
    pins['$id'] = (key: key, at: _now().millisecondsSinceEpoch);
    await _storage.saveString(
      settingsKey,
      jsonEncode({
        for (final MapEntry(:key, :value) in pins.entries) key: {'k': value.key, 'at': value.at},
      }),
    );
    return true;
  }

  /// Whether [id] was given to the target [key] ([claim]): the action of the notification under [id] answers that
  /// target and no other.
  Future<bool> holds(int id, String key) async => (await _read())['$id']?.key == key;
}

/// Take back the notifications of the auto sync [slot] a new one replaces, before it is posted under [id] (with [tag]
/// when it offers the direct reply): the other notifications of the slot offering the direct reply, and, for one
/// offering it, the notification of the slot without it ([sharedId], `localNoticeId` or `localNoticeIdOf`). What was
/// one notification per slot stays one; a reply being typed in a notification taken back is lost, never sent to the
/// target of the new one. [shown] are the ids and tags in the shade.
Future<void> replaceDirectReplySlot(
  FlutterLocalNotificationsPlugin plugin, {
  required int slot,
  required int sharedId,
  required int id,
  required String? tag,
  required List<({int? id, String? tag})> shown,
}) async {
  final prefix = '$_tagPrefix$slot:';
  for (final n in shown) {
    final nid = n.id;
    final ntag = n.tag;
    // Of this slot, or under the same id with another tag (the same target announced in another slot before the
    // accounts announced changed).
    final replaced =
        ntag != null && (ntag.startsWith(prefix) || (tag != null && nid == id && ntag.startsWith(_tagPrefix)));
    if (nid != null && replaced && !(nid == id && ntag == tag)) {
      await plugin.cancel(id: nid, tag: ntag);
    }
  }
  if (tag != null && shown.any((e) => e.id == sharedId && e.tag == null)) {
    await plugin.cancel(id: sharedId);
  }
}

/// Whether [id] is the id of a notification telling how a direct reply went ([DirectReplyRequest.resultNoticeId]).
bool isDirectReplyResultNoticeId(int? id) =>
    id != null && (id & ~(_resultIdMask | _resultConversationBit)) == _resultIdBase;

/// Whether the notification of [info] is one the user can answer from the notification: a single new reply, quote or
/// mention naming its floor, or a single new private message naming its peer. Several new items, a broadcast message,
/// any other notice are not.
bool directReplyFits(NotificationAutoSyncInfo info) {
  if (info.total != 1) {
    return false;
  }
  return switch (info) {
    NotificationAutoSyncInfoNotice(:final noticeType, :final fromIdType, :final tid, :final pid) =>
      tid != null &&
          pid != null &&
          noticeKindRepliable(
            noticeKindOf(
              type: noticeType,
              fromIdType: fromIdType,
              target: NoticeTarget(tid: tid, pid: pid),
            ),
          ),
    NotificationAutoSyncInfoPm(:final peerUid) => peerUid != null,
    NotificationAutoSyncInfoBm() => false,
  };
}

/// Whether the notifications posted now offer the direct reply: Android, the setting on
/// (`SettingsKeys.notificationDirectReply`) and no app lock (a locked app sends nothing before it is unlocked).
///
/// Read from [storage] (the one of this isolate in `getIt` by default) and the app lock file each time: the app and
/// the background message service both post the notifications, and either may have changed them.
Future<bool> directReplyOffered({StorageProvider? storage, Future<bool> Function()? locked}) async {
  if (!isAndroid) {
    return false;
  }
  final store = storage ?? (getIt.isRegistered<StorageProvider>() ? getIt.get<StorageProvider>() : null);
  if (store == null || !await directReplyEnabled(store)) {
    return false;
  }
  return !await (locked ?? appLocked)();
}

/// Whether the setting of the direct reply is on in [storage].
Future<bool> directReplyEnabled(StorageProvider storage) async =>
    await storage.getBool(SettingsKeys.notificationDirectReply.name) ??
    SettingsKeys.notificationDirectReply.defaultValue;

/// Whether the app lock is on (the file of this device, readable from any isolate); a lock file that can not be read
/// counts as locked ([AppLockStore.lockedFailClosed]): nothing is sent without unlocking.
Future<bool> appLocked({AppLockStore? store}) => (store ?? AppLockStore()).lockedFailClosed();

/// The action of the direct reply, with the texts of [translations].
///
/// Handled in the plugin's own isolate (`showsUserInterface: false`); the notification is taken away when it is sent
/// (`cancelNotification`), the outcome is a notification of its own ([showDirectReplyOutcome]): a newer notification
/// posted under the same id meanwhile is never written over.
AndroidNotificationAction directReplyActionOf(Translations translations) {
  final label = translations.localNotification.directReply.action;
  return AndroidNotificationAction(
    directReplyActionId,
    label,
    inputs: [AndroidNotificationActionInput(label: label)],
    semanticAction: SemanticAction.reply,
  );
}

/// The reply link of floor [pid] of thread [tid]: the reply window quoting the floor, as the floor's own reply link
/// (the forum names the forum itself).
String directReplyActionUrl({required int tid, required int pid}) =>
    'forum.php?mod=post&action=reply&tid=$tid&repquote=$pid';

/// A reply typed in a notification: [message] for account [uid], to the floor ([LocalNoticeTarget.tid] and
/// [LocalNoticeTarget.pid]) or the conversation ([LocalNoticeTarget.peerUid]) of [target].
final class DirectReplyRequest {
  /// Constructor.
  const DirectReplyRequest({required this.uid, required this.target, required this.message, int? noticeId})
    : _noticeId = noticeId;

  final int? _noticeId;

  /// Id of the notification the reply was typed in ([directReplyNoticeIdOf] of [targetKey]).
  int get noticeId => _noticeId ?? directReplyNoticeIdOf(targetKey);

  /// The target ([directReplyTargetKey]).
  String get targetKey => directReplyTargetKey(uid, target)!;

  /// The request of the action [response], null when it is none: another action, no text, a notification that is
  /// not one of the auto sync (a watched forum's, a followed thread's) or a payload naming no account or no floor or
  /// conversation.
  static DirectReplyRequest? of(NotificationResponse response) {
    // Only the notifications offering it carry the action, each under the id of its target ([directReplyNoticeIdOf]).
    final id = response.id;
    if (response.actionId != directReplyActionId || id == null || !isDirectReplyNoticeId(id)) {
      return null;
    }
    final message = response.input?.trim() ?? '';
    if (message.isEmpty) {
      return null;
    }
    final uid = LocalNoticeKeys.parseOpenNotification(response.payload)?.uid;
    final target = LocalNoticeKeys.parseTarget(response.payload);
    if (uid == null || target == null) {
      return null;
    }
    final floor = target.tid != null && target.pid != null;
    if (!floor && target.peerUid == null) {
      return null;
    }
    final key = directReplyTargetKey(uid, target)!;
    if (directReplyNoticeIdOf(key) != id) {
      // The payload names another target than the one the id was made for: never sent anywhere.
      talker.warning('direct reply: the target does not match the notification, dropped');
      return null;
    }
    return DirectReplyRequest(
      noticeId: id,
      uid: uid,
      target: LocalNoticeTarget(
        nid: target.nid,
        tid: floor ? target.tid : null,
        pid: floor ? target.pid : null,
        peerUid: floor ? null : target.peerUid,
      ),
      message: message,
    );
  }

  /// The account replying: the one the notification is about, whichever is in use.
  final int uid;

  /// The floor or the conversation.
  final LocalNoticeTarget target;

  /// What was typed.
  final String message;

  /// Whether this is a private message.
  bool get toConversation => target.pid == null;

  /// Id of the notification telling how it went: one per account and floor (or conversation).
  int get resultNoticeId =>
      _resultIdBase |
      (toConversation ? _resultConversationBit : 0) |
      ((uid * 1000003 + (target.pid ?? target.peerUid ?? 0)) & _resultIdMask);

  /// Payload of the notification telling it was sent: a tap opens the floor or the conversation as that account.
  String get payload => LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotificationOf(uid), target);

  /// Payload of the notification telling it was not sent: as [payload], carrying the text ([LocalNoticeTarget.draft])
  /// so a tap keeps it as the draft of the floor or the conversation.
  String get failedPayload => LocalNoticeKeys.withTarget(
    LocalNoticeKeys.openNotificationOf(uid),
    LocalNoticeTarget(
      nid: target.nid,
      tid: target.tid,
      pid: target.pid,
      peerUid: target.peerUid,
      draft: message,
    ),
  );

  /// [failedPayload] of a reply that may have reached the forum: the draft kept from it says so.
  String get unconfirmedPayload => LocalNoticeKeys.withTarget(
    LocalNoticeKeys.openNotificationOf(uid),
    LocalNoticeTarget(
      nid: target.nid,
      tid: target.tid,
      pid: target.pid,
      peerUid: target.peerUid,
      draft: message,
      maybeSent: true,
    ),
  );
}

/// How a direct reply went.
sealed class DirectReplyOutcome {
  const DirectReplyOutcome();
}

/// The forum took it.
final class DirectReplySent extends DirectReplyOutcome {
  /// Constructor.
  const DirectReplySent();
}

/// Not sent, for [reason]: the forum's own words when it told them.
final class DirectReplyNotSent extends DirectReplyOutcome {
  /// Constructor.
  const DirectReplyNotSent(this.reason);

  /// What the notification says.
  final String reason;
}

/// Sent, but nothing came back to tell whether the forum took it (a timeout after the request left, a server error,
/// a redirect): said apart from a reply that was not sent, so it is not sent twice unknowingly.
final class DirectReplyUnconfirmed extends DirectReplyOutcome {
  /// Constructor.
  const DirectReplyUnconfirmed();
}

/// Whether the failure [e] of a post may hide a stored reply or message: the request left and nothing (or a server
/// error, a redirect) came back. The same rule as the reply bar's `maybeSent`; the reply window and a forum that could
/// not be reached at all mean nothing was posted.
bool directReplyMayHaveSent(AppException e) => switch (e) {
  ReplyWindowFetchFailedException() => false,
  HttpHandshakeFailedException(statusCode: null) ||
  HttpRequestFailedException(statusCode: null) => !isNoNetworkFailure(e),
  HttpHandshakeFailedException(:final statusCode?) ||
  HttpRequestFailedException(:final statusCode?) => statusCode >= 500 || (statusCode >= 300 && statusCode < 400),
  _ => false,
};

/// Post the message of a [DirectReplyRequest] with the client of its account.
typedef DirectReplySend =
    Future<Either<AppException, void>> Function(NetClientProvider client, DirectReplyRequest request);

/// [DirectReplySend] of the app: the reply window of the floor and its post ([ReplyRepository.replyToPost]), or the
/// chat dialog and the message ([ShareThreadRepository.sendToFriend], the two steps of the chat page), as the
/// request's account. Each posts once (`singleAttempt`).
Future<Either<AppException, void>> sendDirectReplyWith(NetClientProvider client, DirectReplyRequest request) async {
  final reply = ReplyRepository(client: client, owner: request.uid, postForm: true);
  final target = request.target;
  final tid = target.tid;
  final pid = target.pid;
  if (tid != null && pid != null) {
    final result = await reply
        .replyToPost(
          replyParameters: ReplyParameters(
            // The window names the forum: the old path posts to the thread without it, which the forum takes too.
            fid: '',
            tid: '$tid',
            postTime: null,
            formHash: '',
            subject: '',
            viewerUid: request.uid,
          ),
          replyAction: directReplyActionUrl(tid: tid, pid: pid),
          replyMessage: request.message,
        )
        .run();
    return result.map((_) {});
  }
  return ShareThreadRepository(
    chatRepository: ChatRepository(client: client),
    replyRepository: reply,
  ).sendToFriend(uid: '${target.peerUid}', message: request.message).run();
}

/// Send [request] and tell how it went, with the texts of [translations].
///
/// Nothing is sent when the setting was turned off ([enabled]) or the app was locked ([locked]) since the
/// notification was posted, nor for an account no longer on this device ([clientOf] gives no client): the text waits
/// in the app. A captcha, a security question or a window the app can not fill are for the app too; any other
/// refusal says the forum's words.
Future<DirectReplyOutcome> runDirectReply(
  DirectReplyRequest request, {
  required Translations translations,
  required Future<bool> Function() enabled,
  required Future<bool> Function() locked,
  required Future<NetClientProvider?> Function(int uid) clientOf,
  required Future<bool> Function() pinned,
  DirectReplySend send = sendDirectReplyWith,
}) async {
  final tr = translations.localNotification.directReply;
  if (!await pinned()) {
    // The id of the notification was not given to this target ([DirectReplyPins.holds]): whatever the action carries,
    // it is not sent.
    talker.warning('direct reply: the notification does not hold this target, not sent');
    return DirectReplyNotSent(tr.openApp);
  }
  if (!await enabled()) {
    return DirectReplyNotSent(tr.openApp);
  }
  if (await locked()) {
    return DirectReplyNotSent(tr.locked);
  }
  final client = await clientOf(request.uid);
  if (client == null) {
    return DirectReplyNotSent(translations.localNotification.accountGone);
  }
  final Either<AppException, void> result;
  try {
    result = await send(client, request);
  } on Object catch (e, st) {
    talker.handle(e, st, 'direct reply: sending threw');
    return DirectReplyNotSent(tr.error);
  }
  switch (result) {
    case Right():
      return const DirectReplySent();
    case Left(value: ReplyNeedsVerificationException() || ReplyNeedsBrowserException()):
      return DirectReplyNotSent(tr.openApp);
    case Left(:final value)
        when value is ReplyToPostResultFailedException ||
            value is ReplyToPostFetchParameterFailedException ||
            value is ReplyPersonalMessageFailedException:
      final reason = value.message?.trim() ?? '';
      return DirectReplyNotSent(reason.isEmpty || reason == 'unknown error' ? tr.error : reason);
    case Left(:final value) when directReplyMayHaveSent(value):
      talker.warning('direct reply: result unknown, ${value.runtimeType}');
      return const DirectReplyUnconfirmed();
    case Left(:final value):
      talker.warning('direct reply: not sent, ${value.runtimeType}');
      return DirectReplyNotSent(tr.error);
  }
}

/// What is posted for the outcome of a [DirectReplyRequest]: id, title, body, payload, and whether it is the quiet
/// "sent" one that goes away by itself.
typedef DirectReplyOutcomeContent = ({int id, String title, String body, String payload, bool sent});

/// The notification telling [outcome] of [request], with the texts of [translations].
///
/// Sent: "已回复" and the text, quiet, gone after a few seconds; a tap opens the floor or the conversation. Not sent:
/// the reason (the forum's words) under "回复未发送", and a tap opens the floor's reply page or the conversation with the
/// text kept as its draft.
DirectReplyOutcomeContent directReplyOutcomeContentOf(
  Translations translations,
  DirectReplyRequest request,
  DirectReplyOutcome outcome,
) {
  final tr = translations.localNotification.directReply;
  return switch (outcome) {
    DirectReplySent() => (
      id: request.resultNoticeId,
      title: tr.sent,
      body: request.message,
      payload: request.payload,
      sent: true,
    ),
    DirectReplyNotSent(:final reason) => (
      id: request.resultNoticeId,
      title: tr.failed,
      body: reason,
      payload: request.failedPayload,
      sent: false,
    ),
    // The words of the chat page for a message whose result is unknown; the draft kept from it says it may be sent.
    DirectReplyUnconfirmed() => (
      id: request.resultNoticeId,
      title: tr.unconfirmed,
      body: translations.chatPage.maybeSent,
      payload: request.unconfirmedPayload,
      sent: false,
    ),
  };
}

/// How long the notification telling a reply was sent stays.
const directReplySentShownFor = Duration(seconds: 4);

/// Post the notification telling [outcome] of [request] through [plugin], in the channel of replies or of private
/// messages.
Future<void> showDirectReplyOutcome({
  required FlutterLocalNotificationsPlugin plugin,
  required Translations translations,
  required DirectReplyRequest request,
  required DirectReplyOutcome outcome,
}) async {
  final content = directReplyOutcomeContentOf(translations, request, outcome);
  final category = request.toConversation ? NoticeCategory.pm : NoticeCategory.reply;
  await plugin.show(
    id: content.id,
    title: content.title,
    body: content.body,
    payload: content.payload,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        category.channelId,
        noticeChannelName(translations, category),
        channelDescription: translations.localNotification.channelDesc,
        importance: Importance.high,
        priority: content.sent ? Priority.low : Priority.high,
        visibility: NotificationVisibility.private,
        silent: content.sent,
        timeoutAfter: content.sent ? directReplySentShownFor.inMilliseconds : null,
        styleInformation: BigTextStyleInformation(content.body, contentTitle: content.title),
      ),
    ),
  );
}
