import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/thread/v1/tts/thread_tts_controller.dart';
import 'package:tsdm_client/features/thread/v1/tts/thread_tts_text.dart';
import 'package:tsdm_client/features/thread/v1/tts/tts_engine.dart';
import 'package:tsdm_client/shared/models/models.dart';

Post _post(int i, {bool hot = false}) => Post(
  postID: '$i',
  postFloor: i,
  author: User(name: 'u$i', url: 'u'),
  publishTime: DateTime(2026, 9, 5),
  data: 'body $i',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
  hot: hot,
);

/// An engine that says nothing: a text stays "being said" until the test finishes it.
class _FakeEngine implements TtsEngine {
  final said = <String>[];
  final rates = <double>[];
  final _interruptions = StreamController<void>.broadcast();
  Completer<TtsOutcome>? _current;
  int stops = 0;
  int prepared = 0;
  int released = 0;

  @override
  Stream<void> get interruptions => _interruptions.stream;

  void interrupt() => _interruptions.add(null);

  /// The text being said is over.
  void finish([TtsOutcome outcome = TtsOutcome.completed]) {
    final current = _current;
    _current = null;
    current?.complete(outcome);
  }

  @override
  Future<void> prepare({required String languageTag}) async => prepared++;

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<TtsOutcome> speak(String text) {
    said.add(text);
    final c = Completer<TtsOutcome>();
    _current = c;
    return c.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    finish(TtsOutcome.cancelled);
  }

  @override
  Future<void> release() async => released++;

  @override
  Future<void> dispose() async {}
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeEngine engine;
  late int pageRequests;
  late int failures;

  ThreadTtsController make({bool Function(Post)? skip}) => ThreadTtsController(
    engine: engine,
    languageTag: 'zh-CN',
    requestNextPage: () => pageRequests++,
    onFailed: () => failures++,
    skip: skip ?? (post) => post.hot,
    speechOf: (post) => FloorSpeech(['head ${post.postID}', 'body ${post.postID}']),
  );

  setUp(() {
    engine = _FakeEngine();
    pageRequests = 0;
    failures = 0;
  });

  test('reads the floors in order, heading then content', () async {
    final c = make()..updateFloors([_post(1), _post(2)], canLoadMore: false);
    await c.start('1');
    await _settle();
    expect(c.currentPid, '1');
    expect(engine.said, ['head 1']);
    engine.finish();
    await _settle();
    expect(engine.said, ['head 1', 'body 1']);
    engine.finish();
    await _settle();
    expect(c.currentPid, '2');
    expect(engine.said.last, 'head 2');
    engine.finish();
    await _settle();
    engine.finish();
    await _settle();
    // Over, and no page after: stops.
    expect(c.status, TtsStatus.idle);
    expect(pageRequests, 0);
    expect(engine.released, 1);
  });

  test('hot replies are left out and the start moves on to the next floor read', () async {
    final c = make()..updateFloors([_post(9, hot: true), _post(1), _post(2)], canLoadMore: false);
    await c.start('9');
    await _settle();
    expect(c.currentPid, '1');
  });

  test('asks for the next page once at the end and goes on when it arrives', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: true);
    await c.start('1');
    await _settle();
    engine.finish();
    await _settle();
    engine.finish();
    await _settle();
    expect(c.status, TtsStatus.waitingPage);
    expect(pageRequests, 1);
    // The same floors told again do not ask again.
    c.updateFloors([_post(1)], canLoadMore: true);
    expect(pageRequests, 1);
    c.updateFloors([_post(1), _post(2)], canLoadMore: false);
    await _settle();
    expect(c.status, TtsStatus.speaking);
    expect(c.currentPid, '2');
    expect(engine.said.last, 'head 2');
  });

  test('stops when the next page failed', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: true);
    await c.start('1');
    await _settle();
    engine.finish();
    await _settle();
    engine.finish();
    await _settle();
    c.updateFloors([_post(1)], canLoadMore: true, nextFailed: true);
    await _settle();
    expect(c.status, TtsStatus.idle);
    expect(failures, 1);
  });

  test('pause keeps the part and resume says it again', () async {
    final c = make()..updateFloors([_post(1), _post(2)], canLoadMore: false);
    await c.start('1');
    await _settle();
    engine.finish();
    await _settle();
    expect(engine.said, ['head 1', 'body 1']);
    await c.pause();
    expect(c.status, TtsStatus.paused);
    // The cut text does not move the reader on.
    await _settle();
    expect(c.currentPid, '1');
    c.resume();
    await _settle();
    expect(c.status, TtsStatus.speaking);
    expect(engine.said, ['head 1', 'body 1', 'body 1']);
  });

  test('an interruption by the system pauses', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: false);
    await c.start('1');
    await _settle();
    engine.interrupt();
    await _settle();
    expect(c.status, TtsStatus.paused);
  });

  test('next and previous move by floor, skipping what is not read', () async {
    final c = make()..updateFloors([_post(1), _post(2, hot: true), _post(3)], canLoadMore: false);
    await c.start('1');
    await _settle();
    await c.next();
    await _settle();
    expect(c.currentPid, '3');
    await c.previous();
    await _settle();
    expect(c.currentPid, '1');
    // Before the first floor: the first floor again from its start.
    await c.previous();
    await _settle();
    expect(c.currentPid, '1');
    expect(engine.said.last, 'head 1');
  });

  test('next at the last floor waits for the page after it', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: true);
    await c.start('1');
    await _settle();
    await c.next();
    expect(c.status, TtsStatus.waitingPage);
    expect(pageRequests, 1);
  });

  test('the speed stays within its range and restarts the part being said', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: false);
    await c.start('1');
    await _settle();
    await c.setRate(3);
    await _settle();
    expect(c.rate, ttsMaxRate);
    await c.setRate(0.1);
    await _settle();
    expect(c.rate, ttsMinRate);
    expect(engine.rates, containsAll([ttsMaxRate, ttsMinRate]));
    expect(engine.said.where((e) => e == 'head 1').length, greaterThanOrEqualTo(2));
  });

  test('stops when the floor being read leaves the floors', () async {
    final c = make()..updateFloors([_post(1), _post(2)], canLoadMore: false);
    await c.start('1');
    await _settle();
    c.updateFloors([_post(5)], canLoadMore: false);
    await _settle();
    expect(c.status, TtsStatus.idle);
  });

  test('an engine failure stops and tells', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: false);
    await c.start('1');
    await _settle();
    engine.finish(TtsOutcome.failed);
    await _settle();
    expect(c.status, TtsStatus.idle);
    expect(failures, 1);
  });

  test('a blocked author is left out', () async {
    final c = make(skip: (post) => post.postID == '2')
      ..updateFloors([_post(1), _post(2), _post(3)], canLoadMore: false);
    await c.start('1');
    await _settle();
    await c.next();
    await _settle();
    expect(c.currentPid, '3');
  });
}
