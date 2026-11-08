/// Posting a blog and uploading pictures to an album, for one account (`SpaceWriteRepository`), as measured on the
/// test site (Discuz! X5, plugin 3.4.0):
///
/// * the blog form posts `subject`, `message` with `plaintext=1` (the forum turns the line breaks into `<br />` and
///   keeps the html it allows, so `&`, `<`, `>` are sent as entities), `classid` (`new:NAME` for a new category),
///   `friend`, `password` for `friend=4`; the plugin answers `kind: redirect`, `do_success`, to
///   `home.php?mod=space&uid=N&do=blog&quickforward=1&id=M`;
/// * a picture goes to `misc.php?mod=swfupload&action=swfupload&operation=album` with the `uid` and `hash` of the
///   upload page (the uploader takes the account from them, not from the session), answered
///   `{"picid":"12", …}` (`"picid":"0"` when it took nothing); the album form then files the pictures
///   (`title[picid]`, `albumop` `selectalbum` + `albumid` or `creatalbum` + `albumname`), answered `kind: message`,
///   `upload_images_completed` (`alert: info`) to `do=album&quickforward=1&id=M`.
///
/// Every post is sent once, only for the account the repository belongs to and with a form served to it.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/space/cubit/space_write_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

const _dir = 'test/data/space';

Response<dynamic> _ok(Object? data, String url) => Response<dynamic>(
  requestOptions: RequestOptions(path: url),
  statusCode: 200,
  data: data,
);

Map<String, dynamic> _result({
  required String kind,
  required String key,
  required String url,
  int ok = 1,
  String message = '',
  String alert = '',
  int login = 0,
}) => {
  'ok': ok,
  'api': 1,
  'time': 1700000000,
  'uid': 31,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': kind,
  'message': message,
  'message_key': key,
  'url': url,
  'handlekey': '',
  'values': <String, dynamic>{},
  'login': login,
  'alert': alert,
};

/// A transport recording what goes out.
final class _Transport {
  _Transport({this.uid = 31});

  int? uid;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];
  final files = <(String, Map<String, String>, MultipartFilePart)>[];

  Object? page;
  Object? Function(String url, Map<String, String> body) postAnswer = (_, _) => null;
  Object? Function(MultipartFilePart file) fileAnswer = (_) => '{"picid":"0", "url":"0", "bigimg":"0"}';

  SpaceWriteRepository repository() => SpaceWriteRepository.withTransport(
    currentUid: () => uid,
    getPage: (url) async {
      gets.add(url);
      return right(_ok(page, url));
    },
    sendForm: (url, body) async {
      posts.add((url, body));
      return right(_ok(postAnswer(url, body), url));
    },
    sendFile: (url, fields, file) async {
      files.add((url, fields, file));
      return right(_ok(fileAnswer(file), url));
    },
  );
}

String _fixture(String name) => File('$_dir/$name.html').readAsStringSync();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('blog', () {
    test('the form, served to the account, posted once as plain text', () async {
      final net = _Transport()..page = _fixture('blog_form');
      final repo = net.repository();
      final load = await repo.loadBlogForm();
      expect(load.kind, SpaceFormLoadKind.ready);
      expect(net.gets.single, contains('tsdmapp=json'));
      net.postAnswer = (_, _) => _result(
        kind: 'redirect',
        key: 'do_success',
        url: 'home.php?mod=space&uid=31&do=blog&quickforward=1&id=16',
      );
      final result = await repo.postBlog(
        load.form!,
        const BlogDraft(subject: ' 标题 ', message: 'a <b> & c\nd', privacy: '4', newCategory: '新分类', password: 'pw'),
      );
      expect(result.outcome, SpaceWriteOutcome.done);
      expect(result.id, 16);
      final (url, body) = net.posts.single;
      expect(url, SpaceWriteRepository.blogSubmitUrl);
      expect(body, {
        'formhash': 'f1f2f3f4',
        'blogsubmit': 'true',
        'subject': '标题',
        'message': 'a &lt;b&gt; &amp; c\nd',
        'plaintext': '1',
        'classid': 'new:新分类',
        'friend': '4',
        'password': 'pw',
        'tags': '',
      });
    });

    test('a category of the author, no password unless asked', () {
      const form = BlogPostForm(uid: 31, formHash: 'f1f2f3f4', categories: [], privacy: []);
      final body = SpaceWriteRepository.blogBody(
        form,
        const BlogDraft(subject: '', message: 'x', privacy: '0', category: '1'),
      );
      expect(body['classid'], '1');
      expect(body.containsKey('password'), isFalse);
      expect(body.containsKey('catid'), isFalse);
      expect(
        SpaceWriteRepository.blogBody(form, const BlogDraft(subject: '', message: 'x', privacy: '0'))['classid'],
        '0',
      );
    });

    test("the forum's refusals: nothing posted, the forum's words", () async {
      final net = _Transport()..page = _fixture('blog_form');
      final repo = net.repository();
      final form = (await repo.loadBlogForm()).form!;
      net.postAnswer = (_, _) => _result(
        kind: 'message',
        key: 'operating_too_fast',
        url: '',
        ok: 0,
        alert: 'error',
        message: '两次发布操作太快了，请等 15 秒钟再试',
      );
      final refused = await repo.postBlog(form, const BlogDraft(subject: '', message: 'x', privacy: '0'));
      expect(refused.outcome, SpaceWriteOutcome.rejected);
      expect(refused.message, '两次发布操作太快了，请等 15 秒钟再试');
      net.postAnswer = (_, _) =>
          _result(kind: 'message', key: 'submit_seccode_invalid', url: '', ok: 0, alert: 'error');
      final captcha = await repo.postBlog(form, const BlogDraft(subject: '', message: 'x', privacy: '0'));
      expect(captcha.outcome, SpaceWriteOutcome.rejected);
      expect(captcha.message, t.postEditPage.verificationRequired);
    });

    test('the forum asks to log in: told so, not a refusal to send again', () async {
      final net = _Transport()..page = _fixture('blog_form');
      final repo = net.repository();
      final form = (await repo.loadBlogForm()).form!;
      net.postAnswer = (_, _) => _result(kind: 'message', key: 'to_login', url: '', ok: 0, login: 1);
      final result = await repo.postBlog(form, const BlogDraft(subject: '', message: 'x', privacy: '0'));
      expect(result.outcome, SpaceWriteOutcome.loginRequired);
    });

    test('an answer that does not tell is unconfirmed, never sent again', () async {
      final net = _Transport()..page = _fixture('blog_form');
      final repo = net.repository();
      final form = (await repo.loadBlogForm()).form!;
      net.postAnswer = (_, _) => '<html><body>?</body></html>';
      final result = await repo.postBlog(form, const BlogDraft(subject: '', message: 'x', privacy: '0'));
      expect(result.outcome, SpaceWriteOutcome.unconfirmed);
      expect(net.posts, hasLength(1));
    });

    test('without the plugin: the redirect the forum answered, not followed', () async {
      final repo = SpaceWriteRepository.withTransport(
        currentUid: () => 31,
        getPage: (url) async => right(_ok(_fixture('blog_form'), url)),
        sendForm: (url, body) async => left(
          HttpHandshakeFailedException(
            'redirect',
            statusCode: 302,
            headers: Headers.fromMap({
              'location': ['home.php?mod=space&uid=31&do=blog&quickforward=1&id=17'],
            }),
          ),
        ),
        sendFile: (url, fields, file) async => left(HttpRequestFailedException(500)),
      );
      final form = (await repo.loadBlogForm()).form!;
      final result = await repo.postBlog(form, const BlogDraft(subject: '', message: 'x', privacy: '0'));
      expect(result.outcome, SpaceWriteOutcome.done);
      expect(result.id, 17);
    });

    test('another account: the form is not used, nothing is posted', () async {
      final served = _Transport(uid: 32)..page = _fixture('blog_form');
      expect((await served.repository().loadBlogForm()).kind, SpaceFormLoadKind.identityChanged);

      final net = _Transport()..page = _fixture('blog_form');
      final repo = net.repository();
      final form = (await repo.loadBlogForm()).form!;
      net.uid = 32;
      final result = await repo.postBlog(form, const BlogDraft(subject: '', message: 'x', privacy: '0'));
      expect(result.outcome, SpaceWriteOutcome.identityChanged);
      expect(net.posts, isEmpty);
      net.uid = 31;
      repo.invalidate();
      expect(
        (await repo.postBlog(form, const BlogDraft(subject: '', message: 'x', privacy: '0'))).outcome,
        SpaceWriteOutcome.identityChanged,
      );
      expect(net.posts, isEmpty);
    });

    test("a page that is not the form: the forum's message", () async {
      final net = _Transport()..page = _fixture('blog_missing');
      final load = await net.repository().loadBlogForm();
      expect(load.kind, SpaceFormLoadKind.denied);
      expect(load.message, '抱歉，您要查看的信息不存在或已被删除');
    });
  });

  group('album', () {
    test('pictures uploaded with the hash of the page, then filed to the album, once', () async {
      final net = _Transport()..page = _fixture('album_upload');
      final repo = net.repository();
      final load = await repo.loadUploadForm(albumId: 1);
      expect(load.kind, SpaceFormLoadKind.ready);
      expect(net.gets.single, startsWith('${SpaceWriteRepository.uploadFormUrl}&albumid=1'));
      final form = load.form!;
      var next = 1;
      net.fileAnswer = (_) => '{"picid":"${next++}", "url":"data/x.thumb.jpg", "bigimg":"data/x"}';
      expect(await repo.uploadPhoto(form, '/tmp/a.png', fileSize: (_) => 1000), right<SpaceUploadRefusal, int>(1));
      expect(await repo.uploadPhoto(form, r'C:\x\b.JPG', fileSize: (_) => 1000), right<SpaceUploadRefusal, int>(2));
      final (url, fields, file) = net.files.first;
      expect(url, 'https://forum.test/misc.php?mod=swfupload&action=swfupload&operation=album');
      expect(fields, {'uid': '31', 'hash': '0123456789abcdef0123456789abcdef'});
      expect(file.filename, 'a.png');
      expect(file.contentType, 'image/png');
      expect(net.files.last.$3.filename, 'b.JPG');

      net.postAnswer = (_, _) => _result(
        kind: 'message',
        key: 'upload_images_completed',
        url: 'home.php?mod=space&uid=31&do=album&quickforward=1&id=1',
        message: '图片上传成功',
        alert: 'info',
      );
      final filed = await repo.fileUploads(form, [1, 2], const AlbumTarget.existing('1'));
      expect(filed.outcome, SpaceWriteOutcome.done);
      expect(filed.id, 1);
      final (submit, body) = net.posts.single;
      expect(submit, SpaceWriteRepository.uploadSubmitUrl);
      expect(body, {
        'formhash': 'f1f2f3f4',
        'albumsubmit': 'true',
        'title[1]': '',
        'title[2]': '',
        'albumop': 'selectalbum',
        'albumid': '1',
      });
    });

    test('a new album', () {
      const form = AlbumUploadForm(
        uid: 31,
        formHash: 'f1f2f3f4',
        uploadUrl: 'u',
        uploadUid: '31',
        uploadHash: 'h',
        albums: [],
        privacy: [],
      );
      expect(
        SpaceWriteRepository.albumBody(form, [5], const AlbumTarget.create(' 新相册 ', privacy: '4', password: 'pw')),
        {
          'formhash': 'f1f2f3f4',
          'albumsubmit': 'true',
          'title[5]': '',
          'albumop': 'creatalbum',
          'albumname': '新相册',
          'depict': '',
          'friend': '4',
          'password': 'pw',
        },
      );
    });

    test('a file the forum does not take is refused before sending', () async {
      final net = _Transport()..page = _fixture('album_upload');
      final repo = net.repository();
      final form = (await repo.loadUploadForm()).form!;
      expect(
        await repo.uploadPhoto(form, '/tmp/a.webp', fileSize: (_) => 1),
        left<SpaceUploadRefusal, int>(SpaceUploadRefusal.type),
      );
      expect(
        await repo.uploadPhoto(form, '/tmp/a.png', fileSize: (_) => 2000 * 1024 + 1),
        left<SpaceUploadRefusal, int>(SpaceUploadRefusal.size),
      );
      expect(net.files, isEmpty);
      // The uploader took nothing.
      expect(
        await repo.uploadPhoto(form, '/tmp/a.png', fileSize: (_) => 1),
        left<SpaceUploadRefusal, int>(SpaceUploadRefusal.rejected),
      );
      expect(net.files, hasLength(1));
    });

    test('the hash of another account is never used', () async {
      final net = _Transport()..page = _fixture('album_upload');
      final repo = net.repository();
      final form = (await repo.loadUploadForm()).form!;
      const other = AlbumUploadForm(
        uid: 31,
        formHash: 'f1f2f3f4',
        uploadUrl: 'u',
        uploadUid: '32',
        uploadHash: 'h',
        albums: [],
        privacy: [],
      );
      expect(
        await repo.uploadPhoto(other, '/tmp/a.png', fileSize: (_) => 1),
        left<SpaceUploadRefusal, int>(SpaceUploadRefusal.identityChanged),
      );
      net.uid = 32;
      expect(
        await repo.uploadPhoto(form, '/tmp/a.png', fileSize: (_) => 1),
        left<SpaceUploadRefusal, int>(SpaceUploadRefusal.identityChanged),
      );
      expect(
        (await repo.fileUploads(form, [1], const AlbumTarget.existing('1'))).outcome,
        SpaceWriteOutcome.identityChanged,
      );
      expect(net.files, isEmpty);
      expect(net.posts, isEmpty);
    });

    test('the page: the pictures one after the other, those taken filed, the others told', () async {
      final net = _Transport()
        ..page = _fixture('album_upload')
        ..fileAnswer = ((file) => file.filename == 'bad.png' ? '{"picid":"0"}' : '{"picid":"9"}')
        ..postAnswer = ((_, _) => _result(
          kind: 'message',
          key: 'upload_images_completed',
          url: 'home.php?mod=space&uid=31&do=album&quickforward=1&id=1',
          alert: 'info',
        ));
      final cubit = AlbumUploadCubit(net.repository(), fileSize: (_) => 1);
      await cubit.load();
      expect(cubit.state.status, SpaceWriteStatus.ready);
      await cubit.upload(['/tmp/ok.png', '/tmp/bad.png', '/tmp/x.webp'], const AlbumTarget.existing('1'));
      expect(cubit.state.status, SpaceWriteStatus.done);
      expect(cubit.state.id, 1);
      expect(cubit.state.refused.map((e) => (e.path, e.reason)), [
        ('/tmp/bad.png', SpaceUploadRefusal.rejected),
        ('/tmp/x.webp', SpaceUploadRefusal.type),
      ]);
      expect(net.posts.single.$2['title[9]'], '');
      // Done: nothing more is sent from the page.
      expect(cubit.canSend, isFalse);
      await cubit.close();
    });

    test('filing refused: the pictures taken are filed with the next send, not uploaded again', () async {
      var refuse = true;
      final net = _Transport()
        ..page = _fixture('album_upload')
        ..fileAnswer = ((_) => '{"picid":"7"}')
        ..postAnswer = ((_, _) => refuse
            ? _result(kind: 'message', key: 'operating_too_fast', url: '', ok: 0, alert: 'error', message: '太快了')
            : _result(
                kind: 'message',
                key: 'upload_images_completed',
                url: 'home.php?mod=space&uid=31&do=album&quickforward=1&id=2',
                alert: 'info',
              ));
      final cubit = AlbumUploadCubit(net.repository(), fileSize: (_) => 1);
      await cubit.load();
      await cubit.upload(['/tmp/a.png'], const AlbumTarget.create('新相册'));
      expect(cubit.state.status, SpaceWriteStatus.rejected);
      expect(cubit.state.message, '太快了');
      expect(cubit.state.pending, 1);
      expect(cubit.canSend, isTrue);
      refuse = false;
      await cubit.upload([], const AlbumTarget.create('新相册'));
      expect(cubit.state.status, SpaceWriteStatus.done);
      expect(cubit.state.filed, 1);
      expect(cubit.state.pending, 0);
      expect(net.files, hasLength(1));
      expect(net.posts, hasLength(2));
      expect(net.posts.last.$2['title[7]'], '');
      await cubit.close();
    });

    test('a file that cannot be read is not sent', () async {
      final net = _Transport()..page = _fixture('album_upload');
      final repo = net.repository();
      final form = (await repo.loadUploadForm()).form!;
      expect(
        await repo.uploadPhoto(form, '/nonexistent/space_test/a.png'),
        left<SpaceUploadRefusal, int>(SpaceUploadRefusal.failed),
      );
      expect(net.files, isEmpty);
    });

    test('nothing taken: nothing filed', () async {
      final net = _Transport()..page = _fixture('album_upload');
      final cubit = AlbumUploadCubit(net.repository(), fileSize: (_) => 1);
      await cubit.load();
      await cubit.upload(['/tmp/bad.png'], const AlbumTarget.existing('1'));
      expect(cubit.state.status, SpaceWriteStatus.rejected);
      expect(net.posts, isEmpty);
      await cubit.close();
    });
  });

  group('links', () {
    test("a member's blogs and albums open in the app", () {
      final blog = '$baseUrl/home.php?mod=space&uid=31&do=blog&id=5'.parseUrlToRoute()!;
      expect(blog.screenPath, ScreenPaths.spaceBlog);
      expect(blog.queryParameters, {'uid': '31', 'blogId': '5'});
      final album = '$baseUrl/home.php?mod=space&uid=31&do=album&id=-1'.parseUrlToRoute()!;
      expect(album.screenPath, ScreenPaths.spaceAlbum);
      expect(album.queryParameters, {'uid': '31', 'albumId': '-1'});
      final list = '$baseUrl/home.php?mod=space&uid=31&do=album&view=me&from=space'.parseUrlToRoute()!;
      expect(list.screenPath, ScreenPaths.space);
      expect(list.queryParameters, {'uid': '31', 'tab': 'album'});
      expect('home.php?mod=space&uid=31&do=blog&view=me'.parseUrlToRoute()!.queryParameters['tab'], 'blog');
      // A single picture, a list without a member: as before.
      expect('$baseUrl/home.php?mod=space&uid=31&do=album&picid=2'.parseUrlToRoute()!.screenPath, ScreenPaths.profile);
      expect('$baseUrl/home.php?mod=space&do=blog&view=all'.parseUrlToRoute()?.screenPath, isNot(ScreenPaths.space));
    });
  });
}
