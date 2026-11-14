/// The account's session only goes with an attachment request to the canonical https host of the forum.
///
/// An attachment link written as `http://`, without `www` or with the host in capitals used to be requested as
/// written, with the account's cookie. Now every entry (the tap on a link, the download manager, each hop of its
/// redirects, the audio attachments) asks for `https://www.tsdm39.com/...`; a redirect anywhere else goes without the
/// session. Only `forum.php` itself is an attachment address: `/plugin.php/forum.php?mod=attachment…` is not.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_store.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_fetcher.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';
import 'package:tsdm_client/features/audio_player/utils/audio_attachment.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:universal_html/parsing.dart';

/// The token of attachment [aid] of thread 1000 for uid 31.
String _token(int aid) => Uri.encodeQueryComponent(base64.encode(utf8.encode('$aid|f1f2f3f4|1700000000|31|1000')));

/// The forum: answers by url, records every url asked for.
final class _Fetcher extends ChangeNotifier implements AttachmentFetcher {
  _Fetcher(this.answers, {this.pages = const {}});

  final Map<String, AttachmentFetchAnswer> answers;
  final Map<String, String> pages;
  final requests = <String>[];

  @override
  Future<AttachmentFetchAnswer> fetch(
    String url,
    String savePath, {
    required int uid,
    required CancelToken cancelToken,
    void Function(int received, int? total)? onProgress,
  }) async {
    requests.add(url);
    notifyListeners();
    final answer = answers[url];
    if (answer == null) {
      throw AttachmentFetchException('no route: $url');
    }
    await File(savePath).writeAsString('file bytes');
    return answer;
  }

  @override
  Future<String> fetchPage(String url, {required int uid}) async {
    requests.add(url);
    return pages[url] ?? (throw AttachmentFetchException('no page: $url'));
  }
}

AttachmentFetchAnswer _file() => (status: 200, location: null, disposition: 'attachment; filename="a.zip"', length: 10);

AttachmentFetchAnswer _redirect(String to) => (status: 302, location: to, disposition: null, length: 0);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  final token = _token(36);
  final canonical = '$baseUrl/forum.php?mod=attachment&aid=$token';

  group('the address of an attachment', () {
    test('http, without www and in capitals: on the canonical https host', () {
      for (final url in [
        'http://www.tsdm39.com/forum.php?mod=attachment&aid=$token',
        'http://tsdm39.com/forum.php?mod=attachment&aid=$token',
        'https://tsdm39.com/forum.php?mod=attachment&aid=$token',
        'HTTP://WWW.TSDM39.COM/forum.php?mod=attachment&aid=$token',
        ' forum.php?mod=attachment&aid=$token ',
        '/forum.php?mod=attachment&aid=$token',
        canonical,
      ]) {
        expect(isAttachmentDownloadUrl(url), isTrue, reason: url);
        expect(canonicalAttachmentUrl(url), canonical, reason: url);
        expect(isCanonicalForumUrl(canonicalAttachmentUrl(url)), isTrue, reason: url);
      }
      expect(isCanonicalForumUrl('http://www.tsdm39.com/forum.php'), isFalse);
      expect(isCanonicalForumUrl('https://tsdm39.com/forum.php'), isFalse);
      expect(isCanonicalForumUrl('https://cdn.example.test/a.zip'), isFalse);
      // Another host stays as it is.
      expect(canonicalAttachmentUrl('http://cdn.example.test/a.zip'), 'http://cdn.example.test/a.zip');
    });

    test('only forum.php itself', () {
      for (final url in [
        'https://www.tsdm39.com/plugin.php/forum.php?mod=attachment&aid=$token',
        'plugin.php/forum.php?mod=attachment&aid=$token',
        'https://www.tsdm39.com/x/forum.php?mod=attachment&aid=$token',
        'https://www.tsdm39.com/myforum.php?mod=attachment&aid=$token',
        'https://www.tsdm39.com.example.test/forum.php?mod=attachment&aid=$token',
        'ftp://www.tsdm39.com/forum.php?mod=attachment&aid=$token',
      ]) {
        expect(isAttachmentDownloadUrl(url), isFalse, reason: url);
      }
      expect(isAttachmentDownloadUrl('https://www.tsdm39.com?mod=attachment&aid=$token'), isTrue);
      expect(isAttachmentDownloadUrl('https://www.tsdm39.com/FORUM.PHP?mod=attachment&aid=$token'), isTrue);
    });

    test('a tap on an attachment link of a post: relative or from the root, still an attachment', () {
      for (final href in ['forum.php?mod=attachment&aid=$token', '/forum.php?mod=attachment&aid=$token']) {
        final target = linkTapTargetOf(href)!;
        expect(target, canonical, reason: href);
        expect(isAttachmentDownloadUrl(target), isTrue, reason: href);
      }
      expect(linkTapTargetOf('magnet:?xt=urn:btih:0123'), 'magnet:?xt=urn:btih:0123');
      expect(linkTapTargetOf('www.example.test:8080/a'), '$baseUrl/www.example.test:8080/a');
      expect(linkTapTargetOf('//cdn.example.test/a.png'), 'https://cdn.example.test/a.png');
      expect(linkTapTargetOf('#pid1'), isNull);
      expect(linkTapTargetOf(' JavaScript:void(0)'), isNull);
    });

    test('an audio attachment follows its redirects one by one, the forum ones on the canonical host', () {
      expect(nextAudioAttachmentHop(canonical, 200, null), isNull);
      expect(nextAudioAttachmentHop(canonical, 302, null), isNull);
      final forum = nextAudioAttachmentHop(
        canonical,
        302,
        'http://tsdm39.com/forum.php?mod=attachment&aid=$token&ck=1',
      );
      expect(forum, '$canonical&ck=1');
      expect(isCanonicalForumUrl(forum!), isTrue);
      expect(nextAudioAttachmentHop(canonical, 302, 'forum.php?mod=attachment&aid=$token&ck=1'), '$canonical&ck=1');
      // Anywhere else: as named, and not with the session.
      final other = nextAudioAttachmentHop(canonical, 301, 'http://cdn.example.test/a.mp3');
      expect(other, 'http://cdn.example.test/a.mp3');
      expect(isCanonicalForumUrl(other!), isFalse);
    });

    test('an audio attachment: the same check, the canonical address', () {
      PostAudioAttachment? of(String href) => PostAudioAttachment.of(
        parseHtmlDocument(
          [
            '<ignore_js_op><img src="static/image/filetype/av.gif" />',
            '<span id="attach_36"><a href="$href">song.mp3</a> <em class="xg1">(36.73 KB, 下载次数: 0)</em></span>',
            '</ignore_js_op>',
          ].join(),
        ).querySelector('ignore_js_op')!,
      );
      expect(of('http://tsdm39.com/forum.php?mod=attachment&amp;aid=$token')?.url, canonical);
      expect(of('forum.php?mod=attachment&amp;aid=$token')?.url, canonical);
      expect(of('https://www.tsdm39.com/plugin.php/forum.php?mod=attachment&amp;aid=$token'), isNull);
      expect(of('http://other.example.test/forum.php?mod=attachment&amp;aid=$token'), isNull);
    });
  });

  group('a download', () {
    late Directory dir;
    late Map<String, String> rows;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tsdm_1210');
      rows = {};
    });

    tearDown(() => dir.deleteSync(recursive: true));

    AttachmentDownloadManager managerOf(_Fetcher fetcher) => AttachmentDownloadManager(
      fetcher: fetcher,
      store: AttachmentDownloadStore.memory(rows),
      directory: () async => dir,
      partDirectory: () async => Directory('${dir.path}/parts'),
      progressInterval: Duration.zero,
    );

    Future<AttachmentDownload> finished(AttachmentDownloadManager manager, AttachmentDownload item) async {
      final done = Completer<void>();
      void look() {
        if (!done.isCompleted && !(manager.find(item.uid, item.id)?.status.active ?? true)) {
          done.complete();
        }
      }

      manager.addListener(look);
      look();
      await done.future.timeout(const Duration(seconds: 20));
      manager.removeListener(look);
      return manager.find(item.uid, item.id)!;
    }

    test('a link written as http goes to the canonical https host, each hop too', () async {
      const storage = 'https://cdn.example.test/a.zip';
      const credit = '$baseUrl/forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4';
      final paid = '$canonical&ck=c1c2c3c4';
      final fetcher = _Fetcher(
        {
          // The forum answers with its own host in http: still asked for over https.
          canonical: _redirect('http://tsdm39.com/forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4'),
          paid: _redirect(storage),
          storage: _file(),
        },
        pages: {
          credit: [
            '<div id="messagetext"><p>ok</p><p class="alert_btnleft">',
            '<a href="http://www.tsdm39.com/forum.php?mod=attachment&amp;aid=$token&amp;ck=c1c2c3c4">go</a>',
            '</p></div>',
          ].join(),
        },
      );
      final manager = managerOf(fetcher);
      final item = await manager.start(
        uid: 31,
        url: 'http://tsdm39.com/forum.php?mod=attachment&aid=$token',
        filename: 'a.zip',
      );
      expect(item.url, canonical);
      final done = await finished(manager, item);
      expect(done.status, AttachmentDownloadStatus.completed);
      expect(fetcher.requests, [canonical, credit, paid, storage]);
      // Only the forum's requests carry the session ([NetAttachmentFetcher] picks its client by this).
      expect(fetcher.requests.map(isCanonicalForumUrl), [true, true, true, false]);
    });

    test('a relative link downloads as before', () async {
      final fetcher = _Fetcher({canonical: _file()});
      final manager = managerOf(fetcher);
      final item = await manager.start(uid: 31, url: 'forum.php?mod=attachment&aid=$token', filename: 'a.zip');
      expect((await finished(manager, item)).status, AttachmentDownloadStatus.completed);
      expect(fetcher.requests, [canonical]);
    });

    test('the same attachment written another way is the same download', () async {
      final fetcher = _Fetcher({canonical: _file()});
      final manager = managerOf(fetcher);
      final first = await manager.start(uid: 31, url: canonical, filename: 'a.zip');
      await finished(manager, first);
      final again = await manager.start(
        uid: 31,
        url: 'HTTP://TSDM39.COM/forum.php?mod=attachment&aid=$token',
        filename: 'a.zip',
      );
      expect(again.id, first.id);
      expect(fetcher.requests, [canonical]);
    });
  });
}
