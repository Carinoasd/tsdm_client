/// The redirects of an audio attachment are followed one by one ([followAudioAttachmentRedirects], PR #440): the
/// account's session goes with a request to the canonical https host of the forum only. The loop had no test of its
/// own, and followed one redirect less than [maxAudioAttachmentHops] says. Here: a redirect on the forum's host keeps
/// the session, one to another host goes without it, a redirect to the forum over plain http is asked over https with
/// it (never over http), one to another host over http without it, and the hops end after [maxAudioAttachmentHops]
/// redirects.
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/audio_player/controller/audio_fetcher.dart';

/// The token of attachment [aid] of thread 1000 for uid 31.
String _token(int aid) => Uri.encodeQueryComponent(base64.encode(utf8.encode('$aid|f1f2f3f4|1700000000|31|1000')));

typedef _Request = ({String url, bool session});

/// A forum answering by url: a redirect to the url in [redirects], the file otherwise; records every request.
final class _Forum {
  _Forum(this.redirects);

  final Map<String, String> redirects;
  final requests = <_Request>[];

  Future<Either<AppException, Response<dynamic>>> request(String url, {required bool session}) async {
    requests.add((url: url, session: session));
    final to = redirects[url];
    return Right(
      Response<dynamic>(
        requestOptions: RequestOptions(path: url),
        statusCode: to == null ? 200 : 302,
        headers: Headers.fromMap({
          if (to != null) 'location': [to],
        }),
      ),
    );
  }
}

void main() {
  final attachment = '$baseUrl/forum.php?mod=attachment&aid=${_token(36)}';
  const credit = '$baseUrl/forum.php?mod=misc&action=attachcredit&aid=36&formhash=f1f2f3f4';
  const storage = 'https://files.example.com/a.mp3?sign=1';

  Future<(_Forum, int?)> follow(String url, Map<String, String> redirects) async {
    final forum = _Forum(redirects);
    final result = await followAudioAttachmentRedirects(url, request: forum.request);
    return (forum, result.toNullable()?.statusCode);
  }

  test('a redirect on the forum keeps the session, one to another host goes without it', () async {
    final (forum, status) = await follow(attachment, {attachment: credit, credit: storage});
    expect(status, 200);
    expect(forum.requests, [
      (url: attachment, session: true),
      (url: credit, session: true),
      (url: storage, session: false),
    ]);
  });

  test('a relative redirect is on the forum', () async {
    final (forum, _) = await follow(attachment, {attachment: 'forum.php?mod=misc&action=attachcredit&aid=36'});
    expect(forum.requests.last, (url: '$baseUrl/forum.php?mod=misc&action=attachcredit&aid=36', session: true));
  });

  test('plain http: the forum taken to https with the session, another host without it', () async {
    final (forum, _) = await follow(attachment, {
      attachment: 'http://tsdm39.com/forum.php?mod=misc&action=attachcredit&aid=36',
      '$baseUrl/forum.php?mod=misc&action=attachcredit&aid=36': 'http://files.example.com/a.mp3',
    });
    expect(forum.requests, [
      (url: attachment, session: true),
      (url: '$baseUrl/forum.php?mod=misc&action=attachcredit&aid=36', session: true),
      (url: 'http://files.example.com/a.mp3', session: false),
    ]);
    expect(forum.requests.where((e) => e.session).map((e) => Uri.parse(e.url).scheme), everyElement('https'));
  });

  test('a track kept by an earlier version naming http: asked over https', () async {
    final (forum, _) = await follow('http://tsdm39.com/forum.php?mod=attachment&aid=${_token(36)}', {});
    expect(forum.requests, [(url: attachment, session: true)]);
  });

  test('a redirect back from another host to the forum takes the session again, over https only', () async {
    final (forum, _) = await follow(attachment, {attachment: storage, storage: 'http://www.tsdm39.com/forum.php?x=1'});
    expect(forum.requests, [
      (url: attachment, session: true),
      (url: storage, session: false),
      (url: '$baseUrl/forum.php?x=1', session: true),
    ]);
  });

  test('at most $maxAudioAttachmentHops redirects', () async {
    String hop(int i) => 'https://files.example.com/$i';
    final chain = {attachment: hop(1), for (var i = 1; i < 20; i++) hop(i): hop(i + 1)};
    final (forum, status) = await follow(attachment, chain);
    expect(forum.requests, hasLength(maxAudioAttachmentHops + 1));
    expect(status, 302, reason: 'still a redirect: the fetch fails');

    // Exactly as many redirects as allowed: the file.
    final (enough, ok) = await follow(attachment, {
      attachment: hop(1),
      for (var i = 1; i < maxAudioAttachmentHops; i++) hop(i): hop(i + 1),
    });
    expect(enough.requests, hasLength(maxAudioAttachmentHops + 1));
    expect(ok, 200);
  });

  test('a failed request ends the hops', () async {
    final requests = <String>[];
    final result = await followAudioAttachmentRedirects(
      attachment,
      request: (url, {required session}) async {
        requests.add(url);
        return Left(HttpRequestFailedException(500));
      },
    );
    expect(result.isLeft(), isTrue);
    expect(requests, [attachment]);
  });
}
