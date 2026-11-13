import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_v4.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;

/// Reads the blogs, the albums and the wall of a member's space, and the greetings received.
///
/// The lists are answered as fields by the forum's app API since plugin 4.0.0 (`status` lists `blog`, `album`, `wall`
/// and `poke` in `space_pages`: `type` `space_blog`, `space_album`, `space_wall`, `space_poke`, `schema` 61 to 64),
/// the owner's privacy as the forum's words ([spaceV4ListPageOf]). Without it (an older plugin, the flag off, an
/// answer that is not the page), and for a blog and the pictures of an album, every page is asked in the JSON mode of
/// the forum's app API ([withTsdmAppJson]); the plugin leaves the space pages alone and answers the web page, which is
/// parsed ([tsdmAppPageDocument] also rebuilds a page from the blocks or the message a later plugin may answer).
final class SpaceRepository {
  /// Constructor; [get] replaces the request of the shared client, [currentUid] the account in use.
  const SpaceRepository({Future<SyncEither<Response<dynamic>>> Function(String url)? get, int Function()? currentUid})
    : _get = get,
      _currentUid = currentUid;

  final Future<SyncEither<Response<dynamic>>> Function(String url)? _get;

  final int Function()? _currentUid;

  AsyncEither<T> _page<T>(String url, T Function(uh.Document document) parse) => AsyncEither(
    () => _get == null ? getIt.get<NetClientProvider>().get(withTsdmAppJson(url)).run() : _get(withTsdmAppJson(url)),
  ).mapHttpPage(parse);

  /// The list [url] of plugin 4.0.0 when `status` lists [name] in `space_pages` and the forum answers it as page
  /// [type] of `schema` [schema] ([fromApi]), else the web page ([parse]).
  AsyncEither<SpaceListPage<T>> _list<T>(
    String url, {
    required String name,
    required String type,
    required int schema,
    required SpaceListPage<T> Function(Map<String, dynamic> json, String url) fromApi,
    required SpaceListPage<T> Function(uh.Document document) parse,
  }) => AsyncEither(() async {
    final answer = await fetchSpaceV4Page(
      url,
      name: name,
      type: type,
      schema: schema,
      get: _get,
      currentUid: _currentUid ?? currentLoginUid,
    ).run();
    switch (answer) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        if (spaceV4ListPageOf(value, (json) => fromApi(json, url)) case final page?) {
          return right(page);
        }
    }
    return _page(url, parse).run();
  });

  /// A page of a blog list ([spaceBlogListUrl], or the next page of one).
  AsyncEither<SpaceListPage<SpaceBlog>> fetchBlogList(String url) => _list(
    url,
    name: 'blog',
    type: 'space_blog',
    schema: 61,
    fromApi: spaceBlogListPageFromApi,
    parse: parseSpaceBlogListPage,
  );

  /// A blog, or a further page of its comments ([spaceBlogUrl]).
  AsyncEither<SpaceBlogDetail> fetchBlog(String url) => _page(url, parseSpaceBlogDetail);

  /// A page of an album list ([spaceAlbumListUrl], or the next page of one).
  AsyncEither<SpaceListPage<SpaceAlbum>> fetchAlbumList(String url) => _list(
    url,
    name: 'album',
    type: 'space_album',
    schema: 62,
    fromApi: spaceAlbumListPageFromApi,
    parse: parseSpaceAlbumListPage,
  );

  /// A page of the pictures of an album ([spaceAlbumUrl], or the next page of one).
  AsyncEither<SpaceListPage<SpacePhoto>> fetchAlbumPhotos(String url) => _page(url, parseSpaceAlbumPhotosPage);

  /// A page of a wall ([spaceWallUrl], or the next page of one).
  AsyncEither<SpaceListPage<SpaceBlogComment>> fetchWall(String url) => _list(
    url,
    name: 'wall',
    type: 'space_wall',
    schema: 63,
    fromApi: spaceWallPageFromApi,
    parse: parseSpaceWallPage,
  );

  /// A page of the greetings received ([spacePokeListUrl], or the next page of it).
  AsyncEither<SpaceListPage<ReceivedPoke>> fetchPokes(String url) => _list(
    url,
    name: 'poke',
    type: 'space_poke',
    schema: 64,
    fromApi: spacePokePageFromApi,
    parse: parseReceivedPokePage,
  );
}
