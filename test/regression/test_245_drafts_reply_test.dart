/// Local drafts and the reply box (UX audit, items 9 and 10).
///
/// * Local drafts: a file per account (`drafts/<uid>.json`, written into a temporary file renamed over the old one),
///   keyed by the account and the target (`reply:<tid>`, `floor:<tid>:<pid>`, `pm:<uid>`, `thread:<fid>`,
///   `edit:<pid>`); written about every two seconds while the text changes and at once when the editor collapses or
///   the page goes; offered again ("有未送出的草稿（時間）— 恢復／捨棄") when the same target opens; deleted once sent
///   (by the bloc, also for a page closed meanwhile) or when the user empties the editor, never because an editor
///   opened empty; another account never sees them; the list in the settings.
/// * The reply box: the emoji panel kept open with the recently used ones first, the quote of the floor with "不引用",
///   the editor on the whole page.
/// * The size of the post against the forum's limits (plugin 2.9.0 post forms: bytes, quotes not counted for the
///   minimum, the title in `dstrlen`), the send button waits while it is out of them.
/// * Sent too soon after the previous post (`post_flood_ctrl`, both language packs): the send button counts down.
/// * A captcha or a security question: answered in the app (the quick reply, the reply to a floor, a new thread),
///   asked for again when the answer was wrong or the forum asks only when posting; an edit and a private message are
///   never checked by the forum.
///
/// Screenshots: with `DRAFTS_SHOTS_DIR` (output directory) and `DRAFTS_SHOTS_FONT` (a font file with CJK glyphs) set,
/// the last group writes the reply box (emoji panel, quote, length, countdown, draft offer) light and dark.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_panel.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_autosaver.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_text.dart';
import 'package:tsdm_client/features/local_draft/view/local_draft_page.dart';
import 'package:tsdm_client/features/local_draft/widgets/draft_offer_banner.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/repository/sec_check_repository.dart';
import 'package:tsdm_client/features/post/utils/flood_control.dart';
import 'package:tsdm_client/features/post/utils/post_limits.dart';
import 'package:tsdm_client/features/post/utils/verification.dart';
import 'package:tsdm_client/features/post/view/post_edit_page.dart';
import 'package:tsdm_client/features/post/widgets/sec_check_dialog.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';
import 'package:universal_html/parsing.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);
const _bob = UserLoginInfo(username: 'Bob', uid: 35);

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/post_v16_$name.json').readAsStringSync()) as Map<String, dynamic>;

/// A request the fake forum saw.
typedef _Request = ({String method, Uri uri, Map<String, dynamic> headers, String body});

/// An answer of the fake forum.
typedef _Answer = ({Object body, int status, String contentType});

_Answer _api(Map<String, dynamic> json) =>
    (body: jsonEncode(json), status: 200, contentType: 'application/json; charset=utf-8');

_Answer _xml(String xml) => (body: xml, status: 200, contentType: 'text/xml; charset=utf-8');

_Answer _js(String js) => (body: js, status: 200, contentType: 'application/javascript');

/// A tiny png, the captcha the fake forum draws.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

_Answer _image() => (body: _png, status: 200, contentType: 'image/png');

/// The forum: answers every request through [answer], and records them.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  _Answer Function(_Request request) answer;
  final requests = <_Request>[];

  Iterable<_Request> get posts => requests.where((r) => r.method == 'POST');

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)), allowMalformed: true);
    }
    final request = (method: options.method, uri: options.uri, headers: options.headers, body: body);
    requests.add(request);
    final a = answer(request);
    final headers = {
      Headers.contentTypeHeader: [a.contentType],
    };
    return switch (a.body) {
      final List<int> bytes => ResponseBody.fromBytes(bytes, a.status, headers: headers),
      final Object text => ResponseBody.fromString('$text', a.status, headers: headers),
    };
  }

  @override
  void close({bool force = false}) {}
}

/// The forum's answer to a stored reply.
const _replyStored =
    '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1">'
    "succeedhandle_fastpost('forum.php?mod=viewthread&tid=9600001&pid=9700009&page=1#pid9700009', "
    "'非常感謝，回覆發佈成功', {'fid':'2','tid':'9600001','pid':'9700009'});</script>]]></root>";

/// The forum's refusal of a post sent too soon after the previous one, in the traditional pack.
const _floodRefused =
    '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1">'
    "errorhandle_fastpost('抱歉，您兩次發表間隔少於 15 秒，請稍候再發表', {});</script>]]></root>";

/// The forum's refusal of a wrong captcha.
const _captchaRefused =
    '<?xml version="1.0" encoding="utf-8"?><root><![CDATA[<script type="text/javascript" reload="1">'
    "errorhandle_fastpost('抱歉，验证码填写错误', {});</script>]]></root>";

/// The script of the captcha (`misc.php?mod=seccode&action=update`), as the forum answers it.
String _captchaScript(String hash) =>
    "if(\$('seccode_$hash')) {var string = '<span id=\"vseccode_$hash\">輸入下圖中的字符<img onclick=\"updateseccode(\\'$hash\\')\" "
    'width="150" height="60" src="misc.php?mod=seccode&update=12345&idhash=$hash" class="vm" alt="" /></span>\';}';

const _parameters = ReplyParameters(
  fid: '2',
  tid: '9600001',
  postTime: '1700000000',
  formHash: 'f1f2f3f4',
  subject: '',
  viewerUid: 31,
);

const _floorAction = 'forum.php?mod=post&action=reply&fid=2&tid=9600001&repquote=9700002&extra=page%3D1&page=1';

void main() {
  late Directory tmp;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late LocalDraftStore drafts;
  late _Forum forum;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    TsdmAppApi.reset();
    FloodControl.reset();
    tmp = Directory.systemTemp.createTempSync('tsdm_drafts_');
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    drafts = LocalDraftStore.memory();
    forum = _Forum((r) => throw StateError('unexpected request: ${r.method} ${r.uri}'));
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<LocalDraftStore>(drafts)
      ..registerSingleton<RecentEmojiStore>(RecentEmojiStore.memory())
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  group('A. the keys and the drafts', () {
    test('every target has its key, read back as written; anything else is no key', () {
      for (final key in [
        LocalDraftKey.threadReply('9600001'),
        LocalDraftKey.floorReply('9600001', '9700002'),
        LocalDraftKey.message('1000'),
        LocalDraftKey.newThread('7'),
        LocalDraftKey.edit('9700001'),
        LocalDraftKey.threadReply('9600001').backupAt(1700000000000),
      ]) {
        expect(LocalDraftKey.parse(key.value), key, reason: key.value);
      }
      expect(LocalDraftKey.floorReply('1', '2').value, 'floor:1:2');
      expect(LocalDraftKey.floorReply('1', '2').tid, '1');
      expect(LocalDraftKey.floorReply('1', '2').pid, '2');
      for (final bad in ['reply:', 'reply:0', 'reply:x', 'floor:1', 'pm:1:2', 'other:1', 'reply:1~0', 'reply:1~a~b']) {
        expect(LocalDraftKey.parse(bad), isNull, reason: bad);
      }
    });

    test('a draft keeps everything the editor needs to come back', () {
      final draft = LocalDraft(
        key: LocalDraftKey.floorReply('9600001', '9700002'),
        body: '[b]你好[/b] {:12_865:}',
        delta: '[{"insert":"x\\n"}]',
        updatedAt: DateTime(2026, 10, 23, 14, 5),
        fid: '2',
        replyAction: _floorAction,
        hint: '回覆 Bob #2',
        quote: false,
      );
      final back = LocalDraft.fromJson(draft.key, jsonDecode(jsonEncode(draft.toJson())))!;
      expect(back.sameContent(draft), isTrue);
      expect((back.fid, back.replyAction, back.hint, back.quote), ('2', _floorAction, '回覆 Bob #2', false));
      expect(back.updatedAt, draft.updatedAt);
      expect(draftSnippet(draft.body, emoji: '[表情]'), '你好 [表情]');
    });
  });

  group('B. the store: a file per account', () {
    test('written atomically, read back, never another account', () async {
      final drafts = LocalDraftStore(directory: () async => Directory('${tmp.path}/drafts'));
      final key = LocalDraftKey.threadReply('9600001');
      drafts.save(31, LocalDraft(key: key, body: 'Alice 的回覆', updatedAt: DateTime(2026, 10, 23)));
      drafts.save(35, LocalDraft(key: key, body: 'Bob 的回覆', updatedAt: DateTime(2026, 10, 23)));
      await drafts.pendingWrites;
      final files = Directory('${tmp.path}/drafts').listSync().map((e) => e.path.split(Platform.pathSeparator).last);
      expect(files.toSet(), {'31.json', '35.json'}, reason: 'no temporary file left behind');
      // A new store (the next start) reads the files.
      final again = LocalDraftStore(directory: () async => Directory('${tmp.path}/drafts'));
      expect((await again.load(31, key))?.body, 'Alice 的回覆');
      expect((await again.load(35, key))?.body, 'Bob 的回覆');
      expect(await again.load(36, key), isNull);
      // A file of another account under this name is not read.
      File('${tmp.path}/drafts/36.json').writeAsStringSync(File('${tmp.path}/drafts/31.json').readAsStringSync());
      expect(await LocalDraftStore(directory: () async => Directory('${tmp.path}/drafts')).list(36), isEmpty);
      // The account removed from the device: its file goes.
      drafts.forget(31);
      await drafts.pendingWrites;
      expect(File('${tmp.path}/drafts/31.json').existsSync(), isFalse);
      expect(File('${tmp.path}/drafts/35.json').existsSync(), isTrue);
    });

    test('the oldest go beyond the limit; a broken file is no draft; deleting the last removes the file', () async {
      final small = LocalDraftStore(directory: () async => Directory('${tmp.path}/small'), maxDrafts: 2);
      for (var i = 1; i <= 3; i++) {
        small.save(31, LocalDraft(key: LocalDraftKey.newThread('$i'), body: '$i', updatedAt: DateTime(2026, 1, i)));
      }
      expect((await small.list(31)).map((e) => e.key.fid), ['3', '2']);
      File('${tmp.path}/small/31.json').writeAsStringSync('{not json');
      expect(await LocalDraftStore(directory: () async => Directory('${tmp.path}/small')).list(31), isEmpty);
      small
        ..delete(31, LocalDraftKey.newThread('3'))
        ..delete(31, LocalDraftKey.newThread('2'));
      await small.pendingWrites;
      expect(File('${tmp.path}/small/31.json').existsSync(), isFalse);
    });

    test('removing an account from the device forgets its drafts', () async {
      drafts.save(31, LocalDraft(key: LocalDraftKey.newThread('7'), body: 'x', updatedAt: DateTime(2026)));
      await drafts.pendingWrites;
      await storage.deleteCookieByUid(31);
      await drafts.pendingWrites;
      expect(await drafts.list(31), isEmpty);
    });
  });

  group('C. the autosaver', () {
    test('writes the latest text about every interval, deletes only what it wrote, never an offered draft', () async {
      final key = LocalDraftKey.threadReply('9600001');
      var text = '';
      final saver = DraftAutosaver(
        read: () => (
          uid: 31,
          key: key,
          draft: text.isEmpty ? null : LocalDraft(key: key, body: text, updatedAt: DateTime.now()),
        ),
        interval: const Duration(milliseconds: 40),
      )..attach();
      addTearDown(saver.dispose);
      text = 'a';
      saver.changed();
      text = 'ab';
      saver.changed();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await drafts.pendingWrites;
      expect((await drafts.load(31, key))?.body, 'ab', reason: 'one write, the latest text');
      text = '';
      saver.flush();
      await drafts.pendingWrites;
      expect(await drafts.load(31, key), isNull, reason: 'the user emptied it');

      // Another editor of the same target opens empty: the stored draft is offered, not deleted.
      drafts.save(31, LocalDraft(key: key, body: '舊的', updatedAt: DateTime(2026, 10, 1)));
      final other = DraftAutosaver(read: () => (uid: 31, key: key, draft: null))..attach();
      addTearDown(other.dispose);
      await other.offerStored(31, (k) => k == key);
      expect(other.offer.value?.draft.body, '舊的');
      other.flush();
      await drafts.pendingWrites;
      expect((await drafts.load(31, key))?.body, '舊的');
    });

    test(
      'something else written while a draft is offered keeps that one aside; restoring keeps what was there',
      () async {
        final key = LocalDraftKey.newThread('7');
        var text = '';
        final saver = DraftAutosaver(
          read: () => (
            uid: 31,
            key: key,
            draft: text.isEmpty ? null : LocalDraft(key: key, body: text, updatedAt: DateTime.now()),
          ),
        )..attach();
        addTearDown(saver.dispose);
        drafts.save(31, LocalDraft(key: key, body: '舊的', updatedAt: DateTime(2026, 10, 1)));
        await saver.offerStored(31, (k) => k == key);
        text = '新的';
        saver.flush();
        await drafts.pendingWrites;
        final all = await drafts.list(31);
        expect(all.map((e) => (e.key.isBackup, e.body)), containsAll([(false, '新的'), (true, '舊的')]));
        expect(saver.offer.value?.draft.key.isBackup, isTrue, reason: 'still offered, from aside');
        // Restored: what the editor held goes aside, the old one comes back as the draft of the target.
        final restored = saver.takeOffer()!;
        text = restored.body;
        saver.flush();
        await drafts.pendingWrites;
        final after = await drafts.list(31);
        expect(after.where((e) => !e.key.isBackup).single.body, '舊的');
        expect(after.where((e) => e.key.isBackup).map((e) => e.body), ['新的']);
        // Sent: deleted, and the text still on screen is not written again.
        saver.sent(31, key);
        saver.flush();
        await drafts.pendingWrites;
        expect((await drafts.list(31)).where((e) => !e.key.isBackup), isEmpty);
      },
    );
  });

  group('D. the forum\'s words', () {
    test('the interval of a post sent too soon, in both language packs', () {
      expect(floodControlSeconds('抱歉，您两次发表间隔少于 15 秒，请稍候再发表'), 15);
      expect(floodControlSeconds('抱歉，您兩次發表間隔少於 30 秒，請稍候再發表'), 30);
      expect(floodControlSeconds('抱歉，您所在的用户组每小时限制发回帖 10 个，请稍候再发表'), isNull);
      expect(floodControlSeconds(null), isNull);
      // Counted from the last post the app knows of, else from now.
      final now = DateTime(2026, 10, 23, 12);
      FloodControl.now = () => now;
      expect(FloodControl.retryAt(31, 15), now.add(const Duration(seconds: 15)));
      FloodControl.now = () => now.subtract(const Duration(seconds: 5));
      FloodControl.notePosted(31);
      FloodControl.now = () => now;
      expect(FloodControl.retryAt(31, 15), now.add(const Duration(seconds: 10)));
    });

    test('the checks of a form: the plugin\'s, the web page\'s placeholders, the refusals', () {
      expect(
        SecCheck.fromJson({
          'seccode': 1,
          'secqaa': 1,
          'seccode_hash': 'cSA1',
          'secqaa_hash': 'qSA1',
          'modid': 'forum::post',
        }),
        const SecCheck(seccode: true, secqaa: true, seccodeHash: 'cSAapp', secqaaHash: 'qSAapp'),
      );
      expect(SecCheck.fromJson(null), isNull);
      expect(SecCheck.fromJson({'seccode': 0, 'secqaa': 0}), isNull);
      final page = parseHtmlDocument(
        '<form id="fastpostform"><span id="seccode_cSAx1"></span><script>updateseccode(\'cSAx1\', \'<sec>\', '
        "'forum::viewthread');</script><span id=\"secqaa_qSAx1\"></span></form>",
      ).querySelector('form');
      expect(
        SecCheck.fromElement(page),
        const SecCheck(
          seccode: true,
          secqaa: true,
          seccodeHash: 'cSAapp',
          secqaaHash: 'qSAapp',
          modid: 'forum::viewthread',
        ),
      );
      const answer = SecCheckAnswer(
        check: SecCheck(seccode: true, secqaa: true, seccodeHash: 'cSAx1', secqaaHash: 'qSAx1'),
        seccode: ' ab12 ',
        secanswer: '3',
      );
      expect(answer.fields, {
        'seccodehash': 'cSAx1',
        'seccodemodid': 'forum::post',
        'seccodeverify': 'ab12',
        'secqaahash': 'qSAx1',
        'secanswer': '3',
      });
      expect(refusedVerification(reason: '抱歉，驗證碼填寫錯誤'), (seccode: true, secqaa: false));
      expect(refusedVerification(messageKey: 'submit_secqaa_invalid'), (seccode: false, secqaa: true));
      expect(refusedVerification(reason: '抱歉，您兩次發表間隔少於 15 秒'), isNull);
      // A refusal for the other check after one was answered: both asked again, the answered one keeps its id.
      final again = refusedCheck((
        seccode: true,
        secqaa: false,
      ), answered: const SecCheck(secqaa: true, secqaaHash: 'q1'));
      expect((again.seccode, again.secqaa, again.secqaaHash), (true, true, 'q1'));
      expect(again.seccodeHash, startsWith('cSA'));
    });

    test('the size limits as the forum counts them', () {
      final limits = MessageLimits.of(PostForm.fromJson(_json('reply'))!)!;
      expect((limits.min, limits.max), (10, 10000));
      expect(limits.bytesOf('你好'), 6);
      expect(limits.tooShort('你好'), isTrue);
      expect(limits.tooShort('你好你好'), isFalse);
      expect(limits.tooShort('[quote]很長很長很長很長[/quote]短'), isTrue, reason: 'quotes not counted');
      expect(limits.tooLong('字' * 3334), isTrue);
      expect(quotePreviewOf(PostForm.fromJson(_json('reply_quote'))!.submitFields['noticetrimstr']!), (
        header: 'ag_low2 发表于 2023-11-15 06:13',
        body: 'N1 二樓（ag_low2）000000 斜體',
      ));
    });
  });

  group('E. the replies with the checks', () {
    test('the quick reply asks first, then goes with the answers', () async {
      forum.answer = (r) => _xml(_replyStored);
      const check = SecCheck(seccode: true, seccodeHash: 'cSAapp', modid: 'forum::viewthread');
      final parameters = _parameters.copyWith(verification: true, secCheck: check);
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      final asked = bloc.stream.firstWhere((s) => s.status == ReplyStatus.verification);
      bloc.add(ReplyToThreadRequested(replyParameters: parameters, replyMessage: '回覆回覆回覆'));
      expect((await asked).secCheck, check);
      expect(forum.requests, isEmpty, reason: 'nothing sent before the answer');
      final stored = bloc.stream.firstWhere((s) => s.status == ReplyStatus.success);
      bloc.add(const ReplyVerificationAnswered(SecCheckAnswer(check: check, seccode: 'AB12')));
      await stored;
      final body = Uri.splitQueryString(forum.posts.single.body);
      expect(body['seccodehash'], 'cSAapp');
      expect(body['seccodemodid'], 'forum::viewthread');
      expect(body['seccodeverify'], 'AB12');
    });

    test('a wrong answer, or a check asked only when posting: asked again', () async {
      forum.answer = (r) => _xml(_captchaRefused);
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      var asked = bloc.stream.firstWhere((s) => s.status == ReplyStatus.verification);
      bloc.add(const ReplyToThreadRequested(replyParameters: _parameters, replyMessage: '回覆回覆回覆'));
      final first = await asked;
      expect(first.secCheck?.seccode, isTrue);
      expect(first.wrongAnswer, isFalse);
      asked = bloc.stream.firstWhere((s) => s.status == ReplyStatus.verification);
      bloc.add(ReplyVerificationAnswered(SecCheckAnswer(check: first.secCheck!, seccode: 'XXXX')));
      final second = await asked;
      expect(second.wrongAnswer, isTrue);
      expect(second.secCheck?.seccodeHash, first.secCheck?.seccodeHash, reason: 'the same id, a new image');
    });

    test('a private message is never checked: no captcha on that path', () async {
      // The forum's pm send (`submitcheck('pmsubmit')`) passes no check: the app sends no answers there either.
      forum.answer = (r) =>
          _xml('<?xml version="1.0" encoding="utf-8"?><root><![CDATA[succeedhandle_pmsend(\'\', \'\');]]></root>');
      final result = await const ReplyRepository().replyPersonalMessage('1000', {'message': 'hi'}).run();
      expect(result.isRight(), isTrue);
      expect(Uri.splitQueryString(forum.posts.single.body).keys, isNot(contains('seccodeverify')));
    });

    test('the captcha and the question are asked with the forum\'s own page as the referer', () async {
      forum.answer = (r) => switch (r.uri.queryParameters) {
        {'mod': 'seccode', 'action': 'update'} => _js(_captchaScript(r.uri.queryParameters['idhash']!)),
        {'mod': 'seccode', 'action': 'check'} => _xml('<root><![CDATA[succeed]]></root>'),
        {'mod': 'seccode'} => _image(),
        {'mod': 'secqaa', 'action': 'update'} => _xml('<root><![CDATA[1 + 2 = ?]]></root>'),
        _ => throw StateError('unexpected ${r.uri}'),
      };
      const check = SecCheck(seccode: true, secqaa: true, seccodeHash: 'cSAapp', secqaaHash: 'qSAapp');
      const repository = SecCheckRepository();
      expect((await repository.fetchCaptcha(check).run()).isRight(), isTrue);
      expect((await repository.fetchQuestion(check).run()).getOrElse((_) => ''), '1 + 2 = ?');
      expect(await repository.verify(check, captcha: true, value: 'AB12'), isTrue);
      expect(forum.requests.map((r) => r.uri.queryParameters['update'] ?? r.uri.queryParameters['action']), [
        'update',
        '12345',
        'update',
        'check',
      ]);
      expect(forum.requests.every((r) => '${r.headers[HttpHeaders.refererHeader]}'.startsWith(baseUrl)), isTrue);
    });
  });

  group('F. the reply box', () {
    late AuthenticationRepository auth;
    late ReplyBloc bloc;
    late ReplyBarController controller;

    Future<void> pumpBar(
      WidgetTester tester, {
      UserLoginInfo user = _alice,
      ReplyParameters parameters = _parameters,
      ThemeData? theme,
      Size size = const Size(420, 900),
    }) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      auth = AuthenticationRepository(user: user);
      controller = ReplyBarController();
      bloc = ReplyBloc(replyRepository: const ReplyRepository())
        ..add(ReplyParametersUpdated(parameters))
        ..add(const ReplyThreadClosed(closed: false));
      addTearDown(() async {
        await bloc.close();
        await auth.dispose();
      });
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: RepositoryProvider<ReplyRepository>(
            create: (_) => const ReplyRepository(),
            child: BlocProvider<ReplyBloc>.value(
              value: bloc,
              child: TranslationProvider(
                child: MaterialApp(
                  theme: theme,
                  scaffoldMessengerKey: snackbarKey,
                  home: Scaffold(
                    resizeToAvoidBottomInset: false,
                    appBar: AppBar(title: const Text('帖子')),
                    body: const Center(child: Text('thread page')),
                    bottomNavigationBar: ReplyBar(controller: controller, replyType: ReplyTypes.thread),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    BBCodeEditorController editorOf(WidgetTester tester) =>
        tester.widget<RichEditor>(find.byType(RichEditor)).controller;

    testWidgets('written: kept for the thread; collapsed: kept; opened again: offered, restored', (tester) async {
      await pumpBar(tester);
      expect(controller.draftKey, 'reply:9600001');
      controller.setHintText('回覆');
      await tester.pumpAndSettle();
      controller.setHintText('回覆');
      editorOf(tester).insertBBCode('寫到一半的回覆');
      await tester.pump(const Duration(seconds: 3));
      await _io(tester);
      expect((await _wait(tester, drafts.load(31, LocalDraftKey.threadReply('9600001'))))?.body, '寫到一半的回覆');
      controller.closeEditor();
      await tester.pumpAndSettle();
      await _io(tester);
      expect(find.byKey(const ValueKey('draft-offer-banner')), findsNothing, reason: 'the box holds it');

      // The page again, later: the box is empty, the draft is offered.
      await tester.pumpWidget(const SizedBox());
      await _io(tester);
      await pumpBar(tester);
      await _io(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-offer-banner')), findsOneWidget);
      expect(find.textContaining('有未送出的草稿'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('draft-offer-restore')));
      await tester.pumpAndSettle();
      expect(controller.showingEditor, isTrue);
      expect(editorOf(tester).toForumBBCode(), '寫到一半的回覆');
      await _unpump(tester);
    });

    testWidgets('another account never sees it; discarded, it is gone', (tester) async {
      drafts.save(
        31,
        LocalDraft(key: LocalDraftKey.threadReply('9600001'), body: 'Alice', updatedAt: DateTime(2026)),
      );
      await _wait(tester, drafts.pendingWrites);
      await pumpBar(tester, user: _bob);
      await _io(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-offer-banner')), findsNothing);
      await _unpump(tester);
      await pumpBar(tester);
      await _io(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('draft-offer-discard')));
      await tester.pumpAndSettle();
      await _io(tester);
      expect(await _wait(tester, drafts.list(31)), isEmpty);
      await _unpump(tester);
    });

    testWidgets('sent: the draft goes, also when the page is gone meanwhile', (tester) async {
      forum.answer = (r) => _xml(_replyStored);
      await pumpBar(tester);
      controller.setHintText('回覆');
      await tester.pumpAndSettle();
      editorOf(tester).insertBBCode('要送出的回覆');
      controller.closeEditor();
      await tester.pumpAndSettle();
      await _io(tester);
      expect(await _wait(tester, drafts.list(31)), hasLength(1));
      // Sent with its key (the bar does it from its send button): the bloc deletes it once stored.
      bloc.add(
        ReplyToThreadRequested(
          replyParameters: _parameters,
          replyMessage: '要送出的回覆',
          draftUid: 31,
          draftKey: LocalDraftKey.threadReply('9600001').value,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      await _io(tester);
      await _io(tester);
      expect(await _wait(tester, drafts.list(31)), isEmpty);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a floor: its own draft, its quote shown, "不引用" replies without it', (tester) async {
      TsdmAppApi.notePostForm();
      forum.answer = (r) => r.method == 'GET' ? _api(_json('reply_quote')) : _xml(_replyStored);
      await pumpBar(tester);
      controller
        ..replyAction = _floorAction
        ..setHintText('回覆 ag_low2 #2');
      await _settle(tester);
      expect(controller.draftKey, 'floor:9600001:9700002');
      expect(find.byKey(const ValueKey('reply-bar-quote-preview')), findsOneWidget);
      expect(find.textContaining('ag_low2 发表于 2023-11-15 06:13'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reply-bar-quote-remove')));
      await tester.pumpAndSettle();
      expect(controller.currentReplyAction, contains('reppost=9700002'));
      expect(find.byKey(const ValueKey('reply-bar-quote-removed')), findsOneWidget);
      expect(controller.draftKey, 'floor:9600001:9700002', reason: 'the same floor');
      await tester.tap(find.byKey(const ValueKey('reply-bar-quote-add')));
      await tester.pumpAndSettle();
      expect(controller.currentReplyAction, _floorAction);
      await _unpump(tester);
    });

    testWidgets('the size against the forum\'s limits: counted, the send button waits while out of them', (
      tester,
    ) async {
      TsdmAppApi.notePostForm();
      forum.answer = (r) => _api(_json('reply'));
      await pumpBar(tester);
      controller.setHintText('回覆');
      await _settle(tester);
      editorOf(tester).insertBBCode('短');
      await tester.pumpAndSettle();
      expect(find.text(t.replyBar.tooShort(min: 10, count: 3)), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('reply-bar-send'))).onPressed, isNull);
      editorOf(tester).insertBBCode('夠長了的回覆');
      await tester.pumpAndSettle();
      expect(find.text(t.replyBar.lengthCount(count: 21, max: 10000)), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('reply-bar-send'))).onPressed, isNotNull);
      await _unpump(tester);
    });

    testWidgets('sent too soon: the send button counts the forum\'s interval down, the text stays', (tester) async {
      forum.answer = (r) => _xml(_floodRefused);
      await pumpBar(tester);
      controller.setHintText('回覆');
      await tester.pumpAndSettle();
      editorOf(tester).insertBBCode('第二則回覆');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
      await _settle(tester);
      expect(bloc.state.retryAt, isNotNull);
      expect(find.byKey(const ValueKey('reply-bar-countdown')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^1[45]s$')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('reply-bar-send'))).onPressed, isNull);
      expect(editorOf(tester).toForumBBCode(), '第二則回覆');
      await _unpump(tester);
    });

    testWidgets('the emoji panel stays open, the used ones come first next time', (tester) async {
      final group = EmojiGroup(
        name: '梦予馨',
        id: '12',
        routeName: 'TSDM',
        emojiList: [
          for (final id in ['865', '866']) Emoji(id: id, code: '{:12_$id:}', url: ''),
        ],
      );
      String? picked;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: EmojiPanel(groups: [group], emojiImage: (_) => _png, onPicked: (code) => picked = code),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Nothing used yet: the panel opens on the forum's emojis, the recent tab says what it will hold.
      await tester.tap(find.byKey(const ValueKey('emoji-panel-recent-tab')));
      await tester.pumpAndSettle();
      expect(find.text(t.bbcodeEditor.emoji.noRecent), findsOneWidget);
      await tester.tap(find.text('梦予馨'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-panel-{:12_866:}')));
      await tester.pump();
      expect(picked, '{:12_866:}');
      expect(getIt.get<RecentEmojiStore>().recent.value, ['{:12_866:}']);
      await tester.tap(find.byKey(const ValueKey('emoji-panel-recent-tab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('emoji-panel-{:12_866:}')), findsOneWidget);
      // Inserted into the editor as the emoji embed of the toolbar.
      final editor = buildBBCodeEditorController()..insertEmoji('{:12_866:}');
      expect(editor.toBBCode(), '{:12_866:}');
    });

    testWidgets('the whole page: the editor fills the page, what was written stays', (tester) async {
      await pumpBar(tester);
      controller.setHintText('回覆');
      await tester.pumpAndSettle();
      editorOf(tester).insertBBCode('長篇回覆');
      final before = tester.getSize(find.byType(RichEditor)).height;
      await tester.tap(find.byKey(const ValueKey('reply-bar-maximize')));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(RichEditor)).height, greaterThan(before + 300));
      expect(editorOf(tester).toForumBBCode(), '長篇回覆');
      await _unpump(tester);
    });

    testWidgets('a captcha asked: the dialog, the reply goes again with the answer', (tester) async {
      forum.answer = (r) => switch (r.uri.queryParameters) {
        {'mod': 'seccode', 'action': 'update'} => _js(_captchaScript(r.uri.queryParameters['idhash']!)),
        {'mod': 'seccode', 'action': 'check'} => _xml('<root><![CDATA[succeed]]></root>'),
        {'mod': 'seccode'} => _image(),
        _ => _xml(_replyStored),
      };
      const check = SecCheck(seccode: true, seccodeHash: 'cSAapp', modid: 'forum::viewthread');
      await pumpBar(tester, parameters: _parameters.copyWith(verification: true, secCheck: check));
      controller.setHintText('回覆');
      await tester.pumpAndSettle();
      editorOf(tester).insertBBCode('要驗證的回覆');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
      await _settle(tester);
      expect(find.byType(SecCheckDialog), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('sec-check-code-field')), 'AB12');
      await tester.tap(find.byKey(const ValueKey('sec-check-confirm')));
      await _settle(tester);
      expect(find.byType(SecCheckDialog), findsNothing);
      expect(bloc.state.status, ReplyStatus.success);
      expect(Uri.splitQueryString(forum.posts.single.body)['seccodeverify'], 'AB12');
      await _unpump(tester);
    });
  });

  group('G. the editor of a thread', () {
    late SettingsBloc settingsBloc;
    setUp(() => settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository()));
    tearDown(() => settingsBloc.close());

    Future<GoRouter> pumpEditor(WidgetTester tester) async {
      forum.answer = (r) => r.method == 'GET' ? _api(_json('newthread')) : throw StateError('no post');
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('below the editor')),
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, _) => const PostEditPage(editType: PostEditType.newThread, fid: '7', tid: null, pid: null),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: BlocProvider<SettingsBloc>.value(
              value: settingsBloc,
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      unawaited(router.push('/edit'));
      await _settle(tester);
      return router;
    }

    testWidgets('a new thread: kept while written, "keep and leave", offered and restored when opened again', (
      tester,
    ) async {
      final router = await pumpEditor(tester);
      await tester.enterText(find.byType(TextFormField).first, '新帖標題');
      await tester.pump(const Duration(seconds: 3));
      await _io(tester);
      final stored = await _wait(tester, drafts.load(31, LocalDraftKey.newThread('7')));
      expect(stored?.subject, '新帖標題');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('leave-edit-keep-draft')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('leave-edit-keep-draft')));
      await tester.pumpAndSettle();
      await _io(tester);
      expect(find.text('below the editor'), findsOneWidget);

      unawaited(router.push('/edit'));
      await _settle(tester);
      await _io(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft-offer-banner')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('draft-offer-restore')));
      await tester.pumpAndSettle();
      expect(find.text('新帖標題'), findsWidgets);
      // Discarded when leaving: nothing kept.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('leave-edit-discard')));
      await tester.pumpAndSettle();
      await _io(tester);
      expect(await _wait(tester, drafts.list(31)), isEmpty);
      expect(forum.posts, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });

    test('a new thread asking for a captcha: sent with the answers, refused without', () async {
      final form = PostForm.fromJson({
        ..._json('newthread'),
        'seccheck': {'seccode': 1, 'secqaa': 0, 'seccode_hash': 'cSA0000', 'secqaa_hash': null, 'modid': 'forum::post'},
        'unsupported': ['seccheck'],
      })!;
      final bodies = <Map<String, String>>[];
      final repo = PostEditRepository.withTransport(
        currentUid: () => 31,
        getPage: (_) async => throw StateError('no page'),
        sendForm: (url, body) async {
          bodies.add(body);
          return right(
            Response(
              requestOptions: RequestOptions(),
              statusCode: 302,
              headers: Headers.fromMap({
                'location': ['$baseUrl/forum.php?mod=viewthread&tid=9600009'],
              }),
            ),
          );
        },
      );
      const edits = PostFormEdits(message: '內文內文內文內文', subject: '標題');
      final without = await repo.submitForm(form, edits, told: form.secCheck).run();
      expect(without.getLeft().toNullable(), isA<PostVerificationRequiredException>());
      expect(bodies, isEmpty);
      final answered = await repo
          .submitForm(
            form,
            edits,
            told: form.secCheck,
            verification: SecCheckAnswer(check: form.secCheck!, seccode: 'AB12'),
          )
          .run();
      expect(answered.isRight(), isTrue);
      expect(bodies.single['seccodeverify'], 'AB12');
      expect(bodies.single['seccodehash'], 'cSAapp');
    });

    test('an edit is never checked by the forum: the form tells none', () {
      final edit = PostForm.fromJson(_json('edit_reply'))!;
      expect(edit.secCheck, isNull);
      expect(edit.editorSupport('edit'), PostFormSupport.supported);
    });
  });

  group('H. the list of drafts', () {
    testWidgets('the drafts of the account in use: what they are for, deleted from here', (tester) async {
      drafts
        ..save(
          31,
          LocalDraft(key: LocalDraftKey.threadReply('9600001'), body: '回覆草稿', updatedAt: DateTime(2026, 10, 23, 10)),
        )
        ..save(
          31,
          LocalDraft(
            key: LocalDraftKey.newThread('7'),
            body: '新帖內文',
            subject: '新帖標題',
            title: '測試版塊',
            updatedAt: DateTime(2026, 10, 23, 11),
          ),
        )
        ..save(35, LocalDraft(key: LocalDraftKey.message('31'), body: 'Bob 的私信', updatedAt: DateTime(2026, 10, 23)));
      await _wait(tester, drafts.pendingWrites);
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: const LocalDraftPage()),
          ),
        ),
      );
      await _settle(tester);
      await _io(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('新帖標題'), findsOneWidget);
      expect(find.textContaining('回覆草稿'), findsOneWidget);
      expect(find.textContaining('Bob 的私信'), findsNothing, reason: 'another account');
      expect(find.textContaining('測試版塊'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('local-draft-delete-reply:9600001')));
      await tester.pumpAndSettle();
      await _io(tester);
      expect((await _wait(tester, drafts.list(31))).map((e) => e.key.value), ['thread:7']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('I. review follow-ups', () {
    String domains({bool check = true}) => jsonEncode({
      'www.tsdm39.com': {
        '/': {
          'Ystv_2132_auth': 'Ystv_2132_auth=a;_crt=1',
          'Ystv_2132_saltkey': 'Ystv_2132_saltkey=b;_crt=1',
          if (check) 'Ystv_2132_seccodecSAapp': 'Ystv_2132_seccodecSAapp=c;_crt=1',
          if (check) 'Ystv_2132_secqaaqSAapp': 'Ystv_2132_secqaaqSAapp=d;_crt=1',
        },
      },
    });

    test('M1. the checks always use the app\'s ids; their cookies go once the post with the answers went', () async {
      expect(SecCheck.fromJson({'seccode': 1, 'seccode_hash': 'cSAxyz123'})?.seccodeHash, SecCheck.appSeccodeHash);
      expect(SecCheck.generated(secqaa: true).secqaaHash, SecCheck.appSecqaaHash);
      expect(isSecCheckCookie('Ystv_2132_seccodecSAapp'), isTrue);
      expect(isSecCheckCookie('Ystv_2132_secqaaqSAA1x'), isTrue);
      expect(isSecCheckCookie('Ystv_2132_auth'), isFalse);
      final cookie = CookieProvider(_alice, {'.domains': domains()});
      await getIt.unregister<CookieProvider>();
      getIt.registerSingleton<CookieProvider>(cookie);
      forum.answer = (r) => _xml(_replyStored);
      const check = SecCheck(seccode: true, seccodeHash: 'cSAapp', modid: 'forum::viewthread');
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      final stored = bloc.stream.firstWhere((s) => s.status == ReplyStatus.success);
      bloc.add(
        ReplyToThreadRequested(
          replyParameters: _parameters.copyWith(verification: true, secCheck: check),
          replyMessage: '回覆回覆回覆',
          verification: const SecCheckAnswer(check: check, seccode: 'AB12'),
        ),
      );
      await stored;
      final left = jsonDecode((await cookie.read('.domains'))!) as Map<String, dynamic>;
      final names = ((left['www.tsdm39.com'] as Map)['/'] as Map).keys;
      expect(names, ['Ystv_2132_auth', 'Ystv_2132_saltkey']);
    });

    test('M2. a reply that may have reached the forum: its draft says so, also with the page gone', () async {
      forum.answer = (r) => throw DioException(requestOptions: RequestOptions(), type: DioExceptionType.receiveTimeout);
      final key = LocalDraftKey.threadReply('9600001');
      drafts.save(31, LocalDraft(key: key, body: '送出中的回覆', updatedAt: DateTime(2026)));
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      final failed = bloc.stream.firstWhere((s) => s.status == ReplyStatus.failure);
      bloc.add(
        ReplyToThreadRequested(
          replyParameters: _parameters,
          replyMessage: '送出中的回覆',
          draftUid: 31,
          draftKey: key.value,
        ),
      );
      expect((await failed).maybeSent, isTrue);
      await drafts.pendingWrites;
      expect((await drafts.load(31, key))?.maybeSent, isTrue);
      expect(
        LocalDraft.fromJson(key, jsonDecode(jsonEncode((await drafts.load(31, key))!.toJson())))!.maybeSent,
        isTrue,
      );
    });

    testWidgets('M2. the offer and the list say "may have been sent"', (tester) async {
      final banner = DraftOfferBanner(
        draft: LocalDraft(
          key: LocalDraftKey.threadReply('1'),
          body: 'x',
          updatedAt: DateTime(2026, 10, 23, 14, 5),
          maybeSent: true,
        ),
        onRestore: () {},
        onDiscard: () {},
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: Scaffold(body: banner)),
        ),
      );
      expect(find.text(t.localDraft.offerMaybeSent(time: '2026-10-23 14:05')), findsOneWidget);
    });

    test('L1. sending: written when it starts, nothing more when the editor goes meanwhile', () async {
      final key = LocalDraftKey.threadReply('9600001');
      var text = '送出的內容';
      final saver = DraftAutosaver(
        read: () => (uid: 31, key: key, draft: LocalDraft(key: key, body: text, updatedAt: DateTime.now())),
      )..attach();
      addTearDown(saver.dispose);
      saver.pause();
      await drafts.pendingWrites;
      expect((await drafts.load(31, key))?.body, '送出的內容');
      // The bloc deleted it (stored); the page goes before the answer reached it: not written back.
      drafts.delete(31, key);
      text = '送出的內容';
      saver.detach();
      await drafts.pendingWrites;
      expect(await drafts.load(31, key), isNull);
    });

    test('L3. an account removed: a late write of an editor still open is refused, until it reads again', () async {
      final key = LocalDraftKey.newThread('7');
      drafts
        ..forget(31)
        ..save(31, LocalDraft(key: key, body: 'late', updatedAt: DateTime(2026)));
      await drafts.pendingWrites;
      expect(await drafts.list(31), isEmpty);
      drafts.save(31, LocalDraft(key: key, body: 'again', updatedAt: DateTime(2026)));
      expect((await drafts.load(31, key))?.body, 'again');
    });

    test('L5. a draft kept aside, opened from the list: offered by its target', () async {
      final key = LocalDraftKey.newThread('7');
      final aside = key.backupAt(1700000000000);
      drafts
        ..save(31, LocalDraft(key: key, body: '新的', updatedAt: DateTime(2026, 10, 2)))
        ..save(31, LocalDraft(key: aside, body: '較早', updatedAt: DateTime(2026, 10, 1)))
        ..preferNext(31, aside);
      final saver = DraftAutosaver(read: () => (uid: 31, key: key, draft: null))..attach();
      addTearDown(saver.dispose);
      await saver.offerStored(31, (k) => k == key);
      expect(saver.offer.value?.draft.body, '較早');
      await saver.offerStored(31, (k) => k == key);
      expect(saver.offer.value?.draft.body, '新的', reason: 'asked once');
    });

    test('L6. a private message does not count as a post for the forum\'s interval', () async {
      forum.answer = (r) =>
          _xml('<?xml version="1.0" encoding="utf-8"?><root><![CDATA[succeedhandle_pmsend(\'\', \'\');]]></root>');
      final now = DateTime(2026, 10, 23, 12);
      FloodControl.now = () => now;
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      final sent = bloc.stream.firstWhere((s) => s.status == ReplyStatus.success);
      bloc.add(const ReplyChatRequested('1000', {'message': 'hi'}, draftUid: 31));
      await sent;
      FloodControl.now = () => now.add(const Duration(seconds: 5));
      expect(FloodControl.retryAt(31, 15), now.add(const Duration(seconds: 20)), reason: 'from now, no post known');
    });

    test('L7. a file that cannot be read is kept aside, not written over', () async {
      final files = LocalDraftStore(directory: () async => Directory('${tmp.path}/bad'));
      Directory('${tmp.path}/bad').createSync(recursive: true);
      File('${tmp.path}/bad/31.json').writeAsStringSync('{not json');
      expect(await files.list(31), isEmpty);
      files.save(31, LocalDraft(key: LocalDraftKey.newThread('7'), body: 'x', updatedAt: DateTime(2026)));
      await files.pendingWrites;
      expect(File('${tmp.path}/bad/31.json.bad').readAsStringSync(), '{not json');
      expect(File('${tmp.path}/bad/31.json').existsSync(), isTrue);
    });
  });

  group('screenshots', () {
    final dir = Platform.environment['DRAFTS_SHOTS_DIR'];
    final font = Platform.environment['DRAFTS_SHOTS_FONT'];
    final skip = dir == null || font == null ? 'set DRAFTS_SHOTS_DIR and DRAFTS_SHOTS_FONT to write them' : null;
    const family = 'ShotSans';

    setUpAll(() async {
      if (skip != null) {
        return;
      }
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(font!).readAsBytesSync())))).load();
      final root = Platform.environment['FLUTTER_ROOT'];
      final icons = root == null ? null : '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
      if (icons != null && File(icons).existsSync()) {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(File(icons).readAsBytesSync())))).load();
      }
    });

    late ReplyBarController controller;
    late ReplyBloc bloc;

    ThemeData theme({required bool dark}) => dark
        ? AppTheme.makeDark(_FakeContext(), seedColor: null, fontFamily: family)
        : AppTheme.makeLight(_FakeContext(), seedColor: null, fontFamily: family);

    Future<void> capture(WidgetTester tester, String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
      final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 2)))!;
      final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
      image.dispose();
      Directory(dir!).createSync(recursive: true);
      File('$dir/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    }

    Future<void> pump(WidgetTester tester, {required bool dark, Widget? body}) async {
      tester.view
        ..physicalSize = const Size(400, 820)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = AuthenticationRepository(user: _alice);
      controller = ReplyBarController();
      bloc = ReplyBloc(replyRepository: const ReplyRepository())
        ..add(const ReplyParametersUpdated(_parameters))
        ..add(const ReplyThreadClosed(closed: false));
      addTearDown(() async {
        await bloc.close();
        await auth.dispose();
      });
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('shot'),
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: RepositoryProvider<ReplyRepository>(
              create: (_) => const ReplyRepository(),
              child: BlocProvider<ReplyBloc>.value(
                value: bloc,
                child: TranslationProvider(
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: theme(dark: dark),
                    home: Scaffold(
                      resizeToAvoidBottomInset: false,
                      appBar: AppBar(title: const Text('【公告】論壇使用說明')),
                      body: body ?? const _ThreadBody(),
                      bottomNavigationBar: ReplyBar(controller: controller, replyType: ReplyTypes.thread),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
    }

    BBCodeEditorController editorOf(WidgetTester tester) =>
        tester.widget<RichEditor>(find.byType(RichEditor)).controller;

    for (final dark in [false, true]) {
      final mode = dark ? 'dark' : 'light';

      testWidgets('the emoji panel with the recently used ones ($mode)', skip: skip != null, (tester) async {
        final store = getIt.get<RecentEmojiStore>();
        for (final code in ['{:12_822:}', '{:12_865:}', '{:12_819:}']) {
          store.use(code);
        }
        final group = EmojiGroup(
          name: '梦予馨',
          id: '12',
          routeName: 'TSDM',
          emojiList: [
            for (final id in ['818', '819', '820', '821', '822', '823', '824', '825', '826', '865'])
              Emoji(id: id, code: '{:12_$id:}', url: ''),
          ],
        );
        final images = {
          for (final id in ['818', '819', '820', '821', '822', '823', '824', '825', '826', '865'])
            '{:12_$id:}': File('assets/images/emoji/12_$id.jpg').existsSync()
                ? File('assets/images/emoji/12_$id.jpg').readAsBytesSync()
                : _png,
        };
        EmojiPanel.debugGroups = [group];
        EmojiPanel.debugEmojiImage = (code) => images[code];
        addTearDown(() {
          EmojiPanel.debugGroups = null;
          EmojiPanel.debugEmojiImage = null;
        });
        await pump(tester, dark: dark);
        controller.setHintText('回覆 ag_low2 #2');
        await tester.pumpAndSettle();
        editorOf(tester).insertBBCode('好可愛 ');
        await tester.tap(find.byKey(const ValueKey('reply-bar-emoji')));
        await tester.pumpAndSettle();
        // The images are decoded outside the fake time of the test.
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pumpAndSettle();
        await capture(tester, 'emoji_recent_$mode');
        await _unpump(tester);
      });

      testWidgets('the quote of the floor, the size and the countdown ($mode)', skip: skip != null, (tester) async {
        TsdmAppApi.notePostForm();
        forum.answer = (r) => r.method == 'GET' ? _api(_json('reply_quote')) : _xml(_floodRefused);
        await pump(tester, dark: dark);
        controller
          ..replyAction = _floorAction
          ..setHintText('回覆 ag_low2 #2');
        await _settle(tester);
        editorOf(tester).insertBBCode('同意樓上');
        await tester.pumpAndSettle();
        await capture(tester, 'quote_length_short_$mode');
        editorOf(tester).insertBBCode('，這個做法比較好，下次也照這樣排版。');
        await tester.pumpAndSettle();
        await capture(tester, 'quote_length_ok_$mode');
        await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
        await _settle(tester);
        await capture(tester, 'flood_countdown_$mode');
        await _unpump(tester);
      });

      testWidgets('the draft offered when the thread opens again ($mode)', skip: skip != null, (tester) async {
        drafts.save(
          31,
          LocalDraft(
            key: LocalDraftKey.floorReply('9600001', '9700002'),
            body: '寫到一半的回覆，等等再補完',
            updatedAt: DateTime(2026, 10, 23, 14, 5),
            fid: '2',
            replyAction: _floorAction,
            hint: '回覆 ag_low2 #2',
          ),
        );
        await _wait(tester, drafts.pendingWrites);
        await pump(tester, dark: dark);
        await _io(tester);
        await tester.pumpAndSettle();
        await capture(tester, 'draft_offer_$mode');
        await _unpump(tester);
      });

      testWidgets('the captcha dialog ($mode)', skip: skip != null, (tester) async {
        forum.answer = (r) => switch (r.uri.queryParameters) {
          {'mod': 'seccode', 'action': 'update'} => _js(_captchaScript(r.uri.queryParameters['idhash']!)),
          {'mod': 'seccode'} => _image(),
          {'mod': 'secqaa', 'action': 'update'} => _xml('<root><![CDATA[1 + 2 = ?]]></root>'),
          _ => throw StateError('unexpected'),
        };
        await pump(
          tester,
          dark: dark,
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showSecCheckDialog(
                  context,
                  const SecCheck(seccode: true, secqaa: true, seccodeHash: 'cSAapp', secqaaHash: 'qSAapp'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await _settle(tester);
        await capture(tester, 'sec_check_$mode');
        await _unpump(tester);
      });
    }
  });
}

/// Floors behind the reply box of the screenshots.
class _ThreadBody extends StatelessWidget {
  const _ThreadBody();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: const [
      Text('ag_low2 #2', style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('N1 二樓（ag_low2）000000 斜體'),
      Divider(height: 32),
      Text('Bob #3', style: TextStyle(fontWeight: FontWeight.bold)),
      SizedBox(height: 8),
      Text('排版的部分我覺得可以再討論。'),
    ],
  );
}

/// A context for the theme builders of the screenshots (they read nothing from it).
final class _FakeContext extends Fake implements BuildContext {}

/// Let the file and network work of the page (real futures) and its frames finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// Let the queued work of the stores (in memory, on microtasks) and the frames it causes finish.
Future<void> _io(WidgetTester tester) async {
  await _wait(tester, getIt.get<LocalDraftStore>().pendingWrites);
  await tester.pump();
}

/// [future], once the frames let it complete (the work of the page runs in the fake time of the test).
Future<T> _wait<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  unawaited(
    future.then((v) {
      value = v;
      done = true;
    }),
  );
  for (var i = 0; i < 50 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done, isTrue, reason: 'the store answered');
  return value;
}

/// Take the page down and let the timers of its indicators run out.
Future<void> _unpump(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _io(tester);
  await tester.pump(const Duration(seconds: 3));
}
