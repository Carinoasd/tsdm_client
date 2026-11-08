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

  /// Whether [stop] takes a trip to the platform (a moment) before it returns.
  bool slowStop = false;

  /// Whether [prepare] takes a moment.
  bool slowPrepare = false;

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
  Future<void> prepare({required String languageTag}) async {
    if (slowPrepare) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    prepared++;
  }

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<TtsOutcome> speak(String text) {
    said.add(text);
    // The text before it is over, as the platform ends it.
    finish(TtsOutcome.cancelled);
    final c = Completer<TtsOutcome>();
    _current = c;
    return c.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    final pending = _current;
    if (slowStop) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Not a text begun while stopping, as the real engine.
    if (identical(_current, pending)) {
      finish(TtsOutcome.cancelled);
    }
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

  test('closing right after next is not undone by the next floor', () async {
    engine.slowStop = true;
    final c = make()..updateFloors([_post(1), _post(2)], canLoadMore: false);
    await c.start('1');
    await _settle();
    final moving = c.next();
    final closing = c.stop();
    await Future.wait([moving, closing]);
    await _settle();
    expect(c.status, TtsStatus.idle);
    expect(c.currentPid, isNull);
  });

  test('pausing right after previous is not undone', () async {
    engine.slowStop = true;
    final c = make()..updateFloors([_post(1), _post(2)], canLoadMore: false);
    await c.start('2');
    await _settle();
    final moving = c.previous();
    final pausing = c.pause();
    await Future.wait([moving, pausing]);
    await _settle();
    expect(c.status, TtsStatus.paused);
  });

  test('closing while the speed changes stays closed', () async {
    engine.slowStop = true;
    final c = make()..updateFloors([_post(1)], canLoadMore: false);
    await c.start('1');
    await _settle();
    final changing = c.setRate(1.25);
    final closing = c.stop();
    await Future.wait([changing, closing]);
    await _settle();
    expect(c.status, TtsStatus.idle);
  });

  test('a page that arrives with nothing to read asks for the one after it', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: true);
    await c.start('1');
    await _settle();
    engine.finish();
    await _settle();
    engine.finish();
    await _settle();
    expect(pageRequests, 1);
    c.updateFloors([_post(1), _post(2, hot: true), _post(3, hot: true)], canLoadMore: true);
    expect(c.status, TtsStatus.waitingPage);
    expect(pageRequests, 2);
    // No page after that one: over.
    c.updateFloors([_post(1), _post(2, hot: true), _post(3, hot: true), _post(4, hot: true)], canLoadMore: false);
    await _settle();
    expect(c.status, TtsStatus.idle);
  });

  test('paused while waiting for a page: the floor that arrives is read on resume, not before', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: true);
    await c.start('1');
    await _settle();
    engine.finish();
    await _settle();
    engine.finish();
    await _settle();
    expect(c.status, TtsStatus.waitingPage);
    await c.pause();
    expect(c.status, TtsStatus.paused);
    c.updateFloors([_post(1), _post(2)], canLoadMore: false);
    await _settle();
    expect(c.status, TtsStatus.paused);
    expect(engine.said, ['head 1', 'body 1']);
    c.resume();
    await _settle();
    expect(c.status, TtsStatus.speaking);
    expect(c.currentPid, '2');
    expect(engine.said.last, 'head 2');
  });

  test('resumed while the page is still missing: waits for it', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: true);
    await c.start('1');
    await _settle();
    engine.finish();
    await _settle();
    engine.finish();
    await _settle();
    await c.pause();
    c.resume();
    expect(c.status, TtsStatus.waitingPage);
  });

  test('the speed of the engine: a multiple of the normal one, shifted on Windows', () {
    expect(engineRateOf(1, windows: false), 0.5);
    expect(engineRateOf(1.5, windows: false), 0.75);
    expect(engineRateOf(1, windows: true), 0.5);
    expect(engineRateOf(1.5, windows: true), 1.0);
  });

  test('resuming while the engine is still stopping keeps reading on', () async {
    engine.slowStop = true;
    final c = make()..updateFloors([_post(1), _post(2)], canLoadMore: false);
    await c.start('1');
    await _settle();
    final pausing = c.pause();
    c.resume();
    await pausing;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(c.status, TtsStatus.speaking);
    expect(engine.said, ['head 1', 'head 1']);
    engine.finish();
    await _settle();
    // The part after it follows: not stuck.
    expect(engine.said.last, 'body 1');
  });

  test('a failure of the page before the reading began is not the answer: the page is asked for', () async {
    final c = make()..updateFloors([_post(1)], canLoadMore: true, nextFailed: true);
    await c.start('1');
    await _settle();
    engine.finish();
    await _settle();
    engine.finish();
    await _settle();
    expect(pageRequests, 1);
    expect(failures, 0);
    expect(c.status, TtsStatus.waitingPage);
    c.updateFloors([_post(1)], canLoadMore: true, nextFailed: true);
    await _settle();
    expect(failures, 1);
    expect(c.status, TtsStatus.idle);
  });

  test('closed while the audio session is being taken: the session is given back', () async {
    engine.slowPrepare = true;
    final c = make()..updateFloors([_post(1)], canLoadMore: false);
    final starting = c.start('1');
    await _settle();
    await c.stop();
    await starting;
    expect(c.status, TtsStatus.idle);
    expect(engine.said, isEmpty);
    expect(engine.released, greaterThanOrEqualTo(1));
  });

  test('started again after a close during prepare: the session of the second start is kept', () async {
    engine.slowPrepare = true;
    final c = make()..updateFloors([_post(1)], canLoadMore: false);
    final first = c.start('1');
    await _settle();
    await c.stop();
    final second = c.start('1');
    await Future.wait([first, second]);
    await _settle();
    expect(c.status, TtsStatus.speaking);
    expect(engine.released, 0);
  });
}
