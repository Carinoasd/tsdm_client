import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/utils/parse_add_friend.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

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
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the friends pages (`do=friend`) since plugin 1.6.0
  /// (roadmap item 3); an older plugin answers the web page, which parses the same. The `@` candidates read the own
  /// list through here too when the `atplus` plugin is not there.
  AsyncEither<FriendListPage> fetchPage(String url) => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson(url))
      .mapHttp((v) => parseFriendListPage(tsdmAppPageDocument(v.data)));

  /// The add-friend form for [uid], as the forum's popup loads it.
  static String addFriendFormUrl(String uid) =>
      '$baseUrl/home.php?mod=spacecp&ac=friend&op=add&uid=$uid&handlekey=addfriendhk_$uid&inajax=1';

  /// Where the add-friend form for [uid] is submitted.
  static String addFriendSubmitUrl(String uid) => '$baseUrl/home.php?mod=spacecp&ac=friend&op=add&uid=$uid&inajax=1';

  /// Load the add-friend form for [uid]; the forum refuses here already when the two are friends, a request is
  /// pending, or [uid] is the current user.
  AsyncEither<AddFriendFormResult> fetchAddFriendForm(String uid) =>
      getIt.get<NetClientProvider>().get(addFriendFormUrl(uid)).mapHttp((v) => parseAddFriendForm('${v.data}'));

  /// Send a friend request to [uid] with the [formHash] of its form, an optional [note] and the group [gid].
  AsyncEither<AddFriendResult> addFriend({
    required String uid,
    required String formHash,
    String note = '',
    String gid = '1',
  }) => getIt
      .get<NetClientProvider>()
      .postForm(
        addFriendSubmitUrl(uid),
        data: {
          'referer': '$baseUrl/home.php?mod=space&uid=$uid',
          'addsubmit': 'true',
          'handlekey': 'addfriendhk_$uid',
          'formhash': formHash,
          'note': note,
          'gid': gid,
        },
      )
      .mapHttp((v) => parseAddFriendResult('${v.data}'));
}
