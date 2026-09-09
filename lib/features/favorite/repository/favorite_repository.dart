import 'dart:async';

import 'package:collection/collection.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

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
  /// Constructor.
  FavoriteRepository();

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
  AsyncEither<FavoriteListPage<FavoriteThread>> fetchListPage([String url = listUrl]) =>
      getIt.get<NetClientProvider>().get(url).mapHttp((v) => parseFavoriteListPage(parseHtmlDocument('${v.data}')));

  /// Fetch and parse one page of the forum favorites list.
  AsyncEither<FavoriteListPage<FavoriteForum>> fetchForumListPage([String? url]) => getIt
      .get<NetClientProvider>()
      .get(url ?? listUrlOf(FavoriteType.forum))
      .mapHttp((v) => parseFavoriteForumListPage(parseHtmlDocument('${v.data}')));

  /// Fetch and parse one page of the favorites list of [type]; the first page when [url] is null.
  AsyncEither<FavoriteListPage<FavoriteItem>> fetchListPageOf(FavoriteType type, [String? url]) => getIt
      .get<NetClientProvider>()
      .get(url ?? listUrlOf(type))
      .mapHttp((v) => parseFavoriteListPageOfType(parseHtmlDocument('${v.data}'), type));

  /// Fetch a favorite dialog (add or delete); the html wrapped in the ajax xml answer.
  AsyncEither<String> _fetchDialog(String url) => getIt.get<NetClientProvider>().get(url).mapHttp((v) => '${v.data}');

  /// Add thread [tid] to favorites with an optional note [description].
  ///
  /// Two steps like the web page: fetch the dialog for `formhash`, then submit the form. When the thread is already
  /// favorited the forum answers the notice ("抱歉，您已收藏，请勿重复收藏") right in the dialog, without a form.
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

  AsyncEither<FavoriteAddResult> _add(FavoriteType type, String id, String description) =>
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
              final result = parseFavoriteAddResult('${v.data}');
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
                  final result = parseFavoriteRemoveResult('${v.data}');
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
