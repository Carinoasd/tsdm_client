import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:universal_html/parsing.dart';

const _atUserXml = '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[Alice,Bob, Carol,]]></root>';

/// Serves the official `@` user list and records every request.
final class _FakeAdapter implements HttpClientAdapter {
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(
      _atUserXml,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('official mention format', () {
    test('the editor embed becomes @name followed by a space', () {
      expect(toOfficialMentions('hi [@]Alice[/@]!'), 'hi @Alice !');
      expect(toOfficialMentions('[@]Alice[/@] and [@]Bob[/@]'), '@Alice and @Bob ');
      expect(toOfficialMentions('[@] Alice [/@]'), '@Alice ');
    });

    test('no extra space when whitespace already follows', () {
      expect(toOfficialMentions('[@]Alice[/@] ok'), '@Alice ok');
      expect(toOfficialMentions('[@]Bob[/@]\nnext'), '@Bob\nnext');
    });

    test('a name with brackets is kept whole', () {
      expect(toOfficialMentions('hi [@][TSDM]Alice[/@]!'), 'hi @[TSDM]Alice !');
      expect(toOfficialMentions('[@]a]b[/@] [@]x[y[/@]'), '@a]b @x[y ');
      expect(toOfficialMentions('[@]x and [@]Bob[/@]'), '[@]x and @Bob ', reason: 'a literal [@] is not a chip');
    });

    test('other content is untouched', () {
      expect(toOfficialMentions('no mention [b]bold[/b] @plain'), 'no mention [b]bold[/b] @plain');
      expect(toOfficialMentions(''), '');
    });
  });

  group('official @ user list', () {
    test('comma separated names inside CDATA', () {
      expect(parseAtUserList(_atUserXml), ['Alice', 'Bob', 'Carol']);
    });

    test('empty list and non xml responses', () {
      expect(parseAtUserList('<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[]]></root>'), isEmpty);
      expect(parseAtUserList('<html><body>提示信息</body></html>'), isEmpty);
      expect(parseAtUserList(''), isEmpty);
    });
  });

  group('EditorRepository on X5', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _FakeAdapter adapter;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _FakeAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
        );
      await settings.init();
    });
    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('searches the official getatuser list locally and fetches it once', () async {
      final repo = EditorRepository();
      final all = await repo.loadAtUsers().run();
      expect(all.toNullable(), ['Alice', 'Bob', 'Carol']);
      final uri = adapter.requests.single;
      expect(uri.host, baseHost);
      expect(uri.path, '/misc.php');
      expect(uri.queryParameters, containsPair('mod', 'getatuser'));
      expect(uri.queryParameters, containsPair('inajax', '1'));

      final hit = await repo.searchUserByName(keyword: 'bo').run();
      expect(hit.toNullable(), ['Bob']);
      final miss = await repo.searchUserByName(keyword: 'zed').run();
      expect(miss.toNullable(), isEmpty);
      final everyone = await repo.searchUserByName(keyword: '  ').run();
      expect(everyone.toNullable(), ['Alice', 'Bob', 'Carol']);
      expect(adapter.requests, hasLength(1), reason: 'searching filters the cached list, like the official at.js');

      await repo.loadAtUsers().run();
      expect(adapter.requests, hasLength(2), reason: 'an explicit reload asks the server again');
    });
  });

  // Since the red packet feature the entry becomes a card (a WidgetSpan); its texts and the plugin css never show up
  // as plain text in the post body.
  testWidgets('the red packet entry of a post does not render as text', (tester) async {
    String? plain;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            final body = parseHtmlDocument('''
<div class="pcb"><div class="pcbs">
<div class="hb-entry claimed" data-tid="1264928" onclick="hongbaoOpen(this)"><div class="icon"></div>
<div><div class="t1">許哥牛逼</div><div class="t2">均分紅包 · 剩 0/25 份 · 已被搶光</div></div>
<div class="claimed-mark">已被搶光</div></div>
<style>.hb-entry{width:250px}</style>
<div class="t_fsz">post body</div></div></div>
''').body!;
            final rendered = munchElement(context, body);
            if (rendered is ConstrainedBox && rendered.child is Text) {
              plain = (rendered.child! as Text).textSpan!.toPlainText();
            }
            return const SizedBox();
          },
        ),
      ),
    );
    expect(plain, isNotNull);
    expect(plain, contains('post body'));
    expect(plain, isNot(contains('均分紅包')));
    expect(plain, isNot(contains('已被搶光')));
    expect(plain, isNot(contains('width:250px')));
  });
}
