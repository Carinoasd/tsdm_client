import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/utils/friend_page_api.dart';
import 'package:tsdm_client/features/friend/utils/parse_add_friend.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Repository of friends lists.
final class FriendRepository {
  /// Constructor; [currentUid] tells the account the windows are asked for (the logged in account by default).
  const FriendRepository({this.currentUid});

  /// The account the windows are asked for, the one logged in when null (tests inject their own).
  final int Function()? currentUid;

  /// First page of the friends list of a user, located by [uid] (preferred) or [username].
  static String listUrl({String? uid, String? username}) {
    final who = uid != null ? 'uid=$uid' : 'username=${Uri.encodeQueryComponent(username ?? '')}';
    return '$baseUrl/home.php?mod=space&$who&do=friend';
  }

  /// First page of the visitors list of the current user (`view=visitor`; the forum shows another member's list of
  /// friends there instead, so only the own list is asked).
  static const String visitorListUrl = '$baseUrl/home.php?mod=space&do=friend&view=visitor';

  /// Whether [url] is a page of the visitors list.
  static bool isVisitorUrl(String url) => Uri.tryParse(url)?.queryParameters['view'] == 'visitor';

  /// First page of the members online now (`view=online&type=member`), the list the "在线会员" link of the forum's
  /// homepage opens: 24 a page, the latest active first, invisible members left out; a member's page asks it for the
  /// own space.
  static const String onlineListUrl = '$baseUrl/home.php?mod=space&do=friend&view=online&type=member';

  /// Whether [url] is a page of the members online now ([onlineListUrl]).
  static bool isOnlineUrl(String url) => Uri.tryParse(url)?.queryParameters['view'] == 'online';

  /// Fetch and parse one page of a friends list (or of the visitors list, [isVisitorUrl], or of the members online,
  /// [isOnlineUrl]).
  ///
  /// Asked in the JSON mode of the forum's app API, which answers the friends pages (`do=friend`) since plugin 1.6.0
  /// (roadmap item 3). Plugin 2.5.0 answers them as structured fields (`schema: 10`, [friendApiAnswerOf]), built by
  /// [friendListPageFromApi]; an older plugin answers the web page (as does the privacy page of another member's
  /// list, which the plugin never answers as fields), which parses the same: the members online print the shape of
  /// the visitors list (every `friend_UID_li` row, the time of the last activity in the `h4`). The `@` candidates read the own list
  /// through here too when the `atplus` plugin is not there.
  AsyncEither<FriendListPage> fetchPage(String url) => getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJson(url))
      .mapHttpPageAnswer(friendApiAnswerOf)
      .map(
        (answer) => switch (answer) {
          TsdmAppStructuredPage(:final json) => friendListPageFromApi(json, url),
          TsdmAppWebPage(:final document) => parseFriendListPage(
            document,
            visitor: isVisitorUrl(url) || isOnlineUrl(url),
          ),
        },
      );

  /// The add-friend form for [uid], as the forum's popup loads it.
  static String addFriendFormUrl(String uid) =>
      '$baseUrl/home.php?mod=spacecp&ac=friend&op=add&uid=$uid&handlekey=addfriendhk_$uid&inajax=1';

  /// Where the add-friend form for [uid] is submitted.
  static String addFriendSubmitUrl(String uid) => '$baseUrl/home.php?mod=spacecp&ac=friend&op=add&uid=$uid&inajax=1';

  /// Load the add-friend form for [uid]; the forum refuses here already when the two are friends, a request is
  /// pending, or [uid] is the current user.
  ///
  /// Plugin 4.0.0 answers the window as a small form (`friendadd`, [addFriendFormFromApi]) when its `status` lists it;
  /// otherwise, and for any other answer of it (the window of an approval, `mode: approve`, which this dialog never
  /// sends), the window is read as before: with the write result of the forum's app API (plugin 2.6.0,
  /// [tsdmAppWriteResultOf]): a `page` with the form, or the refusal as a `handle`; an older plugin answers the AJAX
  /// fragment, parsed as before.
  AsyncEither<AddFriendFormResult> fetchAddFriendForm(String uid) => AsyncEither(() async {
    final client = getIt.get<NetClientProvider>();
    await TsdmAppApi.ensureStatus(client);
    if (TsdmAppV4.has(TsdmAppV4Group.forms, SmallFormKind.friendadd.name)) {
      switch (await client.get(withTsdmAppV4Form(addFriendFormUrl(uid))).run()) {
        case Left(:final value):
          return left(value);
        case Right(:final value) when value.statusCode == 200:
          if (addFriendFormFromApi(value.data, uid: uid, viewer: (currentUid ?? currentLoginUid)()) case final form?) {
            return right(form);
          }
        case Right():
          break;
      }
    }
    return client.get(withTsdmAppJsonWrite(addFriendFormUrl(uid))).mapHttp((v) => parseAddFriendForm(v.data)).run();
  });

  /// Send a friend request to [uid] with the [formHash] of its form, an optional [note] and the group [gid].
  ///
  /// A [form] of plugin 4.0.0 ([AddFriendForm.submitFields]) is posted back as served, once ([postTsdmAppV4]), and
  /// its result read by `message_key` ([addFriendResultFromApi]).
  ///
  /// The forum's app API (plugin 2.6.0) answers the result as JSON ([tsdmAppWriteResultOf]): sent on the success
  /// hook (`request_has_been_sent`, shown as a note), refused with the forum's message on the error hook
  /// (`waiting_for_the_other_test`…); an older plugin answers the AJAX fragment, read as before.
  AsyncEither<AddFriendResult> addFriend({
    required String uid,
    required String formHash,
    String note = '',
    String gid = '1',
    AddFriendForm? form,
  }) {
    if (form case AddFriendForm(submitUrl: final url?, submitFields: final fields?)) {
      return postTsdmAppV4(
        getIt.get<NetClientProvider>(),
        withSmallFormInAjax(url),
        {...fields, 'note': note, 'gid': gid},
      ).map((data) => addFriendResultFromApi(data, uid: (currentUid ?? currentLoginUid)()));
    }
    return getIt
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
        .mapHttp((v) => parseAddFriendResult(v.data));
  }
}

/// The add-friend window of plugin 4.0.0 [data] (small form `friendadd`, `mode: add`) for member [uid], asked by
/// account [viewer]: the form, or the forum's refusal (friends already, a request pending, oneself, log in first).
/// Null for anything else, read as the web window instead: another answer, the window of an approval, a form for
/// another member or posting elsewhere, a refusal without a message.
AddFriendFormResult? addFriendFormFromApi(Object? data, {required String uid, required int viewer}) {
  final answer = smallFormAnswerOf(data, SmallFormKind.friendadd);
  switch (answer) {
    case null:
      return null;
    case SmallFormMessage(:final message, :final reason) when answer.uid == 0 || answer.servedTo(viewer):
      return reason.isEmpty ? null : AddFriendRefused(reason, fromForum: message.isNotEmpty);
    case SmallFormMessage():
      return AddFriendRefused(answer.identityProblem(viewer) ?? t.friendPage.addFriend.failed, fromForum: false);
    case final SmallFormFields form:
      if (answer.identityProblem(viewer) case final problem?) {
        return AddFriendRefused(problem, fromForum: false);
      }
      final json = form.json;
      final url = form.submitUrl('home.php', {'mod': 'spacecp', 'ac': 'friend', 'op': 'add', 'uid': uid});
      final fields = form.submitFields;
      final gid = tsdmAppMap(json['gid']);
      final groups = [
        for (final c in tsdmAppList(gid['choices']))
          if (tsdmAppText(c['value']) case final String value when RegExp(r'^\d{1,3}$').hasMatch(value))
            FriendGroup(gid: value, name: tsdmAppText(c['label']).trim()),
      ];
      if (json['mode'] != 'add' ||
          '${json['touid']}' != uid ||
          url == null ||
          !form.usable ||
          fields['addsubmit'] == null ||
          (fields['formhash'] ?? '').isEmpty ||
          groups.isEmpty) {
        return null;
      }
      final selected = tsdmAppText(gid['value']);
      return AddFriendForm(
        formHash: fields['formhash']!,
        targetName: tsdmAppText(json['username']).trim(),
        groups: groups,
        selectedGid: groups.any((g) => g.gid == selected) ? selected : groups.first.gid,
        submitUrl: url,
        submitFields: fields,
      );
  }
}

/// The answer [data] to an add-friend or approval form of plugin 4.0.0: sent when the forum said
/// `request_has_been_sent` (a request) or `friends_add` (an approval), refused otherwise, with the forum's message (or
/// the app's words when it gave none).
///
/// A result served to another account than [uid] (and not the login prompt) is never a success.
AddFriendResult addFriendResultFromApi(Object? data, {required int uid}) {
  final result = switch (tsdmAppV4WriteOutcomeOf(data)) {
    TsdmAppV4Written(:final result) when result.uid == uid || result.login => result,
    _ => null,
  };
  final success = result != null && const {'request_has_been_sent', 'friends_add'}.contains(result.messageKey);
  final reason = result?.reason ?? '';
  return AddFriendResult(
    success: success,
    message: reason.isNotEmpty ? reason : (success ? t.friendPage.addFriend.sent : t.friendPage.addFriend.failed),
    fromForum: (result?.message ?? '').isNotEmpty,
  );
}
