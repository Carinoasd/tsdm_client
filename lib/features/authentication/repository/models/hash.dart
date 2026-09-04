part of 'models.dart';

/// A group of login hash used in login or logout progress.
@MappableClass()
class LoginHash with LoginHashMappable {
  /// Constructor.
  const LoginHash({required this.formHash, required this.loginHash, this.secCodeHash});

  /// Form hash.
  final String formHash;

  /// Login hash.
  ///
  /// The random string in login form id `loginform_${loginHash}`, need to append to the login url.
  final String loginHash;

  /// Hash of captcha (called "seccode" in Discuz!).
  ///
  /// Only exists when the server requires a captcha to login.
  ///
  /// Captcha image can be fetched from `misc.php?mod=seccode&idhash=${secCodeHash}`.
  final String? secCodeHash;

  /// Whether a captcha is required.
  bool get needCaptcha => secCodeHash != null;
}
