// Captured server responses are concatenated verbatim, no whitespace between fragments.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/utils/login_parser.dart';

/// Real login responses captured from the forum server (Discuz! X5).
const _loginFailed =
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<root><![CDATA[抱歉，您输入的密码有误<script type="text/javascript" reload="1">'
    "if(typeof errorhandle_login=='function') {errorhandle_login('抱歉，您输入的密码有误', {});}</script>]]></root>";

const _loginSucceed =
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<root><![CDATA[<script type="text/javascript" reload="1">'
    "if(typeof succeedhandle_login=='function') {succeedhandle_login('https://www.tsdm39.com/forum.php', "
    "'欢迎您回来，超级版主 大和啦，现在将转入登录前页面', "
    "{'username':'大和啦','usergroup':'<font color=\\\"Red\\\">超级版主</font>','uid':'1113'});}"
    '</script>]]></root>';

void main() {
  test('parse login form', () {
    final data = File('test/data/login_form.xml').readAsStringSync();
    final hash = LoginParser.parseLoginHash(data).unwrap();
    expect(hash.loginHash, 'LOr87');
    expect(hash.formHash, '6ec78a6a');
    expect(hash.secCodeHash, isNull);
    expect(hash.needCaptcha, isFalse);
  });

  test('parse login form with captcha', () {
    final data = File('test/data/login_form.xml').readAsStringSync().replaceFirst(
      '<input type="hidden" name="formhash"',
      '<input type="hidden" name="seccodehash" value="SAbcd" /><input type="hidden" name="formhash"',
    );
    final hash = LoginParser.parseLoginHash(data).unwrap();
    expect(hash.secCodeHash, 'SAbcd');
    expect(hash.needCaptcha, isTrue);
  });

  test('parse invalid login form', () {
    expect(LoginParser.parseLoginHash('<root></root>').unwrapErr(), isA<LoginFormHashNotFoundException>());
  });

  test('parse login failure', () {
    expect(LoginParser.parseLoginResult(_loginFailed).unwrapErr(), isA<LoginInvalidCredentialException>());
  });

  test('parse login success', () {
    final user = LoginParser.parseLoginResult(_loginSucceed).unwrap();
    expect(user.username, '大和啦');
    expect(user.uid, 1113);
  });

  test('map error messages', () {
    expect(LoginParser.mapLoginErrorMessage('抱歉，验证码填写错误'), isA<LoginIncorrectCaptchaException>());
    expect(LoginParser.mapLoginErrorMessage('密码错误次数过多，请 15 分钟后重新登录'), isA<LoginAttemptLimitException>());
    expect(LoginParser.mapLoginErrorMessage('安全提问答案错误'), isA<LoginIncorrectSecurityQuestionException>());
    expect(LoginParser.mapLoginErrorMessage('something else'), isA<LoginOtherErrorException>());
  });
}
