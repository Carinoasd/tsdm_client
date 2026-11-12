/// Rating in batches (tsdmapp 3.9.0 second round, `action=batchrate`, schema 32): what the entry answer tells (the
/// forum's switches, the credits with their quota, the reasons, the anti-flood defaults, the limits, the forms), a
/// tampered form never used, the batch rate plugin's own `version` never taken for the app API's, and the entry asked
/// only when `status` says batch rating is on for the account (kept per account and forum).
///
/// The answers are the test forum's (scrubbed).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/utils/batch_rate_access.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>;

BatchRateRepository _repo({
  Map<String, dynamic>? Function(Map<String, String> query)? answer,
  List<Map<String, String>>? asked,
  int Function()? uid,
}) => BatchRateRepository(
  ask: (query) async {
    asked?.add(query);
    return answer == null ? _fixture('batchrate_info_can') : answer(query);
  },
  get: (_) async => throw UnimplementedError(),
  post: (_, _) async => throw UnimplementedError(),
  currentUid: uid ?? () => 31,
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(BatchRateAccess.reset);

  group('answer', () {
    test('a moderator of the forum: the credits, the reasons, the switches, the limits, the forms', () {
      final info = BatchRateInfo.fromJson(_fixture('batchrate_info_can'))!;
      expect(info.uid, 31);
      expect(info.formHash, 'f1f2f3f4');
      expect((info.usable, info.can, info.why, info.canList), (true, true, '', true));
      expect((info.entryList, info.entryThread), (true, true));
      expect((info.offersList, info.offersThread, info.offersBatches), (true, true, true));
      expect((info.maxTotal, info.chunk, info.multMax, info.floorSegments), (500, 50, 99, 50));
      expect(info.fid, 2);
      expect(info.credits.single.id, 6);
      expect(info.credits.single.title, '精灵');
      expect((info.credits.single.min, info.credits.single.max), (-20, 100));
      expect((info.credits.single.daily, info.credits.single.left), (500, 500));
      expect(info.reasonRequired, isFalse);
      expect(info.notifyForced, isFalse);
      expect(info.reasonChoices, ['很给力!', '神马都是浮云', '赞一个!', '山寨', '淡定']);
      expect(info.antispam, (locked: false, rated: true, same: true));
      expect((info.threadTid, info.threadAuthor), (1019, 'gl_dave'));
      expect(info.confirmUrl, '$baseUrl/plugin.php?id=batchrate:rate');
      expect(info.listUrl, '$baseUrl/plugin.php?id=batchrate:list');
    });

    test('without a forum: the batches only; a group that may not rate: nothing', () {
      final nofid = BatchRateInfo.fromJson(_fixture('batchrate_info_nofid'))!;
      expect((nofid.can, nofid.why, nofid.fid), (false, 'fid', 0));
      expect((nofid.offersList, nofid.offersThread, nofid.offersBatches), (false, false, true));
      final norate = BatchRateInfo.fromJson(_fixture('batchrate_info_norate'))!;
      expect((norate.can, norate.why, norate.canList), (false, 'norate', false));
      expect((norate.offersList, norate.offersThread, norate.offersBatches), (false, false, false));
    });

    test('the forum turned an entry off, the plugin missing or too old, not this answer', () {
      final can = _fixture('batchrate_info_can');
      final noList = BatchRateInfo.fromJson({
        ...can,
        'entry': {'list': 0, 'thread': 1},
      })!;
      expect((noList.offersList, noList.offersThread), (false, true));
      final notMod = BatchRateInfo.fromJson({...can, 'can': 0, 'why': 'notmod'})!;
      expect((notMod.offersList, notMod.offersThread), (false, false));
      final missing = BatchRateInfo.fromJson({'ok': 1, 'uid': 31, 'type': 'batchrate', 'schema': 32, 'installed': 0})!;
      expect((missing.usable, missing.offersList, missing.offersBatches), (false, false, false));
      final old = BatchRateInfo.fromJson({...can, 'supported': 0, 'can': 0})!;
      expect((old.usable, old.offersThread), (false, false));
      expect(BatchRateInfo.fromJson({'ok': 0, 'error': 'action'}), isNull);
      expect(BatchRateInfo.fromJson({'ok': 1, 'type': 'admin'}), isNull);
      expect(BatchRateInfo.fromJson(null), isNull);
    });

    test('a form or a link going anywhere but the plugin is never used', () {
      final can = _fixture('batchrate_info_can');
      final forms = can['forms'] as Map<String, dynamic>;
      for (final url in [
        'https://evil.test/plugin.php?id=batchrate:rate',
        'plugin.php?id=other:rate',
        'forum.php?mod=post&id=batchrate:rate',
        'plugin.php?id=batchrate:rate&next=https://evil.test',
      ]) {
        final info = BatchRateInfo.fromJson({
          ...can,
          'forms': {
            ...forms,
            'confirm': {...forms['confirm'] as Map<String, dynamic>, 'url': url},
            'list_url': url,
          },
        })!;
        expect(info.confirmUrl, isNull, reason: url);
        expect(info.listUrl, isNull, reason: url);
        expect((info.offersList, info.offersThread, info.offersBatches), (false, false, false), reason: url);
      }
      expect(
        BatchRateForm.urlOf('plugin.php?id=batchrate:list&bract=detail&batchid=5'),
        '$baseUrl/plugin.php?id=batchrate:list&bract=detail&batchid=5',
      );
    });

    test("the batch rate plugin's version is never taken for the app API's", () {
      expect(TsdmAppPluginInfo.fromAnswer(_fixture('batchrate_info_can')), isNull);
      expect(TsdmAppPluginInfo.fromAnswer({'ok': 1, 'version': '3.9.0', 'actions': <String>[]})!.version, '3.9.0');
    });
  });

  group('repository', () {
    test('asks with the forum and the thread; an answer for another account is dropped', () async {
      final asked = <Map<String, String>>[];
      final info = await _repo(asked: asked).info(fid: 2, tid: 1019);
      expect(info?.can, isTrue);
      expect(asked, [
        {'fid': '2', 'tid': '1019'},
      ]);
      await expectLater(_repo(uid: () => 99).info(fid: 2), throwsA(isA<IdentityChangedException>()));
      expect(await _repo(answer: (_) => null).info(fid: 2), isNull);
    });
  });

  group('access', () {
    Map<String, dynamic> status(int on, {int uid = 31}) => {'ok': 1, 'uid': uid, 'version': '3.9.0', 'batchrate': on};

    test('status off: the forum is never asked', () async {
      final asked = <Map<String, String>>[];
      var statusAsked = 0;
      final info = await BatchRateAccess.check(
        31,
        fid: 2,
        status: () async {
          statusAsked++;
          return status(0);
        },
        repository: _repo(asked: asked),
      );
      expect(info, isNull);
      expect(asked, isEmpty);
      // Kept: asked again, nothing is sent.
      expect(await BatchRateAccess.check(31, fid: 7, status: () async => throw StateError('asked')), isNull);
      expect(statusAsked, 1);
    });

    test('status on: the forum asked once per account and forum, the status once per account', () async {
      final asked = <Map<String, String>>[];
      var statusAsked = 0;
      Future<Map<String, dynamic>?> st() async {
        statusAsked++;
        return status(1);
      }

      final repo = _repo(asked: asked);
      final first = await BatchRateAccess.check(31, fid: 2, status: st, repository: repo);
      expect(first?.offersList, isTrue);
      final again = await BatchRateAccess.check(31, fid: 2, status: st, repository: repo);
      expect(identical(first, again), isTrue);
      final batches = await BatchRateAccess.check(
        31,
        status: st,
        repository: _repo(asked: asked, answer: (_) => _fixture('batchrate_info_nofid')),
      );
      expect(batches?.offersBatches, isTrue);
      expect(asked, [
        {'fid': '2'},
        <String, String>{},
      ]);
      expect(statusAsked, 1);
      expect(BatchRateAccess.cached(31, fid: 2), same(first));
      BatchRateAccess.forget(31, fid: 2);
      expect(BatchRateAccess.cached(31, fid: 2), isNull);
    });

    test('a status of another account, an account changed meanwhile, nothing kept', () async {
      final repo = _repo();
      expect(await BatchRateAccess.check(31, fid: 2, status: () async => status(1, uid: 35), repository: repo), isNull);
      expect(
        await BatchRateAccess.check(
          31,
          fid: 2,
          status: () async => status(1),
          repository: repo,
          stillCurrent: () => false,
        ),
        isNull,
      );
      expect(BatchRateAccess.cached(31, fid: 2), isNull);
      expect(await BatchRateAccess.check(31, fid: 2, status: () async => null, repository: repo), isNull);
    });
  });
}
