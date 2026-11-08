import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;

/// Reads the blogs and the albums of a member's space.
///
/// Every page is asked in the JSON mode of the forum's app API ([withTsdmAppJson]); the plugin (3.4.0) leaves the
/// space pages alone and answers the web page, which is parsed ([tsdmAppPageDocument] also rebuilds a page from the
/// blocks or the message a later plugin may answer).
final class SpaceRepository {
  /// Constructor.
  const SpaceRepository();

  AsyncEither<T> _page<T>(String url, T Function(uh.Document document) parse) =>
      getIt.get<NetClientProvider>().get(withTsdmAppJson(url)).mapHttpPage(parse);

  /// A page of a blog list ([spaceBlogListUrl], or the next page of one).
  AsyncEither<SpaceListPage<SpaceBlog>> fetchBlogList(String url) => _page(url, parseSpaceBlogListPage);

  /// A blog, or a further page of its comments ([spaceBlogUrl]).
  AsyncEither<SpaceBlogDetail> fetchBlog(String url) => _page(url, parseSpaceBlogDetail);

  /// A page of an album list ([spaceAlbumListUrl], or the next page of one).
  AsyncEither<SpaceListPage<SpaceAlbum>> fetchAlbumList(String url) => _page(url, parseSpaceAlbumListPage);

  /// A page of the pictures of an album ([spaceAlbumUrl], or the next page of one).
  AsyncEither<SpaceListPage<SpacePhoto>> fetchAlbumPhotos(String url) => _page(url, parseSpaceAlbumPhotosPage);
}
