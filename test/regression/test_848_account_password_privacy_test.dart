/// The password, the security question and the email changed through the forum's account center (Discuz! X5
/// `home.php?mod=spacecp&ac=account`), and the privacy settings (`ac=privacy`, every tab but the ignore filter).
///
/// The samples under `test/data/account/` are answers of a Discuz! X5.0.2 forum with the tsdmapp plugin 3.7.0, the
/// values of the account replaced (form hash, signature, uid, name, email):
///
/// * the account center lists the ways (`op=verify&method=chgpassword|chgquestion|chgemail`); opening one is an AJAX
///   float that either says "验证通过" with the signed link of the way's form (`showWindow("chgpassword", "…&sign=…")`)
///   when the site asks for no check (`security_verify` empty), or lets the user choose the check
///   (`verify=password`): the current password is posted (`security_submit`) and the answer carries the signed link;
/// * the way's form is posted back to its signed url (`submit=yes`); the forum answers `account_change_success`
///   ("修改成功") and, for a new password, ends every session of the account;
/// * the privacy page has a form per tab; saving one replaces every setting of the tab with what is sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/account_security/cubit/account_security_cubit.dart';
import 'package:tsdm_client/features/account_security/models/account_security.dart';
import 'package:tsdm_client/features/account_security/repository/account_security_repository.dart';
import 'package:tsdm_client/features/account_security/utils/account_security_parser.dart';
import 'package:tsdm_client/features/account_security/view/account_security_page.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

const _uid = 31;
const _dir = 'test/data/account';

/// Typed into the forms of the tests; never in a sample, never in the log.
const _current = 'Current-Secret-1';
const _new = 'New-Secret-2';

String _read(String name) => File('$_dir/$name').readAsStringSync();

/// A forum answering the account center and the privacy page from the samples.
final class _Forum implements HttpClientAdapter {
  _Forum({this.asksPassword = false});

  /// The site asks for the current password (`security_verify` has `password`).
  final bool asksPassword;

  /// The answer to the way's form, a sample name.
  String submitAnswer = 'result_password_done_v13.json';

  /// The answer to the password check, a sample name.
  String verifyAnswer = 'verify_ok_x5.xml';

  /// Fail the posts at the transport level.
  bool failPost = false;

  /// Answer the privacy posts with the redirect the forum sends after a form it handled.
  bool redirectPrivacy = false;

  /// Hold the answer to the way's form until it completes.
  Completer<void>? holdSubmit;

  /// The privacy tabs with their pages, by `op`.
  final privacyPages = <String, String>{
    'base': _read('privacy_base_x5.html'),
    'feed': _read('privacy_feed_x5.html'),
    'other': _read('privacy_other_x5.html'),
  };

  /// Apply the privacy posts to [privacyPages].
  bool applyPrivacy = true;

  final gets = <Uri>[];
  final posts = <({Uri uri, Map<String, String> form})>[];

  static ResponseBody _answer(String body) => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: [
        if (body.startsWith('{')) 'application/json; charset=utf-8' else 'text/html; charset=utf-8',
      ],
    },
  );

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? _) async {
    final uri = options.uri;
    final q = uri.queryParameters;
    if (options.method == 'GET') {
      gets.add(uri);
      if (q['ac'] == 'privacy') {
        return _answer(privacyPages[q['op']] ?? '<html></html>');
      }
      if (q['ac'] == 'account' && q['op'] == 'verify') {
        if ((q['sign'] ?? '').isNotEmpty) {
          return _answer(
            _read(switch (q['method']) {
              'chgquestion' => 'form_question_x5.xml',
              'chgemail' => 'form_email_x5.xml',
              _ => 'form_password_x5.xml',
            }),
          );
        }
        if (q['verify'] == 'password') {
          return _answer(_read('verify_password_x5.xml'));
        }
        if (asksPassword) {
          return _answer(_read('choose_password_x5.xml').replaceAll('chgpassword', q['method']!));
        }
        return _answer(_read('open_signed_x5.xml').replaceAll('chgpassword', q['method']!));
      }
      if (q['ac'] == 'account') {
        return _answer(_read('account_center_x5.html'));
      }
      return _answer('<html></html>');
    }
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)));
    }
    final form = Uri.splitQueryString(body);
    posts.add((uri: uri, form: form));
    if (failPost) {
      throw DioException.connectionError(requestOptions: options, reason: 'reset');
    }
    if (q['ac'] == 'privacy') {
      final op = q['op']!;
      if (applyPrivacy) {
        privacyPages[op] = _applied(privacyPages[op]!, form);
      }
      if (redirectPrivacy) {
        return ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['home.php?mod=spacecp&ac=privacy&op=$op'],
          },
        );
      }
      return _answer(_read('result_privacy_v13.json'));
    }
    if (q['security_submit'] == 'yes') {
      return _answer(_read(verifyAnswer));
    }
    await holdSubmit?.future;
    return _answer(_read(submitAnswer));
  }

  /// [page] with the selects and the checkboxes set as in [form].
  static String _applied(String page, Map<String, String> form) {
    final out = page.replaceAllMapped(RegExp('<select name="([^"]+)">(.*?)</select>', dotAll: true), (m) {
      final value = form[m.group(1)];
      final options = m
          .group(2)!
          .replaceAll(RegExp(' selected(="selected")?'), '')
          .replaceAll('<option value="$value">', '<option value="$value" selected>');
      return '<select name="${m.group(1)}">$options</select>';
    });
    return out.replaceAllMapped(RegExp('<input type="checkbox" class="pc" name="([^"]+)" value="1"( checked)? />'), (
      m,
    ) {
      final on = form.containsKey(m.group(1));
      return '<input type="checkbox" class="pc" name="${m.group(1)}" value="1"${on ? ' checked' : ''} />';
    });
  }

  @override
  void close({bool force = false}) {}
}

AccountSecurityRepository _repo(_Forum forum) => AccountSecurityRepository(
  buildClient: (_) => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(maxHistoryItems: 10000)));

  setUp(() {
    talker.cleanHistory();
    getIt
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver());
  });

  tearDown(() async {
    // No password typed into a form ever reaches the log.
    final log = talker.history.map((e) => e.generateTextMessage()).join('\n');
    expect(log, isNot(contains(_current)));
    expect(log, isNot(contains(_new)));
    await getIt.reset();
  });

  group('parsing', () {
    test('the account center lists the three ways the app handles, in the forum order', () {
      final overview = parseAccountOverview(_read('account_center_x5.html'), expectedUid: _uid)!;
      expect(overview.formHash, 'f1f2f3f4');
      expect(overview.items.map((e) => e.method), [
        AccountMethod.password,
        AccountMethod.question,
        AccountMethod.email,
      ]);
      expect(overview.items.map((e) => e.title), ['账号密码', '安全问题', '安全邮箱']);
      // The masked email is shown; the password's asterisks and the hints are not.
      expect(overview.items.map((e) => e.value), ['', '', 'tes****@example.com']);
    });

    test('the account center of another account, or a guest page, is not taken', () {
      expect(parseAccountOverview(_read('account_center_x5.html'), expectedUid: 32), isNull);
      expect(
        parseAccountOverview(
          '<html><body><form id="lsform"></form><div id="messagetext" class="alert_info"><p>请先登录</p></div></body></html>',
          expectedUid: _uid,
        ),
        isNull,
      );
    });

    test('opening without a check answers the signed link of the way', () {
      final step = parseAccountStep(_read('open_signed_x5.xml'), method: AccountMethod.password);
      expect(step, isA<AccountStepSigned>());
      final url = (step as AccountStepSigned).url;
      expect(url.host, baseHost);
      expect(url.queryParameters, containsPair('method', 'chgpassword'));
      expect(url.queryParameters, containsPair('sign', '0123456789abcdef'));
      // The link of another way is not this one's.
      expect(
        parseAccountStep(_read('open_signed_x5.xml'), method: AccountMethod.email),
        isNot(isA<AccountStepSigned>()),
      );
    });

    test('the password form: two hidden inputs, the forum labels, the submit flag', () {
      final step = parseAccountStep(_read('form_password_x5.xml'), method: AccountMethod.password);
      final form = (step as AccountStepForm).form;
      expect(form.action.host, baseHost);
      expect(form.action.queryParameters, containsPair('submit', 'yes'));
      expect(form.hidden, containsAll([('formhash', 'f1f2f3f4'), ('submit', 'true')]));
      expect(form.fields.map((e) => (e.name, e.label)), [('newpassword', '新密码'), ('renewpassword', '确认新密码')]);
      expect(form.fields.every((e) => e is AccountTextField && e.obscure), isTrue);
    });

    test('the question form: the forum options, "keep" selected; the email form: one text field', () {
      final question =
          (parseAccountStep(_read('form_question_x5.xml'), method: AccountMethod.question) as AccountStepForm).form;
      final choice = question.fields.first as AccountChoiceField;
      expect(choice.name, 'questionidnew');
      expect(choice.label, '安全提问');
      expect(choice.initial, '');
      expect(choice.options.length, 9);
      expect(choice.options[1], ('0', '无安全提问'));
      expect(question.fields[1], isA<AccountTextField>().having((e) => e.obscure, 'obscure', isFalse));
      final email = (parseAccountStep(_read('form_email_x5.xml'), method: AccountMethod.email) as AccountStepForm).form;
      expect(email.fields.map((e) => (e.name, e.label)), [('email', '新邮箱')]);
    });

    test('a form posting elsewhere, or a password asked in plain text, is refused', () {
      final foreign = _read(
        'form_password_x5.xml',
      ).replaceFirst('action="home.php', 'action="https://evil.example/home.php');
      expect(parseAccountStep(foreign, method: AccountMethod.password), isA<AccountStepUnknown>());
      final plain = _read(
        'form_password_x5.xml',
      ).replaceFirst('type="password" name="renewpassword"', 'type="text" name="renewpassword"');
      expect(parseAccountStep(plain, method: AccountMethod.password), isA<AccountStepUnknown>());
      final extra = _read(
        'form_password_x5.xml',
      ).replaceFirst('</table>', '<tr><td><textarea name="x"></textarea></td></tr></table>');
      expect(parseAccountStep(extra, method: AccountMethod.password), isA<AccountStepUnknown>());
    });

    test('the choice of the check, the password check and its answers', () {
      final choose = parseAccountStep(_read('choose_password_x5.xml'), method: AccountMethod.password);
      expect(choose, isA<AccountStepChoose>().having((e) => e.others, 'others', isFalse));
      expect((choose as AccountStepChoose).password?.queryParameters, containsPair('verify', 'password'));
      final email = _read('choose_password_x5.xml').replaceAll('verify=password', 'verify=email');
      expect(
        parseAccountStep(email, method: AccountMethod.password),
        isA<AccountStepChoose>()
            .having((e) => e.password, 'password', isNull)
            .having((e) => e.others, 'others', isTrue),
      );
      final verify = parseAccountStep(_read('verify_password_x5.xml'), method: AccountMethod.password);
      expect((verify as AccountStepVerify).form.hidden, contains(('security_submit', 'true')));
      expect(parseAccountStep(_read('verify_ok_x5.xml'), method: AccountMethod.password), isA<AccountStepSigned>());
      expect(
        parseAccountStep(_read('verify_wrong_x5.xml'), method: AccountMethod.password),
        isA<AccountStepMessage>().having((e) => e.text, 'text', '账号密码错误').having((e) => e.success, 'ok', isFalse),
      );
    });

    test('the answers to the way forms without the plugin', () {
      expect(
        parseAccountStep(_read('result_question_done_x5.xml'), method: AccountMethod.question),
        isA<AccountStepMessage>().having((e) => e.text, 'text', '修改成功').having((e) => e.success, 'ok', isTrue),
      );
      expect(
        parseAccountStep(_read('result_email_invalid_x5.xml'), method: AccountMethod.email),
        isA<AccountStepMessage>().having((e) => e.text, 'text', 'Email 地址无效').having((e) => e.success, 'ok', isFalse),
      );
    });

    test('the privacy page: the tabs but the ignore filter, the settings of each tab', () {
      final base = parsePrivacyPage(_read('privacy_base_x5.html'), expectedUid: _uid, op: 'base')!;
      expect(base.tabs.map((e) => e.op), ['base', 'feed', 'other']);
      expect(base.tabs.first.title, '个人隐私设置');
      final section = base.section!;
      expect(section.items.map((e) => e.label), ['好友列表', '留言板', '动态', '日志', '相册']);
      expect(section.fixed, containsAll([('formhash', 'f1f2f3f4'), ('privacysubmit', 'true')]));
      // "保密" only where the forum offers it.
      expect((section.items.first as PrivacyChoice).options.map((e) => e.$2), contains('保密'));
      expect((section.items[3] as PrivacyChoice).options.map((e) => e.$2), isNot(contains('保密')));

      final feed = parsePrivacyPage(_read('privacy_feed_x5.html'), expectedUid: _uid, op: 'feed')!.section!;
      expect(feed.items.length, 14);
      expect(feed.items.whereType<PrivacyToggle>().where((e) => e.checked).map((e) => e.label), ['论坛发帖']);
      final other = parsePrivacyPage(_read('privacy_other_x5.html'), expectedUid: _uid, op: 'other')!.section!;
      expect(other.fixed, contains(('privacy3submit', 'true')));
      expect(other.items.single.label, '添加好友');

      // A forum without the feed module: two tabs.
      final plain = parsePrivacyPage(_read('privacy_base_nofeed_x5.html'), expectedUid: _uid, op: 'base')!;
      expect(plain.tabs.map((e) => e.op), ['base', 'other']);
    });

    test('a privacy tab with a field the app does not show is not saved at all', () {
      final page = _read('privacy_other_x5.html').replaceFirst('</select>', '</select><input type="text" name="x" />');
      expect(parsePrivacyPage(page, expectedUid: _uid, op: 'other')!.section, isNull);
    });

    test('a tab is sent whole: every select, the checked boxes only', () {
      final feed = parsePrivacyPage(_read('privacy_feed_x5.html'), expectedUid: _uid, op: 'feed')!.section!;
      expect(feed.pairs, [('formhash', 'f1f2f3f4'), ('privacysubmit', 'true'), ('privacy[feed][newthread]', '1')]);
    });
  });

  group('changing the password', () {
    test('without a check: opened, posted once with the forum fields, done', () async {
      final forum = _Forum();
      final repo = _repo(forum);
      final open = await repo.open(_uid, AccountMethod.password, formHash: 'f1f2f3f4');
      final form = (open as AccountOpenForm).form;
      expect(forum.posts, isEmpty);
      final result = await repo.submit(_uid, form, {'newpassword': _new, 'renewpassword': _new});
      expect(result, isA<AccountSubmitDone>().having((e) => e.message, 'message', '修改成功'));
      expect(forum.posts.length, 1);
      final post = forum.posts.single;
      expect(post.uri.queryParameters, containsPair('inajax', '1'));
      expect(post.uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(post.uri.queryParameters, containsPair('sign', '0123456789abcdef'));
      expect(post.form, {
        'formhash': 'f1f2f3f4',
        'referer': 'https://forum.test/./',
        'submit': 'true',
        'newpassword': _new,
        'renewpassword': _new,
      });
      // The password only travels in the body.
      expect(post.uri.toString(), isNot(contains(_new)));
    });

    test('with the password check: nothing posted until the current password is given', () async {
      final forum = _Forum(asksPassword: true);
      final repo = _repo(forum);
      expect(
        await repo.open(_uid, AccountMethod.password, formHash: 'f1f2f3f4'),
        isA<AccountOpenNeedsPassword>(),
      );
      expect(forum.posts, isEmpty);
      final open = await repo.open(_uid, AccountMethod.password, formHash: 'f1f2f3f4', currentPassword: _current);
      expect(open, isA<AccountOpenForm>());
      final check = forum.posts.single;
      expect(check.uri.queryParameters, containsPair('verify', 'password'));
      // Posted as it is: the plugin's result leaves the signed link out.
      expect(check.uri.queryParameters.containsKey('tsdmapp'), isFalse);
      expect(check.form, containsPair('password', _current));
      expect(check.form, containsPair('security_submit', 'true'));
    });

    test('a wrong current password is the forum message', () async {
      final forum = _Forum(asksPassword: true)..verifyAnswer = 'verify_wrong_x5.xml';
      final open = await _repo(
        forum,
      ).open(_uid, AccountMethod.password, formHash: 'f1f2f3f4', currentPassword: _current);
      expect(open, isA<AccountOpenFailed>().having((e) => e.message, 'message', '账号密码错误'));
    });

    test('a site offering only the email or phone check is left to the web page', () async {
      final forum = _Forum(asksPassword: true);
      final repo = AccountSecurityRepository(
        buildClient: (_) => NetClientProvider.build(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _EmailCheckOnly(forum),
        ),
      );
      expect(await repo.open(_uid, AccountMethod.email, formHash: 'f1f2f3f4'), isA<AccountOpenOtherCheck>());
    });

    test('refusals carry the forum message; a lost answer is unknown, never a success', () async {
      final forum = _Forum()..submitAnswer = 'result_password_mismatch_v13.json';
      final repo = _repo(forum);
      final form = ((await repo.open(_uid, AccountMethod.password, formHash: 'f1f2f3f4')) as AccountOpenForm).form;
      expect(
        await repo.submit(_uid, form, {'newpassword': _new, 'renewpassword': _current}),
        isA<AccountSubmitRefused>().having((e) => e.message, 'message', '抱歉，请检查两次密码输入是否一致'),
      );
      forum.failPost = true;
      expect(await repo.submit(_uid, form, {'newpassword': _new, 'renewpassword': _new}), isA<AccountSubmitUnknown>());
    });

    test('the email refused with a plain page, the question changed without the plugin', () async {
      final forum = _Forum()..submitAnswer = 'result_email_invalid_v13.json';
      final repo = _repo(forum);
      final email = ((await repo.open(_uid, AccountMethod.email, formHash: 'f1f2f3f4')) as AccountOpenForm).form;
      expect(
        await repo.submit(_uid, email, {'email': 'bad'}),
        isA<AccountSubmitRefused>().having((e) => e.message, 'message', 'Email 地址无效'),
      );
      forum.submitAnswer = 'result_question_done_x5.xml';
      final question = ((await repo.open(_uid, AccountMethod.question, formHash: 'f1f2f3f4')) as AccountOpenForm).form;
      expect(await repo.submit(_uid, question, {'questionidnew': '', 'answernew': ''}), isA<AccountSubmitDone>());
      expect(forum.posts.last.form, containsPair('questionidnew', ''));
    });

    test('the form cubit keeps no password and asks for the current one only when the forum does', () async {
      final forum = _Forum(asksPassword: true);
      final cubit = AccountFormCubit(
        repository: _repo(forum),
        uid: _uid,
        method: AccountMethod.password,
        formHash: 'f1f2f3f4',
      );
      await cubit.open();
      expect(cubit.state.status, AccountFormStatus.needsPassword);
      forum.verifyAnswer = 'verify_wrong_x5.xml';
      await cubit.open(currentPassword: _current);
      expect(cubit.state.status, AccountFormStatus.needsPassword);
      expect(cubit.state.message, '账号密码错误');
      forum.verifyAnswer = 'verify_ok_x5.xml';
      await cubit.open(currentPassword: _current);
      expect(cubit.state.status, AccountFormStatus.ready);
      await cubit.submit({'newpassword': _new, 'renewpassword': _new});
      expect(cubit.state.status, AccountFormStatus.done);
      expect(cubit.state.message, '修改成功');
      await cubit.close();
    });
  });

  group('privacy', () {
    test('every tab is read from its own page; the ignore filter never', () async {
      final forum = _Forum();
      final settings = (await _repo(forum).privacy(_uid))!;
      expect(settings.map((e) => e.tab.op), ['base', 'feed', 'other']);
      expect(settings.every((e) => e.section != null), isTrue);
      expect(forum.gets.map((e) => e.queryParameters['op']), ['base', 'feed', 'other']);
    });

    test('only the changed tabs are saved, each whole, then read again', () async {
      final forum = _Forum();
      final cubit = PrivacySettingsCubit(repository: _repo(forum), uid: _uid);
      await cubit.load();
      final friend = cubit.state.edited.first.section!.items.first as PrivacyChoice;
      expect(friend.value, '1');
      cubit.change('base', friend.withValue('2'));
      expect(cubit.state.changed, {'base'});
      forum.gets.clear();
      await cubit.save();
      expect(forum.posts.length, 1);
      final post = forum.posts.single;
      expect(post.uri.queryParameters, containsPair('op', 'base'));
      expect(post.form, {
        'formhash': 'f1f2f3f4',
        'privacysubmit': 'true',
        'privacy[view][friend]': '2',
        'privacy[view][wall]': '0',
        'privacy[view][home]': '0',
        'privacy[view][blog]': '3',
        'privacy[view][album]': '0',
      });
      expect(cubit.state.lastSaveOk, isTrue);
      expect(cubit.state.changed, isEmpty);
      expect((cubit.state.saved.first.section!.items.first as PrivacyChoice).value, '2');
      expect(forum.gets.where((e) => e.queryParameters['op'] == 'filter'), isEmpty);
      await cubit.close();
    });

    test('the redirect the forum answers a handled privacy form is taken, then read again', () async {
      final forum = _Forum()..redirectPrivacy = true;
      final cubit = PrivacySettingsCubit(repository: _repo(forum), uid: _uid);
      await cubit.load();
      final other = cubit.state.edited.last.section!.items.single as PrivacyChoice;
      cubit.change('other', other.withValue(other.value == '1' ? '0' : '1'));
      await cubit.save();
      expect(forum.posts.single.uri.queryParameters, containsPair('op', 'other'));
      expect(cubit.state.lastSaveOk, isTrue);
      await cubit.close();
    });

    test('a tab the forum did not take is reported and kept changed', () async {
      final forum = _Forum()..applyPrivacy = false;
      final cubit = PrivacySettingsCubit(repository: _repo(forum), uid: _uid);
      await cubit.load();
      final toggle = cubit.state.edited[1].section!.items.first as PrivacyToggle;
      cubit.change('feed', toggle.withChecked(checked: true));
      await cubit.save();
      expect(cubit.state.lastSaveOk, isFalse);
      expect(cubit.state.changed, {'feed'});
      await cubit.close();
    });
  });

  test('the sign up and the lost password pages are the forum links of its login form', () {
    expect(signUpPage, '$baseUrl/member.php?mod=register');
    expect(lostPasswordPage, '$baseUrl/member.php?mod=logging&action=login&viewlostpw=1');
  });

  group('entries', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<AppDatabase>(db)
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(
            NetClientProvider.buildNoCookie(
              dio: Dio()..httpClientAdapter = _Forum(),
              cookie: CookieProvider.buildEmpty(),
            ),
          ),
        );
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await settings.dispose();
      await db.close();
    });

    testWidgets('settings: password and privacy for an account in use only', (tester) async {
      tester.view
        ..physicalSize = const Size(384, 792)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = ThemeCubit();
      addTearDown(theme.close);
      Future<void> pump(AuthenticationRepository auth) async {
        await tester.pumpWidget(
          RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<ThemeCubit>.value(value: theme),
              ],
              child: TranslationProvider(child: const MaterialApp(home: SettingsPage())),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      final security = find.byKey(const ValueKey('settings-account-security'));
      final privacy = find.byKey(const ValueKey('settings-privacy'));
      await pump(
        AuthenticationRepository(
          user: const UserLoginInfo(username: 'alice', uid: _uid),
        ),
      );
      expect(security, findsOneWidget);
      expect(privacy, findsOneWidget);
      final tr = LocaleSettings.instance.currentTranslations.settingsPage.accountSection;
      expect(find.descendant(of: security, matching: find.text(tr.security)), findsOneWidget);
      expect(find.descendant(of: privacy, matching: find.text(tr.privacy)), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await pump(AuthenticationRepository());
      expect(security, findsNothing);
      expect(privacy, findsNothing);
    });

    testWidgets(
      'the password dialog stays while posting; once changed the login is marked dead, the login page opens',
      (
        tester,
      ) async {
        tester.view
          ..physicalSize = const Size(400, 800)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final storage = getIt.get<StorageProvider>();
        await tester.runAsync(
          () => storage.saveCookie(username: 'alice', uid: _uid, cookie: {'${cookiePrefix}_auth': 'x'}),
        );
        final hold = Completer<void>();
        final forum = _Forum()..holdSubmit = hold;
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => AccountSecurityPage(repository: _repo(forum)),
            ),
            GoRoute(
              path: ScreenPaths.login,
              name: ScreenPaths.login,
              builder: (_, s) => Text('login ${s.uri.queryParameters['username']}'),
            ),
          ],
        );
        addTearDown(router.dispose);
        Future<void> settle() async {
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        await tester.pumpWidget(
          RepositoryProvider<AuthenticationRepository>.value(
            value: AuthenticationRepository(
              user: const UserLoginInfo(username: 'alice', uid: _uid),
            ),
            child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
          ),
        );
        await settle();
        await tester.tap(find.text('账号密码'));
        await settle();
        final fields = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextFormField));
        expect(fields, findsNWidgets(2));
        await tester.enterText(fields.at(0), _new);
        await tester.enterText(fields.at(1), _new);
        final tr = LocaleSettings.instance.currentTranslations;
        await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text(tr.general.ok)));
        await settle();
        expect(forum.posts, hasLength(1));
        // Back while the forum handles the post: the dialog stays.
        await tester.binding.handlePopRoute();
        await settle();
        expect(find.byType(AlertDialog), findsOneWidget);

        hold.complete();
        await settle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('login alice'), findsOneWidget);
        final expired = await tester.runAsync(storage.fetchExpiredSessions);
        expect(expired!.map((e) => e.user.uid), [_uid]);
      },
    );
  });
}

/// The forum of [inner] whose site only offers the email check.
final class _EmailCheckOnly implements HttpClientAdapter {
  _EmailCheckOnly(this.inner);

  final _Forum inner;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    final q = options.uri.queryParameters;
    if (options.method == 'GET' && q['op'] == 'verify' && (q['sign'] ?? '').isEmpty) {
      return _Forum._answer(
        _read(
          'choose_password_x5.xml',
        ).replaceAll('chgpassword', q['method']!).replaceAll('verify=password', 'verify=email'),
      );
    }
    return inner.fetch(options, requestStream, cancel);
  }

  @override
  void close({bool force = false}) {}
}
