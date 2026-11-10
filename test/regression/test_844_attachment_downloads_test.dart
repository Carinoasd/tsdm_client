/// Attachments download in the app: the forum's answers read (the file, a refusal in its words, the price to pay, the
/// credits a download takes), the downloads kept per account and run as a state machine (queued, running, completed,
/// failed, cancelled, retried), and the downloads page.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_store.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_fetcher.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/attachment_download/utils/download_location.dart';
import 'package:tsdm_client/features/attachment_download/view/attachment_downloads_page.dart';
import 'package:tsdm_client/features/attachment_download/widgets/attachment_download_actions.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:universal_html/parsing.dart';

const String _base = baseUrl;

String _fixture(String name) => File('test/data/attachment_download/$name').readAsStringSync();

/// The download address of attachment [aid] of thread 1000 as the post links to it.
String _urlOf(int aid) =>
    '$_base/forum.php?mod=attachment&aid=${base64.encode(utf8.encode('$aid|f1f2f3f4|1700000000|31|1000'))}';

/// One answer of the fake forum: the body written into the file, and the headers.
typedef _Answer = ({int status, String body, String? location, String? disposition});

_Answer _file(String body, {String name = 'acc_note.zip'}) =>
    (status: 200, body: body, location: null, disposition: 'attachment; filename="${Uri.encodeComponent(name)}"');

_Answer _page(String body) => (status: 200, body: body, location: null, disposition: null);

_Answer _redirect(String location) => (status: 302, body: '', location: location, disposition: null);

/// The forum: answers each address from [answers] (the same address answered in turn), records the requests and
/// tells its listeners each one.
final class _FakeFetcher extends ChangeNotifier implements AttachmentFetcher {
  _FakeFetcher(this.answers, {this.pages = const {}});

  final Map<String, List<_Answer>> answers;
  final Map<String, String> pages;
  final requests = <String>[];
  final pageRequests = <String>[];

  /// While not null, a fetch waits for it (or its cancel).
  Completer<void>? gate;

  /// The addresses held back one by one: a fetch of one waits until it is [release]d (or cancelled), before anything
  /// is written.
  final _held = <String, Completer<void>>{};

  /// Hold back the answers of [urls] until each is [release]d.
  void hold(Iterable<String> urls) {
    for (final url in urls) {
      _held[url] = Completer<void>();
    }
  }

  /// Let the answer of [url] go.
  void release(String url) => _held.remove(url)!.complete();

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
    final gate = _held[url] ?? this.gate;
    if (gate != null) {
      await Future.any([gate.future, cancelToken.whenCancel]);
      if (cancelToken.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: 'cancelled',
        );
      }
    }
    final queue = answers[url];
    if (queue == null || queue.isEmpty) {
      throw const AttachmentFetchException('no route');
    }
    final answer = queue.length == 1 ? queue.first : queue.removeAt(0);
    final bytes = utf8.encode(answer.body);
    await File(savePath).writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
    return (status: answer.status, location: answer.location, disposition: answer.disposition, length: bytes.length);
  }

  @override
  Future<String> fetchPage(String url, {required int uid}) async {
    pageRequests.add(url);
    final page = pages[url];
    if (page == null) {
      throw const AttachmentFetchException('no page');
    }
    return page;
  }
}

/// Wait until [test] holds: looked at again each time [manager] tells a change of its downloads or [fetcher] is asked
/// for an address. Nothing is polled and no delay is counted on (the runs are real async work, as slow as the machine
/// is); what never comes fails with the downloads as they are.
Future<void> _until(AttachmentDownloadManager manager, bool Function() test, {_FakeFetcher? fetcher}) async {
  if (test()) {
    return;
  }
  final held = Completer<void>();
  void look() {
    if (!held.isCompleted && test()) {
      held.complete();
    }
  }

  manager.addListener(look);
  fetcher?.addListener(look);
  try {
    await held.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail(
        'never came: the downloads are ${[
          for (final uid in const [0, 31, 35]) ...manager.itemsOf(uid).map((e) => '${e.filename} ${e.status.name}'),
        ]}, asked ${fetcher?.requests.length ?? '?'} times',
      ),
    );
  } finally {
    manager.removeListener(look);
    fetcher?.removeListener(look);
  }
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('the forum answers', () {
    test('the download addresses of attachments, and their thread', () {
      expect(isAttachmentDownloadUrl(_urlOf(36)), isTrue);
      expect(isAttachmentDownloadUrl('forum.php?mod=attachment&aid=MzZ8YQ%3D%3D'), isTrue);
      expect(isAttachmentDownloadUrl('forum.php?mod=attachment&aid=36&nothumb=yes'), isTrue);
      expect(isAttachmentDownloadUrl('forum.php?mod=attachment&aid=36&findpost=1'), isFalse);
      expect(isAttachmentDownloadUrl('forum.php?mod=misc&action=attachpay&aid=37&tid=1000'), isFalse);
      expect(isAttachmentDownloadUrl('forum.php?mod=viewthread&tid=1000'), isFalse);
      expect(isAttachmentDownloadUrl('plugin.php?mod=attachment&aid=1'), isFalse);
      expect(isAttachPayUrl('$_base/forum.php?mod=misc&action=attachpay&aid=37&tid=1000'), isTrue);
      expect(isAttachCreditUrl('forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4'), isTrue);
      expect(tidOfAttachmentUrl(_urlOf(36)), '1000');
      expect(tidOfAttachmentUrl('forum.php?mod=attachment&aid=36'), isNull);
      // Another forum's attachment stays a link.
      expect(isAttachmentDownloadUrl('https://bbs.other.test/forum.php?mod=attachment&aid=MzZ8YQ%3D%3D'), isFalse);
    });

    test('the sizes the forum prints', () {
      expect(attachmentSizeOf('(153 Bytes, 下载次数: 2)'), 153);
      expect(attachmentSizeOf('36.73 KB, 下载次数: 0'), (36.73 * 1024).round());
      expect(attachmentSizeOf('(1.5 MB, 下载次数: 0)'), (1.5 * 1024 * 1024).round());
      expect(attachmentSizeOf('2 GB'), 2 * 1024 * 1024 * 1024);
      expect(attachmentSizeOf('下载次数: 0'), isNull);
      expect(attachmentSizeOf(null), isNull);
    });

    test('the file name the forum sends, percent-encoded in both forms', () {
      // As the forum sent `测试 歌曲.mp3`.
      const both =
          'attachment; filename="%E6%B5%8B%E8%AF%95%20%E6%AD%8C%E6%9B%B2.mp3"; '
          "filename*=utf-8''%E6%B5%8B%E8%AF%95%20%E6%AD%8C%E6%9B%B2.mp3";
      expect(filenameOfContentDisposition(both), '测试 歌曲.mp3');
      expect(filenameOfContentDisposition('attachment; filename="%E6%B5%8B.zip"'), '测.zip');
      expect(filenameOfContentDisposition('attachment; filename="acc_note.zip"'), 'acc_note.zip');
      expect(filenameOfContentDisposition('attachment; filename="bad%E6%.zip"'), 'bad%E6%.zip');
      expect(filenameOfContentDisposition('attachment'), isNull);
      expect(isFileDisposition('attachment; filename="a.zip"'), isTrue);
      expect(isFileDisposition('inline; filename=a.jpg'), isTrue);
      expect(isFileDisposition(null), isFalse);
    });

    test('a refusal in the forum words, its page and its AJAX answer', () {
      final base = Uri.parse('$_base/forum.php');
      final page = forumAnswerOf(_fixture('refused_no_permission.html'), base: base);
      expect(page?.message, '抱歉，只有特定用户可以下载本站附件');
      // The links its script writes (back, the homepage) are no link of the answer.
      expect(page?.link, isNull);
      final ajax = forumAnswerOf(_fixture('refused_no_permission_ajax.xml'), base: base);
      expect(ajax?.message, '抱歉，只有特定用户可以下载本站附件');
      expect(forumAnswerOf('PK\x03\x04 binary', base: base), isNull);
    });

    test('the price not paid leads to the purchase, the credits taken to the download', () {
      final base = Uri.parse('$_base/forum.php');
      final unpaid = forumAnswerOf(_fixture('refused_price_unpaid.html'), base: base)!;
      expect(unpaid.message, '附件需要付费，请您付费后下载');
      expect(unpaid.link, '$_base/forum.php?mod=misc&action=attachpay&aid=37&tid=1000');
      expect(isAttachPayUrl(unpaid.link!), isTrue);
      final credit = forumAnswerOf(_fixture('credit_taken.html'), base: base)!;
      expect(credit.message, '您的 天使币 -1 ，现在将开始下载“acc_note.zip”');
      expect(credit.link, '${_urlOf(36)}&ck=c1c2c3c4');
      expect(isAttachmentDownloadUrl(credit.link!), isTrue);
    });

    test('the name and the size printed with an attachment link, in the post and in the list below it', () {
      final doc = parseHtmlDocument(_fixture('post_attachments.html'));
      final links = doc.querySelectorAll('a[href]').where((e) => isAttachmentDownloadUrl(e.attributes['href']!));
      final infos = [for (final link in links) attachmentLinkInfoOf(link)];
      expect(infos.map((e) => e.filename), ['acc_note.zip', 'perm_note.zip']);
      expect(infos.map((e) => attachmentSizeOf(e.sizeText)), [153, 153]);
      // The attachment to buy links to its purchase: not a download.
      expect(
        doc.querySelectorAll('a[href]').where((e) => isAttachPayUrl(_absolute(e.attributes['href']!))),
        isNotEmpty,
      );
    });

    test('the name a file is saved as', () {
      expect(safeDownloadFileName(r'a/b\c:d*e?.zip', fallback: 'x'), 'a_b_c_d_e_.zip');
      expect(safeDownloadFileName('..', fallback: 'x'), 'x');
      expect(safeDownloadFileName('  ', fallback: 'x'), 'x');
      expect(safeDownloadFileName('.hidden', fallback: 'x'), 'hidden');
      final long = safeDownloadFileName('${'名' * 300}.zip', fallback: 'x');
      expect(long.length, 180);
      expect(long.endsWith('.zip'), isTrue);
      final dir = Directory.systemTemp.createTempSync('tsdm_844_names');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/a.zip').writeAsStringSync('1');
      File('${dir.path}/a (1).zip').writeAsStringSync('1');
      expect(uniqueFileIn(dir, 'a.zip').path, '${dir.path}/a (2).zip');
      expect(uniqueFileIn(dir, 'b.zip').path, '${dir.path}/b.zip');
      expect(formatDownloadSize(153), '153 B');
      expect(formatDownloadSize(2 * 1024 * 1024), '2.0 MB');
    });
  });

  group('the downloads', () {
    late Directory dir;
    late Directory parts;
    late Map<String, String> rows;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tsdm_844_downloads');
      parts = Directory.systemTemp.createTempSync('tsdm_844_parts');
      rows = {};
    });

    tearDown(() {
      for (final d in [dir, parts]) {
        if (d.existsSync()) {
          d.deleteSync(recursive: true);
        }
      }
    });

    AttachmentDownloadManager managerOf(
      _FakeFetcher fetcher, {
      DateTime Function()? now,
      int maxRunning = 2,
      Future<Directory> Function()? partDirectory,
    }) => AttachmentDownloadManager(
      fetcher: fetcher,
      store: AttachmentDownloadStore.memory(rows),
      directory: () async => dir,
      partDirectory: partDirectory ?? () async => parts,
      now: now,
      maxRunning: maxRunning,
      progressInterval: Duration.zero,
    );

    List<Map<String, dynamic>> rowOf(int uid) =>
        (jsonDecode(rows[AttachmentDownloadStore.rowKeyOf(uid)]!) as List).cast<Map<String, dynamic>>();

    test('a file is saved under the name the forum sends, and kept for its account', () async {
      final url = _urlOf(36);
      final fetcher = _FakeFetcher({
        url: [_file('zip bytes', name: '测试 歌曲.mp3')],
      });
      final manager = managerOf(fetcher);
      final item = await manager.start(uid: 31, url: url, filename: 'song.mp3', size: 9);
      expect(item.status, AttachmentDownloadStatus.queued);
      expect(item.tid, '1000');
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
      final done = manager.find(31, item.id)!;
      expect(done.filename, '测试 歌曲.mp3');
      expect(done.path, '${dir.path}/测试 歌曲.mp3');
      expect(File(done.path!).readAsStringSync(), 'zip bytes');
      expect(done.received, 9);
      expect(done.finishedAt, isNotNull);
      // No part file left, nor its empty folder.
      expect(dir.listSync().map((e) => e.path.split('/').last), ['测试 歌曲.mp3']);
      expect(parts.existsSync(), isFalse);
      expect(rowOf(31).single['status'], 'completed');
      expect(rows.containsKey(AttachmentDownloadStore.rowKeyOf(35)), isFalse);
    });

    test('a refusal fails the download with the forum words, the price with its purchase', () async {
      final refused = _urlOf(38);
      final unpaid = _urlOf(37);
      final fetcher = _FakeFetcher({
        refused: [_page(_fixture('refused_no_permission.html'))],
        unpaid: [_page(_fixture('refused_price_unpaid.html'))],
      });
      final manager = managerOf(fetcher);
      final a = await manager.start(uid: 31, url: refused, filename: 'perm_note.zip');
      final b = await manager.start(uid: 31, url: unpaid, filename: 'paid_note.zip');
      await _until(manager, () => manager.itemsOf(31).every((e) => !e.status.active));
      final first = manager.find(31, a.id)!;
      expect(first.status, AttachmentDownloadStatus.failed);
      expect(first.message, '抱歉，只有特定用户可以下载本站附件');
      expect(first.purchaseUrl, isNull);
      expect(first.path, isNull);
      final second = manager.find(31, b.id)!;
      expect(second.message, '附件需要付费，请您付费后下载');
      expect(second.purchaseUrl, '$_base/forum.php?mod=misc&action=attachpay&aid=37&tid=1000');
      expect(attachmentDownloadActionsOf(second).map((e) => e.kind), [
        AttachmentDownloadActionKind.purchase,
        AttachmentDownloadActionKind.retry,
        AttachmentDownloadActionKind.thread,
        AttachmentDownloadActionKind.delete,
      ]);
      // Nothing saved: no file, no part file.
      expect(dir.listSync(), isEmpty);
      expect(parts.existsSync(), isFalse);
    });

    test('a redirect to the purchase fails with it', () async {
      final url = _urlOf(37);
      final fetcher = _FakeFetcher({
        url: [_redirect('forum.php?mod=misc&action=attachpay&aid=37&tid=1000')],
      });
      final manager = managerOf(fetcher);
      final item = await manager.start(uid: 31, url: url, filename: 'paid_note.zip');
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.failed);
      expect(manager.find(31, item.id)!.purchaseUrl, '$_base/forum.php?mod=misc&action=attachpay&aid=37&tid=1000');
    });

    test('a download costing credits takes them once: a retry within the hour reuses the paid address', () async {
      final url = _urlOf(36);
      const credit = '$_base/forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4';
      final paid = '${_urlOf(36)}&ck=c1c2c3c4';
      var now = DateTime(2026, 11, 10, 12);
      final fetcher = _FakeFetcher(
        {
          url: [_redirect('forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4')],
          // The paid address answers a page that is none of the forum's the first time, then hands the file out.
          paid: [_page('<html><body>oops</body></html>'), _file('zip bytes')],
        },
        pages: {credit: _fixture('credit_taken.html')},
      );
      final manager = managerOf(fetcher, now: () => now);
      final item = await manager.start(uid: 31, url: url, filename: 'acc_note.zip');
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.failed);
      var current = manager.find(31, item.id)!;
      expect(fetcher.pageRequests, [credit]);
      expect(current.notice, '您的 天使币 -1 ，现在将开始下载“acc_note.zip”');
      expect(current.resolvedUrl, paid);
      // The page that took the credits is no file: failed, without words of the forum.
      expect(current.message, isNull);

      now = now.add(const Duration(minutes: 10));
      await manager.retry(31, item.id);
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
      current = manager.find(31, item.id)!;
      expect(fetcher.pageRequests, [credit], reason: 'the credits are not taken again');
      expect(fetcher.requests, [url, paid, paid]);
      expect(File(current.path!).readAsStringSync(), 'zip bytes');

      // An hour later the paid address is no longer valid: the download starts over from the post's address.
      expect(attachmentResolvedUrlValidFor, lessThan(const Duration(hours: 1)));
    });

    test(
      'tapping the attachment again after a paid download failed reuses it: the credits are not taken twice',
      () async {
        final url = _urlOf(36);
        // The post opened again: another token of the same attachment.
        final later =
            '$_base/forum.php?mod=attachment&aid=${base64.encode(utf8.encode('36|a1a2a3a4|1700000100|31|1000'))}';
        const credit = '$_base/forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4';
        final paid = '${_urlOf(36)}&ck=c1c2c3c4';
        final fetcher = _FakeFetcher(
          {
            url: [_redirect('forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4')],
            later: [_redirect('forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4')],
            paid: [_page('<html><body>oops</body></html>'), _file('zip bytes')],
          },
          pages: {credit: _fixture('credit_taken.html')},
        );
        final manager = managerOf(fetcher);
        final item = await manager.start(uid: 31, url: url, filename: 'acc_note.zip');
        await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.failed);
        final again = await manager.start(uid: 31, url: later, filename: 'acc_note.zip');
        expect(again.id, item.id);
        expect(again.url, later);
        await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
        expect(fetcher.pageRequests, [credit]);
        expect(fetcher.requests, [url, paid, paid]);
        expect(manager.itemsOf(31), hasLength(1));
      },
    );

    test('a running download is cancelled and retried; the same address is not downloaded twice at once', () async {
      final url = _urlOf(36);
      final fetcher = _FakeFetcher({
        url: [_file('zip bytes')],
      })..gate = Completer<void>();
      final manager = managerOf(fetcher);
      final item = await manager.start(uid: 31, url: url, filename: 'acc_note.zip');
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.running);
      final again = await manager.start(uid: 31, url: url, filename: 'acc_note.zip');
      expect(again.id, item.id);
      expect(manager.itemsOf(31), hasLength(1));
      await manager.cancel(31, item.id);
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.cancelled);
      expect(dir.listSync(), isEmpty);
      expect(parts.existsSync(), isFalse);
      expect(attachmentDownloadActionsOf(manager.find(31, item.id)!).first.kind, AttachmentDownloadActionKind.retry);

      fetcher.gate = null;
      await manager.retry(31, item.id);
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
      expect(manager.find(31, item.id)!.message, isNull);
    });

    test('at most two run at once, the others wait their turn in the order asked', () async {
      final urls = [
        for (final aid in [1, 2, 3, 4]) _urlOf(aid),
      ];
      final fetcher = _FakeFetcher({
        for (final (i, url) in urls.indexed) url: [_file('file $i', name: 'f$i.zip')],
      })..hold(urls);
      // The first download to start is the last of the two to reach the forum: its part folder answers late. Which of
      // the two running asks first is no matter of the queue (both run), and is not counted on.
      final slow = Completer<void>();
      var asked = 0;
      final manager = managerOf(
        fetcher,
        partDirectory: () async {
          if (asked++ == 0) {
            await slow.future;
          }
          return parts;
        },
      );
      final items = [for (final url in urls) await manager.start(uid: 31, url: url, filename: url)];
      AttachmentDownloadStatus statusOf(int i) => manager.find(31, items[i].id)!.status;
      await _until(manager, () => fetcher.requests.isNotEmpty, fetcher: fetcher);
      expect(fetcher.requests, [urls[1]]);
      slow.complete();
      await _until(manager, () => fetcher.requests.length == 2, fetcher: fetcher);
      expect(fetcher.requests, [urls[1], urls[0]]);
      expect(
        [for (var i = 0; i < 4; i++) statusOf(i)],
        [
          AttachmentDownloadStatus.running,
          AttachmentDownloadStatus.running,
          AttachmentDownloadStatus.queued,
          AttachmentDownloadStatus.queued,
        ],
      );

      // One place free: the third asked takes it, not the fourth.
      fetcher.release(urls[1]);
      await _until(manager, () => fetcher.requests.length == 3, fetcher: fetcher);
      expect(fetcher.requests.last, urls[2]);
      expect(statusOf(1), AttachmentDownloadStatus.completed);
      expect(statusOf(3), AttachmentDownloadStatus.queued);
      // The other place: the fourth.
      fetcher.release(urls[0]);
      await _until(manager, () => fetcher.requests.length == 4, fetcher: fetcher);
      expect(fetcher.requests.last, urls[3]);

      fetcher
        ..release(urls[2])
        ..release(urls[3]);
      await _until(manager, () => manager.itemsOf(31).every((e) => e.status == AttachmentDownloadStatus.completed));
      // The newest first.
      expect(manager.itemsOf(31).map((e) => e.filename), ['f3.zip', 'f2.zip', 'f1.zip', 'f0.zip']);
      expect(parts.existsSync(), isFalse);
    });

    test('a download finishing leaves the part folder to the one about to write there', () async {
      final urls = [
        for (final aid in [1, 2, 3]) _urlOf(aid),
      ];
      final fetcher = _FakeFetcher({
        for (final (i, url) in urls.indexed) url: [_file('file $i', name: 'f$i.zip')],
      })..hold(urls);
      final manager = managerOf(fetcher);
      final items = [for (final url in urls) await manager.start(uid: 31, url: url, filename: url)];
      await _until(manager, () => fetcher.requests.length == 2, fetcher: fetcher);
      // The first done, the third starts: it made sure its part folder is there and waits for the forum.
      fetcher.release(urls[0]);
      await _until(manager, () => fetcher.requests.length == 3, fetcher: fetcher);
      // The second done meanwhile: nothing is in the part folder at that moment, and the third still needs it.
      fetcher.release(urls[1]);
      await _until(manager, () => manager.find(31, items[1].id)!.status == AttachmentDownloadStatus.completed);
      expect(parts.existsSync(), isTrue);
      expect(parts.listSync(), isEmpty);
      // The forum answers the third: its part file is written where it was told.
      fetcher.release(urls[2]);
      await _until(manager, () => !manager.find(31, items[2].id)!.status.active);
      expect(manager.find(31, items[2].id)!.status, AttachmentDownloadStatus.completed);
      expect(File(manager.find(31, items[2].id)!.path!).readAsStringSync(), 'file 2');
      // The last one out removes the folder.
      expect(parts.existsSync(), isFalse);
    });

    test('kept per account; a download left running is failed when read again; forgetting an account', () async {
      final url = _urlOf(36);
      final fetcher = _FakeFetcher({
        url: [_file('zip bytes')],
      })..gate = Completer<void>();
      final first = managerOf(fetcher);
      final running = await first.start(uid: 31, url: url, filename: 'acc_note.zip');
      await _until(first, () => first.find(31, running.id)?.status == AttachmentDownloadStatus.running);
      expect(rowOf(31).single['status'], 'running');
      File('${parts.path}/${running.id}.part').writeAsStringSync('half');

      // The app went away; another account has its own list.
      rows[AttachmentDownloadStore.rowKeyOf(35)] = jsonEncode([
        AttachmentDownload(
          id: 'b',
          uid: 35,
          url: _urlOf(9),
          filename: 'other.zip',
          createdAt: DateTime(2026),
          status: AttachmentDownloadStatus.completed,
        ).toJson(),
      ]);
      final second = managerOf(_FakeFetcher({}));
      final mine = await second.load(31);
      expect(mine.single.status, AttachmentDownloadStatus.failed);
      expect(mine.single.message, isNull);
      expect(File('${parts.path}/${running.id}.part').existsSync(), isFalse);
      expect(rowOf(31).single['status'], 'failed');
      expect((await second.load(35)).map((e) => e.filename), ['other.zip']);
      expect(second.itemsOf(31).map((e) => e.filename), ['acc_note.zip']);

      second.forget(35);
      expect(second.itemsOf(35), isEmpty);
      // A row of another account is never read as this one's.
      rows[AttachmentDownloadStore.rowKeyOf(36)] = rows[AttachmentDownloadStore.rowKeyOf(35)]!;
      expect(await AttachmentDownloadStore.memory(rows).load(36), isEmpty);
    });

    test(
      'the attachment saved already is shown again, not downloaded again (its address changes with the page)',
      () async {
        final first = _urlOf(36);
        final later =
            '$_base/forum.php?mod=attachment&aid=${base64.encode(utf8.encode('36|a1a2a3a4|1700000100|31|1000'))}';
        final fetcher = _FakeFetcher({
          first: [_file('zip bytes')],
          later: [_file('zip bytes')],
        });
        final manager = managerOf(fetcher);
        final item = await manager.start(uid: 31, url: first, filename: 'acc_note.zip');
        await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
        final again = await manager.start(uid: 31, url: later, filename: 'acc_note.zip');
        expect(again.id, item.id);
        expect(fetcher.requests, [first]);
        // Its file deleted outside the app: downloaded again, in the same entry.
        File(manager.find(31, item.id)!.path!).deleteSync();
        final fresh = await manager.start(uid: 31, url: later, filename: 'acc_note.zip');
        expect(fresh.id, item.id);
        await _until(manager, () => manager.find(31, fresh.id)?.status == AttachmentDownloadStatus.completed);
        expect(fetcher.requests, [first, later]);
      },
    );

    test('a retried download waits behind those asked before its retry', () async {
      final urls = [
        for (final aid in [1, 2, 3, 4]) _urlOf(aid),
      ];
      final fetcher = _FakeFetcher({
        urls[0]: [_page(_fixture('refused_no_permission.html')), _file('again', name: 'f0.zip')],
        for (final (i, url) in urls.indexed.skip(1)) url: [_file('file $i', name: 'f$i.zip')],
      });
      final manager = managerOf(fetcher);
      final failed = await manager.start(uid: 31, url: urls[0], filename: 'f0.zip');
      await _until(manager, () => manager.find(31, failed.id)?.status == AttachmentDownloadStatus.failed);
      fetcher.hold(urls);
      for (final url in urls.skip(1)) {
        await manager.start(uid: 31, url: url, filename: url);
      }
      await manager.retry(31, failed.id);
      // Two run (whichever asks the forum first), the third asked and the retried one wait.
      await _until(manager, () => fetcher.requests.length == 3, fetcher: fetcher);
      expect(fetcher.requests.first, urls[0]);
      expect(fetcher.requests.skip(1), unorderedEquals([urls[1], urls[2]]));
      // The places come free one at a time: the third asked first, the retried one last.
      fetcher.release(urls[1]);
      await _until(manager, () => fetcher.requests.length == 4, fetcher: fetcher);
      expect(fetcher.requests.last, urls[3]);
      fetcher.release(urls[2]);
      await _until(manager, () => fetcher.requests.length == 5, fetcher: fetcher);
      expect(fetcher.requests.last, urls[0]);
      fetcher
        ..release(urls[3])
        ..release(urls[0]);
      await _until(manager, () => manager.itemsOf(31).every((e) => e.status == AttachmentDownloadStatus.completed));
      expect(fetcher.requests, hasLength(5));
    });

    test('two downloads of the same name finishing at once get two files', () async {
      final a = _urlOf(1);
      final b = _urlOf(2);
      final fetcher = _FakeFetcher({
        a: [_file('first', name: '1.zip')],
        b: [_file('second', name: '1.zip')],
      })..gate = Completer<void>();
      final manager = managerOf(fetcher);
      final first = await manager.start(uid: 31, url: a, filename: '1.zip');
      final second = await manager.start(uid: 31, url: b, filename: '1.zip');
      await _until(manager, () => fetcher.requests.length == 2, fetcher: fetcher);
      fetcher.gate!.complete();
      await _until(manager, () => manager.itemsOf(31).every((e) => e.status == AttachmentDownloadStatus.completed));
      final paths = {manager.find(31, first.id)!.path, manager.find(31, second.id)!.path};
      expect(paths, hasLength(2));
      expect(paths.map((e) => File(e!).readAsStringSync()).toSet(), {'first', 'second'});
    });

    test('a saved attachment whose file is gone is downloaded again in the same entry, paid address kept', () async {
      final url = _urlOf(36);
      const credit = '$_base/forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4';
      final paid = '${_urlOf(36)}&ck=c1c2c3c4';
      final fetcher = _FakeFetcher(
        {
          url: [_redirect('forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4')],
          paid: [_file('zip bytes')],
        },
        pages: {credit: _fixture('credit_taken.html')},
      );
      final manager = managerOf(fetcher);
      final item = await manager.start(uid: 31, url: url, filename: 'acc_note.zip');
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
      File(manager.find(31, item.id)!.path!).deleteSync();
      final again = await manager.start(uid: 31, url: url, filename: 'acc_note.zip');
      expect(again.id, item.id);
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
      expect(fetcher.pageRequests, [credit]);
      expect(manager.itemsOf(31), hasLength(1));
      expect(File(manager.find(31, item.id)!.path!).existsSync(), isTrue);
    });

    test('removing a download deletes its file', () async {
      final url = _urlOf(36);
      final manager = managerOf(
        _FakeFetcher({
          url: [_file('zip bytes')],
        }),
      );
      final item = await manager.start(uid: 31, url: url, filename: 'acc_note.zip');
      await _until(manager, () => manager.find(31, item.id)?.status == AttachmentDownloadStatus.completed);
      final path = manager.find(31, item.id)!.path!;
      expect(File(path).existsSync(), isTrue);
      await manager.remove(31, item.id);
      expect(manager.itemsOf(31), isEmpty);
      expect(File(path).existsSync(), isFalse);
      expect(rows.containsKey(AttachmentDownloadStore.rowKeyOf(31)), isFalse);
    });
  });

  group('the data saver', () {
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      NetworkUsage.reset();
    });

    tearDown(() async {
      NetworkUsage.reset();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('asks before a large download on a metered network only', () async {
      const large = attachmentLargeDownloadBytes;
      NetworkUsage.check = () async => false;
      // Off: never asks.
      expect(await attachmentDownloadNeedsConfirm(large), isFalse);
      await settings.setValue(SettingsKeys.dataSaverMode, DataSaverMode.meteredOnly.index);
      expect(await attachmentDownloadNeedsConfirm(large), isTrue);
      expect(await attachmentDownloadNeedsConfirm(large - 1), isFalse);
      // A size the post did not print is not asked for.
      expect(await attachmentDownloadNeedsConfirm(null), isFalse);
      NetworkUsage.reset();
      NetworkUsage.check = () async => true;
      expect(await attachmentDownloadNeedsConfirm(large), isFalse);
    });
  });

  group('the downloads page', () {
    late Directory dir;
    late Map<String, String> rows;
    late _FakeFetcher fetcher;
    late AttachmentDownloadManager manager;

    setUpAll(() async {
      await LocaleSettings.setLocale(AppLocale.zhCn);
    });

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('tsdm_844_page');
      final done = File('${dir.path}/done.zip')..writeAsStringSync('done');
      rows = {
        AttachmentDownloadStore.rowKeyOf(0): jsonEncode([
          AttachmentDownload(
            id: 'failed',
            uid: 0,
            url: _urlOf(38),
            filename: 'perm_note.zip',
            createdAt: DateTime(2026, 11, 10, 9),
            status: AttachmentDownloadStatus.failed,
            message: '抱歉，只有特定用户可以下载本站附件',
            tid: '1000',
            threadTitle: '附件帖',
          ).toJson(),
          AttachmentDownload(
            id: 'done',
            uid: 0,
            url: _urlOf(36),
            filename: 'done.zip',
            createdAt: DateTime(2026, 11, 10, 8),
            status: AttachmentDownloadStatus.completed,
            path: done.path,
            total: 4,
            received: 4,
            tid: '1000',
          ).toJson(),
        ]),
        AttachmentDownloadStore.rowKeyOf(35): jsonEncode([
          AttachmentDownload(
            id: 'other',
            uid: 35,
            url: _urlOf(9),
            filename: 'someone_else.zip',
            createdAt: DateTime(2026),
            status: AttachmentDownloadStatus.completed,
          ).toJson(),
        ]),
      };
      fetcher = _FakeFetcher({
        _urlOf(38): [_file('now allowed', name: 'perm_note.zip')],
      });
      manager = AttachmentDownloadManager(
        fetcher: fetcher,
        store: AttachmentDownloadStore.memory(rows),
        directory: () async => dir,
        partDirectory: () async => Directory('${dir.path}/parts'),
        progressInterval: Duration.zero,
      );
      getIt.registerSingleton<AttachmentDownloadManager>(manager);
    });

    tearDown(() async {
      await getIt.reset();
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: Builder(
            builder: (context) => MaterialApp(
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: const AttachmentDownloadsPage(),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('the unfinished and the completed downloads of the account in use, the forum words shown', (
      tester,
    ) async {
      await pump(tester);
      final tr = context844.attachmentDownload;
      expect(find.byKey(const ValueKey('attachment-downloads-failed')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-downloads-completed')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-downloads-active')), findsNothing);
      expect(find.text(tr.failed), findsOneWidget);
      expect(find.text(tr.completed), findsOneWidget);
      expect(find.text('perm_note.zip'), findsOneWidget);
      expect(find.text('done.zip'), findsOneWidget);
      expect(find.text('抱歉，只有特定用户可以下载本站附件'), findsOneWidget);
      expect(find.textContaining('附件帖'), findsOneWidget);
      // Another account's never.
      expect(find.text('someone_else.zip'), findsNothing);
      // The unfinished first.
      expect(
        tester.getTopLeft(find.text('perm_note.zip')).dy,
        lessThan(tester.getTopLeft(find.text('done.zip')).dy),
      );
      expect(find.byKey(const ValueKey('attachment-download-retry-failed')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-download-open-done')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a retry downloads it again and it moves to the completed ones', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('attachment-download-retry-failed')));
      await settle(tester, rounds: 10);
      expect(fetcher.requests, [_urlOf(38)]);
      expect(find.byKey(const ValueKey('attachment-downloads-failed')), findsNothing);
      expect(find.text('抱歉，只有特定用户可以下载本站附件'), findsNothing);
      expect(manager.find(0, 'failed')!.status, AttachmentDownloadStatus.completed);
      expect(File('${dir.path}/perm_note.zip').readAsStringSync(), 'now allowed');
    });

    testWidgets('deleting asks first, then removes the download and its file', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('attachment-download-menu-done')));
      await tester.pumpAndSettle();
      final tr = context844.attachmentDownload;
      await tester.tap(find.text(tr.delete).last);
      await tester.pumpAndSettle();
      expect(find.text(tr.deleteMessage(name: 'done.zip')), findsOneWidget);
      await tester.tap(find.text(context844.general.ok));
      await settle(tester);
      expect(find.text('done.zip'), findsNothing);
      expect(File('${dir.path}/done.zip').existsSync(), isFalse);
      expect(manager.itemsOf(0).map((e) => e.id), ['failed']);
    });

    testWidgets('a tap shows the download in a sheet with its actions', (tester) async {
      await pump(tester);
      await tester.tap(find.text('perm_note.zip'));
      await settle(tester, rounds: 3);
      expect(find.byKey(const ValueKey('attachment-download-message')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-download-retry')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-download-manager')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('nothing downloaded', (tester) async {
      rows.clear();
      await pump(tester);
      expect(find.text(context844.attachmentDownload.empty), findsOneWidget);
    });
  });
}

Translations get context844 => LocaleSettings.instance.currentTranslations;

String _absolute(String href) => href.startsWith('http') ? href : '$_base/$href';
