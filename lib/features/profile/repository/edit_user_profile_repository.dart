import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/birthday_info.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart';
import 'package:tsdm_client/features/profile/models/profile_form_api.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

typedef _Keys = UserProfileKeys;

/// The repository provide functionality about editing user profile.
final class EditUserProfileRepository with LoggerMixin {
  /// Constructor; [currentUid] tells the account the editor is asked for (the logged in account by default).
  EditUserProfileRepository({int Function()? currentUid}) : _currentUid = currentUid ?? currentLoginUid;

  final int Function() _currentUid;

  static const _pageUrl = '$baseUrl/home.php?mod=spacecp';

  /// The editor of the forum's app API the last profile was loaded from (plugin 3.0.0), null when it was parsed from
  /// the web page.
  ProfileApiForm? _apiForm;

  /// The editor of the forum's app API of the profile loaded last, for tests.
  ProfileApiForm? get apiForm => _apiForm;

  AsyncEither<UserProfile> _parseProfilePage(uh.Document doc) => AsyncEither(() async {
    final v = doc.querySelector('form[target="frame_profile"]');
    if (v == null) {
      error('failed to fetch editable user profile: form not found');
      return left(EditUserProfileFormNotFound());
    }
    final profile = UserProfile.fromForm(v);
    if (profile == null) {
      error('failed to fetch editable user profile: invalid form');
      return left(EditUserProfileFormNotFound());
    }

    return right(profile);
  });

  /// Load profile from page.
  ///
  /// The editor is asked as a small form of the forum's app API ([withTsdmAppForm], plugin 3.0.0): the fields the
  /// page printed ([ProfileApiForm.fromApi]: only those are shown and posted), or the forum's message instead of it
  /// (the login prompt, a locked account: [EditUserProfileFormNotFound] with its text), served to the account that
  /// asked or never used. An older plugin, or none, answers the web page itself, which is parsed as before; a form
  /// with other plugins' fields or something the plugin says the app cannot fill (`hook_fields`, `unsupported`), and
  /// any other answer, have the page asked again the way it always was.
  AsyncEither<UserProfile> loadProfile() => AsyncEither(() async {
    _apiForm = null;
    final uid = _currentUid();
    final Object? data;
    switch (await getIt.get<NetClientProvider>().get(withTsdmAppForm(_pageUrl, page: true)).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        data = value.data;
    }
    switch (smallFormAnswerOf(data, SmallFormKind.profile)) {
      case final SmallFormAnswer answer when answer.identityProblem(uid) != null:
        return left(EditUserProfileFormNotFound(reason: answer.identityProblem(uid)));
      case final SmallFormMessage message:
        return left(EditUserProfileFormNotFound(reason: message.reason));
      case final SmallFormFields form when form.usable:
        if (ProfileApiForm.fromApi(form) case final api?) {
          _apiForm = api;
          return right(api.profile);
        }
      case _:
        break;
    }
    if (data is String && tsdmAppAnswerJson(data) == null) {
      // The web page: a forum without the plugin, or with one older than 3.0.0. Read as it always was.
      return _parseProfilePage(parseHtmlDocument(data)).run();
    }
    return getIt
        .get<NetClientProvider>()
        .get(_pageUrl)
        .mapHttp((v) => parseHtmlDocument(v.data as String))
        .flatMap(_parseProfilePage)
        .run();
  });

  /// Upload user profile [profile] to server.
  ///
  /// The forum answers the editor's frame a `parent.show_success('')` script when the profile was saved, and its
  /// 提示信息 page otherwise. With the forum's app API (plugin 2.6.0) that comes as the write result
  /// ([tsdmAppWriteResultOf]): the script as a `page` (a `parent.show_error(` page is not `ok`), the message as a
  /// `message` with its verdict; an older plugin answers the forum's page, read as before.
  ///
  /// A profile loaded from the forum's app API (plugin 3.0.0) posts the page's fields as served with the member's
  /// changes over them ([ProfileApiForm.bodyWith]) to its `submit.url`; a field the forum refuses
  /// (`parent.show_error("field")`: a required one left empty, a value not among its choices) is named by its title.
  AsyncVoidEither uploadProfile(UserProfile profile) {
    final api = _apiForm;
    if (api != null && profile.apiKeys != null) {
      final body = api.bodyWith(profile);
      if (body == null) {
        return AsyncVoidEither.left(EditUserProfileUploadFailed());
      }
      return _upload(api.submitUrl, body, api: api);
    }
    return _upload('$baseUrl/home.php?mod=spacecp&ac=profile&op=base', _webBody(profile));
  }

  /// The fields the profile [profile] parsed from the web page is posted with: every field the app knows.
  static Map<String, String> _webBody(UserProfile profile) => <String, String>{
    'formhash': profile.formHash,
    _Keys.gender: profile.gender.value.toString(),
    _Keys.gender.visibility(): profile.genderVisibility.value.toString(),
    _Keys.birthYear: '${profile.birthdayYear ?? "0"}',
    _Keys.birthMonth: '${profile.birthdayMonth ?? "0"}',
    _Keys.birthday: '${profile.birthdayDay ?? "0"}',
    _Keys.birthday.visibility(): profile.birthdayVisibility.value.toString(),
    _Keys.qq: '${profile.qq ?? ""}',
    _Keys.qq.visibility(): profile.qqVisibility.value.toString(),
    _Keys.msn: profile.msn ?? '',
    _Keys.msn.visibility(): profile.msnVisibility.value.toString(),
    _Keys.homepage: profile.homepage ?? '',
    _Keys.homepage.visibility(): profile.homepageVisibility.value.toString(),
    _Keys.bio: profile.bio,
    _Keys.bio.visibility(): profile.bioVisibility.value.toString(),
    _Keys.hobby: profile.hobby ?? '',
    _Keys.hobby.visibility(): profile.hobbyVisibility.value.toString(),
    _Keys.location: profile.location ?? '',
    _Keys.location.visibility(): profile.locationVisibility.value.toString(),
    _Keys.nickname: profile.nickname ?? '',
    _Keys.nickname.visibility(): profile.nicknameVisibility.value.toString(),
    _Keys.wordsToSay: profile.wordsToSay ?? '',
    _Keys.wordsToSay.visibility(): profile.wordsToSayVisibility.value.toString(),
    _Keys.skill: profile.skill ?? '',
    _Keys.skill.visibility(): profile.skillVisibility.value.toString(),
    _Keys.favoriteBangumi: profile.favoriteBangumi ?? '',
    _Keys.favoriteBangumi.visibility(): profile.favoriteBangumiVisibility.value.toString(),
    _Keys.pageStyle: profile.pageStyle?.value.toString() ?? '0',
    _Keys.customTitle: profile.customTitle ?? '',
    _Keys.signature: profile.signature ?? '',
    _Keys.timezone: profile.timeZone?.value ?? '0',
    'profilesubmit': 'true',
    'profilesubmitbtn': 'true',
  };

  static final _showErrorRe = RegExp(r'''show_error\(\s*["']([^"']+)["']''');

  AsyncVoidEither _upload(String url, Map<String, String> body, {ProfileApiForm? api}) =>
      getIt.get<NetClientProvider>().postMultipartForm(url, data: body).mapHttp((v) => v.data).flatMap((data) {
        final result = tsdmAppWriteResultOf(data);
        final bool saved;
        final String? failure;
        if (result != null) {
          // As without the plugin: the editor's frame is answered `parent.show_success('')` when the profile was
          // saved (a `page`; a `parent.show_error(` page is not `ok`). A 提示信息 page counts only when the forum
          // shows it as a success (`alert_right`): the hook of an AJAX form, a redirect or a note is no proof.
          saved = switch (result.kind) {
            TsdmAppWriteKind.page => result.ok && result.documentHtml.contains('show_success'),
            TsdmAppWriteKind.message => result.succeeded && result.alert == 'right',
            TsdmAppWriteKind.handle || TsdmAppWriteKind.redirect => false,
          };
          failure = result.reason.isNotEmpty
              ? result.reason
              : result.document.querySelector('div#messagetext > p')?.innerText;
        } else {
          final doc = tsdmAppAnswerText(data);
          saved = doc.contains('show_success');
          failure = parseHtmlDocument(doc).querySelector('div#messagetext > p')?.innerText;
        }
        if (saved) {
          return TaskEither<AppException, void>.right(null);
        }
        error('failed to upload user profile: $failure');
        if (api == null) {
          return TaskEither<AppException, void>.left(EditUserProfileUploadFailed());
        }
        // The editor of the forum's app API: the forum's words, or the field it refused by the title it printed.
        final refused = result == null ? null : _showErrorRe.firstMatch(result.documentHtml)?.group(1);
        final reason = refused != null
            ? t.editUserProfilePage.fieldRefused(field: api.titles[refused] ?? refused)
            : (failure?.trim().isNotEmpty ?? false)
            ? failure!.trim()
            : null;
        return TaskEither<AppException, void>.left(EditUserProfileUploadFailed(reason: reason));
      });
}
