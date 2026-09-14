import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:universal_html/parsing.dart';

String _fixture(String name) => File('test/data/poll_${name}_x5.html').readAsStringSync();
ForumPoll _parse(String html, {bool loggedIn = true}) => parseForumPoll(parseHtmlDocument(html), loggedIn: loggedIn);

class _FormAdapter implements HttpClientAdapter {
  _FormAdapter({this.respond});

  final String Function(RequestOptions options)? respond;
  final requests = <RequestOptions>[];
  Object? data;
  String? encodedBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    data = options.data;
    encodedBody = requestStream == null ? null : utf8.decode(await requestStream.expand((chunk) => chunk).toList());
    return ResponseBody.fromString(
      respond?.call(options) ?? '<html><body>Accepted</body></html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
  });
  tearDownAll(getIt.reset);
  test('real multi-choice form keeps its limit, hidden results and public-vote notice', () {
    final poll = _parse(_fixture('multiple'));
    expect(poll.availability, PollAvailability.available);
    expect(poll.maxChoices, 2);
    expect(poll.options, hasLength(5));
    expect(poll.options.every((o) => o.result == null), isTrue);
    expect(poll.notice, contains('公开投票'));
    expect(poll.accepts({'40028', '40029'}), isTrue);
    expect(poll.accepts({'40028', '40029', '40030'}), isFalse);
    expect(poll.accepts({'injected'}), isFalse);
  });
  test('real voted page shows only supplied results, no copy-result BBCode', () {
    final poll = _parse(_fixture('voted'));
    expect(poll.availability, PollAvailability.voted);
    expect(poll.options.first.result, '50.00% (1)');
    expect(poll.notice, '您已经投过票，谢谢您的参与');
    expect(poll.accepts({'40028'}), isFalse);
  });
  test('real guest page distinguishes login from account permission', () {
    expect(_parse(_fixture('guest'), loggedIn: false).availability, PollAvailability.loginRequired);
    expect(_parse(_fixture('guest')).availability, PollAvailability.denied);
  });
  test('derived closed and unsupported forms fail closed', () {
    final closed = _fixture('voted').replaceAll('您已经投过票，谢谢您的参与', '投票已经结束');
    expect(_parse(closed).availability, PollAvailability.closed);
    expect(
      _parse(_fixture('multiple').replaceAll('action=votepoll', 'action=delete')).availability,
      PollAvailability.unsupported,
    );
    expect(
      _parse(
        _fixture('multiple').replaceAll('action="forum.php', 'action="https://evil.example/forum.php'),
      ).availability,
      PollAvailability.unsupported,
    );
    expect(_parse(_fixture('multiple').replaceAll('最多可选 2 项', '未知限制')).availability, PollAvailability.unsupported);
    expect(
      _parse(_fixture('multiple').replaceAll('action="forum.php', 'action="javascript:alert(1)//')).availability,
      PollAvailability.unsupported,
    );
    expect(
      _parse(_fixture('multiple').replaceAll('method="post"', 'method="get"')).availability,
      PollAvailability.unsupported,
    );
  });
  test('derived single-choice form replaces selection', () async {
    final html = _fixture('multiple').replaceAll('type="checkbox"', 'type="radio"');
    final repo = PollRepository(getPage: (_) async => html, postForm: (_, _) async => '');
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit
      ..select('40028', selected: true)
      ..select('40029', selected: true);
    expect(cubit.state.choices, {'40029'});
    await cubit.close();
  });
  test('network payload supports Android string maps and desktop form encoding without losing choices', () async {
    final adapter = _FormAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
    await PollRepository.network(client).vote(_parse(_fixture('multiple')), {'40028', '40029'});
    // The Kotlin adapter passes options.data directly to a Map<String, String> method channel.
    expect(adapter.data, isA<Map<String, String>>());
    final decoded = Uri.splitQueryString(adapter.encodedBody!);
    expect(decoded['pollanswers[0]'], '40028');
    expect(decoded['pollanswers[1]'], '40029');
    expect(decoded, adapter.data);
    dio.close();
  });
  test('double submit issues one POST, preserves all indexed options and uses fresh results', () async {
    var gets = 0;
    final sent = <Map<String, String>>[];
    final pending = Completer<String>();
    final repo = PollRepository(
      getPage: (_) async => _fixture(++gets == 1 ? 'multiple' : 'voted'),
      postForm: (_, body) {
        sent.add(body);
        return pending.future;
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit
      ..select('40028', selected: true)
      ..select('40029', selected: true)
      ..select('40030', selected: true);
    expect(cubit.state.choices, hasLength(2));
    final submit = cubit.submit();
    await cubit.submit();
    expect(sent, hasLength(1));
    expect(sent.single['pollanswers[0]'], '40028');
    expect(sent.single['pollanswers[1]'], '40029');
    pending.complete('server response');
    await submit;
    expect(cubit.state.poll!.availability, PollAvailability.voted);
    expect(cubit.state.choices, isEmpty);
    expect(gets, 2);
    await cubit.close();
  });
  for (final confirmed in [true, false]) {
    test('a challenged POST is never replayed; fresh GET determines confirmation=$confirmed', () async {
      // Real challenge fixtures use separate threads to isolate the shared sign cache.
      final tid = confirmed ? '1257592' : '1257589';
      final challenge = File('test/data/antitheft/$tid.html').readAsStringSync();
      var submitted = false;
      final adapter = _FormAdapter(
        respond: (options) {
          if (options.method == 'POST') {
            submitted = true;
            return challenge;
          }
          if (submitted && !options.uri.queryParameters.containsKey('_dsign')) return challenge;
          return _fixture(submitted && confirmed ? 'voted' : 'multiple').replaceAll('1266029', tid);
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = NetClientProvider.buildNoCookie(dio: dio, cookie: CookieProvider.buildEmpty());
      final cubit = PollCubit(
        url: 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=$tid',
        currentUid: () => 1000,
        repository: () => PollRepository.network(client),
      );
      addTearDown(cubit.close);
      await cubit.load();
      cubit
        ..select('40028', selected: true)
        ..select('40029', selected: true);
      await cubit.submit();

      expect(adapter.requests.map((r) => r.method), ['GET', 'POST', 'GET', 'GET']);
      expect(adapter.requests.where((r) => r.method == 'GET').every((r) => r.data == null), isTrue);
      expect(adapter.requests.last.uri.queryParameters['_dsign'], isNotEmpty);
      expect(cubit.state.submissionUnconfirmed, !confirmed);
      expect(cubit.state.poll!.availability, confirmed ? PollAvailability.voted : PollAvailability.available);
      expect(cubit.state.choices, isEmpty);
    });
  }
  test('timed-out POST is not retried; a fresh GET can still confirm it', () async {
    var gets = 0;
    var posts = 0;
    final repo = PollRepository(
      getPage: (_) async => _fixture(++gets == 1 ? 'multiple' : 'voted'),
      postForm: (_, _) async {
        posts++;
        throw TimeoutException('response lost');
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit.select('40028', selected: true);
    await cubit.submit();
    expect(cubit.state.poll!.availability, PollAvailability.voted);
    expect(cubit.state.submissionUnconfirmed, isFalse);
    await cubit.load();
    expect(posts, 1);
    await cubit.close();
  });
  test('failed refresh exposes only GET retry, never success or an old submit form', () async {
    var gets = 0;
    var posts = 0;
    final repo = PollRepository(
      getPage: (_) async {
        if (++gets == 2) throw const HttpException('offline');
        return _fixture(gets == 1 ? 'multiple' : 'voted');
      },
      postForm: (_, _) async {
        posts++;
        return 'error';
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await cubit.load();
    cubit.select('40028', selected: true);
    await cubit.submit();
    expect(cubit.state.failed, isTrue);
    expect(cubit.state.poll, isNull);
    await cubit.submit();
    await cubit.load();
    expect(posts, 1);
    expect(cubit.state.poll!.availability, PollAvailability.voted);
    await cubit.close();
  });
  test('account switch rejects stale responses and old account submissions', () async {
    int? uid = 1000;
    final pending = Completer<String>();
    var posts = 0;
    final repo = PollRepository(
      getPage: (_) => pending.future,
      postForm: (_, _) async {
        posts++;
        return '';
      },
    );
    final cubit = PollCubit(url: 'poll', currentUid: () => uid, repository: () => repo);
    final load = cubit.load();
    uid = 1001;
    cubit.invalidate();
    pending.complete(_fixture('multiple'));
    await load;
    expect(cubit.state.poll, isNull);
    await cubit.submit();
    expect(posts, 0);
    await cubit.close();
  });
  test('session expiration returns a login state', () async {
    final repo = PollRepository(getPage: (_) async => _fixture('guest'), postForm: (_, _) async => '');
    final poll = await repo.fetch('poll', 1000);
    expect(poll.availability, PollAvailability.loginRequired);
  });
  testWidgets('selection limit is visible and submit stays disabled until an explicit choice', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final repo = PollRepository(getPage: (_) async => _fixture('multiple'), postForm: (_, _) async => '');
    final cubit = PollCubit(url: 'poll', currentUid: () => 1000, repository: () => repo);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PollCard('1', controller: cubit)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.byType(CheckboxListTile).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile).at(1));
    await tester.pumpAndSettle();
    expect(find.text('Selected 2 / 2'), findsOneWidget);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile).at(2)).onChanged, isNull);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await cubit.close();
  });
}
