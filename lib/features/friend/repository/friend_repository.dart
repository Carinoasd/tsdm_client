import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// Repository of friends lists.
final class FriendRepository {
  /// Constructor.
  const FriendRepository();

  /// First page of the friends list of a user, located by [uid] (preferred) or [username].
  static String listUrl({String? uid, String? username}) {
    final who = uid != null ? 'uid=$uid' : 'username=${Uri.encodeQueryComponent(username ?? '')}';
    return '$baseUrl/home.php?mod=space&$who&do=friend';
  }

  /// Fetch and parse one page of a friends list.
  AsyncEither<FriendListPage> fetchPage(String url) =>
      getIt.get<NetClientProvider>().get(url).mapHttp((v) => parseFriendListPage(parseHtmlDocument('${v.data}')));
}
