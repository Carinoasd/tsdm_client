import 'dart:async';

import 'package:collection/collection.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/utils/favorite_page_api.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Repository of favorites (收藏) on the forum: threads (帖子) and forums (版块).
///
/// The forum never tells whether a thread or a forum is favorited in the page itself, so this repository also keeps
/// the records it has seen (list pages, successful adds, the favorites panel of `forum.php`) per user; the thread
/// and forum pages use that to label their menu item.
///
/// Both kinds share one Discuz! code path (`spacecp&ac=favorite`), only the `type` query parameter differs. The
/// `handlekey` is echoed back by the server, so the app keeps sending the same two for every kind.
///
/// **Need to call dispose.**
final class FavoriteRepository with LoggerMixin {
  /// Constructor; [currentUid] tells the account the dialogs are asked for (the logged in account by default).
  FavoriteRepository({this.currentUid});

  /// The account the dialogs are asked for, the one logged in when null (tests inject their own).
  final int Function()? currentUid;

  /// First page of the thread favorites list.
  static const listUrl = '$baseUrl/home.php?mod=space&do=favorite&type=thread';

  /// First page of the favorites list of [type].
  static String listUrlOf(FavoriteType type) => '$baseUrl/home.php?mod=space&do=favorite&type=${type.queryValue}';

  /// Dialog (GET) and submit (POST, with `&spaceuid=0`) url of adding a thread favorite.
  static String dialogUrl(String tid) => dialogUrlOf(FavoriteType.thread, tid);

  /// Dialog (GET) and submit (POST, with `&spaceuid=0`) url of adding a favorite of [type] with target [id].
  static String dialogUrlOf(FavoriteType type, String id) =>
      '$baseUrl/home.php?mod=spacecp&ac=favorite&type=${type.queryValue}&id=$id&infloat=yes&handlekey=k_favorite'
      '&inajax=1';

  /// Dialog (GET) and submit (POST) url of removing a thread favorite.
  static String removeUrl(String favid) => removeUrlOf(FavoriteType.thread, favid);

  /// Dialog (GET) and submit (POST) url of removing the favorite record [favid] of [type].
  ///
  /// Discuz! deletes by favid alone; `type` only picks the page it would redirect to.
  static String removeUrlOf(FavoriteType type, String favid) =>
      '$baseUrl/home.php?mod=spacecp&ac=favorite&op=delete&favid=$favid&type=${type.queryValue}&infloat=yes'
      '&handlekey=favdelete&inajax=1';

  /// Known records: type -> uid -> (target id -> favid).
  ///
  /// A null favid means the record is known to exist (seen in the favorites panel of `forum.php`) but its id is not
  /// known yet; [findForumFavid] resolves it when needed.
  final _known = <FavoriteType, Map<int, Map<String, String?>>>{};

  final _forumFavoritesChanged = StreamController<void>.broadcast();

  /// Emits after every successful add or removal of a forum favorite, so the topics tab can reload the favorites
  /// panel.
  Stream<void> get forumFavoritesChanged => _forumFavoritesChanged.stream;

  /// Release the streams.
  Future<void> dispose() async {
    await _forumFavoritesChanged.close();
  }

  Map<String, String?> _of(FavoriteType type, int uid) => (_known[type] ??= {})[uid] ??= <String, String?>{};

  /// The favid of thread [tid] if it is known to be favorited by user [uid].
  String? cachedFavid({required int uid, required String tid}) => _known[FavoriteType.thread]?[uid]?[tid];

  /// Remember that [tid] is favorited as [favid] by [uid].
  void remember({required int uid, required String tid, required String favid}) =>
      _of(FavoriteType.thread, uid)[tid] = favid;

  /// Forget the record of [tid].
  void forget({required int uid, required String tid}) => _known[FavoriteType.thread]?[uid]?.remove(tid);

  /// Whether forum [fid] is known to be favorited by user [uid] (favid known or not).
  bool isForumFavorited({required int uid, required String fid}) =>
      _known[FavoriteType.forum]?[uid]?.containsKey(fid) ?? false;

  /// The favid of forum [fid] if it is known to be favorited by user [uid] and the record id was seen.
  String? cachedForumFavid({required int uid, required String fid}) => _known[FavoriteType.forum]?[uid]?[fid];

  /// Remember that forum [fid] is favorited as [favid] by [uid].
  void rememberForum({required int uid, required String fid, required String favid}) =>
      _of(FavoriteType.forum, uid)[fid] = favid;

  /// Forget the record of forum [fid].
  void forgetForum({required int uid, required String fid}) => _known[FavoriteType.forum]?[uid]?.remove(fid);

  /// Replace the set of favorite forums of [uid] with [fids], as listed by the favorites panel of `forum.php`.
  ///
  /// The panel lists every favorite forum but not the record ids, so favids already known for forums still in the
  /// set are kept; forums no longer in the set are forgotten.
  void seedForumFavorites({required int uid, required Iterable<String> fids}) {
    final current = _of(FavoriteType.forum, uid);
    final next = <String, String?>{for (final fid in fids) fid: current[fid]};
    current
      ..clear()
      ..addAll(next);
  }

  /// Remember every record in [items], threads and forums alike.
  void rememberAll({required int uid, required Iterable<FavoriteItem> items}) {
    for (final item in items) {
      _of(item.type, uid)[item.targetId] = item.favid;
    }
  }

  /// Forget the record [item].
  void forgetItem({required int uid, required FavoriteItem item}) => _known[item.type]?[uid]?.remove(item.targetId);

  /// Fetch and parse one page of the thread favorites list.
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the favorites pages (`do=favorite`) since plugin
  /// 1.6.0. Plugin 2.5.0 answers them as structured fields (`schema: 8`, [favoriteApiAnswerOf]), built by
  /// [favoriteThreadsFromApi]; an older plugin answers the web page, which parses as before.
  AsyncEither<FavoriteListPage<FavoriteThread>> fetchListPage([String url = listUrl]) => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson(url))
      .mapHttpPageAnswer(favoriteApiAnswerOf)
      .map(
        (answer) => switch (answer) {
          TsdmAppStructuredPage(:final json) => favoriteThreadsFromApi(json, url),
          TsdmAppWebPage(:final document) => parseFavoriteListPage(document),
        },
      );

  /// Fetch and parse one page of the forum favorites list, as [fetchListPage] fetches the threads.
  AsyncEither<FavoriteListPage<FavoriteForum>> fetchForumListPage([String? url]) {
    final pageUrl = url ?? listUrlOf(FavoriteType.forum);
    return getIt
        .get<NetClientProvider>()
        .get(withTsdmAppJson(pageUrl))
        .mapHttpPageAnswer(favoriteApiAnswerOf)
        .map(
          (answer) => switch (answer) {
            TsdmAppStructuredPage(:final json) => favoriteForumsFromApi(json, pageUrl),
            TsdmAppWebPage(:final document) => parseFavoriteForumListPage(document),
          },
        );
  }

  /// Fetch and parse one page of the favorites list of [type]; the first page when [url] is null. As
  /// [fetchListPage] fetches the threads.
  AsyncEither<FavoriteListPage<FavoriteItem>> fetchListPageOf(FavoriteType type, [String? url]) {
    final pageUrl = url ?? listUrlOf(type);
    return getIt
        .get<NetClientProvider>()
        .get(withTsdmAppJson(pageUrl))
        .mapHttpPageAnswer(favoriteApiAnswerOf)
        .map(
          (answer) => switch (answer) {
            TsdmAppStructuredPage(:final json) => favoriteListPageOfTypeFromApi(json, type, pageUrl),
            TsdmAppWebPage(:final document) => parseFavoriteListPageOfType(document, type),
          },
        );
  }

  /// Fetch a favorite dialog (add or delete): the html wrapped in the ajax xml answer, or the write result of the
  /// forum's app API (plugin 2.6.0, [tsdmAppWriteResultOf]: a `page` with the form, or the forum's notice as a
  /// `handle`), which the parsers of `parse_favorite.dart` take either way.
  AsyncEither<Object?> _fetchDialog(String url) =>
      getIt.get<NetClientProvider>().get(withTsdmAppJsonWrite(url)).mapHttp((v) => v.data);

  /// Add thread [tid] to favorites with an optional note [description].
  ///
  /// Two steps like the web page: fetch the dialog for `formhash`, then submit the form. When the thread is already
  /// favorited the forum answers the notice ("抱歉，您已收藏，请勿重复收藏") right in the dialog, without a form.
  ///
  /// The forum's app API (plugin 2.6.0) answers the dialog and the form as JSON ([tsdmAppWriteResultOf]); an older
  /// plugin answers the AJAX fragments, parsed as before.
  AsyncEither<FavoriteAddResult> addFavorite({required String tid, String description = ''}) =>
      _add(FavoriteType.thread, tid, description);

  /// Add forum [fid] to favorites with an optional note [description]; same two steps as [addFavorite].
  ///
  /// [forumFavoritesChanged] emits when the forum got added.
  AsyncEither<FavoriteAddResult> addForumFavorite({required String fid, String description = ''}) =>
      _add(FavoriteType.forum, fid, description).map((result) {
        if (result is FavoriteAdded) {
          notifyForumFavoritesChanged();
        }
        return result;
      });

  /// Plugin 4.0.0 answers the dialog as a small form (`favorite`) when its `status` lists it: the form is posted back
  /// as served and its result read by `message_key` ([favoriteAddResultFromApi]); anything else of it, and an older
  /// plugin, take the two steps as before.
  AsyncEither<FavoriteAddResult> _add(FavoriteType type, String id, String description) => AsyncEither(() async {
    final client = getIt.get<NetClientProvider>();
    await TsdmAppApi.ensureStatus(client);
    if (TsdmAppV4.has(TsdmAppV4Group.forms, SmallFormKind.favorite.name)) {
      // Never with a `formhash`: the forum would add the favorite on that GET already.
      switch (await client.get(withTsdmAppV4Form(dialogUrlOf(type, id))).run()) {
        case Left(:final value):
          return left(value);
        case Right(:final value) when value.statusCode == 200:
          switch (favoriteFormFromApi(value.data, type: type, id: id, viewer: (currentUid ?? currentLoginUid)())) {
            case Left(value: final result):
              debug('add favorite ${type.name}=$id answered in the dialog: $result');
              return right(result);
            case Right(value: (:final url, :final fields)?):
              return postTsdmAppV4(
                client,
                withSmallFormInAjax(url),
                {...fields, 'description': description},
              ).map(favoriteAddResultFromApi).run();
            case Right():
              break;
          }
        case Right():
          break;
      }
    }
    return _addFromWindow(type, id, description).run();
  });

  AsyncEither<FavoriteAddResult> _addFromWindow(FavoriteType type, String id, String description) =>
      _fetchDialog(dialogUrlOf(type, id)).flatMap((dialog) {
        final form = parseFavoriteForm(dialog);
        if (form == null) {
          final result = parseFavoriteAddResult(dialog);
          debug('add favorite ${type.name}=$id answered in the dialog: $result');
          return TaskEither<AppException, FavoriteAddResult>.right(result);
        }
        return getIt
            .get<NetClientProvider>()
            .postForm(
              '${dialogUrlOf(type, id)}&spaceuid=0',
              data: {
                'favoritesubmit': 'true',
                'referer': form.referer,
                'formhash': form.formHash,
                'handlekey': 'k_favorite',
                'description': description,
              },
            )
            .mapHttp((v) {
              final result = parseFavoriteAddResult(v.data);
              debug('add favorite ${type.name}=$id: $result');
              return result;
            });
      });

  /// Remove the favorite record [favid] of [type].
  ///
  /// When the record does not exist anymore the forum answers the notice ("抱歉，您指定的收藏不存在") right in the
  /// dialog, without a form; that counts as removed. [forumFavoritesChanged] emits when a forum record got removed.
  AsyncEither<FavoriteRemoveResult> removeFavorite({required String favid, FavoriteType type = FavoriteType.thread}) =>
      _fetchDialog(removeUrlOf(type, favid))
          .flatMap((dialog) {
            final form = parseFavoriteForm(dialog);
            if (form == null) {
              final result = parseFavoriteRemoveResult(dialog);
              debug('remove favorite favid=$favid answered in the dialog: $result');
              return TaskEither<AppException, FavoriteRemoveResult>.right(result);
            }
            return getIt
                .get<NetClientProvider>()
                .postForm(
                  removeUrlOf(type, favid),
                  data: {
                    'referer': form.referer,
                    'deletesubmit': 'true',
                    'formhash': form.formHash,
                    'handlekey': 'favdelete',
                  },
                )
                .mapHttp((v) {
                  final result = parseFavoriteRemoveResult(v.data);
                  debug('remove favorite favid=$favid: $result');
                  return result;
                });
          })
          .map((result) {
            if (type == FavoriteType.forum && result.removed) {
              notifyForumFavoritesChanged();
            }
            return result;
          });

  /// Tell the topics tab the "我收藏的版块" panel is out of date although no request of this repository changed it:
  /// the forum page found the record already on the server, or found it missing, while acting on a forum.
  ///
  /// [rememberForum], [forgetForum] and [rememberAll] stay silent on purpose: the add and remove paths already
  /// emit here, and the favorites list page and the topics tab itself write the cache through them.
  void notifyForumFavoritesChanged() {
    if (!_forumFavoritesChanged.isClosed) {
      _forumFavoritesChanged.add(null);
    }
  }

  /// Look up the favid of thread [tid] by walking the favorites list, at most [maxPages] pages.
  ///
  /// Used when the server says "already favorited" without telling which record it is.
  AsyncEither<String?> findFavid({required String tid, required int uid, int maxPages = 20}) =>
      _find(FavoriteType.thread, id: tid, uid: uid, maxPages: maxPages);

  /// Look up the favid of forum [fid] by walking the forum favorites list, at most [maxPages] pages.
  AsyncEither<String?> findForumFavid({required String fid, required int uid, int maxPages = 20}) =>
      _find(FavoriteType.forum, id: fid, uid: uid, maxPages: maxPages);

  AsyncEither<String?> _find(FavoriteType type, {required String id, required int uid, required int maxPages}) =>
      AsyncEither(() async {
        String? url = listUrlOf(type);
        for (var page = 0; page < maxPages && url != null; page++) {
          switch (await fetchListPageOf(type, url).run()) {
            case Left(:final value):
              return left(value);
            case Right(:final value):
              rememberAll(uid: uid, items: value.items);
              final hit = value.items.firstWhereOrNull((e) => e.targetId == id);
              if (hit != null) {
                return right(hit.favid);
              }
              url = value.nextPageUrl;
          }
        }
        return right(null);
      });
}

/// The favorite dialog of plugin 4.0.0 [data] (small form `favorite`) for target [id] of [type], asked by account
/// [viewer]: the forum's answer in the dialog as the left (favorited already, favorites switched off, the target not
/// there, log in first), or the form to post as the right (its url, absolute, and its fields as served). Right null for
/// anything else, read as before: another answer, a form for another target or posting elsewhere, a message without
/// text.
Either<FavoriteAddResult, ({String url, Map<String, String> fields})?> favoriteFormFromApi(
  Object? data, {
  required FavoriteType type,
  required String id,
  required int viewer,
}) {
  final answer = smallFormAnswerOf(data, SmallFormKind.favorite);
  switch (answer) {
    case null:
      return right(null);
    case _ when !answer.servedTo(viewer):
      return left(FavoriteAddFailed(answer.identityProblem(viewer) ?? t.general.accountChangedRetry));
    case SmallFormMessage(:final messageKey) when messageKey == 'favorite_repeat':
      return left(const FavoriteAlreadyExists());
    case SmallFormMessage(:final reason):
      return reason.isEmpty ? right(null) : left(FavoriteAddFailed(reason));
    case final SmallFormFields form:
      final json = form.json;
      final url = form.submitUrl('home.php', {'mod': 'spacecp', 'ac': 'favorite', 'type': type.queryValue, 'id': id});
      final fields = form.submitFields;
      if (json['favtype'] != type.queryValue ||
          '${json['id']}' != id ||
          url == null ||
          !form.usable ||
          fields['favoritesubmit'] == null ||
          (fields['formhash'] ?? '').isEmpty) {
        return right(null);
      }
      return right((url: url, fields: fields));
  }
}

/// The answer [data] to a favorite form of plugin 4.0.0, by its `message_key`: added for `favorite_do_success` (its
/// `favid`), favorited already for `favorite_repeat`, refused with the forum's message otherwise.
FavoriteAddResult favoriteAddResultFromApi(Object? data) {
  final result = switch (tsdmAppV4WriteOutcomeOf(data)) {
    TsdmAppV4Written(:final result) => result,
    _ => null,
  };
  return switch (result?.messageKey) {
    'favorite_do_success' => FavoriteAdded(result!.values['favid']),
    'favorite_repeat' => const FavoriteAlreadyExists(),
    _ => FavoriteAddFailed(result?.reason ?? ''),
  };
}
