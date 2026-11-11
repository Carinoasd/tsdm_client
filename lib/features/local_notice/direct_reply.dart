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
/// The name of the setting is [settingsKey]; the value is `{"<id>": {"k": "<target key>", "at": <ms>, "s": <slot>}}`
/// (the slot the notification was last announced in, absent when written by an older version).
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

  Future<Map<String, ({String key, int at, int? slot})>> _read() async {
    final raw = await _storage.getString(settingsKey);
    final pins = <String, ({String key, int at, int? slot})>{};
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
              pins[key] = (
                key: value['k'] as String,
                at: at,
                slot: switch (value['s']) {
                  final int slot => slot,
                  _ => null,
                },
              );
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
  /// notification is then posted without the action, as any other one. [slot] is the auto sync slot it is announced
  /// in, kept for [tagOf].
  Future<bool> claim(int id, String key, {int? slot, List<({int? id, String? tag})>? shown}) async {
    final pins = await _read();
    final held = pins['$id'];
    if (held != null && held.key != key) {
      return false;
    }
    final other = shown?.any((e) => e.id == id && e.tag != null && !e.tag!.endsWith(':$key')) ?? false;
    if (other) {
      return false;
    }
    pins['$id'] = (key: key, at: _now().millisecondsSinceEpoch, slot: slot ?? held?.slot);
    await _storage.saveString(
      settingsKey,
      jsonEncode({
        for (final MapEntry(:key, :value) in pins.entries) key: {'k': value.key, 'at': value.at, 's': ?value.slot},
      }),
    );
    return true;
  }

  /// The tag the notification under [id] was last posted with ([directReplyTag] of the slot and the target given to
  /// [claim]), null when the id is given to no target or its slot was not kept. The action of a notification does
  /// not carry its tag, and a notification taken back is not in the shade to read it from.
  Future<String?> tagOf(int id) async {
    final pin = (await _read())['$id'];
    final slot = pin?.slot;
    return pin == null || slot == null ? null : directReplyTag(slot, pin.key);
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
/// Handled in the plugin's own isolate (`showsUserInterface: false`). The plugin does not take the notification away
/// when the text is sent (`cancelNotification: false`): the isolate does, once the reply is dealt with
/// ([RepliedNotice]). The outcome is a notification of its own ([showDirectReplyOutcome]): a newer notification posted
/// under the same id meanwhile is never written over.
AndroidNotificationAction directReplyActionOf(Translations translations) {
  final label = translations.localNotification.directReply.action;
  return AndroidNotificationAction(
    directReplyActionId,
    label,
    inputs: [AndroidNotificationActionInput(label: label)],
    semanticAction: SemanticAction.reply,
    cancelNotification: false,
  );
}

/// How long the notification a reply was typed in stays in the shade without its action ([RepliedNotice.seal]) before
/// it is taken back ([RepliedNotice.remove]): the time the system needs to show the update, which is what ends the
/// "sending" state of its text input.
const directReplySealedFor = Duration(seconds: 1);

/// A notification offering the direct reply as the shade holds it.
typedef _HeldNotice = ({String tag, String? channelId, String? title, String? body, String? bigText});

/// What the notification a reply was typed in says once it is closed, when what it said before is not known
/// ([RepliedNotice.seal]): the outcome of the reply, in the channel of the outcome.
typedef RepliedNoticeTold = ({String title, String body, NoticeCategory category});

/// The notification a reply was typed in, from the moment the reply reaches the isolate to the moment the
/// notification leaves the shade.
///
/// It can not simply be cancelled. Measured on the Android 14 emulator (`dumpsys activity service
/// com.android.systemui`): once a text is sent from a notification, the system UI shows its input as "sending" until
/// the app posts the notification again, and a notification cancelled by its app in that state is not removed. The
/// system UI keeps it (`lifetimeExtenders=[RemoteInputHistory]`, `cancellationReason=8`), writes the text under it and
/// offers the action again, until the user swipes it away. Posted again and cancelled at once, it is kept all the
/// same; posted again and cancelled a second later, it goes. So it is posted once more under the same id and tag, as
/// it was but without the action ([seal]), and cancelled once the system has shown that ([remove]).
///
/// The notification is read from the shade when the reply arrives ([of]): the action carries neither its tag nor its
/// texts. A newer item of the same target posted under the same id and tag while the reply was sent is told by its
/// texts and left alone.
///
/// A notification the app took back before the reply was sent (a newer result of its slot arrived while the user was
/// typing, [replaceDirectReplySlot]) is kept by the system UI too, and is not in the shade to be read: its tag is
/// then the one its id was last posted with ([DirectReplyPins.tagOf]), and it is posted again saying the outcome.
final class RepliedNotice {
  RepliedNotice._(this._plugin, this.id, this._held, this._lastTag);

  final FlutterLocalNotificationsPlugin _plugin;

  /// Id of the notification ([directReplyNoticeIdOf]).
  final int id;

  /// What the shade held under [id] when the reply arrived; null when it could not be read.
  final List<_HeldNotice>? _held;

  /// The tag [id] was last posted with, asked for when the shade holds nothing under [id].
  final Future<String?> Function()? _lastTag;

  /// What [seal] posted again without the action, with the texts it was posted with, and when.
  final _sealed = <_HeldNotice>[];
  DateTime? _sealedAt;
  bool _sealing = false;

  /// The notification under [id] (the id of the action's response, null for none) as the shade of [plugin] holds it
  /// now. [lastTag] gives the tag [id] was last posted with ([DirectReplyPins.tagOf]).
  static Future<RepliedNotice?> of(
    FlutterLocalNotificationsPlugin plugin,
    int? id, {
    Future<String?> Function()? lastTag,
  }) async {
    if (id == null || !isDirectReplyNoticeId(id)) {
      return null;
    }
    List<_HeldNotice>? held;
    try {
      held = await _read(plugin, id);
    } on Object catch (e) {
      talker.warning('direct reply: shade not read: $e');
    }
    return RepliedNotice._(plugin, id, held, lastTag);
  }

  static Future<List<_HeldNotice>> _read(FlutterLocalNotificationsPlugin plugin, int id) async => [
    for (final n in await plugin.getActiveNotifications())
      if (n.id == id)
        if (n.tag case final tag? when tag.startsWith(_tagPrefix))
          (tag: tag, channelId: n.channelId, title: n.title, body: n.body, bigText: n.bigText),
  ];

  static bool _sameTexts(_HeldNotice a, _HeldNotice b) => a.title == b.title && a.body == b.body;

  /// Post the notification again without its action, with the texts it had and the channel names of [translations]:
  /// the text input is closed, nothing more can be typed in it. A tap opens [payload].
  ///
  /// A notification taken back meanwhile (by a newer result of its slot, [replaceDirectReplySlot]) is posted too,
  /// silently: the system UI may still be keeping it. One whose texts changed is a newer item and is left as it is.
  /// When the shade held nothing under the id, the notification under the tag the id was last posted with is posted
  /// saying [told], silently, if [told] is given. Done once: a second call does nothing.
  ///
  /// When the shade could not be read as the reply arrived, what it holds under the id now is what is closed: a newer
  /// item posted meanwhile can not be told from the one answered then, and is taken back with it. Chosen over leaving
  /// the answered one in the shade for good; both need the shade to fail and a newer item to come within the seconds
  /// of the reply.
  Future<void> seal(Translations translations, {String? payload, RepliedNoticeTold? told}) async {
    if (_sealing) {
      return;
    }
    _sealing = true;
    try {
      final now = await _read(_plugin, id);
      final held = _held ?? now;
      for (final notice in held) {
        final current = now.where((e) => e.tag == notice.tag).firstOrNull;
        if (current != null && !_sameTexts(current, notice)) {
          continue;
        }
        // Android 7 has no channels and tells none: any will do there.
        final category = notice.channelId == null
            ? NoticeCategory.reply
            : NoticeCategory.values.where((e) => e.channelId == notice.channelId).firstOrNull;
        if (category == null) {
          // Not a channel of the auto sync: nothing to post it in, taken back as it is.
          await _plugin.cancel(id: id, tag: notice.tag);
          continue;
        }
        await _post(translations, notice, category, payload: payload, shown: current != null);
      }
      if (held.isEmpty && told != null) {
        final tag = await _lastTag?.call();
        if (tag != null && now.every((e) => e.tag != tag)) {
          await _post(
            translations,
            (tag: tag, channelId: told.category.channelId, title: told.title, body: told.body, bigText: null),
            told.category,
            payload: payload,
            shown: false,
          );
        }
      }
    } on Object catch (e) {
      talker.warning('direct reply: closing the notification failed: $e');
    } finally {
      _sealedAt = DateTime.now();
    }
  }

  /// The notification as [showLocalNotificationWith] posts one offering the direct reply, less the action: a single
  /// item ([directReplyFits]), so the whole body in the big text style, never the list of several items.
  Future<void> _post(
    Translations translations,
    _HeldNotice notice,
    NoticeCategory category, {
    required String? payload,
    required bool shown,
  }) async {
    final body = notice.body;
    await _plugin.show(
      id: id,
      title: notice.title,
      body: body,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          category.channelId,
          noticeChannelName(translations, category),
          channelDescription: translations.localNotification.channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
          onlyAlertOnce: true,
          // Posted anew when the app had taken it back: never announced a second time.
          silent: !shown,
          styleInformation: body == null
              ? null
              : BigTextStyleInformation(notice.bigText ?? body, contentTitle: notice.title),
          tag: notice.tag,
        ),
      ),
    );
    _sealed.add(notice);
  }

  /// Take back what [seal] posted, once it was shown for [shownFor]; a newer item posted under the same id and tag
  /// meanwhile stays.
  Future<void> remove({Duration shownFor = directReplySealedFor}) async {
    final sealedAt = _sealedAt;
    if (sealedAt == null || _sealed.isEmpty) {
      return;
    }
    final left = shownFor - DateTime.now().difference(sealedAt);
    if (left > Duration.zero) {
      await Future<void>.delayed(left);
    }
    try {
      final now = await _read(_plugin, id);
      for (final sealed in _sealed) {
        final current = now.where((e) => e.tag == sealed.tag).firstOrNull;
        if (current != null && _sameTexts(current, sealed)) {
          await _plugin.cancel(id: id, tag: sealed.tag);
        }
      }
    } on Object catch (e) {
      talker.warning('direct reply: taking back the notification failed: $e');
    } finally {
      _sealed.clear();
    }
  }
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
  String get failedPayload => failedPayloadOf();

  /// [failedPayload] naming the failure [draftEvent] the text was kept under for the app
  /// ([LocalNoticeTarget.draftEvent]); [maybeSent] for a reply that may have reached the forum.
  String failedPayloadOf({String? draftEvent, bool maybeSent = false}) => LocalNoticeKeys.withTarget(
    LocalNoticeKeys.openNotificationOf(uid),
    LocalNoticeTarget(
      nid: target.nid,
      tid: target.tid,
      pid: target.pid,
      peerUid: target.peerUid,
      draft: message,
      maybeSent: maybeSent,
      draftEvent: draftEvent,
    ),
  );

  /// [failedPayload] of a reply that may have reached the forum: the draft kept from it says so.
  String get unconfirmedPayload => failedPayloadOf(maybeSent: true);
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
///
/// [draftEvent] is the id the text of a reply not sent was kept under for the app ([LocalNoticeTarget.draftEvent]).
DirectReplyOutcomeContent directReplyOutcomeContentOf(
  Translations translations,
  DirectReplyRequest request,
  DirectReplyOutcome outcome, {
  String? draftEvent,
}) {
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
      payload: request.failedPayloadOf(draftEvent: draftEvent),
      sent: false,
    ),
    // The words of the chat page for a message whose result is unknown; the draft kept from it says it may be sent.
    DirectReplyUnconfirmed() => (
      id: request.resultNoticeId,
      title: tr.unconfirmed,
      body: translations.chatPage.maybeSent,
      payload: request.failedPayloadOf(draftEvent: draftEvent, maybeSent: true),
      sent: false,
    ),
  };
}

/// What the notification [request] was typed in says when it is closed without its texts being known
/// ([RepliedNotice.seal]): the title and the body of [outcome], in the channel of its notification.
RepliedNoticeTold repliedNoticeToldOf(
  Translations translations,
  DirectReplyRequest request,
  DirectReplyOutcome outcome,
) {
  final content = directReplyOutcomeContentOf(translations, request, outcome);
  return (title: content.title, body: content.body, category: _outcomeCategoryOf(request));
}

NoticeCategory _outcomeCategoryOf(DirectReplyRequest request) =>
    request.toConversation ? NoticeCategory.pm : NoticeCategory.reply;

/// How long the notification telling a reply was sent stays.
const directReplySentShownFor = Duration(seconds: 4);

/// Post the notification telling [outcome] of [request] through [plugin], in the channel of replies or of private
/// messages; [draftEvent] as for [directReplyOutcomeContentOf].
Future<void> showDirectReplyOutcome({
  required FlutterLocalNotificationsPlugin plugin,
  required Translations translations,
  required DirectReplyRequest request,
  required DirectReplyOutcome outcome,
  String? draftEvent,
}) async {
  final content = directReplyOutcomeContentOf(translations, request, outcome, draftEvent: draftEvent);
  final category = _outcomeCategoryOf(request);
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
