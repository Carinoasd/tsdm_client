/// The app's one sound player ([AudioPlayerController]) over a fake player and a fake fetcher: a track is fetched and
/// played, the next track of its thread plays when it ends, the last one stays at its end; pause, resume, seek; a
/// track that cannot be fetched stops the queue there and is tried again on play; another track started while one is
/// fetched cancels it; closed, from the mini player or the system's media controls, it forgets the queue.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_backend.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_player_controller.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_queue.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';

final class _FakeBackend implements AudioBackend {
  final calls = <String>[];
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _state = StreamController<AudioBackendState>.broadcast(sync: true);
  final _position = StreamController<Duration>.broadcast(sync: true);

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<AudioBackendState> get stateStream => _state.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Future<Duration?> load(String path, AudioTrack track) async {
    calls.add('load $path');
    return const Duration(seconds: 90);
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async => calls.add('seek ${position.inSeconds}');

  @override
  Future<void> stop() async => calls.add('stop');

  /// The player played to the end.
  void complete() => _state.add(AudioBackendState.completed);

  /// Stopped from the system's media controls.
  void stopFromSystem() => _state.add(AudioBackendState.idle);

  void playingChanged({required bool playing}) => _playing.add(playing);
}

final class _FakeFetcher implements AudioFetcher {
  /// The fetches asked for, by track id, completed by the test.
  final pending = <String, Completer<String>>{};
  final tokens = <String, CancelToken>{};

  /// Track ids answered at once with their file.
  final ready = <String>{};

  @override
  Future<String> fetch(
    AudioTrack track, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  }) {
    tokens[track.id] = cancelToken;
    if (ready.contains(track.id)) {
      return Future.value('/cache/${track.id}');
    }
    onProgress?.call(0.5);
    final completer = pending[track.id] = Completer<String>();
    unawaited(
      cancelToken.whenCancel.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(DioException.requestCancelled(requestOptions: RequestOptions(), reason: 'x'));
        }
      }),
    );
    return completer.future;
  }
}

AudioTrack _track(int aid) => AudioTrack.attachment(aid: aid, filename: '$aid.mp3', url: 'https://x/$aid', tid: '9');

final AudioTrack _a = _track(1);
final AudioTrack _b = _track(2);
final AudioTrack _c = _track(3);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeBackend backend;
  late _FakeFetcher fetcher;
  late AudioPlayerController controller;

  setUp(() {
    backend = _FakeBackend();
    fetcher = _FakeFetcher()..ready.addAll([_a.id, _b.id, _c.id]);
    controller = AudioPlayerController(backend: backend, fetcher: fetcher);
  });

  tearDown(() async => controller.close());

  group('AudioQueue', () {
    test('from a track of the thread, else the track alone', () {
      final queue = AudioQueue.from([_a, _b, _c], _b);
      expect(queue.current, _b);
      expect(queue.next?.current, _c);
      expect(queue.next?.next, isNull);
      final alone = AudioQueue.from([_a, _b], _c);
      expect(alone.tracks, [_c]);
      expect(alone.hasNext, isFalse);
    });
  });

  test('plays a track, then the next one of the thread when it ends, and stays at the end of the last', () async {
    await controller.playTrack(_b, queue: [_a, _b, _c]);
    expect(controller.state.status, AudioPlayerStatus.playing);
    expect(controller.state.current, _b);
    expect(controller.state.duration, const Duration(seconds: 90));
    expect(backend.calls, ['load /cache/attach:2', 'play']);

    backend.complete();
    await _settle();
    expect(controller.state.current, _c);
    expect(controller.state.status, AudioPlayerStatus.playing);
    expect(backend.calls.skip(2), ['pause', 'load /cache/attach:3', 'play']);

    backend.complete();
    await _settle();
    expect(controller.state.current, _c);
    expect(controller.state.status, AudioPlayerStatus.completed);

    // Played again from the start.
    await controller.toggle();
    expect(backend.calls.skip(5), ['seek 0', 'play']);
    expect(controller.state.status, AudioPlayerStatus.playing);

    // Sought at the end: paused there, as the player still says it plays.
    backend.complete();
    await _settle();
    await controller.seek(const Duration(seconds: 10));
    expect(controller.state.status, AudioPlayerStatus.paused);
    expect(backend.calls.skip(7), ['pause', 'seek 10']);
  });

  test('the track played now pauses and resumes; seek goes where asked', () async {
    await controller.playTrack(_a, queue: [_a, _b]);
    await controller.playTrack(_a, queue: [_a, _b]);
    expect(controller.state.status, AudioPlayerStatus.paused);
    await controller.seek(const Duration(seconds: 30));
    await controller.playTrack(_a);
    expect(controller.state.status, AudioPlayerStatus.playing);
    expect(backend.calls, ['load /cache/attach:1', 'play', 'pause', 'seek 30', 'play']);

    // From the system's media controls.
    backend.playingChanged(playing: false);
    expect(controller.state.status, AudioPlayerStatus.paused);
    backend.playingChanged(playing: true);
    expect(controller.state.status, AudioPlayerStatus.playing);
  });

  test('loading tells the part fetched; another track started cancels the fetch', () async {
    fetcher.ready.clear();
    unawaited(controller.playTrack(_a, queue: [_a, _b]));
    await _settle();
    expect(controller.state.status, AudioPlayerStatus.loading);
    expect(controller.state.progress, 0.5);

    unawaited(controller.playTrack(_b, queue: [_a, _b]));
    await _settle();
    expect(fetcher.tokens[_a.id]!.isCancelled, isTrue);
    expect(controller.state.current, _b);
    expect(controller.state.status, AudioPlayerStatus.loading);

    fetcher.pending[_b.id]!.complete('/cache/b');
    await _settle();
    expect(controller.state.status, AudioPlayerStatus.playing);
    expect(backend.calls, ['load /cache/b', 'play']);
  });

  test('a track that cannot be fetched stops the queue there; play tries it again', () async {
    fetcher.ready.remove(_b.id);
    await controller.playTrack(_a, queue: [_a, _b, _c]);
    backend.complete();
    await _settle();
    expect(controller.state.current, _b);
    fetcher.pending[_b.id]!.completeError(const AudioFetchException(AudioFetchFailure.notAudio));
    await _settle();
    expect(controller.state.status, AudioPlayerStatus.failed);
    expect(controller.state.failure, AudioFetchFailure.notAudio);
    // Not the one after it: each fetch of an attachment may cost credits.
    expect(fetcher.tokens.containsKey(_c.id), isFalse);

    unawaited(controller.playTrack(_b, queue: [_a, _b, _c]));
    await _settle();
    expect(controller.state.status, AudioPlayerStatus.loading);
    fetcher.pending[_b.id]!.complete('/cache/b');
    await _settle();
    expect(controller.state.status, AudioPlayerStatus.playing);
  });

  test('closed from the mini player or the media controls, the queue is forgotten', () async {
    await controller.playTrack(_a, queue: [_a, _b]);
    await controller.dismiss();
    expect(controller.state.queue, isNull);
    expect(controller.state.status, AudioPlayerStatus.idle);
    expect(backend.calls.last, 'stop');

    await controller.playTrack(_b, queue: [_a, _b]);
    backend.stopFromSystem();
    await _settle();
    expect(controller.state.queue, isNull);
  });

  test('another track started pauses the one played; it stays silent when the new one fails', () async {
    fetcher.ready.remove(_b.id);
    await controller.playTrack(_a, queue: [_a, _b]);
    unawaited(controller.playTrack(_b, queue: [_a, _b]));
    await _settle();
    expect(backend.calls, ['load /cache/attach:1', 'play', 'pause']);
    fetcher.pending[_b.id]!.completeError(const AudioFetchException(AudioFetchFailure.network));
    await _settle();
    expect(controller.state.status, AudioPlayerStatus.failed);
    expect(backend.calls.last, 'pause');
  });

  test('a fetch cancelled for the track played now fails it, it is not left loading', () async {
    fetcher.ready.clear();
    unawaited(controller.playTrack(_a));
    await _settle();
    fetcher.pending[_a.id]!.completeError(DioException.requestCancelled(requestOptions: RequestOptions(), reason: 'x'));
    await _settle();
    expect(controller.state.status, AudioPlayerStatus.failed);
    expect(controller.state.failure, AudioFetchFailure.network);
  });

  test('a fetch finished after close is dropped', () async {
    fetcher.ready.clear();
    unawaited(controller.playTrack(_a));
    await _settle();
    await controller.dismiss();
    expect(fetcher.tokens[_a.id]!.isCancelled, isTrue);
    await _settle();
    expect(controller.state.queue, isNull);
    expect(backend.calls, ['stop']);
  });

  group('looksLikeAudio', () {
    Uint8List bytes(List<int> b) => Uint8List.fromList(b);
    test('sound files', () {
      expect(looksLikeAudio(bytes('ID3\x04'.codeUnits)), isTrue);
      expect(looksLikeAudio(bytes([0xFF, 0xFB, 0x90, 0x00])), isTrue);
      expect(looksLikeAudio(bytes('fLaC'.codeUnits)), isTrue);
      expect(looksLikeAudio(bytes('\x00\x00\x00\x20ftypM4A '.codeUnits)), isTrue);
    });
    test("the forum's pages", () {
      expect(looksLikeAudio(bytes('<!DOCTYPE html>'.codeUnits)), isFalse);
      expect(looksLikeAudio(bytes('<?xml version'.codeUnits)), isFalse);
      expect(looksLikeAudio(bytes(const [])), isFalse);
    });
  });
}
