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

/// Repository of thread favorites (收藏) on the forum.
///
/// The forum never tells whether a thread is favorited in the thread page itself, so this repository also keeps the
/// records it has seen (list pages, successful adds) per user; the thread page uses that to label its menu item.
final class FavoriteRepository with LoggerMixin {
  /// Constructor.
  FavoriteRepository();

  /// First page of the favorites list.
  static const listUrl = '$baseUrl/home.php?mod=space&do=favorite&type=thread';

  /// Dialog (GET) and submit (POST, with `&spaceuid=0`) url of adding a favorite.
  static String dialogUrl(String tid) =>
      '$baseUrl/home.php?mod=spacecp&ac=favorite&type=thread&id=$tid&infloat=yes&handlekey=k_favorite&inajax=1';

  /// Dialog (GET) and submit (POST) url of removing a favorite.
  static String removeUrl(String favid) =>
      '$baseUrl/home.php?mod=spacecp&ac=favorite&op=delete&favid=$favid&type=thread&infloat=yes'
      '&handlekey=favdelete&inajax=1';

  /// Known records: uid -> (tid -> favid).
  final _known = <int, Map<String, String>>{};

  /// The favid of thread [tid] if it is known to be favorited by user [uid].
  String? cachedFavid({required int uid, required String tid}) => _known[uid]?[tid];

  /// Remember that [tid] is favorited as [favid] by [uid].
  void remember({required int uid, required String tid, required String favid}) =>
      (_known[uid] ??= <String, String>{})[tid] = favid;

  /// Remember every record in [items].
  void rememberAll({required int uid, required Iterable<FavoriteThread> items}) {
    for (final item in items) {
      remember(uid: uid, tid: item.tid, favid: item.favid);
    }
  }

  /// Forget the record of [tid].
  void forget({required int uid, required String tid}) => _known[uid]?.remove(tid);

  /// Fetch and parse one page of the favorites list.
  AsyncEither<FavoriteListPage> fetchListPage([String url = listUrl]) =>
      getIt.get<NetClientProvider>().get(url).mapHttp((v) => parseFavoriteListPage(parseHtmlDocument('${v.data}')));

  /// Fetch a favorite dialog (add or delete); the html wrapped in the ajax xml answer.
  AsyncEither<String> _fetchDialog(String url) => getIt.get<NetClientProvider>().get(url).mapHttp((v) => '${v.data}');

  /// Add thread [tid] to favorites with an optional note [description].
  ///
  /// Two steps like the web page: fetch the dialog for `formhash`, then submit the form. When the thread is already
  /// favorited the forum answers the notice ("抱歉，您已收藏，请勿重复收藏") right in the dialog, without a form.
  AsyncEither<FavoriteAddResult> addFavorite({required String tid, String description = ''}) =>
      _fetchDialog(dialogUrl(tid)).flatMap((dialog) {
        final form = parseFavoriteForm(dialog);
        if (form == null) {
          final result = parseFavoriteAddResult(dialog);
          debug('add favorite tid=$tid answered in the dialog: $result');
          return TaskEither<AppException, FavoriteAddResult>.right(result);
        }
        return getIt
            .get<NetClientProvider>()
            .postForm(
              '${dialogUrl(tid)}&spaceuid=0',
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
              debug('add favorite tid=$tid: $result');
              return result;
            });
      });

  /// Remove the favorite record [favid].
  ///
  /// When the record does not exist anymore the forum answers the notice ("抱歉，您指定的收藏不存在") right in the
  /// dialog, without a form; that counts as removed.
  AsyncEither<FavoriteRemoveResult> removeFavorite({required String favid}) =>
      _fetchDialog(removeUrl(favid)).flatMap((dialog) {
        final form = parseFavoriteForm(dialog);
        if (form == null) {
          final result = parseFavoriteRemoveResult(dialog);
          debug('remove favorite favid=$favid answered in the dialog: $result');
          return TaskEither<AppException, FavoriteRemoveResult>.right(result);
        }
        return getIt
            .get<NetClientProvider>()
            .postForm(
              removeUrl(favid),
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
      });

  /// Look up the favid of thread [tid] by walking the favorites list, at most [maxPages] pages.
  ///
  /// Used when the server says "already favorited" without telling which record it is.
  AsyncEither<String?> findFavid({required String tid, required int uid, int maxPages = 20}) => AsyncEither(() async {
    String? url = listUrl;
    for (var page = 0; page < maxPages && url != null; page++) {
      switch (await fetchListPage(url).run()) {
        case Left(:final value):
          return left(value);
        case Right(:final value):
          rememberAll(uid: uid, items: value.items);
          final hit = value.items.firstWhereOrNull((e) => e.tid == tid);
          if (hit != null) {
            return right(hit.favid);
          }
          url = value.nextPageUrl;
      }
    }
    return right(null);
  });
}
