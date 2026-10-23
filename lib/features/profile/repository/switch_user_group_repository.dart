import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/available_user_group.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The user group list as the app shows it.
final class UserGroupList {
  /// Constructor.
  const UserGroupList({required this.currentUserGroup, required this.availableGroups, required this.formHash});

  /// The name of the current user group.
  final String? currentUserGroup;

  /// The groups the member can switch to.
  final List<AvailableUserGroup> availableGroups;

  /// The form hash of the page, posted by a switch to a group parsed from the web page.
  final String formHash;
}

/// The repository of switching user group.
final class SwitchUserGroupRepository with LoggerMixin {
  /// Constructor; [currentUid] tells the account the list is asked for (the logged in account by default).
  SwitchUserGroupRepository({int Function()? currentUid}) : _currentUid = currentUid ?? currentLoginUid;

  final int Function() _currentUid;

  /// Page to fetch available user groups info.
  static const _infoPageUrl = '$baseUrl/home.php?mod=spacecp&ac=usergroup&do=expiry';

  /// Handle key used in the switch dialog.
  ///
  /// `home.php?mod=spacecp&ac=usergroup&do=switch&groupid=3&handlekey=switchgrouphk`
  static const _handleKey = 'switchgrouphk';

  /// Url to submit the user group switching request.
  static String _buildSubmitUrl(int gid) =>
      '$baseUrl/home.php?mod=spacecp&ac=usergroup&do=switch&groupid=$gid&handlekey=$_handleKey&inajax=1';

  /// Fetch the document page of all available user groups.
  AsyncEither<uh.Document> fetchAvailableGroupDocument() =>
      getIt.get<NetClientProvider>().get(_infoPageUrl).mapHttp((v) => parseHtmlDocument(v.data as String));

  /// Fetch the user group list.
  ///
  /// The page is asked as a small form of the forum's app API ([withTsdmAppForm], plugin 3.0.0): the list as
  /// structured fields, of which only the groups the member can switch to are taken
  /// ([AvailableUserGroup.parseApi]), or the forum's message instead of it ([SwitchUserGroupFailed] with the forum's
  /// text), served to the account that asked or never used. An older plugin, or none, answers the web page itself,
  /// which is parsed as before ([AvailableUserGroup.parseInfoDocument]); any other answer (a form the plugin could
  /// not tell, other plugins' fields) has the page asked again the way it always was.
  AsyncEither<UserGroupList> fetchAvailableGroups() => AsyncEither(() async {
    final uid = _currentUid();
    final Object? data;
    switch (await getIt.get<NetClientProvider>().get(withTsdmAppForm(_infoPageUrl, page: true)).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        data = value.data;
    }
    switch (smallFormAnswerOf(data, SmallFormKind.usergroup)) {
      case final SmallFormAnswer answer when answer.identityProblem(uid) != null:
        return left(SwitchUserGroupFailed('identity', reason: answer.identityProblem(uid)));
      case final SmallFormMessage message:
        return left(SwitchUserGroupFailed('message', reason: message.reason));
      case final SmallFormFields form when form.usable:
        if (AvailableUserGroup.parseApi(form) case (final current, final groups)) {
          return right(
            UserGroupList(
              currentUserGroup: current.isEmpty ? null : current,
              availableGroups: groups,
              formHash: tsdmAppText(form.json['formhash']),
            ),
          );
        }
      case _:
        break;
    }
    if (data is String && tsdmAppAnswerJson(data) == null) {
      // The web page: a forum without the plugin, or with one older than 3.0.0. Read as it always was.
      return _listOf(parseHtmlDocument(data));
    }
    return (await fetchAvailableGroupDocument().run()).flatMap(_listOf);
  });

  Either<AppException, UserGroupList> _listOf(uh.Document document) {
    final (currentUserGroup, availableUserGroups) = AvailableUserGroup.parseInfoDocument(document);
    final formHash = document.querySelector('input[name="formhash"]')?.attributes['value'];
    if (formHash == null) {
      error('failed to build switch user group document: form hash not found');
      return left(SwitchUserGroupFailed('form hash not found'));
    }
    return right(
      UserGroupList(currentUserGroup: currentUserGroup, availableGroups: availableUserGroups, formHash: formHash),
    );
  }

  /// Switch to [group], the name of the group switched to on success.
  ///
  /// A group of the list of the forum's app API ([AvailableUserGroup.switchUrl], plugin 3.0.0) opens its switch
  /// window as the website does, asked as a small form: the form as structured fields is posted as served to its
  /// `submit.url` with `inajax=1`; the forum's message instead of it (not in the group, not allowed while banned…)
  /// fails with its text. Any other answer of the window, and a group parsed from the web page, is posted to the
  /// fixed switch url with [formHash] ([submitSwitchRequest]).
  AsyncEither<String> switchTo(AvailableUserGroup group, String formHash) => AsyncEither(() async {
    final url = group.switchUrl;
    if (url == null) {
      return (await submitSwitchRequest(group.gid, formHash).run()).map((_) => group.name);
    }
    final uid = _currentUid();
    // A same-site home.php url ([AvailableUserGroup.parseApi]), asked on the app's host.
    final window = withTsdmAppForm(
      _withInfloat(Uri.parse(baseUrl).replace(path: '/home.php', query: Uri.parse(url).query).toString()),
    );
    final Object? data;
    switch (await getIt.get<NetClientProvider>().get(window).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        data = value.data;
    }
    switch (smallFormAnswerOf(data, SmallFormKind.usergroup)) {
      case final SmallFormAnswer answer when answer.identityProblem(uid) != null:
        return left(SwitchUserGroupFailed('identity', reason: answer.identityProblem(uid)));
      case final SmallFormMessage message:
        return left(SwitchUserGroupFailed('message', reason: message.reason));
      case final SmallFormFields form when form.usable && form.json['do'] == 'switch':
        final groupId = tsdmAppInt(form.json['groupid']);
        final target = form.submitUrl('home.php', {
          'mod': 'spacecp',
          'ac': 'usergroup',
          'do': 'switch',
          'groupid': '$groupId',
        });
        if (groupId > 0 && target != null && (form.submitFields['formhash'] ?? '').isNotEmpty) {
          final to = tsdmAppText(tsdmAppMap(form.json['to'])['title']).trim();
          return (await _post(withSmallFormInAjax(target), form.submitFields).run()).map(
            (_) => to.isNotEmpty ? to : group.name,
          );
        }
      case _:
        break;
    }
    return (await submitSwitchRequest(group.gid, formHash).run()).map((_) => group.name);
  });

  /// [url] of a switch window with `infloat=yes&inajax=1`, as the website's `showWindow` asks it.
  static String _withInfloat(String url) {
    final query = Uri.tryParse(url)?.queryParameters ?? const {};
    return [
      url,
      if (query['infloat'] != 'yes') 'infloat=yes',
      if (query['inajax'] != '1') 'inajax=1',
    ].join('&');
  }

  /// Submit the switch user group request to server.
  ///
  /// The forum's app API (plugin 2.6.0) answers the result as JSON ([tsdmAppWriteResultOf]): the success hook is
  /// the success, the error hook, a refusal page or the login prompt fail with the forum's message; an older plugin
  /// answers the AJAX fragment, read as before.
  AsyncVoidEither submitSwitchRequest(int gid, String formHash) => _post(_buildSubmitUrl(gid), <String, String>{
    'referer': '$baseUrl/?mod=spacecp&ac=usergroup&do=expiry',
    'groupsubmit': 'true',
    'gid': '',
    // Discuz X5 uses "switchgrouphk" as handle key in the switch link, X3 used "group".
    'handlekey': _handleKey,
    'formhash': formHash,
  });

  AsyncVoidEither _post(String url, Map<String, String> body) =>
      getIt.get<NetClientProvider>().postForm(url, data: body).mapHttp((resp) => resp.data).flatMap((data) {
        if (tsdmAppWriteResultOf(data) case final result?) {
          if (result.kind != TsdmAppWriteKind.page && result.succeeded) {
            return AsyncEither.right(());
          }
          return AsyncEither.left(
            result.reason.isEmpty
                ? SwitchUserGroupFailed('unknown error')
                : SwitchUserGroupFailed(result.reason, reason: result.reason),
          );
        }
        final respData = tsdmAppAnswerText(data);
        // If succeeded.
        if (respData.contains('succeedhandle_$_handleKey') || respData.contains('succeedhandle_group')) {
          return AsyncEither.right(());
        }

        final xmlDoc = parseXmlDocument(respData);
        final htmlBodyData = xmlDoc.documentElement?.nodes.firstOrNull?.text;
        if (htmlBodyData == null) {
          return AsyncEither.left(SwitchUserGroupFailed('xml not found'));
        }
        final htmlDoc = parseHtmlDocument(htmlBodyData).body;
        // Try find the error message in `<div class="alert_error">`
        final msg = htmlDoc?.querySelector('div.alert_error')?.innerText.trim();
        if (msg == null) {
          error('failed to parse the error message, original data was: ${htmlDoc?.outerHtml}');
          return AsyncEither.left(SwitchUserGroupFailed('unknown error'));
        }
        return AsyncEither.left(SwitchUserGroupFailed(msg, reason: msg));
      });
}
