import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/modcp_v4.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The pages of the moderation panel (`forum.php?mod=modcp`) beyond the moderation queue: the forums it offers, the
/// recycle bins and the log. Web pages the plugin leaves as they are.
///
/// Bound to the account logged in when each request is made, as [ModerateRepository]: a page served to another account
/// is dropped ([IdentityChangedException]), and an operation is never sent once the account changed. The panel decides
/// everything: the forums offered, deleting for good, the refusals in its own words.
final class ModcpRepository with LoggerMixin {
  /// Constructor; transports are injected so the flow is tested without the forum.
  ModcpRepository({
    required ModerateGet get,
    required ModeratePost post,
    int Function()? currentUid,
    ModerateEnsureStatus? ensureStatus,
  }) : _get = get,
       _post = post,
       _currentUid = currentUid ?? currentLoginUid,
       _ensureStatus = ensureStatus ?? moderateStatusKnown;

  /// Uses the app's client.
  factory ModcpRepository.network() => ModcpRepository(
    get: (url) async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
    post: (url, body) async =>
        switch (await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
        },
    ensureStatus: moderateEnsureStatus,
  );

  final ModerateGet _get;
  final ModeratePost _post;
  final int Function() _currentUid;

  /// Asks the `status` of the forum's app API when it is not known yet ([moderateEnsureStatus]).
  final ModerateEnsureStatus _ensureStatus;

  /// Read [page] of plugin 4.0.0 at [url] for the account logged in, when the last `status` lists it
  /// ([modcpV4Page]); null when the web page is read instead.
  Future<Either<AppException, ModcpAnswer<T>?>> _v4<T>(
    ModcpV4Page page,
    String url,
    T? Function(Map<String, dynamic> json, int uid) read,
  ) => modcpV4Page(page, url, read, get: _get, ensureStatus: _ensureStatus, currentUid: _currentUid);

  /// [_v4], or the web page read by [read] when it is not answered.
  Future<Either<AppException, ModcpAnswer<T>>> _pageOrV4<T>(
    ModcpV4Page page,
    String url,
    T? Function(Map<String, dynamic> json, int uid) fromApi,
    T? Function(uh.Document doc, int uid) read,
  ) async {
    switch (await _v4(page, url, fromApi)) {
      case Left(:final value):
        return left(value);
      case Right(:final value?):
        return right(value);
      case Right(value: null):
        return _page(url, read);
    }
  }

  /// The panel's login, as the moderation queue sends it.
  late final ModerateRepository _moderate = ModerateRepository(get: _get, post: _post, currentUid: _currentUid);

  /// Read [url] for the account logged in and hand its document to [read]; a page served to another account, or the account
  /// changed meanwhile, is an [IdentityChangedException]; the panel's login form a [ModcpNeedsLogin]; a page [read]
  /// does not know is the panel's message ([ModcpRefused]), or a failure without one.
  Future<Either<AppException, ModcpAnswer<T>>> _page<T>(String url, T? Function(uh.Document doc, int uid) read) =>
      _answer(url, (data, uid) => answerOf(data, uid: uid, read: read));

  /// Read [url] for the account logged in and hand the answer as it came to [read], with the account that asked: a
  /// failed request and an account that changed meanwhile ([IdentityChangedException]) never reach it.
  Future<Either<AppException, ModcpAnswer<T>>> _answer<T>(
    String url,
    Either<AppException, ModcpAnswer<T>> Function(Object? data, int uid) read,
  ) async {
    final uid = _currentUid();
    if (uid <= 0) {
      return left(IdentityChangedException());
    }
    final resp = await _get(url);
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return read(value.data, uid);
    }
  }

  /// The answer [data] asked by account [uid], read by [read].
  static Either<AppException, ModcpAnswer<T>> answerOf<T>(
    Object? data, {
    required int uid,
    required T? Function(uh.Document doc, int uid) read,
  }) => _answerOfPage(parseHtmlDocument(tsdmAppAnswerText(data)), uid: uid, read: read);

  /// The panel's page [doc] asked by account [uid], read by [read].
  static Either<AppException, ModcpAnswer<T>> _answerOfPage<T>(
    uh.Document doc, {
    required int uid,
    required T? Function(uh.Document doc, int uid) read,
  }) {
    if (moderatePageUid(doc) case final served? when served != uid) {
      return left(IdentityChangedException());
    }
    if (moderatePanelLoginFormHash(doc) case final formHash?) {
      return right(ModcpNeedsLogin(formHash: formHash));
    }
    if (read(doc, uid) case final value?) {
      return right(ModcpReady(value));
    }
    final message = moderatePageMessage(doc);
    if (message.isNotEmpty) {
      return right(ModcpRefused(message));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// The forums the moderation queue offers (its forum select), to choose the one whose queue is shown.
  AsyncEither<ModcpAnswer<List<ModcpForum>>> fetchQueueForums() => AsyncEither(
    () => _pageOrV4(
      ModcpV4Page.moderate,
      ModerateQueueList.url(ModerateQueueKind.threads, fid: 0),
      (json, _) => json['op'] == ModerateQueueKind.threads.name ? modcpForumsFromApi(json) : null,
      queueForumsOf,
    ),
  );

  /// The forums of the queue's page [doc]; null when it is not the queue.
  static List<ModcpForum>? queueForumsOf(uh.Document doc, int uid) {
    final isQueue = doc
        .querySelectorAll('ul.tb > li.a > a')
        .map((e) => modcpQuery(e.attributes['href'] ?? ''))
        .any((q) => q != null && q['mod'] == 'modcp' && q['action'] == 'moderate');
    return isQueue ? modcpForums(doc).$1 : null;
  }

  /// Read page [page] of bin [kind] of forum [fid] (none for 0: the forums offered only).
  AsyncEither<ModcpAnswer<RecycleBinList>> fetchRecycleBin(RecycleBinKind kind, {int fid = 0, int page = 1}) =>
      AsyncEither(
        () => _pageOrV4(
          ModcpV4Page.bin(kind),
          RecycleBinList.url(kind, fid: fid, page: page),
          (json, uid) => recycleBinFromApi(json, kind, fid: fid, uid: uid, page: page),
          (doc, uid) => parseRecycleBin(doc, kind, fid: fid, uid: uid, page: page),
        ),
      );

  /// The bin [kind] of forum [fid] in answer [data], asked by account [uid].
  static Either<AppException, ModcpAnswer<RecycleBinList>> recycleBinOf(
    Object? data,
    RecycleBinKind kind, {
    required int fid,
    required int uid,
    int page = 1,
  }) {
    // The bin of plugin 4.0.0 drawn again after an operation (or read), the web page otherwise.
    final bin = ModcpV4Page.bin(kind);
    if (tsdmAppV4AnswerOf(data, type: bin.type, schema: bin.schema) case final answer?) {
      if (modcpV4AnswerOf(answer, uid, (json, uid) => recycleBinFromApi(json, kind, fid: fid, uid: uid, page: page))
          case final read?) {
        return read;
      }
    }
    return answerOf(
      data,
      uid: uid,
      read: (doc, uid) => parseRecycleBin(doc, kind, fid: fid, uid: uid, page: page),
    );
  }

  /// Do [action] on the items [ids] of bin [list], once; never when the account changed since the list was served
  /// ([IdentityChangedException]).
  ///
  /// The panel answers with the bin again, no message: what it still lists was not done. The items picked may be on
  /// the pages up to [lastPage]; the answer is the first page and the later ones up to it are read again, as an item
  /// left moves up, never down.
  AsyncEither<RecycleBinOutcome> submitRecycleBin(
    RecycleBinList list,
    RecycleBinAction action,
    List<String> ids, {
    int lastPage = 1,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0 || list.uid != uid || list.fid <= 0) {
      return left(IdentityChangedException());
    }
    final resp = await _post(list.v4 ? withTsdmAppV4Write(list.submitUrl) : list.submitUrl, list.body(action, ids));
    final Object? data;
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        // The panel's session ended: it fails on the fields of the operation before showing its login form.
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        data = value.data;
    }
    if (_currentUid() != uid) {
      return left(IdentityChangedException());
    }
    final listed = <String>{};
    switch (recycleBinOf(data, list.kind, fid: list.fid, uid: uid)) {
      case Left(:final value):
        return left(value);
      case Right(value: ModcpNeedsLogin()):
        return right(const RecycleBinSessionEnded());
      case Right(value: ModcpRefused(:final message)):
        return right(RecycleBinRefused(message));
      case Right(value: ModcpReady(:final value)) when value.fid != list.fid:
        // Not the bin of this forum: nothing to tell what was done.
        return left(HttpRequestFailedException(HttpStatus.ok));
      case Right(value: ModcpReady(:final value)):
        listed.addAll(value.items.map((e) => e.id));
        var more = value.hasNext;
        for (var page = 2; more && page <= lastPage; page++) {
          final next = await fetchRecycleBin(list.kind, fid: list.fid, page: page).run();
          switch (next) {
            case Right(value: ModcpReady(:final value)) when value.fid == list.fid:
              listed.addAll(value.items.map((e) => e.id));
              more = value.hasNext;
            case Left(value: IdentityChangedException()):
              return left(IdentityChangedException());
            default:
              // Sent and answered, but what the later pages hold is not known: not told done. Those still listed on
              // the pages read were not done whatever the others hold.
              final known = ids.where(listed.contains).toList();
              return right(
                known.isEmpty
                    ? const RecycleBinUnknown()
                    : RecycleBinNotDone(done: ids.length - known.length, remaining: known),
              );
          }
        }
    }
    final remaining = ids.where(listed.contains).toList();
    return right(
      remaining.isEmpty
          ? RecycleBinDone(ids.length)
          : RecycleBinNotDone(done: ids.length - remaining.length, remaining: remaining),
    );
  });

  /// Read page [page] of the panel's log, the lines containing [keyword] only when not empty.
  ///
  /// Asked in the JSON mode of the forum's app API: plugin 3.8.0 answers the log as fields ([logOf]), an older plugin
  /// and a forum without one leave the panel's pages alone and answer the web page, read as before. One request
  /// either way.
  AsyncEither<ModcpAnswer<ModcpLogPage>> fetchLog({String keyword = '', int page = 1}) => AsyncEither(
    () => _answer(
      withTsdmAppJson(ModcpLogPage.url(keyword: keyword, page: page)),
      (data, uid) => logOf(data, uid: uid, keyword: keyword, page: page),
    ),
  );

  /// The log in answer [data], asked by account [uid].
  ///
  /// The answer of the forum's app API (plugin 3.8.0), served to [uid] or dropped ([IdentityChangedException]):
  ///
  /// * the log as fields (`type: modcp_log`, `schema` 24: [modcpLogFromApi]);
  /// * the forum's message instead of the panel (`error: message`: no access to the panel, the panel locked after
  ///   too many wrong passwords, the login prompt) is the panel's refusal in its words;
  /// * the panel's own page in the answer's `document` (`error: modcp_login`, the panel's login form;
  ///   `modcp_noperm`, its "no permission"; `modcp_log_storage`, the page's own empty log of a forum that keeps the
  ///   log in files) is read as the web page is.
  ///
  /// Anything else is the web page (an older plugin, no plugin), read as before.
  static Either<AppException, ModcpAnswer<ModcpLogPage>> logOf(
    Object? data, {
    required int uid,
    String keyword = '',
    int page = 1,
  }) {
    ModcpLogPage? read(uh.Document doc, int uid) => parseModcpLog(doc, uid: uid, keyword: keyword, page: page);
    final json = tsdmAppAnswerJson(data);
    if (json == null) {
      return answerOf(data, uid: uid, read: read);
    }
    if (json['uid'] is num && tsdmAppInt(json['uid']) != uid) {
      return left(IdentityChangedException());
    }
    if (modcpLogFromApi(json, keyword: keyword) case final log?) {
      return right(ModcpReady(log));
    }
    if (json['ok'] == 0 && json['error'] == 'message') {
      return right(ModcpRefused(tsdmAppText(json['message']).trim()));
    }
    if (json['document'] is String) {
      return _answerOfPage(tsdmAppPageDocument(json), uid: uid, read: read);
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Log in to the panel with the account's [password] on the login form of form hash [formHash], once.
  AsyncEither<ModeratePanelLogin> loginPanel({required String formHash, required String password}) =>
      _moderate.loginPanel(formHash: formHash, fid: 0, password: password);

  // -------------------------------------------------------------------------------------------------------------------
  // Members, new members, rules and announcements
  // -------------------------------------------------------------------------------------------------------------------

  /// The panel's menu (from its first page): which of its pages the account may use. The panel prints it on its login
  /// form too: read there unless [loggedIn] asks the panel's session first (its login form, [ModcpNeedsLogin]).
  AsyncEither<ModcpAnswer<ModcpMenu>> fetchMenu({bool loggedIn = false}) => AsyncEither(() async {
    const url = '$baseUrl/forum.php?mod=modcp&action=home';
    if (loggedIn) {
      return _page(url, (doc, _) => modcpMenuOf(doc));
    }
    final uid = _currentUid();
    if (uid <= 0) {
      return left(IdentityChangedException());
    }
    switch (await _get(url)) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        final doc = parseHtmlDocument(tsdmAppAnswerText(value.data));
        if (moderatePageUid(doc) case final served? when served != uid) {
          return left(IdentityChangedException());
        }
        if (modcpMenuOf(doc) case final menu?) {
          return right(ModcpReady(menu));
        }
        return answerOf(value.data, uid: uid, read: (_, _) => null);
    }
  });

  /// Look member [query] up on the panel's 禁止用户 page, or its 编辑用户 page when [edit].
  AsyncEither<ModcpAnswer<ModcpMemberLookup>> lookupMember(ModcpMemberQuery query, {bool edit = false}) => AsyncEither(
    () => _pageOrV4(
      ModcpV4Page.member,
      query.url(edit ? 'edit' : 'ban'),
      (json, uid) => memberLookupFromApi(json, uid: uid, edit: edit),
      (doc, uid) => edit ? parseMemberEditPage(doc, uid: uid) : parseMemberBanPage(doc, uid: uid),
    ),
  );

  /// The lookup in answer [data] asked by account [uid] on the 禁止用户 page, or the 编辑用户 page when [edit].
  static Either<AppException, ModcpAnswer<ModcpMemberLookup>> memberLookupOf(
    Object? data, {
    required int uid,
    bool edit = false,
  }) => answerOf(
    data,
    uid: uid,
    read: (doc, uid) => edit ? parseMemberEditPage(doc, uid: uid) : parseMemberBanPage(doc, uid: uid),
  );

  /// Change [member] to [choice] for [days] (null for ever) with [reason], once.
  ///
  /// The panel words the result itself: its message is the verdict (the window is read again afterwards to show the
  /// state).
  AsyncEither<ModcpWriteOutcome> submitMemberBan(
    ModcpMember member,
    ModcpBanChoice choice, {
    int? days,
    String reason = '',
  }) => AsyncEither(() async {
    if (member.form.v4) {
      return _sendV4(
        member.form.uid,
        MemberBanForm.submitUrl,
        member.body(choice, days: days, reason: reason),
        page: ModcpV4Page.member,
        written: _keyOutcome('modcp_member_ban_succeed'),
      );
    }
    final sent = await _send(
      member.form.uid,
      withTsdmAppJsonWrite(MemberBanForm.submitUrl),
      member.body(choice, days: days, reason: reason),
    );
    return sent.map(_messageOutcome);
  });

  /// Save the edit window [form] with [bio] and [signature] (both always sent: the forum writes both), the avatar
  /// cleared when [clearAvatar], once.
  AsyncEither<ModcpWriteOutcome> submitMemberEdit(
    MemberEditForm form, {
    required String bio,
    required String signature,
    bool clearAvatar = false,
  }) => AsyncEither(() async {
    if (form.v4) {
      return _sendV4(
        form.uid,
        MemberEditForm.submitUrl,
        form.body(bio: bio, signature: signature, clearAvatar: clearAvatar),
        page: ModcpV4Page.member,
        written: _keyOutcome('members_edit_succeed'),
      );
    }
    final sent = await _send(
      form.uid,
      withTsdmAppJsonWrite(MemberEditForm.submitUrl),
      form.body(bio: bio, signature: signature, clearAvatar: clearAvatar),
    );
    return sent.map(_messageOutcome);
  });

  /// The panel's 禁止 IP page.
  AsyncEither<ModcpAnswer<IpBanList>> fetchIpBans() => AsyncEither(
    () => _pageOrV4(
      ModcpV4Page.ipban,
      IpBanList.url,
      (json, uid) => ipBanListFromApi(json, uid: uid),
      (doc, uid) => parseIpBanList(doc, uid: uid),
    ),
  );

  /// Ban [ip] for [days], once. The panel draws its page again and prints a line only when adding failed: done when
  /// the list holds a new ban of it.
  ///
  /// The page of plugin 4.0.0 drawn again tells it itself (spec 4.3): done when `result.added`, refused by
  /// `result.error_key` (a malformed IP, a range for an administrator only, banned already) whatever `ok` says.
  AsyncEither<ModcpWriteOutcome> addIpBan(IpBanList list, String ip, int days) => AsyncEither(() async {
    if (list.v4) {
      return _sendV4(
        list.uid,
        IpBanList.url,
        list.addBody(ip, days),
        page: ModcpV4Page.ipban,
        drawn: (json) {
          final result = tsdmAppMap(json['result']);
          if (tsdmAppInt(result['added']) == 1) {
            return const ModcpWriteDone();
          }
          return ModcpWriteRefused(ipBanErrorText(tsdmAppText(result['error_key'])));
        },
      );
    }
    final sent = await _send(list.uid, IpBanList.url, list.addBody(ip, days));
    return sent.map(
      (written) => switch (written) {
        _WrittenPage(:final doc) => switch (parseIpBanList(doc, uid: list.uid)) {
          null => const ModcpWriteUnknown(),
          final now => () {
            final known = {for (final e in list.entries) e.id};
            final added = now.entries.where((e) => !known.contains(e.id)).toList();
            final done =
                added.any((e) => e.ip.toLowerCase() == ip.trim().toLowerCase()) ||
                (added.isNotEmpty && now.ipEcho.isEmpty);
            return done ? ModcpWriteDone(message: now.message) : ModcpWriteRefused(now.message);
          }(),
        },
        final other => _messageOutcome(other),
      },
    );
  });

  /// Delete the IP bans [ids] of [list], once. The panel draws its list again without a word: what it still lists was
  /// not done.
  AsyncEither<ModcpWriteOutcome> deleteIpBans(IpBanList list, List<String> ids) => AsyncEither(() async {
    if (list.v4) {
      return _sendV4(
        list.uid,
        IpBanList.url,
        list.deleteBody(ids),
        page: ModcpV4Page.ipban,
        drawn: (json) => switch (ipBanListFromApi(json, uid: list.uid)) {
          null => const ModcpWriteUnknown(),
          final now => _remaining(ids, now.entries.map((e) => e.id)),
        },
      );
    }
    final sent = await _send(list.uid, IpBanList.url, list.deleteBody(ids));
    return sent.map(
      (written) => switch (written) {
        _WrittenPage(:final doc) => switch (parseIpBanList(doc, uid: list.uid)) {
          null => const ModcpWriteUnknown(),
          final now => _remaining(ids, now.entries.map((e) => e.id)),
        },
        final other => _messageOutcome(other),
      },
    );
  });

  /// Read page [page] of the new members waiting for approval.
  AsyncEither<ModcpAnswer<MemberReviewList>> fetchMemberReview({int page = 1}) => AsyncEither(
    () => _pageOrV4(
      ModcpV4Page.moderate,
      MemberReviewList.url(page: page),
      (json, uid) => memberReviewFromApi(json, uid: uid, page: page),
      (doc, uid) => parseMemberReview(doc, uid: uid, page: page),
    ),
  );

  /// Do [action] on the new members [ids] of [list] with [reason], once.
  ///
  /// The panel says 审核处理完毕 as soon as one of those sent was one it handles, and drops the others without a word:
  /// the list is read again (up to [lastPage], where the members picked may be), and those still waiting were not
  /// done.
  AsyncEither<ModcpWriteOutcome> submitMemberReview(
    MemberReviewList list,
    MemberReviewAction action,
    List<String> ids, {
    String reason = '',
    int lastPage = 1,
  }) => AsyncEither(() async {
    if (list.v4) {
      // Plugin 4.0.0: the forum's verdict by its key (`modcp_mod_succeed`); the list read again tells which.
      final told = await _sendV4(
        list.uid,
        MemberReviewList.submitUrl,
        list.body(action, ids, reason: reason),
        page: ModcpV4Page.moderate,
        written: _keyOutcome('modcp_mod_succeed'),
      );
      switch (told) {
        case Right(value: ModcpWriteDone()):
          break;
        case final other:
          return other;
      }
    } else {
      final sent = await _send(
        list.uid,
        withTsdmAppJsonWrite(MemberReviewList.submitUrl),
        list.body(action, ids, reason: reason),
      );
      final _Written written;
      switch (sent) {
        case Left(:final value):
          return left(value);
        case Right(:final value):
          written = value;
      }
      switch (written) {
        case _WrittenMessage(ok: true):
          break;
        case final other:
          return right(_messageOutcome(other));
      }
    }
    final waiting = <String>{};
    var more = true;
    for (var page = 1; more && page <= lastPage; page++) {
      switch (await fetchMemberReview(page: page).run()) {
        case Right(value: ModcpReady(:final value)):
          waiting.addAll(value.items.map((e) => e.id));
          more = value.hasNext;
        case Left(value: IdentityChangedException()):
          return left(IdentityChangedException());
        default:
          // Sent and taken, but what the pages hold is not known.
          final known = ids.where(waiting.contains).toList();
          return right(
            known.isEmpty
                ? const ModcpWriteUnknown()
                : ModcpWriteNotDone(done: ids.length - known.length, remaining: known),
          );
      }
    }
    return right(_remaining(ids, waiting));
  });

  /// The rules of forum [fid] (0: the forum the panel chooses).
  AsyncEither<ModcpAnswer<ForumRules>> fetchForumRules({int fid = 0}) => AsyncEither(
    () => _pageOrV4(
      ModcpV4Page.editforum,
      ForumRules.url(fid: fid),
      (json, uid) => forumRulesFromApi(json, uid: uid),
      (doc, uid) => parseForumRules(doc, uid: uid),
    ),
  );

  /// Save [text] as the rules of [rules]' forum, once.
  ///
  /// The panel prints 版规更新成功 even when it kept the rules (a group not allowed to change them, its editor then
  /// locked): done when the editor it draws again for the forum is open and holds what was sent, or says so (the
  /// forum turns some BBCode around: tabs to spaces, `[s]`, lists).
  ///
  /// The page of plugin 4.0.0 drawn again tells it itself (spec 4.5): done when `updated` (or the rules it holds are
  /// what was sent), refused when the rules can not be changed.
  AsyncEither<ModcpWriteOutcome> saveForumRules(ForumRules rules, String text) => AsyncEither(() async {
    if (rules.v4) {
      return _sendV4(
        rules.uid,
        ForumRules.submitUrl,
        rules.body(text),
        page: ModcpV4Page.editforum,
        drawn: (json) => switch (forumRulesFromApi(json, uid: rules.uid)) {
          final now? when now.fid == rules.fid && tsdmAppInt(json['updated']) == 1 => const ModcpWriteDone(),
          final now? when now.fid == rules.fid && !now.editable => ModcpWriteRefused(now.note),
          final now? when now.fid == rules.fid && modcpNormalized(now.rules) == modcpNormalized(text) =>
            const ModcpWriteDone(),
          _ => const ModcpWriteUnknown(),
        },
      );
    }
    final sent = await _send(rules.uid, ForumRules.submitUrl, rules.body(text));
    return sent.map(
      (written) => switch (written) {
        _WrittenPage(:final doc) => switch (parseForumRules(doc, uid: rules.uid)) {
          final now? when now.fid == rules.fid && !now.editable => ModcpWriteRefused(now.note),
          final now?
              when now.fid == rules.fid &&
                  (modcpNormalized(now.rules) == modcpNormalized(text) || now.message.isNotEmpty) =>
            ModcpWriteDone(message: now.message),
          _ => const ModcpWriteUnknown(),
        },
        final other => _messageOutcome(other),
      },
    );
  });

  /// The announcements, and the form adding one.
  AsyncEither<ModcpAnswer<AnnouncementList>> fetchAnnouncements() => AsyncEither(
    () => _pageOrV4(
      ModcpV4Page.announcement,
      AnnouncementList.url,
      (json, uid) => announcementsFromApi(json, uid: uid),
      (doc, uid) => parseAnnouncements(doc, uid: uid),
    ),
  );

  /// The form of announcement [id].
  AsyncEither<ModcpAnswer<AnnouncementForm>> fetchAnnouncement(int id) => AsyncEither(
    () => _pageOrV4(
      ModcpV4Page.announcement,
      AnnouncementForm.url(id),
      (json, uid) => announcementFormFromApi(json, id: id, uid: uid),
      (doc, uid) => parseAnnouncementForm(doc, id: id, uid: uid),
    ),
  );

  /// Send the announcement [form] filled in, once: a new one (the list [known] the ids before), or the one edited.
  ///
  /// The panel draws the list again after adding (done when it holds a new announcement), and the form again with
  /// what was sent after editing (the form is read again to see what it keeps).
  AsyncEither<ModcpWriteOutcome> submitAnnouncement(
    AnnouncementForm form, {
    required String subject,
    required AnnouncementType type,
    required String start,
    required String end,
    required String message,
    Set<String> known = const {},
  }) => AsyncEither(() async {
    if (form.v4) {
      // Plugin 4.0.0: the page drawn again tells it (`result.added`, `result.edited`); a refusal is the forum's
      // message (`modcp_ann_empty`, `modcp_ann_urlerror`, `modcp_ann_nofound`).
      return _sendV4(
        form.uid,
        form.submitUrl,
        form.body(subject: subject, type: type, start: start, end: end, message: message),
        page: ModcpV4Page.announcement,
        drawn: (json) {
          final result = tsdmAppMap(json['result']);
          return tsdmAppInt(result[form.id > 0 ? 'edited' : 'added']) == 1
              ? const ModcpWriteDone()
              : const ModcpWriteRefused('');
        },
      );
    }
    final sent = await _send(
      form.uid,
      form.submitUrl,
      form.body(subject: subject, type: type, start: start, end: end, message: message),
    );
    final _Written written;
    switch (sent) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        written = value;
    }
    switch (written) {
      case _WrittenPage(:final doc) when form.id <= 0:
        return right(switch (parseAnnouncements(doc, uid: form.uid)) {
          null => const ModcpWriteUnknown(),
          final list when list.items.any((e) => !known.contains(e.id)) => ModcpWriteDone(message: list.message),
          final list => ModcpWriteRefused(list.message),
        });
      case _WrittenPage():
        switch (await fetchAnnouncement(form.id).run()) {
          case Right(value: ModcpReady(:final value)):
            return right(
              value.holds(subject: subject, type: type, message: message, start: start, end: end)
                  ? const ModcpWriteDone()
                  : const ModcpWriteRefused(''),
            );
          case Left(value: IdentityChangedException()):
            return left(IdentityChangedException());
          default:
            return right(const ModcpWriteUnknown());
        }
      case final other:
        return right(_messageOutcome(other));
    }
  });

  /// Delete the announcements [ids] of [list], once. The panel draws the list again: what it still lists was not done.
  AsyncEither<ModcpWriteOutcome> deleteAnnouncements(AnnouncementList list, List<String> ids) => AsyncEither(() async {
    if (list.v4) {
      return _sendV4(
        list.uid,
        AnnouncementList.deleteUrl,
        list.deleteBody(ids),
        page: ModcpV4Page.announcement,
        drawn: (json) => switch (announcementsFromApi(json, uid: list.uid)) {
          null => const ModcpWriteUnknown(),
          final now => _remaining(ids, now.items.map((e) => e.id)),
        },
      );
    }
    final sent = await _send(list.uid, AnnouncementList.deleteUrl, list.deleteBody(ids));
    return sent.map(
      (written) => switch (written) {
        _WrittenPage(:final doc) => switch (parseAnnouncements(doc, uid: list.uid)) {
          null => const ModcpWriteUnknown(),
          final now => _remaining(ids, now.items.map((e) => e.id)),
        },
        final other => _messageOutcome(other),
      },
    );
  });

  /// Post [body] to [url] for account [uid] once, and read the answer; never when the account changed since the page
  /// was served ([IdentityChangedException]). A status other than 200 is a failure, never sent again: the panel fails
  /// that way on the lists' fields when its session ended (503), nothing done.
  Future<Either<AppException, _Written>> _send(int uid, String url, Map<String, String> body) async {
    if (uid <= 0 || _currentUid() != uid) {
      return left(IdentityChangedException());
    }
    final resp = await _post(url, body);
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return _writtenOf(value.data, uid: uid);
    }
  }

  /// Post [body] to [url] with [tsdmAppV4Query] for account [uid] once, the panel's form of a page of plugin 4.0.0
  /// ([page]), and tell what it answered (spec 4.0, section 8: never by `ok` alone):
  ///
  /// * the write result (`schema` 13) by [written] (the forum's language key), a refusal in its words otherwise;
  /// * the page drawn again by [drawn] (its `result`, `updated`, the list it holds); the panel's login form there is
  ///   [ModcpWriteSessionEnded], the forum's message a refusal in its words;
  /// * anything else as the web page's answer is read ([_writtenOf]).
  Future<Either<AppException, ModcpWriteOutcome>> _sendV4(
    int uid,
    String url,
    Map<String, String> body, {
    required ModcpV4Page page,
    ModcpWriteOutcome Function(TsdmAppWriteResult result)? written,
    ModcpWriteOutcome Function(Map<String, dynamic> json)? drawn,
  }) async {
    if (uid <= 0 || _currentUid() != uid) {
      return left(IdentityChangedException());
    }
    final resp = await _post(withTsdmAppV4Write(url), body);
    final Object? data;
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        data = value.data;
    }
    if (_currentUid() != uid) {
      return left(IdentityChangedException());
    }
    switch (tsdmAppV4WriteOutcomeOf(data, type: page.type, schema: page.schema)) {
      case TsdmAppV4Written(:final result):
        if (result.uid != uid) {
          return left(IdentityChangedException());
        }
        if (result.login) {
          return right(ModcpWriteRefused(result.reason));
        }
        return right(written?.call(result) ?? ModcpWriteRefused(result.reason));
      case TsdmAppV4Redrawn(:final answer):
        if (answer.uid != uid) {
          return left(IdentityChangedException());
        }
        return right(switch (answer) {
          TsdmAppV4Page(:final json) => drawn?.call(json) ?? const ModcpWriteUnknown(),
          TsdmAppV4Refused(error: 'modcp_login') => const ModcpWriteSessionEnded(),
          TsdmAppV4Message(:final reason) => ModcpWriteRefused(reason),
          TsdmAppV4Refused() => const ModcpWriteUnknown(),
        });
      case TsdmAppV4WriteUnknown():
        return _writtenOf(data, uid: uid).map(_messageOutcome);
    }
  }

  /// The outcome of a write result told by its language key: done with [key], a refusal in the forum's words
  /// otherwise.
  static ModcpWriteOutcome Function(TsdmAppWriteResult result) _keyOutcome(String key) =>
      (result) => result.messageKey == key ? ModcpWriteDone(message: result.message) : ModcpWriteRefused(result.reason);

  /// The answer [data] to a change sent by account [uid]: the forum's message, the panel's login form, or its page.
  static Either<AppException, _Written> _writtenOf(Object? data, {required int uid}) {
    final uh.Document doc;
    if (tsdmAppWriteResultOf(data) case final result?) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      switch (result.kind) {
        case TsdmAppWriteKind.message || TsdmAppWriteKind.handle:
          return right(_WrittenMessage(ok: result.succeeded && !result.isError, message: result.reason));
        case TsdmAppWriteKind.redirect:
          // The panel answers these with a message or a page; a redirect is someone else's (the login's).
          return right(result.login ? _WrittenMessage(ok: false, message: result.reason) : const _WrittenUnknown());
        case TsdmAppWriteKind.page:
          doc = result.document;
      }
    } else {
      doc = parseHtmlDocument(tsdmAppAnswerText(data));
    }
    if (moderatePageUid(doc) case final served? when served != uid) {
      return left(IdentityChangedException());
    }
    if (moderatePanelLoginFormHash(doc) != null) {
      return right(const _WrittenLogin());
    }
    if (doc.querySelector('div#messagetext') case final box?) {
      // Success as the panel shows it (`alert_right`, or `alert_info` for the words of its own); anything else a
      // refusal.
      final ok = box.classes.contains('alert_info') || box.classes.contains('alert_right');
      return right(_WrittenMessage(ok: ok, message: moderatePageMessage(doc)));
    }
    if (moderatePageMessage(doc) case final message when message.isNotEmpty) {
      // The panel's own error block (no permission).
      return right(_WrittenMessage(ok: false, message: message));
    }
    return right(_WrittenPage(doc));
  }

  /// The outcome of an answer that is not a page to read: the forum's message, the login form.
  static ModcpWriteOutcome _messageOutcome(_Written written) => switch (written) {
    _WrittenMessage(ok: true, :final message) => ModcpWriteDone(message: message),
    _WrittenMessage(:final message) => ModcpWriteRefused(message),
    _WrittenLogin() => const ModcpWriteSessionEnded(),
    // A page where a message was expected: nothing tells it was done.
    _WrittenPage() => const ModcpWriteRefused(''),
    _WrittenUnknown() => const ModcpWriteUnknown(),
  };

  /// Done when none of [ids] is among [listed] now, otherwise not done for those.
  static ModcpWriteOutcome _remaining(List<String> ids, Iterable<String> listed) {
    final now = listed.toSet();
    final remaining = ids.where(now.contains).toList();
    return remaining.isEmpty
        ? ModcpWriteDone(count: ids.length)
        : ModcpWriteNotDone(done: ids.length - remaining.length, remaining: remaining);
  }
}

/// A change's answer read: the forum's message, the panel's login form, or its page.
sealed class _Written {
  const _Written();
}

final class _WrittenMessage extends _Written {
  const _WrittenMessage({required this.ok, required this.message});

  final bool ok;
  final String message;
}

final class _WrittenLogin extends _Written {
  const _WrittenLogin();
}

final class _WrittenPage extends _Written {
  const _WrittenPage(this.doc);

  final uh.Document doc;
}

final class _WrittenUnknown extends _Written {
  const _WrittenUnknown();
}
