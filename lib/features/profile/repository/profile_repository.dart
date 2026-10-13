import 'dart:convert';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/models.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

// Re-export the avatar parser for users of the profile page document (e.g. homepage bloc).
export 'package:tsdm_client/features/profile/utils/parse_profile.dart' show parseProfileAvatarUrl;

/// Repository to get profile page.
final class ProfileRepository with LoggerMixin {
  static const _profileV2Target = '$baseUrl/home.php?mobile=yes&tsdmapp=1&mod=space';
  static const _editAvatarPage = '$baseUrl/home.php?mod=spacecp&ac=avatar';

  /// Profile page of the logged user, fetched for the account [_loggedUserUid].
  uh.Document? _loggedUserDocument;

  /// Uid of the account [_loggedUserDocument] belongs to.
  ///
  /// The repository is app wide and outlives account switches and logouts, so the cache only answers for the account
  /// in use: after a quick account switch the profile page and its unread counts showed the previous account until
  /// the homepage happened to reload it (GitHub #184 follow-up).
  int? _loggedUserUid;

  /// Cached profile v2 for current logged user.
  UserProfileV2? _loggedProfileV2;

  /// [_loggedUserDocument] when it belongs to the account in use, null otherwise.
  uh.Document? get _currentCache {
    final document = _loggedUserDocument;
    if (document == null) {
      return null;
    }
    final uid = getIt.get<SettingsRepository>().currentSettings.loginUid;
    return uid != 0 && uid == _loggedUserUid ? document : null;
  }

  /// Check has cached html [_loggedUserDocument] for logged user or not.
  bool hasCache() => _currentCache != null;

  /// Get the cached [_loggedUserDocument] for logged user.
  uh.Document? getCache() => _currentCache;

  /// Clear cache as logged out.
  void logout() {
    _loggedUserDocument = null;
    _loggedUserUid = null;
  }

  /// Profile page document cache;

  /// Fetch profile page from server.
  ///
  /// * Try to get the profile page of [uid] or [username] if provided.
  /// * Try to get current logged user profile if no parameter provided.
  /// * Return null if not logged in.
  AsyncEither<uh.Document> fetchProfile({String? username, String? uid, bool force = false}) => AsyncEither(() async {
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
        final document = tsdmAppPageDocument(value.data);
        // Not when the account changed while the page was on its way: it belongs to the previous one.
        if (loggedUid != null && getIt.get<SettingsRepository>().currentSettings.loginUid == loggedUid) {
          _loggedUserDocument = document;
          _loggedUserUid = loggedUid;
        }
        return right(document);
    }
  });

  /// Fetch user avatar for current user.
  ///
  /// Parsed from the html profile page of current logged user because the v2 API is gone.
  AsyncEither<String> fetchAvatarUrl({bool force = false}) => fetchProfile(force: force).flatMap((doc) {
    if (!isLoggedInDocument(doc)) {
      // Session expired, the server rendered a guest page.
      error('failed to fetch avatar url: not logged in');
      return TaskEither<AppException, String>.left(ProfileNeedLoginException());
    }
    return switch (parseProfileAvatarUrl(doc)) {
      final String url => TaskEither.right(url),
      null => () {
        error('failed to fetch avatar url: avatar not found in profile page');
        return TaskEither<AppException, String>.left(ProfileStatusNotFoundException());
      }(),
    };
  });

  /// Fetch user profile through API.
  ///
  /// ## CAUTION
  ///
  /// The API is GONE since the server upgraded to Discuz X5: the server responds a normal html page instead of json.
  /// This function detects the non-json response and returns [ProfileStatusNotFoundException] gracefully, prefer
  /// [fetchProfile] with html parsing.
  ///
  /// ## Return value
  ///
  /// ### Success
  ///
  /// ```json
  /// {
  ///   "status": 0,
  ///   ... // Other fields can be converted into UserProfileV2.
  /// }
  /// ```
  ///
  /// ### Failure
  ///
  /// ```json
  /// {
  ///   "status": -1,
  ///   "message": "login_before_enter_home",
  ///   "url": null,
  ///   "extra": {
  ///     "showmsg": "1",
  ///     "login": "1"
  ///   },
  ///   "values": []
  /// }
  /// ```
  AsyncEither<UserProfileV2> fetchProfileV2({String? username, String? uid, bool force = false}) {
    return AsyncEither(() async {
      debug('fetch profile page v2');
      late final String targetUrl;
      late final bool isLoggedUserProfile;
      if (uid != null) {
        targetUrl = '$_profileV2Target&username=$uid';
        isLoggedUserProfile = false;
      } else if (username != null) {
        targetUrl = '$_profileV2Target&uid=$username';
        isLoggedUserProfile = false;
      } else {
        targetUrl = _profileV2Target;
        isLoggedUserProfile = true;
      }

      if (!force && _loggedProfileV2 != null) {
        return right(_loggedProfileV2!);
      }

      switch (await NetClientProvider.build(forceDesktop: false).get(targetUrl).run()) {
        case Left(:final value):
          return left(value);
        case Right(:final value):
          final Map<String, dynamic> jsonMap;
          try {
            final decoded = jsonDecode(value.data as String);
            if (decoded is! Map<String, dynamic>) {
              error('failed to fetch profile v2: response is not a json object');
              return left(ProfileStatusNotFoundException());
            }
            jsonMap = decoded;
          } on FormatException catch (e) {
            error('failed to fetch profile v2: response is not json (API gone?): $e');
            return left(ProfileStatusNotFoundException());
          }
          if (!jsonMap.containsKey('status')) {
            error('failed to fetch profile v2: status not found');
            return left(ProfileStatusNotFoundException());
          }
          final status = jsonMap['status'] as int?;
          if (status == -1) {
            error(
              'failed to fetch profile v2: '
              'message=${jsonMap.lookup("message")}',
            );
            return left(ProfileNeedLoginException());
          }
          if (status != 0) {
            error('failed to fetch profile v2: unknown status $status');
            return left(ProfileStatusUnknownException(jsonMap['status'].toString()));
          }
          // status is zero
          final userProfile = UserProfileV2Mapper.fromMap(jsonMap);

          if (isLoggedUserProfile) {
            _loggedProfileV2 = userProfile;
          }

          return right(userProfile);
      }
    });
  }

  /// Load the current using avatar url from server.
  AsyncEither<(String, String)> loadAvatarUrl() => getIt
      .get<NetClientProvider>()
      .get(_editAvatarPage)
      .mapHttp((v) => parseHtmlDocument(v.data as String))
      .map(
        (v) => (
          v.querySelector('input[name="headedit"]')?.attributes['value'],
          v.querySelector('input[name="formhash"]')?.attributes['value'],
        ),
      )
      .flatMap(
        (v) => switch (v) {
          (final String avatarUrl, final String formHash) => TaskEither.right((avatarUrl, formHash)),
          (_, _) => TaskEither.left(EditAvatarUrlNotFound()),
        },
      );

  /// Upload the new avatar [url] to server.
  AsyncVoidEither uploadAvatarUrl({required String url, required String formHash}) => getIt
      .get<NetClientProvider>()
      .postForm(_editAvatarPage, data: <String, String>{'headedit': url, 'formhash': formHash, 'headsubmit': 'true'})
      .mapHttp((v) => v);
}
