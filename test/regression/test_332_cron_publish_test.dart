/// A new thread published later, set in the editor.
///
/// A member whose group may set the publication time (`allowsetpublishdate`) gets the `cronpublish` block in the form
/// of a new thread (plugin 2.9.0, `post_v16`): the `cronpublish` checkbox and the `cronpublishdate` text. Posted with a
/// time ahead, the forum (newthread.php) keeps the thread a draft (`save` forced to 1, `displayorder` -4, the time as
/// its `dateline`) and lists it in the `cronpublish` cache, which `cron_publish_halfhourly` publishes once the time
/// has come; a time already passed publishes it now. The time is read with `strtotime()` in the member's time zone:
/// the app posts the wall clock of the answer's offset (`timeoffset`, the forum's +8 when the answer names none) of
/// the instant picked on the device.
///
/// `post_v16_newthread_cronpublish.json` is the plugin's 3.4.0 answer on the test forum for a group allowed to set the
/// time, scrubbed as the other `post_v16_*` fixtures.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/widgets/cron_publish_dialog.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _cron() => _json('post_v16_newthread_cronpublish');

PostForm _form([Map<String, dynamic>? json]) => PostForm.fromJson(json ?? _cron())!;

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

/// 2026-11-09 12:00 at +8.
final _at = DateTime.utc(2026, 11, 9, 4);

Map<String, dynamic> _thread({required int draft}) {
  final json = _json('thread_v3_plain');
  return {
    ...json,
    'uid': 31,
    'thread': {...json['thread'] as Map<String, dynamic>, 'draft': draft},
  };
}

Future<(PostEditState, Map<String, String>)> _post({
  DateTime? at,
  int draft = 1,
  String save = '',
  Map<String, dynamic>? thread,
}) async {
  final posts = <Map<String, String>>[];
  final repo = PostEditRepository.withTransport(
    currentUid: () => 31,
    getPage: (url) async => right(_response(url.contains('viewthread') ? thread ?? _thread(draft: draft) : _cron())),
    sendForm: (url, body) async {
      posts.add(body);
      return right(
        _response({
          'ok': 1,
          'api': 1,
          'uid': 31,
          'formhash': 'f1f2f3f4',
          'type': 'result',
          'schema': 13,
          'kind': 'redirect',
          'message': '',
          'message_key': 'post_newthread_succeed',
          'url': 'forum.php?mod=viewthread&tid=9600060&extra=',
          'handlekey': '',
          'values': <String, Object?>{},
          'login': 0,
          'alert': '',
        }),
      );
    },
  );
  final bloc = PostEditBloc(postEditRepository: repo);
  addTearDown(bloc.close);
  final loaded = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
  bloc.add(const ThreadPubFetchInfoRequested(fid: '7'));
  expect((await loaded.timeout(const Duration(seconds: 3))).status, PostEditStatus.editing);
  final content = bloc.state.content!;
  final done = bloc.stream.firstWhere((s) => s.status != PostEditStatus.uploading);
  bloc.add(
    ThreadPubPostThread(
      ThreadPublishInfo(
        formHash: content.formHash,
        postTime: content.postTime,
        delAttachOp: '0',
        wysiwyg: content.wysiwyg,
        fid: '7',
        threadType: null,
        checkbox: '0',
        subject: '定時發布',
        message: '定時發布內文內文',
        price: null,
        perm: null,
        save: save,
        options: const [],
      ),
      cronPublish: at,
    ),
  );
  return (await done.timeout(const Duration(seconds: 3)), posts.single);
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });
  setUp(TsdmAppApi.reset);

  group('the form', () {
    test('offered for a new thread of a group allowed to set the time', () {
      expect(_form().offersCronPublish, isTrue);
      expect(_form().editorSupport('newthread'), PostFormSupport.supported);
      expect(_form({..._cron(), 'cronpublish': null}).offersCronPublish, isFalse);
      // Without the date field, nothing to post the time in.
      expect(
        _form({
          ..._cron(),
          'cronpublish': {
            'inputs': [
              {'name': 'cronpublish', 'type': 'checkbox', 'value': 'true', 'checked': 0, 'disabled': 0},
            ],
          },
        }).offersCronPublish,
        isFalse,
      );
    });

    test('not for a red packet thread: the plugin makes the packet with the thread, draft or not', () {
      final hongbao = _form({..._json('post_v16_newthread_hongbao'), 'cronpublish': _cron()['cronpublish']});
      expect(hongbao.isHongbao, isTrue);
      expect(hongbao.offersCronPublish, isFalse);
    });

    test('not for an edit: a scheduled draft edited is left to the website', () {
      final edit = _form({..._json('post_v16_edit_draft'), 'cronpublish': _cron()['cronpublish']});
      expect(edit.offersCronPublish, isFalse);
    });

    test("the time as the forum reads it: the wall clock of the answer's offset", () {
      expect(_form().cronPublishDate(_at), '2026-11-09 12:00');
      expect(_form({..._cron(), 'timeoffset': 0}).cronPublishDate(_at), '2026-11-09 04:00');
      expect(_form({..._cron(), 'timeoffset': 9}).cronPublishDate(_at), '2026-11-09 13:00');
    });

    test('the body: the box checked with the time, or as served', () {
      final scheduled = _form().bodyWith(PostFormEdits(message: 'm', cronPublish: _at)).toMap()!;
      expect(scheduled['cronpublish'], 'true');
      expect(scheduled['cronpublishdate'], '2026-11-09 12:00');
      expect(scheduled['save'], '');
      final now = _form().bodyWith(const PostFormEdits(message: 'm')).toMap()!;
      expect(now.containsKey('cronpublish'), isFalse);
      expect(now['cronpublishdate'], '');
      // A form that does not offer it posts no time, whatever is asked.
      final none = _form({..._cron(), 'cronpublish': null}).bodyWith(PostFormEdits(message: 'm', cronPublish: _at));
      expect(none.toMap()!.containsKey('cronpublish'), isFalse);
    });
  });

  group('the editor', () {
    test('a thread kept a draft until its time: scheduled', () async {
      final (state, body) = await _post(at: _at);
      expect(state.status, PostEditStatus.scheduled);
      expect(state.redirectTid, '9600060');
      expect(body['cronpublish'], 'true');
      expect(body['cronpublishdate'], '2026-11-09 12:00');
      expect(body['subject'], '定時發布');
    });

    test('saved as a draft: a plain draft, never scheduled', () async {
      final (state, body) = await _post(at: _at, save: '1');
      expect(state.status, PostEditStatus.success);
      expect(body['save'], '1');
      expect(body.containsKey('cronpublish'), isFalse);
    });

    test('the thread not told (another account served): not reported as published', () async {
      final (state, _) = await _post(at: _at, thread: {..._thread(draft: 1), 'uid': 32});
      expect(state.status, PostEditStatus.draftUnconfirmed);
    });

    test('a thread the forum published (the time passed meanwhile): published', () async {
      final (state, _) = await _post(at: _at, draft: 0);
      expect(state.status, PostEditStatus.success);
    });

    test('no time: published as before', () async {
      final (state, body) = await _post(draft: 0);
      expect(state.status, PostEditStatus.success);
      expect(body.containsKey('cronpublish'), isFalse);
    });
  });

  group('the dialog', () {
    Future<Object? Function()> open(WidgetTester tester, DateTime? initial) async {
      Object? result = 'not closed';
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showCronPublishDialog(context, initial),
                child: const Text('open'),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => result;
    }

    testWidgets('a time passed is refused, cleared it is publishing now', (tester) async {
      final result = await open(tester, DateTime(2020));
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      expect(find.text('發布時間必須晚於現在'), findsOneWidget);
      expect(result(), 'not closed');
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      expect(result(), (at: null));
    });

    testWidgets('a time ahead is returned, cancelled nothing', (tester) async {
      final ahead = DateTime.now().add(const Duration(days: 2));
      var result = await open(tester, ahead);
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      expect(result(), (at: ahead));

      result = await open(tester, ahead);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result(), isNull);
    });
  });
}
