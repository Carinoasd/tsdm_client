import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/avatar_upload.dart';
import 'package:tsdm_client/features/profile/utils/profile_page_api.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Repository to get profile page.
final class ProfileRepository with LoggerMixin {
  /// Constructor; [currentUid] tells the account logged in (the app's settings by default) the avatar page is
  /// checked against.
  ProfileRepository({int Function()? currentUid}) : _currentUid = currentUid;

  final int Function()? _currentUid;

  int _loginUid() => _currentUid?.call() ?? getIt.get<SettingsRepository>().currentSettings.loginUid;

  static const _editAvatarPage = '$baseUrl/home.php?mod=spacecp&ac=avatar';

  /// Profile page of the logged user, fetched for the account [_loggedUserUid].
  ProfilePage? _loggedUserPage;

  /// Uid of the account [_loggedUserPage] belongs to.
  ///
  /// The repository is app wide and outlives account switches and logouts, so the cache only answers for the account
  /// in use: after a quick account switch the profile page and its unread counts showed the previous account until
  /// the homepage happened to reload it (GitHub #184 follow-up).
  int? _loggedUserUid;

  /// [_loggedUserPage] when it belongs to the account in use, null otherwise.
  ProfilePage? get _currentCache {
    final page = _loggedUserPage;
    if (page == null) {
      return null;
    }
    final uid = getIt.get<SettingsRepository>().currentSettings.loginUid;
    return uid != 0 && uid == _loggedUserUid ? page : null;
  }

  /// Check has cached page [_loggedUserPage] for logged user or not.
  bool hasCache() => _currentCache != null;

  /// Get the cached [_loggedUserPage] for logged user.
  ProfilePage? getCache() => _currentCache;

  /// Clear cache as logged out.
  void logout() {
    _loggedUserPage = null;
    _loggedUserUid = null;
  }

  /// Fetch profile page from server.
  ///
  /// * Try to get the profile page of [uid] or [username] if provided.
  /// * Try to get current logged user profile if no parameter provided.
  /// * Return null if not logged in.
  ///
  /// The page is asked in the JSON mode of the forum's app API. An answer of plugin 2.2.0 or later carries the
  /// profile as structured fields (`schema: 4`), or is the forum's own message with `login` (please log in, no such
  /// user): a [ProfileApiPage], built by `profileFromApi`, its `document` never read. Any other answer (a web page
  /// from a forum without the plugin, an older plugin's answer, whose `document` holds the blocks of the page) is a
  /// [ProfileWebPage], parsed as the web page (`buildProfile`).
  AsyncEither<ProfilePage> fetchProfile({String? username, String? uid, bool force = false}) => AsyncEither(() async {
    debug('fetch profile page');
    late final String targetUrl;
    // Uid of the logged user whose profile is fetched, null for another user's profile.
    int? loggedUid;
    if (uid != null) {
      targetUrl = '$uidProfilePage$uid';
    } else if (username != null) {
      targetUrl = '$usernameProfilePage$username';
    } else {
      // Fetching logged user profile.
      final settings = getIt.get<SettingsRepository>().currentSettings;
      final loginUsername = settings.loginUsername;
      final loginUid = settings.loginUid;
      // TODO: Check if this condition check works during login progress.
      if (loginUsername.isEmpty || loginUid == 0) {
        warning(
          'fetch profile: not login, unsatisfied fields: '
          'name(${loginUsername.isEmpty}), uid(${loginUid == 0})',
        );
        // Not logged in.
        return left(ProfileNeedLoginException());
      }
      if (!force && _currentCache != null) {
        return right(_currentCache!);
      }
      targetUrl = '$uidProfilePage$loginUid';
      loggedUid = loginUid;
    }

    // JSON mode of the forum's app API when the forum has it (see TsdmAppApi); the web page otherwise.
    switch (await getIt.get<NetClientProvider>().get(withTsdmAppJson(targetUrl)).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        final ProfilePage page;
        if (profileApiAnswerOf(value.data) case final api?) {
          page = ProfileApiPage(api);
        } else if (tsdmAppAnswerWithoutPage(value.data)) {
          // A failed request, not a profile page of a guest (which would read as an expired session).
          return left(HttpRequestFailedException(value.statusCode));
        } else {
          page = ProfileWebPage(tsdmAppPageDocument(value.data));
        }
        // Not when the account changed while the page was on its way: it belongs to the previous one. Nor the forum's
        // message (please log in, no such user): it is not the profile of the account.
        if (loggedUid != null &&
            !(page is ProfileApiPage && page.json['ok'] != 1) &&
            getIt.get<SettingsRepository>().currentSettings.loginUid == loggedUid) {
          _loggedUserPage = page;
          _loggedUserUid = loggedUid;
        }
        return right(page);
    }
  });

  /// Fetch user avatar for current user.
  ///
  /// Parsed from the profile page of current logged user.
  AsyncEither<String> fetchAvatarUrl({bool force = false}) => fetchProfile(force: force).flatMap((page) {
    if (!page.loggedIn) {
      // Session expired, the server rendered a guest page.
      error('failed to fetch avatar url: not logged in');
      return TaskEither<AppException, String>.left(ProfileNeedLoginException());
    }
    return switch (page.avatarUrl) {
      final String url => TaskEither.right(url),
      null => () {
        error('failed to fetch avatar url: avatar not found in profile page');
        return TaskEither<AppException, String>.left(ProfileStatusNotFoundException());
      }(),
    };
  });

  /// Load the forum's avatar page: the external avatar url form and the avatar editor, each when printed.
  ///
  /// Left with [EditAvatarUrlNotFound] when the page offers neither (the forum's message instead: no permission to
  /// upload, the login prompt), and with [IdentityChangedException] when it was served to another account than the
  /// one logged in.
  AsyncEither<AvatarEditPage> loadAvatarEditPage() => getIt
      .get<NetClientProvider>()
      .get(_editAvatarPage)
      .mapHttp((v) => AvatarEditPage.parse(parseHtmlDocument(tsdmAppAnswerText(v.data))))
      .flatMap((page) {
        final uid = _loginUid();
        if (page.uid != null && page.uid != uid) {
          return TaskEither<AppException, AvatarEditPage>.left(IdentityChangedException());
        }
        if (!page.hasExternal && !page.hasUpload) {
          return TaskEither<AppException, AvatarEditPage>.left(EditAvatarUrlNotFound());
        }
        return TaskEither.right(page);
      });

  /// Upload the avatar [images] with the forum's avatar editor.
  ///
  /// The url the editor posts to is signed for the account and the user agent that opened the page, and only for a
  /// while, so the page is opened again right before the images are posted (once: never sent twice). The forum then
  /// opens the page once more, as the editor reloads it after saving, which marks the account as having an avatar.
  /// Not posted when the account changed, or the page has no editor any more.
  AsyncVoidEither uploadAvatarImages(AvatarImages images) => loadAvatarEditPage().flatMap((page) {
    final url = page.uploadUrl;
    final uid = _loginUid();
    if (page.uid == null || page.uid != uid) {
      return TaskEither<AppException, void>.left(IdentityChangedException());
    }
    if (url == null) {
      return TaskEither<AppException, void>.left(EditAvatarUrlNotFound());
    }
    return getIt
        .get<NetClientProvider>()
        .postForm(url, data: images.toBody(), singleAttempt: true, tsdmAppJson: false)
        .mapHttp((v) => tsdmAppAnswerText(v.data))
        .flatMap((body) {
          final answer = AvatarUploadAnswer.parse(body);
          if (answer != AvatarUploadAnswer.success) {
            error('failed to upload avatar: $answer');
            return TaskEither<AppException, void>.left(EditAvatarUploadFailed(answer.name));
          }
          return getIt.get<NetClientProvider>().get(_editAvatarPage).map((_) {});
        });
  });

  /// Upload the new avatar [url] to server.
  AsyncVoidEither uploadAvatarUrl({required String url, required String formHash}) => getIt
      .get<NetClientProvider>()
      .postForm(_editAvatarPage, data: <String, String>{'headedit': url, 'formhash': formHash, 'headsubmit': 'true'})
      .mapHttp((v) => v);
}
