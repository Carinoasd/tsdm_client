/// The poster's IP of a floor for a moderator (tsdmapp 3.9.0 §11.1): the floor offers it where `can.viewip` is 1 with
/// its `urls.viewip` (the url alone is not enough: the test forum gives it on floors of a higher rank too, with
/// `can.viewip` 0); the window is the small form `getip` asked with `tsdmapp=json&tsdmform=1&nodoc=1`, only for the
/// forum's own `topicadmin&action=getip` of that floor; the IP, its port and place are shown and the IP copied on a
/// long press; the forum's refusal (a rank above) is told in its words.
///
/// The answers are the test forum's (scrubbed: the IP and the admin centre links are documentation addresses).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/thread_admin_forms.dart';
import 'package:tsdm_client/features/moderate/repository/thread_admin_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/thread_admin_dialogs.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path.json').readAsStringSync()) as Map<String, dynamic>;

const _url = '$baseUrl/forum.php?mod=topicadmin&action=getip&fid=2&tid=9202952&pid=11736';

ThreadAdminRepository _repo({required Object? answer, int uid = 32, List<String>? asked}) => ThreadAdminRepository(
  get: (url) async {
    asked?.add(url);
    return right((statusCode: 200, data: answer));
  },
  post: (_, _) async => throw StateError('nothing is posted'),
  currentUid: () => uid,
);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('floor', () {
    test('offered where can.viewip is 1, with the url the forum gives', () {
      final json = _json('tsdmapp_390/thread_viewip');
      final page = threadPageFromApi(threadApiAnswerOf(json)!, 1);
      expect(page.perms!.allowViewIp, isTrue);
      expect(
        page.postList.single.viewIpUrl,
        '$baseUrl/forum.php?mod=topicadmin&action=getip&fid=2&tid=9203116&pid=15505',
      );

      // A floor of a higher rank: the url is there, can.viewip 0.
      final floor = (json['posts'] as List).single as Map<String, dynamic>;
      (floor['can'] as Map<String, dynamic>)['viewip'] = 0;
      expect(threadPageFromApi(threadApiAnswerOf(json)!, 1).postList.single.viewIpUrl, isNull);
      // An older plugin: neither.
      (floor['can'] as Map<String, dynamic>).remove('viewip');
      (floor['urls'] as Map<String, dynamic>).remove('viewip');
      expect(threadPageFromApi(threadApiAnswerOf(json)!, 1).postList.single.viewIpUrl, isNull);
    });

    test("only the forum's own IP window of that floor", () {
      expect(isFloorIpUrl(_url, pid: 11736), isTrue);
      expect(isFloorIpUrl('forum.php?mod=topicadmin&action=getip&fid=2&tid=9202952&pid=11736', pid: 11736), isTrue);
      expect(isFloorIpUrl(_url, pid: 11737), isFalse);
      expect(isFloorIpUrl(_url.replaceFirst('getip', 'delpost'), pid: 11736), isFalse);
      expect(isFloorIpUrl('https://example.com/forum.php?mod=topicadmin&action=getip&pid=11736', pid: 11736), isFalse);
      expect(isFloorIpUrl('$_url&pid=1', pid: 11736), isFalse);
    });
  });

  group('window', () {
    test('the small form getip: the IP, the port, the place', () async {
      final asked = <String>[];
      final answer = await _repo(answer: _json('moderate/getip'), asked: asked).fetchFloorIp(_url, pid: 11736);
      final ip = (answer.getRight().toNullable()! as ThreadAdminWindowReady<FloorIp>).value;
      expect(
        (ip.uid, ip.pid, ip.author, ip.ip, ip.port, ip.location),
        (
          32,
          11736,
          'ag_admin',
          '203.0.113.5',
          42204,
          'Reserved',
        ),
      );
      final query = Uri.parse(asked.single).queryParameters;
      expect((query['tsdmapp'], query['tsdmform'], query['nodoc'], query['pid']), ('json', '1', '1', '11736'));
    });

    test("refused in the forum's words; another account's, or another url, is never read", () async {
      final refused = await _repo(answer: _json('moderate/getip_refused'), uid: 70).fetchFloorIp(_url, pid: 11736);
      expect(
        (refused.getRight().toNullable()! as ThreadAdminWindowRefused<FloorIp>).message,
        '抱歉，您没有权限查看更高级别的管理员 IP',
      );
      final other = await _repo(answer: _json('moderate/getip'), uid: 35).fetchFloorIp(_url, pid: 11736);
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
      final floor = await _repo(answer: _json('moderate/getip')).fetchFloorIp(_url, pid: 11737);
      expect(floor.isLeft(), isTrue);
      final asked = <String>[];
      await _repo(answer: _json('moderate/getip'), asked: asked).fetchFloorIp('https://example.com/x', pid: 11736);
      expect(asked, isEmpty);
    });

    testWidgets('shown, the IP copied on a long press', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: Scaffold(
              body: FloorIpDialog(
                url: _url,
                pid: 11736,
                repository: _repo(answer: _json('moderate/getip')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('203.0.113.5'), findsOneWidget);
      expect(find.text(':42204 · Reserved'), findsOneWidget);
      await tester.longPress(find.byKey(const ValueKey('floor-ip')));
      await tester.pumpAndSettle();
      expect(copied, ['203.0.113.5']);
    });
  });
}
