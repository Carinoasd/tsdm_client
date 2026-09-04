import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Parsers for the Discuz! login progress.
///
/// Both the login form and the login result are xml documents wrapping html in CDATA:
///
/// ```xml
/// <?xml version="1.0" encoding="utf-8"?>
/// <root><![CDATA[ ... ]]></root>
/// ```
abstract final class LoginParser {
  static final _layerLoginRe = RegExp(r'layer_login_(?<Hash>\w+)');
  static final _formHashRe = RegExp(r'formhash" value="(?<FormHash>\w+)"');
  static final _secCodeHashRe = RegExp(r'seccodehash" value="(?<Hash>\w+)"');

  /// Result message of login request.
  ///
  /// * Success: `succeedhandle_login('URL', 'MESSAGE', {'username':'NAME','usergroup':'GROUP','uid':'UID'})`
  /// * Failure: `errorhandle_login('MESSAGE', {})`
  static final _loginSucceedRe = RegExp(
    r"succeedhandle_login\('[^']*',\s*'(?<message>[^']*)',\s*(?<values>\{.*?\})\);",
  );
  static final _loginErrorRe = RegExp(r"errorhandle_login\('(?<message>[^']*)'");
  static final _loginValueRe = RegExp(r"'(?<key>\w+)':'(?<value>[^']*)'");

  /// Parse [LoginHash] from the login form page [data].
  ///
  /// The form is fetched from `member.php?mod=logging&action=login&infloat=yes&handlekey=login&inajax=1`.
  static Either<AppException, LoginHash> parseLoginHash(String data) {
    final loginHash = _layerLoginRe.firstMatch(data)?.namedGroup('Hash');
    if (loginHash == null) {
      return left(LoginFormHashNotFoundException());
    }
    final formHash = _formHashRe.firstMatch(data)?.namedGroup('FormHash');
    if (formHash == null) {
      return left(LoginInvalidFormHashException());
    }
    final secCodeHash = _secCodeHashRe.firstMatch(data)?.namedGroup('Hash');
    return right(LoginHash(formHash: formHash, loginHash: loginHash, secCodeHash: secCodeHash));
  }

  /// Parse the response [data] of login request.
  ///
  /// Return the logged user info if succeeded.
  static Either<AppException, UserLoginInfo> parseLoginResult(String data) {
    final succeedMatch = _loginSucceedRe.firstMatch(data);
    if (succeedMatch == null) {
      final message = _loginErrorRe.firstMatch(data)?.namedGroup('message');
      if (message == null) {
        return left(LoginMessageNotFoundException());
      }
      return left(mapLoginErrorMessage(message));
    }

    final values = <String, String>{
      for (final m in _loginValueRe.allMatches(succeedMatch.namedGroup('values')!))
        m.namedGroup('key')!: m.namedGroup('value')!,
    };
    final username = values['username'];
    final uid = values['uid']?.parseToInt();
    if (username == null || uid == null) {
      return left(LoginUserInfoIncompleteException());
    }
    return right(UserLoginInfo(username: username, uid: uid));
  }

  /// Map the error [message] in login response to exception.
  ///
  /// Messages are defined in Discuz! language file `lang_message.php`:
  ///
  /// * `login_invalid`: 抱歉，您输入的密码有误
  /// * `login_strike`: 密码错误次数过多，请 15 分钟后重新登录
  /// * `login_seccheck2`: 抱歉，验证码填写错误
  /// * `login_question_invalid`: 安全提问答案错误
  static AppException mapLoginErrorMessage(String message) {
    if (message.contains('验证码')) {
      return LoginIncorrectCaptchaException();
    }
    if (message.contains('安全提问')) {
      return LoginIncorrectSecurityQuestionException();
    }
    if (message.contains('次数过多') || message.contains('分钟后')) {
      return LoginAttemptLimitException();
    }
    if (message.contains('密码') || message.contains('用户名') || message.contains('不存在')) {
      return LoginInvalidCredentialException();
    }
    return LoginOtherErrorException(message);
  }
}
