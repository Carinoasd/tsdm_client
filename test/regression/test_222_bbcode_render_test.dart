/// The forum's app API, plugin 2.7.0: each floor of the thread page carries its bbcode (`schema: 14`), drawn by the
/// app's own renderer behind the experimental setting 「用 App 渲染器顯示帖子（實驗）」 (off by default).
///
/// The plugin gives a floor's bbcode (`message`) only when the account sees the whole content on the web page, with
/// the floor's switches (`bbcodeoff`, `smileyoff`, `parseurloff`), the attachments the forum loaded for the request,
/// the forum's `codes` and the version of the smilies table (`smilies_version`, the table itself from the `smilies`
/// action). [Post.fromApi] keeps them beside everything it read before; [decidePostBbcode] draws a floor from its
/// bbcode only when every tag in it is drawn as the forum shows it, and keeps the floor's html otherwise; the card
/// shows the html exactly as before while the setting is off.
///
/// The fixtures `thread_v14_*.json` are answers of the test forum (Discuz X5 with plugin 2.7.0, 2026-10-21, the
/// plugin's contract samples) with the test forum's host and name and the form hash scrubbed;
/// `thread_v14_smilies.json` is the answer of the `smilies` action.
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
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/post_bbcode_view.dart';
import 'package:tsdm_client/features/thread/v1/bbcode/smilies.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/code_card.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:tsdm_client/widgets/quoted_text.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) => jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, dynamic>;

/// The floors of the page built from [json].
List<Post> _posts(Map<String, dynamic> json) => threadPageFromApi(json, 1).postList;

/// The floor at [index] of the page built from the fixture [name] (the fixture threads keep their floors in order;
/// their ids change when the fixtures are fetched again).
Post _post(String name, int index) => _posts(_json(name))[index];

/// The floor at [index] of the answer [json] as the answer gives it.
Map<String, dynamic> _floor(Map<String, dynamic> json, int index) =>
    (json['posts'] as List).cast<Map<String, dynamic>>()[index];

/// The attachment ids `[attach]` names in [bbcode], in order.
List<int> _attachIds(String bbcode) =>
    RegExp(r'\[attach\](\d+)\[/attach\]').allMatches(bbcode).map((m) => int.parse(m.group(1)!)).toList();

/// The first floor of `thread_v14_attachments.json` without its `[media]` line, which the app does not draw, and
/// with the forum's `spoiler` among the floor's [customtags] (the 2.7.0 samples do not carry the field yet).
Post _firstFloorWithoutMedia(String name, {List<String>? customtags = const ['spoiler']}) {
  final json = _json(name);
  final floor = _floor(json, 0);
  floor['message'] = (floor['message'] as String).replaceFirst(RegExp(r'\[media=[^\]]*\][^\[]*\[/media\]\r\n'), '');
  if (customtags != null) {
    floor['customtags'] = customtags;
  }
  return _posts(json).first;
}

/// The floor at [index] of the fixture [name] with [customtags].
Post _withCustomTags(String name, int index, List<String> customtags) {
  final json = _json(name);
  _floor(json, index)['customtags'] = customtags;
  return _posts(json)[index];
}

/// The floor of `thread_v14_plain.json` (its html has the message cell) with the bbcode [message] and the switches.
Post _synthetic(
  String message, {
  int bbcodeoff = 0,
  int smileyoff = 1,
  int parseurloff = 0,
  List<Map<String, Object?>> attachments = const [],
  Map<String, Object?> codes = const {},
  List<String>? customtags = const ['spoiler'],
}) {
  final json = _json('thread_v14_plain.json');
  json['codes'] = {...json['codes'] as Map<String, dynamic>, ...codes};
  final floor = _floor(json, 0)
    ..['message'] = message
    ..['bbcodeoff'] = bbcodeoff
    ..['smileyoff'] = smileyoff
    ..['parseurloff'] = parseurloff
    ..['attachments'] = attachments;
  codes.keys.forEach(floor.remove);
  if (customtags != null) {
    floor['customtags'] = customtags;
  }
  return _posts(json).single;
}

SmiliesTable _table() => SmiliesTable.fromJson(_json('thread_v14_smilies.json'))!;

PostBbcodeRender _render(Post post, {SmiliesTable? smilies}) {
  final decision = decidePostBbcode(post, smilies: smilies);
  expect(decision, isA<PostBbcodeRender>(), reason: '$decision');
  return decision as PostBbcodeRender;
}

String _fallback(Post post, {SmiliesTable? smilies}) {
  final decision = decidePostBbcode(post, smilies: smilies);
  expect(decision, isA<PostBbcodeFallback>());
  return (decision as PostBbcodeFallback).reason;
}

/// Every node of [nodes], depth first.
Iterable<BbNode> _all(List<BbNode> nodes) sync* {
  for (final node in nodes) {
    yield node;
    switch (node) {
      case BbLink(:final children) ||
          BbQuote(:final children) ||
          BbSpoiler(:final children) ||
          BbAlign(:final children):
        yield* _all(children);
      case BbList(:final items):
        for (final item in items) {
          yield* _all(item);
        }
      case BbText() || BbSmiley() || BbImage() || BbAttachment() || BbCodeBlock() || BbDivider() || BbVideo():
        break;
    }
  }
}

/// [nodes] without what loads an image (the smilies, `[img]`, an attachment image): there is no forum to load them
/// from in a widget test.
List<BbNode> _withoutImages(List<BbNode> nodes) => [
  for (final node in nodes)
    switch (node) {
      BbSmiley() || BbImage() => null,
      BbAttachment(:final attachment) when !attachment.locked && attachment.isImage => null,
      BbQuote(:final children) => BbQuote(_withoutImages(children)),
      BbSpoiler(:final title, :final children) => BbSpoiler(title, _withoutImages(children)),
      BbAlign(:final align, :final children) => BbAlign(align, _withoutImages(children)),
      BbLink(:final href, :final children, :final auto) => BbLink(href, _withoutImages(children), auto: auto),
      BbList(:final type, :final items) => BbList(type, [for (final item in items) _withoutImages(item)]),
      _ => node,
    },
].nonNulls.toList();

/// The text of [nodes] (smilies as their code), blocks on lines of their own.
String _plain(List<BbNode> nodes) => _all(nodes)
    .map(
      (e) => switch (e) {
        BbText(:final text) => text,
        BbSmiley(:final smiley) => smiley.code,
        _ => '',
      },
    )
    .join();

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The block list rows in memory.
final class _MemoryBlockList extends Fake implements StorageProvider {
  final rows = <String, List<String>>{};

  @override
  Future<List<String>?> getStringList(String key) async => rows[key];

  @override
  Future<void> saveStringList(String key, List<String> value) async => rows[key] = List.of(value);

  @override
  Future<void> deleteKey(String key) async => rows.remove(key);
}

/// A [SmiliesStore] in memory.
final class _MemoryStore implements SmiliesStore {
  String? data;
  int writes = 0;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String data) async {
    this.data = data;
    writes++;
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('A. the floor keeps its bbcode', () {
    test('the fields of a floor given its bbcode, beside what it had before', () {
      final json = _json('thread_v14_attachments.json');
      final raw = _floor(json, 0);
      final post = _posts(json).first;
      expect(post.messageBbcode, raw['message']);
      expect(post.messageBbcode, startsWith('首樓 :) 表情與各種標籤'));
      expect(post.messageReason, '');
      expect(post.bbcodeOff, isFalse);
      expect(post.smileyOff, isFalse);
      expect(post.parseUrlOff, isFalse);
      expect(post.data, raw['body_html'], reason: 'the html stays the content as the forum printed it');
      expect(post.smiliesVersion, json['smilies_version']);
      expect(post.smiliesVersion, isNotEmpty);

      final codes = post.bbcodeCodes!;
      expect(codes.allowSmilies, isTrue);
      expect(codes.allowBbcode, isTrue);
      expect(codes.allowImgCode, isTrue);
      expect(codes.allowHtml, isFalse);
      expect(codes.jammer, isFalse);
      expect(codes.maxSmilies, 10);
      expect(
        codes.allowMediaCode,
        raw['allowmediacode'] == 1,
        reason: "the floor's own value (the author's group) over the top level one (the viewer's)",
      );

      expect(post.attachments.map((e) => e.filename), [
        'tsdmapp270_cover.png',
        'tsdmapp270_note.zip',
        'tsdmapp270_paid.png',
      ]);
      expect(post.attachments.map((e) => e.aid), (raw['attachments'] as List).map((e) => (e as Map)['aid']));
      final cover = post.attachments[0];
      expect(cover.filename, 'tsdmapp270_cover.png');
      expect(cover.isImage, isTrue);
      expect(cover.locked, isFalse);
      expect(cover.inPost, isTrue);
      expect(cover.url, 'https://www.tsdm39.com/data/attachment/forum/202610/16/095551dcacw748nxjowxnk.png');
      expect(cover.width, 1920);
      expect(cover.height, 1080);
      expect(cover.description, isNotEmpty);
      final zip = post.attachments[1];
      expect(zip.isImage, isFalse);
      expect(zip.inPost, isFalse);
      expect(zip.download, startsWith('https://www.tsdm39.com/forum.php?mod=attachment&aid='));
      final paid = post.attachments[2];
      expect(paid.locked, isTrue);
      expect(paid.price, 2);
      expect((paid.url, paid.thumb, paid.download), ('', '', ''));
    });

    test('withheld floors: no bbcode, the reason, no attachment', () {
      final json = _json('thread_v14_attachments.json');
      final posts = _posts(json);
      for (final (index, reason) in [(1, 'hide'), (2, 'hide'), (4, 'bbcodeoff'), (5, 'html'), (6, 'password')]) {
        final post = posts[index];
        expect(post.messageBbcode, isNull, reason: '$index');
        expect(post.messageReason, reason, reason: '$index');
        expect(post.attachments, isEmpty, reason: '$index');
        expect(post.data, isNotEmpty, reason: '$index keeps its html');
      }
      expect(posts[4].bbcodeOff, isTrue);
      expect(_post('thread_v14_free_paid.json', 0).messageReason, 'pay');
      expect(_post('thread_v14_moderate.json', 1).messageReason, 'moderate');
      expect(_post('thread_v14_hiddenreply_attach.json', 1).messageReason, 'locked');
      expect(_post('thread_v14_smileys.json', 3).messageReason, 'json');
      expect(_post('thread_v14_jammer.json', 3).messageReason, 'jammer');
    });

    test('an answer before 2.7.0 (schema 3) leaves the new fields empty', () {
      // The fixture is the answer of 2.8.0 (schema 15): without what 2.7.0 and 2.8.0 added, it is the answer of 2.1.0.
      const addedTop = {'codes', 'smilies_version', 'special'};
      const addedFloor = {
        'message',
        'message_reason',
        'bbcodeoff',
        'smileyoff',
        'parseurloff',
        'allowbbcode',
        'allowsmilies',
        'allowimgcode',
        'allowmediacode',
        'attachments',
        'best',
        'customtags',
        'stand',
        'stand_votes',
      };
      final json = _json('thread_v3_plain.json');
      final old = <String, dynamic>{
        for (final e in json.entries)
          if (!addedTop.contains(e.key)) e.key: e.value,
        'schema': 3,
        'posts': [
          for (final floor in (json['posts'] as List).cast<Map<String, dynamic>>())
            {
              for (final e in floor.entries)
                if (!addedFloor.contains(e.key)) e.key: e.value,
            },
        ],
      };
      final post = _posts(old).first;
      expect(post.messageBbcode, isNull);
      expect(post.messageReason, isNull);
      expect(post.bbcodeCodes, isNull);
      expect(post.smiliesVersion, isNull);
      expect(post.attachments, isEmpty);
      expect(post.bbcodeOff || post.smileyOff || post.parseUrlOff, isFalse);
      expect(decidePostBbcode(post), isA<PostBbcodeFallback>());
    });

    test('a locked attachment never keeps a url, even one given by mistake', () {
      final a = PostAttachment.fromApi({
        'aid': 7,
        'filename': 'x.png',
        'isimage': 1,
        'url': 'https://www.tsdm39.com/x.png',
        'thumb': 'https://www.tsdm39.com/x.thumb.png',
        'download': 'https://www.tsdm39.com/forum.php?mod=attachment&aid=7',
        'locked': 1,
      })!;
      expect((a.url, a.thumb, a.download), ('', '', ''));
      expect(PostAttachment.fromApi({'aid': 0, 'filename': 'x'}), isNull);
    });

    test('the smilies answer names the plugin as plugin_version: its version is the table', () {
      final answer = _json('thread_v14_smilies.json');
      final info = TsdmAppPluginInfo.fromAnswer(answer)!;
      expect(info.version, '2.7.0');
      expect(info.version, isNot(answer['version']));
    });
  });

  group('B. the gate: drawn from bbcode, or the html as before', () {
    test('a withheld floor keeps its html, with the reason', () {
      final json = _json('thread_v14_jammer.json');
      final posts = _posts(json);
      expect(_fallback(posts[1]), 'hide');
      expect(_fallback(posts[3]), 'jammer');
      expect(_fallback(posts[4]), 'bbcodeoff');
      expect(_fallback(posts[5]), 'html');
      expect(_fallback(posts[6]), 'password');
      expect(_fallback(_post('thread_v14_free_paid.json', 0)), 'pay');
      expect(_fallback(_post('thread_v14_moderate.json', 1)), 'moderate');
      expect(_fallback(_post('thread_v14_smileys.json', 3)), 'json');
    });

    test('a plain floor with bbcodeoff 1 (the forum stores -1 without tags) is drawn as its text', () {
      final post = _post('thread_v14_plain.json', 0);
      expect(post.bbcodeOff, isTrue);
      final render = _render(post);
      expect(render.nodes, hasLength(1));
      expect((render.nodes.single as BbText).text, '原生发帖页。');
      expect(render.htmlBefore, isEmpty, reason: 'nothing shows before the message');
      expect(render.htmlAfter, contains('modact'), reason: 'the moderation notice after the message stays html');
      expect(render.htmlAfter, isNot(contains('postmessage_')));
      expect(render.htmlAfter, isNot(contains('原生发帖页')));
    });

    test('literal floors: the text as it is, tags as text, no smiley with smileyoff 1', () {
      final json = _json('thread_v14_attachments.json');
      final posts = _posts(json);
      final literal = _render(posts[7], smilies: _table());
      expect(posts[7].parseUrlOff, isTrue);
      expect(literal.nodes.whereType<BbSmiley>(), isEmpty);
      expect(_plain(literal.nodes), _floor(json, 7)['message']);
      expect(_plain(literal.nodes), startsWith(':) http://example.com/x 不換表情不自動連結'));
      expect(
        literal.nodes.whereType<BbLink>().map((e) => e.href),
        ['http://example.com/x'],
        reason: 'linked as the html renderer links it, parseurloff or not',
      );
      final lines = _render(posts[8]);
      expect(_plain(lines.nodes), (_floor(json, 8)['message'] as String).replaceAll('\r\n', '\n'));
      expect(_plain(lines.nodes), matches(RegExp(r'^純文字\n第二行 \d+\n\n日本語とemoji 😀 結尾$')));
      final literalTags = _render(_synthetic('[b]x[/b] y', bbcodeoff: 1));
      expect(_plain(literalTags.nodes), '[b]x[/b] y');
      expect(_fallback(_synthetic('a [attach]1[/attach]', bbcodeoff: 1)), 'attach-in-literal');
    });

    test('a tag the app does not draw keeps the html: media, payment, table, sup, @, uppercase…', () {
      expect(_fallback(_post('thread_v14_attachments.json', 0), smilies: _table()), 'tag:media');
      expect(_fallback(_post('thread_v14_attachments.json', 9)), 'tag:payment');
      for (final (bbcode, reason) in [
        ('[table][tr][td]a[/td][/tr][/table]', 'tag:table'),
        ('[flash]https://x/a.swf[/flash]', 'tag:flash'),
        ('[audio]https://x/a.mp3[/audio]', 'tag:audio'),
        ('[attachimg]1[/attachimg]', 'tag:attachimg'),
        ('x[sup]2[/sup]', 'tag:sup'),
        ('[@]name[/@]', 'tag:@'),
        ('[email]a@b.c[/email]', 'tag:email'),
        ('[float=left]x[/float]', 'tag:float'),
        ('[B]x[/B]', 'case:B'),
        ('[Quote]x[/Quote]', 'case:Quote'),
        ('[OP] 公告', 'tag:OP'),
        ('[b]x', 'literal-tag:[b]'),
        ('[b]x[i]y[/b][/i]', 'literal-tag:[b]'),
        ('[size=12px]x[/size]', 'literal-tag:[size=12px]'),
        ('[align=justify]x[/align]', 'literal-tag:[align=justify]'),
        ('[spoiler]x[/spoiler]', 'literal-tag:[spoiler]'),
        ('[quote]a[quote]b[/quote]c[/quote]', 'quote-nested'),
        ('[spoiler=a][spoiler=b]x[/spoiler][/spoiler]', 'spoiler-nested'),
        ('[url=https://a/][quote]x[/quote][/url]', 'block-in-url'),
        ('[list=i][*]a[/list]', 'list:i'),
        ('[list]text[*]a[/list]', 'list-text-before-item'),
        ('[*]a', 'literal-tag:[*]'),
        ('[url]not a url[/url]', 'url-without-url'),
        ('[hide]x[/hide]', 'hidden'),
        ('ed2k://|file|a|1|h|/', 'special-url'),
      ]) {
        expect(_fallback(_synthetic(bbcode)), reason, reason: bbcode);
      }
      expect(_fallback(_synthetic('[img]https://x/a.png[/img]', codes: {'allowimgcode': 0})), 'img-not-allowed');
    });

    test('the floor drawn from bbcode: text, quote, code, image, links, styles, list, spoiler, attachments', () {
      final post = _firstFloorWithoutMedia('thread_v14_attachments.json');
      final render = _render(post, smilies: _table());
      final nodes = render.nodes;
      final all = _all(nodes).toList();

      // Smilies, in and out of the quote.
      final smilies = all.whereType<BbSmiley>().toList();
      expect(smilies.map((e) => e.smiley.code), [':)', ':(']);
      expect(smilies.first.smiley.url, 'https://www.tsdm39.com/static/image/smiley/default/smile.gif');
      final quote = nodes.whereType<BbQuote>().single;
      expect(_plain(quote.children), '引用的話 :( ');

      expect(nodes.whereType<BbCodeBlock>().single.code, '<?php echo 1; ?>');
      final image = nodes.whereType<BbImage>().single;
      expect(image.url, 'https://example.com/a.png');
      expect((image.width, image.height), (null, null));

      final links = all.whereType<BbLink>().toList();
      expect(links.map((e) => (e.href, e.auto)), [('https://example.com/', false), ('https://example.com/auto', true)]);
      expect(_plain(links.first.children), '連結');

      final texts = all.whereType<BbText>().toList();
      expect(texts.firstWhere((e) => e.text == '粗體').style.bold, isTrue);
      expect(texts.firstWhere((e) => e.text == '紅字').style.color, 'red');
      expect(texts.firstWhere((e) => e.text == '大字').style.size, '4');

      final list = nodes.whereType<BbList>().single;
      expect(list.type, isNull);
      expect(list.items.map(_plain), ['一', '二']);

      final spoiler = nodes.whereType<BbSpoiler>().single;
      expect(spoiler.title, '標題');
      expect(_plain(spoiler.children), '折疊內文');

      final attachments = nodes.whereType<BbAttachment>().toList();
      expect(attachments.map((e) => e.aid), _attachIds(post.messageBbcode!));
      expect(attachments.map((e) => e.attachment.filename), ['tsdmapp270_cover.png', 'tsdmapp270_paid.png']);
      expect(attachments[0].attachment.locked, isFalse);
      expect(attachments[0].attachment.url, endsWith('.png'));
      expect(attachments[1].attachment.locked, isTrue, reason: 'not bought: the placeholder, nothing fetched');
      expect(attachments[1].attachment.url, isEmpty);

      expect(_plain(nodes), endsWith('結尾\u3000全形空白與\u00a0 \u00a0 \u00a0 \u00a0 tab'));
      // The order of the blocks, each on its own line.
      expect(
        nodes.where((e) => e.isBlock).map((e) => e.runtimeType),
        [BbQuote, BbCodeBlock, BbList, BbSpoiler],
      );
      expect(render.htmlAfter, contains('tsdmapp270_note.zip'), reason: 'the attachment list below stays html');
      expect(render.htmlAfter, isNot(contains('postmessage_')));
    });

    test('[attach]: the listed one, a locked one (a placeholder, nothing fetched), once per id; one not listed keeps '
        'the html', () {
      // The account can not view images: the forum gives them as locked files without url.
      final noImage = _render(_firstFloorWithoutMedia('thread_v14_access_noimage.json'), smilies: _table());
      final shown = noImage.nodes.whereType<BbAttachment>().toList();
      expect(shown.map((e) => (e.attachment.filename, e.attachment.locked, e.attachment.url)), [
        ('tsdmapp270_cover.png', true, ''),
        ('tsdmapp270_paid.png', true, ''),
      ]);

      // A guest of a forum showing guests thumbnails only.
      final guest = _render(_firstFloorWithoutMedia('thread_v14_guestthumb.json'), smilies: _table());
      expect(guest.nodes.whereType<BbAttachment>().every((e) => e.attachment.locked), isTrue);

      // A guest without the attachments: none listed, the html shows what the forum decided.
      final guestFloor = _firstFloorWithoutMedia('thread_v14_hide_viewer_not_replied.json');
      expect(guestFloor.attachments, isEmpty);
      expect(_attachIds(guestFloor.messageBbcode!), isNotEmpty);
      expect(_fallback(guestFloor, smilies: _table()), 'attach-unlisted');

      // A banned author's floor: its bbcode, but no attachment listed.
      expect(_fallback(_post('thread_v14_banned_digest.json', 1)), 'attach-unlisted');
      // The same for a single-banned floor shown to a moderator; the notice above its message is html anyway.
      final singleFloor = _post('thread_v14_singleban_mod.json', 1);
      expect(_fallback(singleFloor), 'attach-unlisted');
      expect(splitPostBodyHtml(singleFloor.data, singleFloor.postID)!.before, contains('该帖被管理员或版主屏蔽'));
      final plainSingle = _render(_post('thread_v14_singleban_mod.json', 2));
      expect(plainSingle.htmlBefore, contains('作者被禁止或删除'));
      expect(_plain(plainSingle.nodes), matches(RegExp(r'^BANNED_PLAIN_\d+ 非精華主題裡禁止組作者的回覆$')));

      final twice = _render(
        _synthetic(
          '[attach]9[/attach] and [attach]9[/attach]',
          attachments: [
            {
              'aid': 9,
              'filename': 'a.zip',
              'isimage': 0,
              'url': 'https://www.tsdm39.com/d',
              'download': 'https://www.tsdm39.com/d',
            },
          ],
        ),
      );
      expect(twice.nodes.whereType<BbAttachment>(), hasLength(1), reason: 'the forum drops the second one');
      final zeroLed = _render(
        _synthetic(
          'a [attach]09[/attach] b [attach]0[/attach]',
          attachments: [
            {
              'aid': 9,
              'filename': 'a.zip',
              'isimage': 0,
              'url': 'https://www.tsdm39.com/d',
              'download': 'https://www.tsdm39.com/d',
            },
          ],
        ),
      );
      expect(
        zeroLed.nodes.whereType<BbAttachment>(),
        isEmpty,
        reason: 'an id with a leading zero: the forum prints nothing',
      );
      expect(_plain(zeroLed.nodes), 'a  b');
      expect(_fallback(_synthetic('[code][attach]1[/attach][/code]')), 'attach-in-code');
    });

    test('free, url, img sizes, code as raw text, the edit note, lists, alignment', () {
      final free = _render(_post('thread_v14_attachments.json', 3));
      expect(free.nodes.first, isA<BbQuote>());
      expect(_plain((free.nodes.first as BbQuote).children), matches(RegExp(r'^FREE_PART_\d+$')));
      expect(
        _plain(free.nodes.skip(1).toList()),
        matches(RegExp(r'^AFTER_FREE_\d+$')),
        reason: 'the forum takes the line break',
      );

      final url = _render(_synthetic('[url]www.example.com/a[/url]'));
      final link = url.nodes.single as BbLink;
      expect(link.href, 'http://www.example.com/a');
      expect(_plain(link.children), 'www.example.com/a');
      final long = 'https://example.com/${'a' * 80}';
      final shortened = _render(_synthetic('[url]$long[/url]')).nodes.single as BbLink;
      expect(shortened.href, long);
      expect(_plain(shortened.children), '${long.substring(0, 32)} ... ${long.substring(long.length - 19)}');
      final inForum = _render(_synthetic('[url=forum.php?mod=viewthread&tid=1]t[/url]')).nodes.single as BbLink;
      expect(inForum.href, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1');

      final sized = _render(_synthetic('[img=100x50]https://example.com/b.png[/img]')).nodes.single as BbImage;
      expect((sized.url, sized.width, sized.height), ('https://example.com/b.png', 100, 50));
      final noScheme = _render(_synthetic('[img]example.com/c.png[/img]')).nodes.single as BbImage;
      expect(noScheme.url, 'http://example.com/c.png');

      final code = _render(_synthetic('a\r\n[code][b]x[/b] :)\r\n\tline[/code]\r\nb', smileyoff: 0), smilies: _table());
      expect(code.nodes.whereType<BbCodeBlock>().single.code, '[b]x[/b] :)\n\u00a0 \u00a0 \u00a0 \u00a0 line');
      expect(code.nodes.whereType<BbSmiley>(), isEmpty, reason: 'no smiley in code');

      final edited = _render(_synthetic('[i=s] 本帖最后由 a 于 2026-10-01 12:00 编辑 [/i]\r\n\r\nbody'));
      expect(_plain(edited.nodes), 'body');

      final ordered = _render(_synthetic('[list=1]\r\n[*]a\r\n[*]b [b]c[/b]\r\n[/list]')).nodes.single as BbList;
      expect(ordered.type, '1');
      expect(ordered.items.map(_plain), ['a', 'b c']);
      final nested = _render(_synthetic('[list][*]a[list][*]x[*]y[/list][*]b[/list]')).nodes.single as BbList;
      expect(nested.items, hasLength(2));
      expect(nested.items.first.whereType<BbList>().single.items.map(_plain), ['x', 'y']);

      final aligned = _render(_synthetic('[align=center][color=#ff0000]c[/color][/align]')).nodes.single as BbAlign;
      expect(aligned.align, 'center');
      expect((aligned.children.single as BbText).style.color, '#ff0000');
      expect(_render(_synthetic('a[hr]b')).nodes.whereType<BbDivider>(), hasLength(1));
      expect(_plain(_render(_synthetic('[font=宋体]f[/font]')).nodes), 'f');
    });

    test("links and images on the forum's old domains go to the current one, as the forum's oldlinkfix does", () {
      String href(String bbcode) => (_render(_synthetic(bbcode)).nodes.single as BbLink).href;
      expect(
        href('[url=http://www.tsdm.me/thread-123-2-1.html]a[/url]'),
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123&page=2',
      );
      expect(href('[url=thread-9-1-1.html]a[/url]'), 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=9');
      expect(
        href('[url=https://www.tsdm39.com/space-uid-7.html]a[/url]'),
        'https://www.tsdm39.com/home.php?mod=space&uid=7',
      );
      expect(href('[url=https://example.com/thread-1-1-1.html]a[/url]'), 'https://example.com/thread-1-1-1.html');
      final shown = _render(_synthetic('[url]tsdm.net/viewthread.php?tid=5[/url]')).nodes.single as BbLink;
      expect(shown.href, 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=5');
      expect(_plain(shown.children), 'tsdm.net/viewthread.php?tid=5', reason: 'the text stays as written');
      final image = _render(_synthetic('[img=10,20]http://bbs.tsdm.live/static/a.png[/img]')).nodes.single as BbImage;
      expect((image.url, image.width), ('https://www.tsdm39.com/static/a.png', 10));
      expect(fixOldForumUrl('space.php?action=viewpro&uid=3', relative: true), 'home.php?mod=space&uid=3');
      expect(fixOldForumUrl('mailto:a@b.c', relative: true), 'mailto:a@b.c');
    });

    test('bare urls are linked whatever parseurloff says, as the html renderer links them', () {
      final linked = _render(_synthetic('see https://example.com/x.'));
      final link = linked.nodes.whereType<BbLink>().single;
      expect((link.href, link.auto), ('https://example.com/x', true));
      expect(_plain(linked.nodes), 'see https://example.com/x.');
      final off = _render(_synthetic('see https://example.com/x.', parseurloff: 1));
      expect(off.nodes.whereType<BbLink>().single.href, 'https://example.com/x');
      final literal = _render(_synthetic('see https://example.com/y', bbcodeoff: 1, parseurloff: 1));
      expect(literal.nodes.whereType<BbLink>().single.href, 'https://example.com/y');
      final inUrl = _render(_synthetic('[url=https://a.example/]https://b.example/[/url]'));
      expect(_all(inUrl.nodes).whereType<BbLink>().map((e) => e.href), ['https://a.example/']);
    });

    test('a floor without its message cell in the html keeps the html', () {
      final json = _json('thread_v14_plain.json');
      _floor(json, 0)['body_html'] = '<div>no cell</div>';
      expect(_fallback(_posts(json).single), 'no-message-cell');
    });
  });

  group('C. smilies', () {
    test('turned into the images of the table, as the forum does, when the floor needs them', () {
      expect(
        _fallback(_post('thread_v14_smileys.json', 1), smilies: _table()),
        'custom:spoiler',
        reason: 'the answer does not say the forum expands [spoiler] here',
      );
      final post = _withCustomTags('thread_v14_smileys.json', 1, ['spoiler']);
      expect(post.customTags, ['spoiler']);
      expect(postBbcodeNeedsSmilies(post), isTrue);
      expect(_fallback(post), 'smilies', reason: 'no table yet: the html');
      final render = _render(post, smilies: _table());
      final spoiler = render.nodes.first as BbSpoiler;
      expect(spoiler.title, '折疊');
      expect(_plain(spoiler.children), matches(RegExp(r'^SPOILER_TEXT_\d+$')));
      final smiley = render.nodes.whereType<BbSmiley>().single;
      expect(smiley.smiley.code, ':D');
      expect(smiley.smiley.url, 'https://www.tsdm39.com/static/image/smiley/default/biggrin.gif');
    });

    test('at most maxsmilies of each code, in the order of the table (the longer code first), none with smileyoff', () {
      final many = _render(_synthetic(List.filled(12, ':)').join(' '), smileyoff: 0), smilies: _table());
      expect(many.nodes.whereType<BbSmiley>(), hasLength(10));
      expect(_plain(many.nodes), List.filled(12, ':)').join(' '));
      expect(many.nodes.last, isA<BbText>());
      expect((many.nodes.last as BbText).text, ' :) :)');

      final unlimited = _render(
        _synthetic(List.filled(12, ':)').join(' '), smileyoff: 0, codes: {'maxsmilies': -1}),
        smilies: _table(),
      );
      expect(unlimited.nodes.whereType<BbSmiley>(), hasLength(12));
      final zero = _synthetic(List.filled(12, ':)').join(' '), smileyoff: 0, codes: {'maxsmilies': 0});
      expect(postBbcodeNeedsSmilies(zero), isTrue);
      expect(
        _render(zero, smilies: _table()).nodes.whereType<BbSmiley>(),
        hasLength(12),
        reason: "the forum's settings cache turns a limit of 0 into -1: no limit",
      );
      final literalSmiley = _synthetic(':) and [b]', smileyoff: 0, bbcodeoff: 1);
      expect(postBbcodeNeedsSmilies(literalSmiley), isTrue, reason: 'bbcodeoff does not stop the smilies');
      final literal = _render(literalSmiley, smilies: _table());
      expect(literal.nodes.whereType<BbSmiley>(), hasLength(1));
      expect(_plain(literal.nodes), ':) and [b]');

      const longer = Smiley(id: 2, code: ':))', url: 'https://www.tsdm39.com/b.gif', type: 'x');
      const shorter = Smiley(id: 1, code: ':)', url: 'https://www.tsdm39.com/a.gif', type: 'x');
      const table = SmiliesTable(version: 'v', smilies: [longer, shorter]);
      final ordered = _render(_synthetic('a:))b:)c', smileyoff: 0), smilies: table);
      expect(ordered.nodes.whereType<BbSmiley>().map((e) => e.smiley.code), [':))', ':)']);

      final off = _synthetic(':) :D');
      expect(postBbcodeNeedsSmilies(off), isFalse);
      expect(_render(off, smilies: _table()).nodes.whereType<BbSmiley>(), isEmpty);
      final forumOff = _synthetic(':)', smileyoff: 0, codes: {'allowsmilies': 0});
      expect(postBbcodeNeedsSmilies(forumOff), isFalse);
    });
  });

  group('D. the smilies table, kept by version', () {
    test('fetched for a new version, kept, saved; the same version is not asked again', () async {
      final store = _MemoryStore();
      var fetches = 0;
      final answer = _json('thread_v14_smilies.json');
      final version = answer['version'] as String;
      final repo = SmiliesRepository(
        store: store,
        fetch: () async {
          fetches++;
          return answer;
        },
      );
      addTearDown(repo.dispose);
      var notified = 0;
      repo.table.addListener(() => notified++);

      expect(repo.tableFor(version), isNull, reason: 'not kept yet: asked in the background');
      final table = await repo.ensure(version);
      expect(table, isNotNull);
      expect(table!.version, version);
      expect(table.smilies, hasLength(answer['count']));
      expect(fetches, 1);
      expect(notified, 1);
      expect(identical(repo.tableFor(version), table), isTrue);
      await repo.ensure(version);
      expect(fetches, 1);
      expect(store.writes, 1);
      expect(SmiliesTable.fromJson(jsonDecode(store.data!) as Map<String, dynamic>)!.version, version);

      // The next run reads the saved table: nothing asked.
      final next = SmiliesRepository(
        store: store,
        fetch: () async {
          fetches++;
          return answer;
        },
      );
      addTearDown(next.dispose);
      expect((await next.ensure(version))?.smilies.first.code, table.smilies.first.code);
      expect(fetches, 1);
    });

    test('another version is fetched again; an answer of yet another version is not asked again soon', () async {
      final store = _MemoryStore();
      final answers = <Map<String, dynamic>?>[
        {
          'ok': 1,
          'plugin_version': '2.7.0',
          'version': 'v1',
          'smilies': [
            {'id': 1, 'code': ':)', 'url': 'https://www.tsdm39.com/a.gif', 'type': 'default'},
          ],
        },
        {
          'ok': 1,
          'plugin_version': '2.7.0',
          'version': 'v2',
          'smilies': [
            {'id': 1, 'code': ':)', 'url': 'https://www.tsdm39.com/b.gif', 'type': 'default'},
          ],
        },
      ];
      answers.add(answers.last);
      var fetches = 0;
      final repo = SmiliesRepository(store: store, fetch: () async => answers[fetches++]);
      addTearDown(repo.dispose);
      expect((await repo.ensure('v1'))?.smilies.single.url, 'https://www.tsdm39.com/a.gif');
      expect((await repo.ensure('v2'))?.smilies.single.url, 'https://www.tsdm39.com/b.gif');
      expect(fetches, 2);
      expect(SmiliesTable.fromJson(jsonDecode(store.data!) as Map<String, dynamic>)!.version, 'v2');

      // The forum answers v2 although the page named v3: v2 is kept, v3 is not asked again for a while.
      expect(await repo.ensure('v3'), isNull);
      expect(fetches, 3);
      expect(repo.table.value?.version, 'v2');
      expect(repo.tableFor('v3'), isNull);
      expect(await repo.ensure('v3'), isNull);
      expect(fetches, 3, reason: 'no more answers here: asking again would throw');
    });

    test('a failed fetch, or the forum without the action, keeps no table and is not retried at once', () async {
      var fetches = 0;
      final repo = SmiliesRepository(
        store: _MemoryStore(),
        fetch: () async {
          fetches++;
          return fetches == 1 ? null : {'ok': 0, 'error': 'action'};
        },
      );
      addTearDown(repo.dispose);
      expect(await repo.ensure('v1'), isNull);
      expect(await repo.ensure('v1'), isNull);
      expect(fetches, 1);
      expect(await repo.ensure('v2'), isNull);
      expect(fetches, 2);
      expect(repo.table.value, isNull);
    });

    test('saved in the app database without a new table', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = StorageSmiliesStore(StorageProvider(db, {}, {}));
      expect(await store.read(), isNull);
      await store.write('{"version":"v"}');
      expect(await store.read(), '{"version":"v"}');
    });
  });

  group('E. the post card', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// [post] without the images of its author (nothing to load in a widget test).
    Post bare(Post post) => post.copyWith(
      author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
      userBriefProfile: null,
      postMedals: null,
      badge: null,
      secondBadge: null,
      signature: null,
      pokemon: null,
      checkin: null,
    );

    /// Turn the experimental renderer [on] (the database and the settings stream run outside the fake clock).
    Future<void> setRenderer(WidgetTester tester, {required bool on}) async {
      await tester.runAsync(() async {
        await settings.setValue(SettingsKeys.enableAppPostRenderer, on);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
    }

    Future<void> pumpCards(WidgetTester tester, List<Post> posts, {SmiliesRepository? smilies}) async {
      Widget app = MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: Column(children: [for (final p in posts) PostCard(p)])),
        ),
      );
      if (smilies != null) {
        app = RepositoryProvider<SmiliesRepository>.value(value: smilies, child: app);
      }
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(child: app),
        ),
      );
      await tester.pump();
    }

    testWidgets('the setting is off by default: the floor is the html exactly as before', (tester) async {
      expect(SettingsKeys.enableAppPostRenderer.defaultValue, isFalse);
      expect(settings.currentSettings.enableAppPostRenderer, isFalse);
      final post = bare(_post('thread_v14_plain.json', 0));
      expect(decidePostBbcode(post), isA<PostBbcodeRender>(), reason: 'a floor the app could draw');
      await pumpCards(tester, [post]);
      expect(tester.widgetList<MunchedHtml>(find.byType(MunchedHtml)).map((e) => e.html), [post.data]);
      expect(find.byType(PostBbcodeBody), findsNothing);
      expect(find.byType(PostBbcodeView), findsNothing);
    });

    testWidgets('the setting on: a floor the app draws from bbcode, a withheld one as html', (tester) async {
      await setRenderer(tester, on: true);
      final drawn = bare(_post('thread_v14_plain.json', 0));
      final withheld = bare(_post('thread_v14_moderate.json', 1));
      await pumpCards(tester, [drawn, withheld]);
      expect(find.byType(PostBbcodeBody), findsNWidgets(2));
      expect(find.byType(PostBbcodeView), findsOneWidget);
      expect(find.textContaining('原生发帖页。', findRichText: true), findsOneWidget);
      final htmls = tester.widgetList<MunchedHtml>(find.byType(MunchedHtml)).map((e) => e.html).toList();
      expect(htmls, contains(withheld.data));
      expect(htmls, isNot(contains(drawn.data)), reason: 'only the html around the message of the drawn floor');
      expect(htmls.where((e) => e.contains('modact')), hasLength(1));

      // Back off: the html again.
      await setRenderer(tester, on: false);
      expect(find.byType(PostBbcodeView), findsNothing);
      expect(tester.widgetList<MunchedHtml>(find.byType(MunchedHtml)).map((e) => e.html), [drawn.data, withheld.data]);
    });

    testWidgets('a rich floor drawn: quote, code, spoiler, list, links, attachment placeholders', (
      tester,
    ) async {
      final render = _render(_firstFloorWithoutMedia('thread_v14_attachments.json'), smilies: _table());
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PostBbcodeView(_withoutImages(render.nodes)),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(QuotedText), findsOneWidget);
      expect(find.byType(CodeCard), findsOneWidget);
      expect(find.byType(SpoilerCard), findsOneWidget);
      expect(find.textContaining('•  一', findRichText: true), findsOneWidget);
      expect(find.byIcon(Icons.link), findsOneWidget, reason: 'the [url] link, not the bare one');
      expect(find.textContaining('tsdmapp270_paid.png\n${t.postCard.bbcode.attachmentLocked}'), findsOneWidget);
      expect(find.textContaining('連結', findRichText: true), findsOneWidget);
      expect(find.textContaining('https://example.com/auto', findRichText: true), findsOneWidget);
      expect(find.textContaining('粗體 紅字 大字', findRichText: true), findsOneWidget, reason: 'the spaces kept');
      expect(find.text('標題'), findsOneWidget, reason: 'the spoiler title on its button');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a floor with smilies waits for the table as html, then is drawn from bbcode', (tester) async {
      await setRenderer(tester, on: true);
      final post = bare(_synthetic('[b]bold[/b] text', smileyoff: 0));
      final answer = Completer<Map<String, dynamic>?>();
      var fetches = 0;
      final repo = SmiliesRepository(
        store: _MemoryStore(),
        fetch: () {
          fetches++;
          return answer.future;
        },
      );
      addTearDown(repo.dispose);
      await pumpCards(tester, [post], smilies: repo);
      expect(fetches, 1, reason: 'the table of the version the answer names is asked');
      expect(find.byType(PostBbcodeView), findsNothing);
      expect(tester.widgetList<MunchedHtml>(find.byType(MunchedHtml)).map((e) => e.html), [post.data]);

      answer.complete({..._json('thread_v14_smilies.json'), 'version': post.smiliesVersion});
      await tester.pump();
      await tester.pump();
      expect(fetches, 1);
      expect(find.byType(PostBbcodeView), findsOneWidget);
      expect(find.textContaining('bold text', findRichText: true), findsOneWidget);
    });

    testWidgets('the switch in the advanced settings: off by default, toggled, kept for the next run', (tester) async {
      getIt
        ..registerSingleton<AppDatabase>(db)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter()),
        );
      tester.view
        ..physicalSize = const Size(384, 792)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final theme = ThemeCubit();
      addTearDown(theme.close);
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      Future<bool?> stored() => tester.runAsync(() => settings.getValue(SettingsKeys.enableAppPostRenderer));

      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: bloc),
            BlocProvider<ThemeCubit>.value(value: theme),
          ],
          child: TranslationProvider(child: const MaterialApp(home: SettingsPage())),
        ),
      );
      await settle();
      final tile = find.byKey(const ValueKey('settings-app-post-renderer'));
      final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(tile, 200, scrollable: list);
      await settle();
      final tr = t.settingsPage.advancedSection.appPostRenderer;
      expect(find.descendant(of: tile, matching: find.text(tr.title)), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text(tr.detail)), findsOneWidget);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse, reason: 'off by default');

      await tester.tap(tile);
      await settle();
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      expect(settings.currentSettings.enableAppPostRenderer, isTrue);
      expect(await stored(), isTrue);
      // The next run reads it back from the database.
      final next = SettingsRepository(getIt.get<StorageProvider>());
      await tester.runAsync(next.init);
      expect(next.currentSettings.enableAppPostRenderer, isTrue);
      await tester.runAsync(next.dispose);

      await tester.tap(tile);
      await settle();
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(await stored(), isFalse);
    });

    testWidgets('a spoofed floor shows a neutral line instead of an empty floor, with either renderer', (tester) async {
      final posts = _posts(_json('thread_v14_spoofed.json')).map(bare).toList();
      final spoofed = posts.where((e) => e.isSpoofed).toList();
      expect(spoofed, hasLength(2));
      for (final on in [false, true]) {
        await setRenderer(tester, on: on);
        await pumpCards(tester, posts);
        expect(
          find.text(t.postCard.contentUnavailable, skipOffstage: false),
          findsNWidgets(2),
          reason: 'renderer on: $on',
        );
        final bodies = find.byType(on ? PostBbcodeBody : MunchedHtml, skipOffstage: false);
        expect(bodies, findsNWidgets(posts.length - spoofed.length), reason: 'no body for the spoofed floors');
      }
    });
  });

  group('F. floors the forum gives nothing of, and blocked quotes', () {
    test('a spoofed floor: no content, no bbcode, no reply; the author stays', () {
      final json = _json('thread_v14_spoofed.json');
      final posts = _posts(json);
      final raws = (json['posts'] as List).cast<Map<String, dynamic>>();
      final index = raws.indexWhere((e) => e['message_reason'] == 'spoofed');
      final post = posts[index];
      expect(post.isSpoofed, isTrue);
      expect(post.data, isEmpty);
      expect(post.messageBbcode, isNull);
      expect(post.attachments, isEmpty);
      expect(post.replyAction, isNull, reason: 'can.reply 0');
      expect(post.rate, isNull);
      expect(post.poll, isNull);
      expect(post.packetUrl, isNull);
      expect((post.lastEditUsername, post.lastEditTime), (null, null));
      expect(post.author.name, raws[index]['author']);
      expect(post.author.uid, '${raws[index]['authorid']}');
      expect(_fallback(post), 'spoofed');
      expect(posts.where((e) => e.isSpoofed), hasLength(2));
      expect(posts.first.isSpoofed, isFalse);
      expect(_render(posts.first).nodes, isNotEmpty);
    });

    test('a custom code with a hidden part is withheld; unknown tags and odd attachment ids keep the html', () {
      final posts = _posts(_json('thread_v14_customcode.json'));
      expect(_fallback(posts[1]), 'hide');
      expect(_fallback(posts[2]), 'tag:index');
    });

    testWidgets('a floor whose blocked quote is redacted drops its bbcode too', (tester) async {
      const aliceUid = 1000;
      const bobUid = 1001;
      final repository = UserBlockRepository(_MemoryBlockList());
      await repository.block(ownerUid: aliceUid, uid: bobUid, username: 'Bob');
      final cubit = UserBlockCubit(
        repository: repository,
        currentUid: () => aliceUid,
        authStatus: const Stream<AuthStatus>.empty(),
      );
      addTearDown(() async {
        await cubit.close();
        await repository.dispose();
      });
      final plain = _post('thread_v14_plain.json', 0);
      final bobPost = plain.copyWith(
        postID: '1',
        author: const User(name: 'Bob', uid: '$bobUid', url: 'home.php?mod=space&uid=$bobUid'),
      );
      const link = 'forum.php?mod=redirect&amp;goto=findpost&amp;pid=1&amp;ptid=5';
      const quote =
          '<div class="quote"><blockquote><font size="2"><a href="$link"><font color="#999999">Bob '
          '发表于 2026-9-5 17:38</font></a></font><br>SECRET</blockquote></div>';
      final reply = plain.copyWith(
        postID: '3',
        author: const User(name: 'Alice', uid: '$aliceUid', url: 'home.php?mod=space&uid=$aliceUid'),
        data: '<td id="postmessage_3">$quote reply</td>',
        messageBbcode: '[quote]SECRET[/quote] reply',
      );
      final built = <Post>[];
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: BlocProvider.value(
              value: cubit,
              child: Scaffold(
                body: Column(
                  children: [
                    for (final post in [bobPost, reply])
                      BlockAwarePost(
                        post: post,
                        postList: [bobPost, reply],
                        builder: (_, p) {
                          built.add(p);
                          return Text(p.postID);
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final shown = built.lastWhere((e) => e.postID == '3');
      expect(shown.data, isNot(contains('SECRET')));
      expect(shown.messageBbcode, isNull);
      expect(shown.messageReason, 'blocked-quote');
      expect(decidePostBbcode(shown), isA<PostBbcodeFallback>());
    });
  });

  group('G. what the review found', () {
    const listed = {
      'aid': 1,
      'filename': 'a.png',
      'isimage': 1,
      'url': 'https://www.tsdm39.com/data/attachment/forum/a.png',
      'locked': 0,
      'inpost': 1,
    };

    test('a [code] or an [attach] inside an attribute or an [img] keeps the html, nothing is asked for', () {
      expect(
        _fallback(_synthetic('[spoiler=[attach]1[/attach]]x[/spoiler]', attachments: [listed])),
        'placeholder-in-attribute',
      );
      expect(
        _fallback(_synthetic('[url=[attach]1[/attach]]x[/url]', attachments: [listed])),
        'placeholder-in-attribute',
      );
      expect(_fallback(_synthetic('[img][attach]1[/attach][/img]', attachments: [listed])), 'img-url');
      expect(_fallback(_synthetic('[img][code]x[/code][/img]')), 'img-url');
      expect(_fallback(_synthetic('[color=[code]red[/code]]x[/color]')), 'placeholder-in-attribute');
    });

    test("an [img] off the forum's image whitelist keeps the html; without the field nothing changes", () {
      const whitelist = {
        'imgwhitelist': {
          'enabled': 1,
          'domains': ['example.com', 'img.example.org'],
        },
      };
      String? image(String bbcode, Map<String, Object?> codes) {
        final decision = decidePostBbcode(_synthetic(bbcode, codes: codes));
        return switch (decision) {
          PostBbcodeRender(:final nodes) => (nodes.single as BbImage).url,
          PostBbcodeFallback(:final reason) => 'fallback $reason',
        };
      }

      expect(image('[img]https://example.com/a.png[/img]', whitelist), 'https://example.com/a.png');
      expect(image('[img]https://i.example.com/a.png[/img]', whitelist), 'https://i.example.com/a.png');
      expect(image('[img]http://cdn.img.example.org/b.png[/img]', whitelist), 'http://cdn.img.example.org/b.png');
      expect(image('[img]https://www.tsdm39.com/c.png[/img]', whitelist), 'https://www.tsdm39.com/c.png');
      expect(image('[img]static/image/x.png[/img]', whitelist), 'https://www.tsdm39.com/static/image/x.png');
      expect(image('[img]https://evil.org/a.png[/img]', whitelist), 'fallback img-not-whitelisted');
      expect(image('[img]https://example.org/a.png[/img]', whitelist), 'fallback img-not-whitelisted');
      final off = {
        'imgwhitelist': {'enabled': 0, 'domains': <String>[]},
      };
      expect(image('[img]https://evil.org/a.png[/img]', off), 'https://evil.org/a.png');
      expect(image('[img]https://evil.org/a.png[/img]', const {}), 'https://evil.org/a.png');
      expect(_synthetic('x', codes: whitelist).bbcodeCodes!.imgWhitelist, ['example.com', 'img.example.org']);
      expect(_synthetic('x').bbcodeCodes!.imgWhitelist, isNull);
    });

    test('a bracket left open at the end, odd image sizes, empty quotes keep the html', () {
      expect(_fallback(_synthetic('text [b=xyz')), 'unclosed-bracket');
      expect(
        _fallback(_synthetic('[list][*]a [b=x[/list]')),
        startsWith('literal-tag:'),
        reason: 'the open bracket swallows the list tail: the list itself is left as text',
      );
      expect(_fallback(_synthetic('a [ b')), 'unclosed-bracket');
      expect(_plain(_render(_synthetic('a [ b ] c')).nodes), 'a [ b ] c', reason: 'closed later: drawn as text');
      expect(_fallback(_synthetic('[img=12345,1]https://example.com/a.png[/img]')), 'img-size');
      expect(_fallback(_synthetic('[img=]https://example.com/a.png[/img]')), 'img-size');
      expect(_fallback(_synthetic('[quote][/quote]')), 'quote-empty');
      expect(_fallback(_synthetic('[free][/free]')), 'free-empty');
    });

    test('[url=] goes where the forum sends it: the attribute as written, no bracket in it', () {
      BbLink link(String bbcode) => _render(_synthetic(bbcode)).nodes.single as BbLink;
      expect(link('[url= https://a.example/]x[/url]').href, 'https://www.tsdm39.com/ https://a.example/');
      expect(
        link('[url=forum.php?mod=viewthread&tid=1]x[/url]').href,
        'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1',
      );
      expect(link('[url=https://a.example/b]x[/url]').href, 'https://a.example/b');
      expect(_plain(link('[url=https://a.example/b]x[/url]').children), 'x');
      expect(_fallback(_synthetic('[url=a[b]x[/url]')), 'url-attr');
    });

    test('[spoiler] only where the answer says the forum expands it', () {
      expect(_fallback(_synthetic('[spoiler=t]x[/spoiler]', customtags: null)), 'custom:spoiler');
      expect(_fallback(_synthetic('[spoiler=t]x[/spoiler]', customtags: const ['ruby'])), 'custom:spoiler');
      final shown = _render(_synthetic('[spoiler=t]x[/spoiler]', customtags: const ['Spoiler']));
      expect((shown.nodes.single as BbSpoiler).title, 't');
      expect(_plain((shown.nodes.single as BbSpoiler).children), 'x');
      expect(_fallback(_synthetic('[ruby]x[/ruby]', customtags: const ['ruby'])), 'tag:ruby', reason: 'not drawn');
    });

    test('literal floors with an ed2k or attach link keep the html', () {
      expect(_fallback(_synthetic('see ed2k://|file|a|1|h|/', bbcodeoff: 1)), 'special-url');
      expect(_fallback(_synthetic('see attach://1.png', bbcodeoff: 1)), 'special-url');
    });

    test('an old quote header: the back arrow is the jump button of the html renderer', () {
      const header =
          '[quote][size=2][color=#999999]Bob 发表于 2020-1-1 12:00[/color] '
          '[url=forum.php?mod=redirect&goto=findpost&pid=1&ptid=2][img]static/image/common/back.gif[/img][/url][/size]\r\n'
          'quoted words[/quote]';
      final quote = _render(_synthetic(header)).nodes.single as BbQuote;
      final link = _all(quote.children).whereType<BbLink>().single;
      expect(link.href, 'https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&pid=1&ptid=2');
      expect((link.children.single as BbImage).url, 'https://www.tsdm39.com/static/image/common/back.gif');
      expect(_plain(quote.children), 'Bob 发表于 2020-1-1 12:00 \nquoted words');
    });

    testWidgets('the back arrow renders as the button, not as an image', (tester) async {
      const header =
          '[quote][size=2][color=#999999]Bob 发表于 2020-1-1 12:00[/color] '
          '[url=forum.php?mod=redirect&goto=findpost&pid=1&ptid=2][img]static/image/common/back.gif[/img][/url][/size]\r\n'
          'quoted words[/quote]';
      final nodes = _render(_synthetic(header)).nodes;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: Scaffold(body: PostBbcodeView(nodes))),
        ),
      );
      await tester.pump();
      final button = find.widgetWithIcon(IconButton, Icons.navigate_before_outlined);
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(button).onPressed, isNotNull);
      expect(tester.widget<IconButton>(button).tooltip, t.workaroundRedirect);
      expect(find.byType(NetworkIndicatorImage), findsNothing);
      expect(find.textContaining('quoted words', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('the saved table is read ahead once the renderer is on, never before', () async {
      final store = _MemoryStore()
        ..data = jsonEncode({
          'version': 'v1',
          'smilies': [
            {'id': '7', 'code': ':)', 'url': 'https://www.tsdm39.com/a.gif', 'type': 'default'},
            {'id': 'x', 'code': ':(', 'url': 'https://www.tsdm39.com/b.gif'},
          ],
        });
      var reads = 0;
      final counting = _CountingStore(store, () => reads++);
      final on = StreamController<bool>();
      var fetches = 0;
      final repo = SmiliesRepository(
        store: counting,
        fetch: () async {
          fetches++;
          return null;
        },
        preloadWhen: on.stream,
      );
      addTearDown(() async {
        repo.dispose();
        await on.close();
      });
      on.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(reads, 0, reason: 'the renderer is off: nothing read');
      on.add(true);
      await Future<void>.delayed(Duration.zero);
      await repo.preload();
      expect(reads, 1);
      final table = repo.tableFor('v1');
      expect(table, isNotNull, reason: 'kept before any floor asks: no html first');
      expect(table!.smilies.map((e) => (e.id, e.code)), [(7, ':)'), (0, ':(')]);
      on.add(true);
      await repo.ensure('v1');
      expect((reads, fetches), (1, 0));
    });
  });
}

/// A [SmiliesStore] counting its reads.
final class _CountingStore implements SmiliesStore {
  _CountingStore(this._inner, this._onRead);

  final SmiliesStore _inner;
  final void Function() _onRead;

  @override
  Future<String?> read() {
    _onRead();
    return _inner.read();
  }

  @override
  Future<void> write(String data) => _inner.write(data);
}
