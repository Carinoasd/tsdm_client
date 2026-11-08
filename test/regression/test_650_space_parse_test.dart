/// The pages of a member's space the app reads for the blogs and the albums, as the forum (Discuz! X5, the test site
/// with the blogs and the albums switched on) printed them: the lists, a blog with its comments, the pictures of an
/// album, the new blog form and the album upload page, and the pages the forum prints instead (the privacy notice, a
/// blog's password form, a missing blog).
///
/// The forum's app API (plugin 3.4.0) does not answer these pages as fields: they come back as the web page whether
/// or not `tsdmapp=json` is asked, and are parsed here.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/widgets/space_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/space';

uh.Document _page(String name) => parseHtmlDocument(File('$_dir/$name.html').readAsStringSync());

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('blog list', () {
    test("another member's list: the blogs they may read, the hidden note and the next page", () {
      final page = parseSpaceBlogListPage(_page('blog_list'));
      expect(page.message, isNull);
      // Ten a page, one of them kept from the viewer.
      expect(page.items, hasLength(9));
      final first = page.items.first;
      expect(first.uid, 31);
      expect(first.blogId, greaterThan(0));
      expect(first.author, '测试会员甲');
      expect(first.time, isNotNull);
      expect(first.privacy, isNull);
      expect(page.items.map((e) => e.blogId), isNot(contains(6)));
      expect(page.hiddenNote, '本页有 1 篇日志因作者的隐私设置或未通过审核而隐藏');
      expect(page.nextPageUrl, '$baseUrl/home.php?mod=space&uid=31&do=blog&view=me&order=dateline&page=2');
    });

    test('the last page: a blog with its category, reads and comments, and no next page', () {
      final page = parseSpaceBlogListPage(_page('blog_list_p2'));
      final blog = page.items.firstWhere((e) => e.blogId == 5);
      expect(blog.title, '测试日志一');
      expect(blog.summary, '第一行 粗 第二行 结束');
      expect(blog.category, '日常');
      expect(blog.views, greaterThanOrEqualTo(1));
      expect(blog.replies, 2);
      expect(page.hiddenNote, isNull);
      expect(page.nextPageUrl, isNull);
    });

    test("the author's own list tells who may read each blog", () {
      final page = parseSpaceBlogListPage(_page('blog_list_own'));
      final private = page.items.firstWhere((e) => e.blogId == 6);
      expect(private.title, '只给自己看的日志');
      expect(private.privacy, '仅自己可见');
      expect(private.author, '测试会员甲');
      expect(page.items.firstWhere((e) => e.blogId == 8).privacy, '凭密码可见');
      expect(page.items.firstWhere((e) => e.blogId == 7).privacy, isNull);
    });
  });

  group('blog', () {
    test('the content and the comments', () {
      final blog = parseSpaceBlogDetail(_page('blog_detail'));
      expect(blog.message, isNull);
      expect(blog.title, '测试日志一');
      expect(blog.time, '2026-11-9 01:05');
      expect(blog.category, '日常');
      expect(blog.content?.text, contains('第二行 & 结束'));
      expect(blog.commentCount, 2);
      expect(blog.comments, hasLength(2));
      final comment = blog.comments.first;
      expect(comment.cid, 7);
      expect(comment.author, '测试会员乙');
      expect(comment.uid, 33);
      expect(comment.time, '2026-11-9 01:08');
      expect(comment.avatarUrl, 'https://forum.test/data/avatar/noavatar.svg');
      expect(comment.message.text, '很好看的日志');
      // The forum escaped the html of a comment: it is text.
      expect(blog.comments.last.message.text, '第二条评论 <b>x</b>');
      expect(blog.nextCommentsUrl, isNull);
    });

    test('a blog the author keeps from the viewer: the privacy notice', () {
      final blog = parseSpaceBlogDetail(_page('blog_privacy'));
      expect(blog.content, isNull);
      expect(blog.message, '抱歉！由于 测试会员甲 的隐私设置，您不能访问当前内容');
      expect(blog.passwordRequired, isFalse);
      expect(blog.needLogin, isFalse);
    });

    test('a blog with a password', () {
      final blog = parseSpaceBlogDetail(_page('blog_password'));
      expect(blog.content, isNull);
      expect(blog.passwordRequired, isTrue);
      expect(blog.message, '您需要正确输入密码后才能继续查看');
    });

    test('a missing blog: the forum message', () {
      final blog = parseSpaceBlogDetail(_page('blog_missing'));
      expect(blog.content, isNull);
      expect(blog.message, '抱歉，您要查看的信息不存在或已被删除');
      expect(blog.needLogin, isFalse);
    });
  });

  group('albums', () {
    test('the album list with the default album', () {
      final page = parseSpaceAlbumListPage(_page('album_list_own'));
      expect(page.items, hasLength(2));
      final album = page.items.first;
      expect(album.albumId, 1);
      expect(album.uid, 31);
      expect(album.name, '测试相册');
      expect(album.count, 2);
      expect(album.coverUrl, '$baseUrl/data/attachment/album/cover/c4/1.jpg');
      final fallback = page.items.last;
      expect(fallback.albumId, -1);
      expect(fallback.name, '默认相册');
      expect(fallback.coverUrl, isNull);
    });

    test("another member's album list", () {
      final page = parseSpaceAlbumListPage(_page('album_list'));
      expect(page.message, isNull);
      expect(page.items.map((e) => e.albumId), contains(1));
    });

    test('the pictures of an album: thumbnails and the pictures themselves', () {
      final page = parseSpaceAlbumPhotosPage(_page('album_photos'));
      expect(page.title, '测试相册');
      expect(page.totalCount, 2);
      expect(page.items.map((e) => e.picId), [2, 1]);
      final photo = page.items.first;
      expect(photo.thumbUrl, endsWith('.png.thumb.jpg'));
      expect(photo.thumbUrl, startsWith('$baseUrl/data/attachment/album/'));
      expect(photo.imageUrl, photo.thumbUrl.substring(0, photo.thumbUrl.length - '.thumb.jpg'.length));
      expect(page.nextPageUrl, isNull);
    });

    test('a picture too small for a thumbnail is shown as it is', () {
      expect(spacePhotoImageUrl('$baseUrl/data/attachment/album/a.gif'), '$baseUrl/data/attachment/album/a.gif');
      expect(
        spacePhotoImageUrl('$baseUrl/data/attachment/album/a.jpg.thumb.jpg'),
        '$baseUrl/data/attachment/album/a.jpg',
      );
      expect(spaceAbsoluteUrl('./data/avatar/x.jpg'), '$baseUrl/data/avatar/x.jpg');
      expect(spaceAbsoluteUrl('https://img.example/x.jpg'), 'https://img.example/x.jpg');
    });
  });

  group('forms', () {
    test('the new blog form', () {
      final page = parseBlogPostForm(_page('blog_form'));
      final form = page.form!;
      expect(form.uid, 31);
      expect(form.formHash, 'f1f2f3f4');
      expect(form.categories, [(value: '1', label: '日常')]);
      expect(form.privacy.map((e) => e.value), ['0', '1', '2', '3', '4']);
      expect(form.privacy.first.label, '全站用户可见');
      expect(form.systemCategories, isEmpty);
    });

    test('a page that is not the form: its message', () {
      final page = parseBlogPostForm(_page('blog_missing'));
      expect(page.form, isNull);
      expect(page.message, '抱歉，您要查看的信息不存在或已被删除');
    });

    test('the album upload page', () {
      final form = parseAlbumUploadForm(_page('album_upload')).form!;
      expect(form.uid, 31);
      expect(form.formHash, 'f1f2f3f4');
      expect(form.uploadUrl, 'https://forum.test/misc.php?mod=swfupload&action=swfupload&operation=album');
      expect(form.uploadUid, '31');
      expect(form.uploadHash, '0123456789abcdef0123456789abcdef');
      expect(form.maxKb, 2000);
      expect(form.extensions, ['jpg', 'jpeg', 'gif', 'png']);
      expect(form.albums, [(value: '1', label: '测试相册')]);
      expect(form.privacy.map((e) => e.value), ['0', '1', '2', '3', '4']);
      expect(form.accepts('a.PNG'), isTrue);
      expect(form.accepts('a.webp'), isFalse);
      expect(form.accepts('noext'), isFalse);
    });

    test('the answers of the album uploader', () {
      expect(parseAlbumUploadAnswer('{"picid":"12", "url":"data/x.thumb.jpg", "bigimg":"data/x"}'), 12);
      expect(parseAlbumUploadAnswer({'picid': '3', 'url': 'u'}), 3);
      expect(parseAlbumUploadAnswer('{"picid":"0", "url":"0", "bigimg":"0"}'), isNull);
      expect(parseAlbumUploadAnswer('<html>'), isNull);
      expect(parseAlbumUploadAnswer(null), isNull);
    });

    test('where the forum goes once a blog is posted, and pictures filed', () {
      expect(spaceBlogIdOfUrl('home.php?mod=space&uid=31&do=blog&quickforward=1&id=5'), 5);
      expect(spaceBlogIdOfUrl('home.php?mod=space&uid=31&do=album&id=5'), isNull);
      expect(spaceBlogIdOfUrl(null), isNull);
      expect(spaceAlbumIdOfUrl('home.php?mod=space&uid=31&do=album&quickforward=1&id=-1'), -1);
      expect(spaceAlbumIdOfUrl('home.php?mod=space&uid=31&do=album&quickforward=1&id=1'), 1);
    });

    test('a blog posted as plain text shows what was typed', () {
      expect(spaceBlogPlainText('a <b> & c\r\nd'), 'a &lt;b&gt; &amp; c\nd');
    });
  });

  testWidgets('the cards of the lists and a comment lay out', (tester) async {
    final blog = parseSpaceBlogDetail(_page('blog_detail'));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                SpaceBlogCard(parseSpaceBlogListPage(_page('blog_list_own')).items.firstWhere((e) => e.blogId == 6)),
                SizedBox(
                  width: 180,
                  height: 220,
                  child: SpaceAlbumTile(parseSpaceAlbumListPage(_page('album_list_own')).items.last),
                ),
                SpaceBlogCommentTile(
                  SpaceBlogComment(cid: 1, author: '测试会员乙', message: blog.comments.first.message, time: '2026-11-9'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('只给自己看的日志'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.text('默认相册'), findsOneWidget);
    expect(find.text('测试会员乙'), findsOneWidget);
    expect(find.textContaining('很好看的日志', findRichText: true), findsOneWidget);
  });
}
