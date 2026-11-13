import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/modcp_v4.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What a form of the panel sent did (`outcome`), and the page the panel drew again after it (`page`, null when it
/// drew none: its login, the forum's message).
typedef ModcpPosted<T> = ({ModcpWriteOutcome outcome, T? page});

/// The message key of the post management's deletion done (not in the X5 language pack: the app words it).
const modcpPostsDeletedKey = 'modcp_thread_delete_succeed';

/// The pages of the moderation panel the forum's app API answers as fields (plugin 3.9.0, second round): the first
/// page and the notes (`modcp_home`), the thread and the post management (`modcp_thread`, `modcp_post`), the members'
/// permissions in a forum (`modcp_forumaccess`).
///
/// Bound to the account logged in, as [ModcpRepository]: an answer served to another account, or an account changed
/// meanwhile, is an [IdentityChangedException]; a form is never sent once the account changed, and sent once (no
/// retry). The panel's password is asked as the panel asks it ([panel]); the panel decides everything else.
final class ModcpPagesRepository {
  /// Constructor; transports are injected so the flow is tested without the forum.
  ModcpPagesRepository({
    required this.panel,
    required ModerateGet get,
    required ModeratePost post,
    int Function()? currentUid,
  }) : _get = get,
       _post = post,
       _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client, with the panel [panel] (its login).
  factory ModcpPagesRepository.network(ModcpRepository panel) => ModcpPagesRepository(
    panel: panel,
    get: (url) async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
    post: (url, body) async =>
        switch (await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
        },
  );

  /// The panel, for its login.
  final ModcpRepository panel;

  final ModerateGet _get;
  final ModeratePost _post;
  final int Function() _currentUid;

  static String _url(String query, {int fid = 0, int page = 1}) => withTsdmAppJson(
    '$baseUrl/forum.php?mod=modcp&$query${fid > 0 ? '&fid=$fid' : ''}${page > 1 ? '&page=$page' : ''}',
  );

  /// The panel's first page.
  static String homeUrl() => _url('action=home');

  /// Page [page] of the threads of forum [fid] (0: the forums to choose from).
  static String threadsUrl({int fid = 0, int page = 1}) => _url('action=thread&op=thread', fid: fid, page: page);

  /// The post management of forum [fid] (0: all the account's).
  static String postsUrl({int fid = 0}) => _url('action=thread&op=post', fid: fid);

  /// Page [page] of the permissions set in forum [fid] (0: the forums to choose from).
  static String accessUrl({int fid = 0, int page = 1}) => _url('action=forumaccess', fid: fid, page: page);

  // -------------------------------------------------------------------------------------------------------------------
  // Reading
  // -------------------------------------------------------------------------------------------------------------------

  /// The panel's first page: what waits, and the notes.
  AsyncEither<ModcpAnswer<ModcpHome>> fetchHome() => AsyncEither(() => _read(homeUrl(), modcpHomeFromApi));

  /// Page [page] of the threads of forum [fid].
  AsyncEither<ModcpAnswer<ModcpThreadPage>> fetchThreads({int fid = 0, int page = 1}) =>
      AsyncEither(() => _read(threadsUrl(fid: fid, page: page), modcpThreadFromApi));

  /// Search the threads of [shown]'s forum for [conditions] (at least one, [ModcpThreadQuery.hasCondition]: the panel
  /// lists the whole forum again without one).
  AsyncEither<ModcpAnswer<ModcpThreadPage>> searchThreads(ModcpThreadPage shown, Map<String, String> conditions) =>
      AsyncEither(() async {
        final search = shown.search;
        if (search == null || shown.needForum || !ModcpThreadQuery.hasCondition(conditions)) {
          return left(HttpRequestFailedException(HttpStatus.badRequest));
        }
        return _read(search.url(shown.fid, conditions), modcpThreadFromApi);
      });

  /// Page [page] of the results of the search of [shown] (the panel keeps them in its session).
  AsyncEither<ModcpAnswer<ModcpThreadPage>> fetchThreadResults(ModcpThreadPage shown, int page) =>
      AsyncEither(() async {
        final url = shown.resultsUrl(page);
        if (url == null) {
          return left(HttpRequestFailedException(HttpStatus.badRequest));
        }
        return _read(url, modcpThreadFromApi);
      });

  /// The post management of forum [fid].
  AsyncEither<ModcpAnswer<ModcpPostPage>> fetchPosts({int fid = 0}) =>
      AsyncEither(() => _read(postsUrl(fid: fid), modcpPostFromApi));

  /// Search the posts of forum [fid] for [conditions] with the form of [shown].
  AsyncEither<ModcpAnswer<ModcpPostPage>> searchPosts(ModcpPostPage shown, int fid, Map<String, String> conditions) =>
      AsyncEither(() async {
        final search = shown.search;
        if (search == null) {
          return left(HttpRequestFailedException(HttpStatus.badRequest));
        }
        return _read(search.url(fid, conditions), modcpPostFromApi);
      });

  /// Page [page] of the results of the search of [shown].
  AsyncEither<ModcpAnswer<ModcpPostPage>> fetchPostResults(ModcpPostPage shown, int page) => AsyncEither(() async {
    final url = shown.resultsUrl(page);
    if (url == null) {
      return left(HttpRequestFailedException(HttpStatus.badRequest));
    }
    return _read(url, modcpPostFromApi);
  });

  /// Page [page] of the permissions set in forum [fid].
  AsyncEither<ModcpAnswer<ModcpAccessPage>> fetchAccess({int fid = 0, int page = 1}) =>
      AsyncEither(() => _read(accessUrl(fid: fid, page: page), modcpAccessFromApi));

  /// The permissions of member [username] in [shown]'s forum (the panel's search is a form posted; it changes
  /// nothing).
  AsyncEither<ModcpAnswer<ModcpAccessPage>> searchAccess(ModcpAccessPage shown, String username) =>
      AsyncEither(() async {
        final form = shown.searchForm;
        final uid = _currentUid();
        if (form == null || shown.needForum) {
          return left(HttpRequestFailedException(HttpStatus.badRequest));
        }
        if (uid <= 0 || shown.uid != uid) {
          return left(IdentityChangedException());
        }
        switch (await _post(form.form.postUrl, form.body(shown.fid, username))) {
          case Left(:final value):
            return left(value);
          case Right(:final value) when value.statusCode != HttpStatus.ok:
            return left(HttpRequestFailedException(value.statusCode));
          case Right(:final value):
            if (_currentUid() != uid) {
              return left(IdentityChangedException());
            }
            return pageOf(value.data, uid: uid, read: modcpAccessFromApi);
        }
      });

  Future<Either<AppException, ModcpAnswer<T>>> _read<T extends ModcpJsonPage>(
    String url,
    T? Function(Map<String, dynamic> json) read,
  ) async {
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
        return pageOf(value.data, uid: uid, read: read);
    }
  }

  /// The page in answer [data], asked by account [uid], read by [read]:
  ///
  /// * the page as fields;
  /// * the forum's message instead of the panel (`error: message`: a guest, a member without the panel, the panel
  ///   locked) is its refusal in its words;
  /// * the panel's login form (`error: modcp_login`) asks the password;
  /// * the panel's "no permission" (`error: modcp_noperm`: the forum's permissions need a group allowed to edit
  ///   members) is its refusal, in the words of the page it attaches, the app's own without one ([modcpErrorText]);
  /// * anything else (an older plugin's web page) is not read: the entries are offered on plugin 3.9.0 only.
  static Either<AppException, ModcpAnswer<T>> pageOf<T extends ModcpJsonPage>(
    Object? data, {
    required int uid,
    required T? Function(Map<String, dynamic> json) read,
  }) {
    final json = tsdmAppAnswerJson(data);
    if (json == null) {
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    if (json['uid'] is num && tsdmAppInt(json['uid']) != uid) {
      // The forum's login ended (the app's account is the same): its login prompt, not another account.
      if (tsdmAppInt(json['uid']) == 0 && json['error'] == 'message' && tsdmAppInt(json['login']) == 1) {
        return right(ModcpRefused(tsdmAppText(json['message']).trim()));
      }
      return left(IdentityChangedException());
    }
    if (read(json) case final page?) {
      return page.uid == uid ? right(ModcpReady(page)) : left(IdentityChangedException());
    }
    if (json['ok'] == 0 && json['error'] == 'message') {
      return right(ModcpRefused(tsdmAppText(json['message']).trim()));
    }
    if (json['ok'] == 0 && (json['error'] == 'modcp_login' || json['error'] == 'modcp_noperm')) {
      final doc = tsdmAppPageDocument(json);
      if (moderatePageUid(doc) case final served? when served != uid) {
        return left(IdentityChangedException());
      }
      if (json['error'] == 'modcp_login') {
        return right(ModcpNeedsLogin(formHash: moderatePanelLoginFormHash(doc) ?? tsdmAppText(json['formhash'])));
      }
      final message = moderatePageMessage(doc);
      return right(ModcpRefused(message.isNotEmpty ? message : modcpErrorText('modcp_noperm')));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  // -------------------------------------------------------------------------------------------------------------------
  // Writing
  // -------------------------------------------------------------------------------------------------------------------

  /// Leave note [message] for [days] days, seen by the super moderators when [toSupermod] and the moderators when
  /// [toModerator], once.
  ///
  /// The panel draws its first page again without a word: done when it lists a note it did not before; not told when
  /// it lists none new (a note the account's own level does not see is not listed to it).
  AsyncEither<ModcpPosted<ModcpHome>> addNote(
    ModcpHome home, {
    required String message,
    required bool toSupermod,
    required bool toModerator,
    required int days,
  }) => AsyncEither(() async {
    final form = home.addForm;
    if (form == null || message.trim().isEmpty) {
      return right((outcome: const ModcpWriteRefused(''), page: null));
    }
    final known = {for (final n in home.notes) n.id};
    final sent = await _send(
      home.uid,
      form.form.postUrl,
      form.body(message: message, toSupermod: toSupermod, toModerator: toModerator, days: days),
      modcpHomeFromApi,
    );
    return sent.map(
      (posted) => switch (posted) {
        (outcome: null, :final page?) => (
          outcome: page.notes.any((n) => !known.contains(n.id)) ? const ModcpWriteDone() : const ModcpWriteUnknown(),
          page: page,
        ),
        (:final outcome, :final page) => (outcome: outcome ?? const ModcpWriteUnknown(), page: page),
      },
    );
  });

  /// Delete notes [ids] of [home], once. The panel draws its first page again without a word, and passes over the
  /// notes the account may not delete: those it still lists were not deleted.
  AsyncEither<ModcpPosted<ModcpHome>> deleteNotes(ModcpHome home, List<int> ids) => AsyncEither(() async {
    final form = home.deleteForm;
    if (form == null || ids.isEmpty) {
      return right((outcome: const ModcpWriteRefused(''), page: null));
    }
    final sent = await _send(home.uid, form.form.postUrl, form.body(ids.map((e) => '$e')), modcpHomeFromApi);
    return sent.map(
      (posted) => switch (posted) {
        (outcome: null, :final page?) => (outcome: _remaining(ids, page.notes.map((n) => n.id)), page: page),
        (:final outcome, :final page) => (outcome: outcome ?? const ModcpWriteUnknown(), page: page),
      },
    );
  });

  /// Delete posts [pids] of the results [shown], the authors' credits kept when [keepCredits], once.
  ///
  /// The panel draws the results again: done when it says so ([modcpPostsDeletedKey]) and lists none of those sent
  /// (it passes over the posts of forums the account does not moderate); refused when the account may not delete
  /// posts ([ModcpPostError.noperm]).
  AsyncEither<ModcpPosted<ModcpPostPage>> deletePosts(
    ModcpPostPage shown,
    List<int> pids, {
    bool keepCredits = false,
  }) => AsyncEither(() async {
    final form = shown.deleteForm;
    if (form == null || !shown.canDelete || pids.isEmpty) {
      return right((outcome: const ModcpWriteRefused(''), page: null));
    }
    final sent = await _send(
      shown.uid,
      form.ids.form.postUrl,
      form.body(pids, keepCredits: keepCredits),
      modcpPostFromApi,
    );
    return sent.map(
      (posted) => switch (posted) {
        (outcome: null, :final page?) when page.error == ModcpPostError.noperm => (
          outcome: const ModcpWriteRefused(''),
          page: page,
        ),
        (outcome: null, :final page?) when page.messageKey == modcpPostsDeletedKey => (
          outcome: _remaining(pids, page.posts.map((p) => p.pid)),
          page: page,
        ),
        (outcome: null, :final page?) => (outcome: const ModcpWriteUnknown(), page: page),
        (:final outcome, :final page) => (outcome: outcome ?? const ModcpWriteUnknown(), page: page),
      },
    );
  });

  /// Deny [denied] to member [username] in [shown]'s forum (the whole set: those not sent are the user group's
  /// again), or give them the user group's permissions again when [denied] is empty, once.
  ///
  /// The panel draws the list again with what it did ([ModcpAccessPage.result]): done only when it says so; its
  /// reasons ([ModcpAccessResult]) are told by the app; nothing said is not done.
  AsyncEither<ModcpPosted<ModcpAccessPage>> setAccess(
    ModcpAccessPage shown,
    String username,
    Set<ModcpAccessRight> denied,
  ) => AsyncEither(() async {
    final form = shown.addForm;
    if (form == null || !shown.canSet || username.trim().isEmpty) {
      return right((outcome: const ModcpWriteRefused(''), page: null));
    }
    final body = denied.isEmpty ? form.restoreBody(shown.fid, username) : form.body(shown.fid, username, denied);
    final sent = await _send(shown.uid, form.form.postUrl, body, modcpAccessFromApi);
    return sent.map(
      (posted) => switch (posted) {
        (outcome: null, :final page?) when page.fid != shown.fid => (outcome: const ModcpWriteUnknown(), page: page),
        (outcome: null, :final page?) => (
          outcome: switch (page.result) {
            ModcpAccessResult.done => const ModcpWriteDone(),
            ModcpAccessResult.none => const ModcpWriteUnknown(),
            _ => const ModcpWriteRefused(''),
          },
          page: page,
        ),
        (:final outcome, :final page) => (outcome: outcome ?? const ModcpWriteUnknown(), page: page),
      },
    );
  });

  /// Post [body] to [url] for account [uid] once and read the answer: the page drawn again (no outcome yet: the caller
  /// reads it), or the outcome of an answer that is not the page (the panel's login, the forum's message).
  Future<Either<AppException, ({ModcpWriteOutcome? outcome, T? page})>> _send<T extends ModcpJsonPage>(
    int uid,
    String url,
    Map<String, String> body,
    T? Function(Map<String, dynamic> json) read,
  ) async {
    if (uid <= 0 || _currentUid() != uid) {
      return left(IdentityChangedException());
    }
    final resp = await _post(url, body);
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        // Nothing tells what was done: never sent again.
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return writtenOf(value.data, uid: uid, read: read);
    }
  }

  /// The answer [data] to a form of the panel sent by account [uid]: the page drawn again (read by [read], no outcome
  /// yet), or the outcome of an answer that is not it.
  ///
  /// * the same page (`schema` 37～39) with `message_key`: the page;
  /// * the panel's login form (`modcp_login`, or a write result whose page is the login form): its session ended,
  ///   nothing done;
  /// * the forum's message (a write result of `schema` 13, `error: message`): its verdict in its words;
  /// * anything else: not known.
  static Either<AppException, ({ModcpWriteOutcome? outcome, T? page})> writtenOf<T extends ModcpJsonPage>(
    Object? data, {
    required int uid,
    required T? Function(Map<String, dynamic> json) read,
  }) {
    if (tsdmAppWriteResultOf(data) case final result?) {
      if (result.uid != uid) {
        // The forum's login ended: nothing was done, its login prompt is the reason.
        if (result.uid == 0 && result.login) {
          return right((outcome: ModcpWriteRefused(result.reason.trim()), page: null));
        }
        return left(IdentityChangedException());
      }
      return right((
        outcome: switch (result.kind) {
          TsdmAppWriteKind.message || TsdmAppWriteKind.handle =>
            result.succeeded && !result.isError
                ? ModcpWriteDone(message: result.reason.trim())
                : ModcpWriteRefused(result.reason.trim()),
          TsdmAppWriteKind.page when moderatePanelLoginFormHash(result.document) != null =>
            const ModcpWriteSessionEnded(),
          TsdmAppWriteKind.redirect when result.login => ModcpWriteRefused(result.reason.trim()),
          _ => const ModcpWriteUnknown(),
        },
        page: null,
      ));
    }
    return pageOf(data, uid: uid, read: read).map(
      (answer) => switch (answer) {
        ModcpReady(:final value) => (outcome: null, page: value),
        ModcpNeedsLogin() => (outcome: const ModcpWriteSessionEnded(), page: null),
        ModcpRefused(:final message) => (outcome: ModcpWriteRefused(message), page: null),
      },
    );
  }

  /// Done when none of [ids] is among [listed] now, otherwise not done for those.
  static ModcpWriteOutcome _remaining(List<int> ids, Iterable<int> listed) {
    final now = listed.toSet();
    final remaining = [
      for (final id in ids)
        if (now.contains(id)) '$id',
    ];
    return remaining.isEmpty
        ? ModcpWriteDone(count: ids.length)
        : ModcpWriteNotDone(done: ids.length - remaining.length, remaining: remaining);
  }
}
