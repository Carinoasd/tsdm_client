/// Editing the profile: the signature in its own editor, and the avatar uploaded with the forum's avatar editor.
///
/// The signature lives in one tab of the forum's profile editor (the base tab on the forum, the 个人信息 tab on a
/// default Discuz! X5), so the editor is asked tab by tab until one prints it, from the forum's app API (plugin 3.0.0,
/// `form: profile`) or the web page. It is posted with the tab's own fields alone (the forum saves only the fields a
/// post carries), and checked against the member's group limit the way the forum cuts it (`cutstr`).
///
/// The avatar page offers the external url form and the avatar editor of Discuz! X5 (`stl_src`, UCenter's
/// `rectavatar`); the cropped images (JPEG, at most 200×250, 120×120 and 48×48) are posted once, in base64, to the
/// url of a page opened right before, and the answer (`postMessage('success'|'failure')`, `<message value="-1">`)
/// read.
///
/// Fixtures: `test/data/profile_edit/`, taken from the test forum (ag_low2) and scrubbed.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:image/image.dart' as img;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/bloc/edit_avatar_bloc.dart';
import 'package:tsdm_client/features/profile/models/avatar_upload.dart';
import 'package:tsdm_client/features/profile/models/signature_form.dart';
import 'package:tsdm_client/features/profile/repository/edit_user_profile_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart'
    show singleAttemptHttpRequestKey;
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/profile_edit';

String _read(String name) => File('$_dir/$name').readAsStringSync();

Map<String, dynamic> _json(String name) => jsonDecode(_read(name)) as Map<String, dynamic>;

SmallFormFields _fields(Map<String, dynamic> json) =>
    smallFormAnswerOf(json, SmallFormKind.profile)! as SmallFormFields;

typedef _Answer = ({String body, bool json});

_Answer _api(Map<String, dynamic> json) => (body: jsonEncode(json), json: true);

_Answer _html(String body) => (body: body, json: false);

/// The write result (plugin 2.6.0, schema 13) of the profile editor's frame.
Map<String, dynamic> _result(String document, {int ok = 1}) => {
  'ok': ok,
  'api': 1,
  'time': 1700000000,
  'uid': 31,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': 'page',
  'message': '',
  'message_key': '',
  'url': '',
  'handlekey': '',
  'values': <String, Object?>{},
  'login': 0,
  'alert': '',
  'head': '',
  'document': document,
};

/// A forum answering every request with [answer], recording the requests.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    requests.add(options);
    final a = answer(options);
    return ResponseBody.fromString(
      a.body,
      200,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(
  () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
);

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

AppException _left<T>(Either<AppException, T> either) =>
    either.fold((e) => e, (v) => throw StateError('expected a failure, got $v'));

Map<String, String> _query(RequestOptions r) => {...r.uri.queryParameters}..remove('mobile');

bool _asksForm(RequestOptions r) => _query(r)['tsdmapp'] == 'json' && _query(r)['tsdmform'] == '1';

/// The fields of a multipart post.
Map<String, String> _multipart(RequestOptions r) => {for (final e in (r.data as FormData).fields) e.key: e.value};

/// The fields of a form-urlencoded post.
Map<String, String> _posted(RequestOptions r) => {
  for (final MapEntry(:key, :value) in (r.data as Map).entries) '$key': '$value',
};

/// The tab of the profile editor's answer [json] made to say it is tab [op] (its own form posts to it).
Map<String, dynamic> _asTab(Map<String, dynamic> json, String op) => {
  ...json,
  'op': op,
  'signature': null,
  'submit': {
    ...(json['submit'] as Map<String, dynamic>),
    'url': 'home.php?mod=spacecp&ac=profile&op=$op',
  },
};

/// The web page of the 个人信息 tab without the signature: what any other tab looks like to the reader.
String _webTabWithoutSignature() {
  final doc = parseHtmlDocument(_read('signature_info_x5.html'));
  doc.querySelector('textarea[name="sightml"]')!.remove();
  return doc.documentElement!.outerHtml!;
}

Uint8List _png(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (final p in image) {
    p
      ..r = p.x * 255 ~/ width
      ..g = p.y * 255 ~/ height
      ..b = 128;
  }
  return img.encodePng(image);
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);
  tearDown(() async {
    if (getIt.isRegistered<NetClientProvider>()) {
      await getIt.unregister<NetClientProvider>();
    }
  });

  group('A. the signature length as the forum cuts it', () {
    test('ASCII 1, tab and line feed 1, carriage return 0, any other character 2', () {
      expect(signatureLength('abc'), 3);
      expect(signatureLength('a\tb\nc'), 5);
      expect(signatureLength('a\r\nb'), 3);
      expect(signatureLength('中文'), 4);
      expect(signatureLength('😀'), 2);
    });

    test('measured on the test forum (maxsigsize 200): 198 A + 中 kept, 199 A + 中 cut', () {
      expect(signatureFits('${'A' * 198}中', 200), isTrue);
      expect(signatureFits('${'A' * 199}中', 200), isFalse);
      expect(signatureFits('A' * 200, 200), isTrue);
      expect(signatureFits('A' * 201, 200), isFalse);
      // At most max bytes is never cut, whatever the count.
      expect(signatureFits('中' * 2, 6), isTrue);
    });
  });

  group('B. the signature form', () {
    test('of the app API: the 个人信息 tab prints it, the base tab does not', () {
      final form = SignatureForm.fromApi(_fields(_json('signature_info_v17.json')))!;
      expect(form.uid, 31);
      expect(form.value, '[b]测试签名[/b] 第二行\n[color=Red]红字[/color]');
      expect(form.max, 200);
      expect(form.bbcode, isTrue);
      expect(form.imgcode, isFalse);
      expect(form.submitUrl, '$baseUrl/home.php?mod=spacecp&ac=profile&op=info');
      expect(form.fits('A' * 200), isTrue);
      expect(form.fits('A' * 201), isFalse);
      expect(SignatureForm.fromApi(_fields(_json('signature_base_v17.json'))), isNull);
    });

    test("posted with the form's own fields and the signature, nothing else of the tab", () {
      final form = SignatureForm.fromApi(_fields(_json('signature_info_v17.json')))!;
      expect(form.bodyWith('[b]x[/b]'), {
        'formhash': 'f1f2f3f4',
        'profilesubmit': 'true',
        'profilesubmitbtn': 'true',
        'sightml': '[b]x[/b]',
      });
    });

    test('of the web page: the same signature, switches and target', () {
      final form = SignatureForm.fromDocument(parseHtmlDocument(_read('signature_info_x5.html')), 31)!;
      expect(form.value, '[b]测试签名[/b] 第二行\n[color=Red]红字[/color]');
      expect(form.max, isNull);
      expect(form.bbcode, isTrue);
      expect(form.imgcode, isFalse);
      expect(form.submitUrl, '$baseUrl/home.php?mod=spacecp&ac=profile&op=info');
      expect(form.bodyWith('x'), {
        'formhash': 'f1f2f3f4',
        'profilesubmit': 'true',
        'profilesubmitbtn': 'true',
        'sightml': 'x',
      });
      expect(SignatureForm.fromDocument(parseHtmlDocument(_webTabWithoutSignature()), 31), isNull);
    });
  });

  group('C. loading and saving the signature', () {
    test('app API: the default tab, then the tab that prints it; saved to that tab', () async {
      final forum = _Forum((r) {
        if (r.method == 'POST') {
          return _api(_result("<script type=\"text/javascript\">parent.show_success('');</script>"));
        }
        return _query(r)['op'] == 'info'
            ? _api(_json('signature_info_v17.json'))
            : _api(_json('signature_base_v17.json'));
      });
      _use(forum);
      final repo = EditUserProfileRepository(currentUid: () => 31);
      final form = _right(await repo.loadSignature().run());
      expect(form.value, startsWith('[b]测试签名'));
      expect(forum.requests, hasLength(2));
      expect(forum.requests.every(_asksForm), isTrue);
      expect(_query(forum.requests.first), isNot(contains('op')));
      expect(_query(forum.requests.last)['op'], 'info');

      _right(await repo.uploadSignature(form, '[b]新签名[/b]').run());
      final post = forum.requests.last;
      expect(post.method, 'POST');
      expect(_query(post), {'mod': 'spacecp', 'ac': 'profile', 'op': 'info', 'tsdmapp': 'json'});
      expect(_multipart(post), {
        'formhash': 'f1f2f3f4',
        'profilesubmit': 'true',
        'profilesubmitbtn': 'true',
        'sightml': '[b]新签名[/b]',
      });
    });

    test('app API: no tab prints it (the group has no signature)', () async {
      final base = _json('signature_base_v17.json');
      final forum = _Forum((r) => _api(_asTab(base, _query(r)['op'] ?? 'base')));
      _use(forum);
      expect(
        _left(await EditUserProfileRepository(currentUid: () => 31).loadSignature().run()),
        isA<EditUserProfileFormNotFound>().having(
          (e) => e.reason,
          'reason',
          t.editUserProfilePage.signatureUnavailable,
        ),
      );
      // Every tab asked once: the default one (base), then info first, then the others.
      expect(forum.requests.map((r) => _query(r)['op']).toList(), [null, 'info', 'contact', 'edu', 'work']);
    });

    test('the web page (no plugin): the tabs it links, then the tab that prints it', () async {
      final other = _webTabWithoutSignature();
      final info = _read('signature_info_x5.html');
      final forum = _Forum((r) => _html(_query(r)['op'] == 'info' ? info : other));
      _use(forum);
      final form = _right(await EditUserProfileRepository(currentUid: () => 31).loadSignature().run());
      expect(form.value, startsWith('[b]测试签名'));
      expect(form.submitUrl, '$baseUrl/home.php?mod=spacecp&ac=profile&op=info');
      expect(_query(forum.requests.last)['op'], 'info');
    });

    test('a tab the plugin could not tell: asked again as the web page', () async {
      final info = _read('signature_info_x5.html');
      final forum = _Forum(
        (r) => _asksForm(r) ? _api({'ok': 0, 'error': 'unknown', 'form': 'profile', 'uid': 31}) : _html(info),
      );
      _use(forum);
      final form = _right(await EditUserProfileRepository(currentUid: () => 31).loadSignature().run());
      expect(form.value, startsWith('[b]测试签名'));
      expect(forum.requests.map(_asksForm).toList(), [true, false]);
    });

    test('a page of another account is never used; a form of another account is never posted', () async {
      _use(_Forum((_) => _api(_json('signature_info_v17.json'))));
      expect(
        _left(await EditUserProfileRepository(currentUid: () => 35).loadSignature().run()),
        isA<EditUserProfileFormNotFound>().having((e) => e.reason, 'reason', t.general.accountChangedRetry),
      );
      await getIt.unregister<NetClientProvider>();

      final forum = _Forum((_) => _api(_result('')));
      _use(forum);
      final form = SignatureForm.fromApi(_fields(_json('signature_info_v17.json')))!;
      expect(
        _left(await EditUserProfileRepository(currentUid: () => 35).uploadSignature(form, 'x').run()),
        isA<IdentityChangedException>(),
      );
      expect(forum.requests, isEmpty);
    });

    test('the profile of a web page without the signature does not post one (it would clear it)', () async {
      final doc = parseHtmlDocument(File('test/data/profile_edit_form_x5.html').readAsStringSync());
      doc.querySelector('td#td_sightml')!.remove();
      doc.querySelector('td#td_customstatus')?.remove();
      final page = doc.documentElement!.outerHtml!;
      final forum = _Forum(
        (r) => r.method == 'POST'
            ? _html("<script type=\"text/javascript\">parent.show_success('');</script>")
            : _html(page),
      );
      _use(forum);
      final repo = EditUserProfileRepository(currentUid: () => 35);
      final profile = _right(await repo.loadProfile().run());
      expect(profile.apiKeys, isNull);
      expect(profile.signature, isNull);
      _right(await repo.uploadProfile(profile).run());
      final sent = _multipart(forum.requests.last);
      expect(sent, isNot(contains('sightml')));
      expect(sent, isNot(contains('customstatus')));
      expect(sent, containsPair('profilesubmit', 'true'));
    });

    test('the image upload event can be told and compared (logged by the bloc observer)', () async {
      final images = (await AvatarImages.crop(_png(8, 8), left: 0, top: 0, side: 8))!;
      final event = EditAvatarImageUploadRequested(images);
      expect(event.toString, returnsNormally);
      expect(event == EditAvatarImageUploadRequested(images), isTrue);
      expect(() => event.hashCode, returnsNormally);
    });

    test('a refused signature (the word filter) is told by its title', () async {
      _use(_Forum((_) => _api(_result('<script>parent.show_error("sightml");</script>', ok: 0))));
      final form = SignatureForm.fromApi(_fields(_json('signature_info_v17.json')))!;
      expect(
        _left(await EditUserProfileRepository(currentUid: () => 31).uploadSignature(form, 'x').run()),
        isA<EditUserProfileUploadFailed>().having(
          (e) => e.reason,
          'reason',
          t.editUserProfilePage.fieldRefused(field: t.editUserProfilePage.signature),
        ),
      );
    });
  });

  group('D. the avatar page', () {
    test('the external url form and the avatar editor of X5', () {
      final page = AvatarEditPage.parse(parseHtmlDocument(_read('avatar_x5.html')));
      expect(page.uid, 31);
      expect(page.hasExternal, isTrue);
      expect(page.externalUrl, '');
      expect(page.formHash, 'f1f2f3f4');
      expect(page.hasUpload, isTrue);
      final upload = Uri.parse(page.uploadUrl!);
      expect(upload.toString(), startsWith('https://forum.test/api/avatar/index.php?'));
      expect(upload.queryParameters, {
        'm': 'user',
        'inajax': '1',
        'a': 'rectavatar',
        'appid': '1',
        'input': 'AbCdEf0123456789',
        'agent': '0123456789abcdef0123456789abcdef',
        'avatartype': 'virtual',
        'base64': 'yes',
      });
      expect(page.currentAvatar, '$baseUrl/data/avatar/000/00/00/31_avatar_big.jpg?ts=1700000000');
    });

    test('a page with only one of them; a page with neither', () {
      final doc = parseHtmlDocument(_read('avatar_x5.html'));
      doc.querySelector('#avatardesigner')!.remove();
      final external = AvatarEditPage.parse(doc);
      expect((external.hasExternal, external.hasUpload), (true, false));
      doc.querySelector('input[name="headedit"]')!.remove();
      final none = AvatarEditPage.parse(doc);
      expect((none.hasExternal, none.hasUpload), (false, false));
    });

    test("the editor's answers", () {
      expect(
        AvatarUploadAnswer.parse("<script>window.parent.postMessage('success','*');</script>"),
        AvatarUploadAnswer.success,
      );
      expect(
        AvatarUploadAnswer.parse("<script>window.parent.postMessage('failure','*');</script>"),
        AvatarUploadAnswer.failure,
      );
      expect(AvatarUploadAnswer.parse('<root><message type="error" value="-1" /></root>'), AvatarUploadAnswer.denied);
      expect(
        AvatarUploadAnswer.parse('<root><message type="error" value="-2" /></root>'),
        AvatarUploadAnswer.incomplete,
      );
      expect(AvatarUploadAnswer.parse('<html></html>'), AvatarUploadAnswer.unknown);
    });
  });

  group('E. the avatar images', () {
    test('a square of a large image: 200, 120 and 48, JPEG', () async {
      final images = (await AvatarImages.crop(_png(400, 300), left: 50, top: 0, side: 300))!;
      for (final (bytes, side) in [(images.big, 200), (images.middle, 120), (images.small, 48)]) {
        final decoded = img.decodeJpg(bytes)!;
        expect((decoded.width, decoded.height), (side, side));
      }
    });

    test('a small image is not scaled up but the small one is 48; within the limits UCenter takes', () async {
      final images = (await AvatarImages.crop(_png(30, 40), left: 0, top: 5, side: 30))!;
      expect((img.decodeJpg(images.big)!.width, img.decodeJpg(images.big)!.height), (30, 30));
      expect(img.decodeJpg(images.middle)!.width, 30);
      expect(img.decodeJpg(images.small)!.width, 48);
      for (final (i, bytes) in [images.big, images.middle, images.small].indexed) {
        final d = img.decodeJpg(bytes)!;
        final (w, h) = AvatarImages.limits[i];
        expect(d.width <= w && d.height <= h, isTrue);
      }
      // A crop out of the image is pulled back inside it.
      final pulled = (await AvatarImages.crop(_png(100, 100), left: 90, top: 90, side: 50))!;
      expect(img.decodeJpg(pulled.big)!.width, 50);
    });

    test('not an image', () async {
      expect(await AvatarImages.crop(Uint8List.fromList([1, 2, 3]), left: 0, top: 0, side: 1), isNull);
    });

    test('posted in base64 as avatar1, avatar2, avatar3', () async {
      final images = (await AvatarImages.crop(_png(64, 64), left: 0, top: 0, side: 64))!;
      final body = images.toBody();
      expect(body.keys, ['avatar1', 'avatar2', 'avatar3']);
      expect(base64.decode(body['avatar3']!), images.small);
    });
  });

  group('F. uploading the avatar', () {
    final page = _read('avatar_x5.html');

    test('the page opened again, the images posted once to its url, the page opened after saving', () async {
      final images = (await AvatarImages.crop(_png(64, 64), left: 0, top: 0, side: 64))!;
      final forum = _Forum(
        (r) => r.method == 'POST' ? _html("<script>window.parent.postMessage('success','*');</script>") : _html(page),
      );
      _use(forum);
      _right(await ProfileRepository(currentUid: () => 31).uploadAvatarImages(images).run());
      expect(forum.requests.map((r) => r.method).toList(), ['GET', 'POST', 'GET']);
      final post = forum.requests[1];
      expect(post.uri.host, 'forum.test');
      expect(post.uri.path, '/api/avatar/index.php');
      expect(post.uri.queryParameters['a'], 'rectavatar');
      expect(post.uri.queryParameters, isNot(contains('tsdmapp')));
      expect(post.extra[singleAttemptHttpRequestKey], isTrue);
      expect(post.followRedirects, isFalse);
      expect(_posted(post), images.toBody());
    });

    test('refused, denied: told; the page of another account: nothing posted', () async {
      final images = (await AvatarImages.crop(_png(64, 64), left: 0, top: 0, side: 64))!;
      for (final (answer, name) in [
        ("<script>window.parent.postMessage('failure','*');</script>", 'failure'),
        ('<root><message type="error" value="-1" /></root>', 'denied'),
      ]) {
        _use(_Forum((r) => r.method == 'POST' ? _html(answer) : _html(page)));
        expect(
          _left(await ProfileRepository(currentUid: () => 31).uploadAvatarImages(images).run()),
          isA<EditAvatarUploadFailed>().having((e) => e.answer, 'answer', name),
        );
        await getIt.unregister<NetClientProvider>();
      }

      final forum = _Forum((_) => _html(page));
      _use(forum);
      expect(
        _left(await ProfileRepository(currentUid: () => 35).uploadAvatarImages(images).run()),
        isA<IdentityChangedException>(),
      );
      expect(forum.requests.map((r) => r.method), everyElement('GET'));
    });
  });
}
