import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';

/// The key of [RequestOptions.extra] holding the most bytes the body of the answer may have (an `int`): a larger
/// answer fails with [ResponseTooLargeException] instead of being read whole. Images set it (`getImage`).
///
/// Applied by the transport of every client ([limitResponseBody]); the Kotlin client of Android is told it and stops
/// reading there itself.
const responseMaxBytesKey = 'tsdm_response_max_bytes';

/// The limit [options] asks for, null when none.
int? responseMaxBytesOf(RequestOptions options) => switch (options.extra[responseMaxBytesKey]) {
  final int v when v > 0 => v,
  _ => null,
};

/// [body] held to the limit of [options] ([responseMaxBytesKey]), [body] itself when there is none.
///
/// An answer whose `Content-Length` is over the limit fails at once, its body never read; one telling no size (or
/// telling less than it sends) fails as soon as more than the limit arrived, the rest not read. Counted on the body as
/// the transport gives it: after gzip is undone by the dart:io client.
ResponseBody limitResponseBody(RequestOptions options, ResponseBody body) {
  final max = responseMaxBytesOf(options);
  if (max == null) {
    return body;
  }
  final length = body.headers.entries
      .where((e) => e.key.toLowerCase() == Headers.contentLengthHeader)
      .map((e) => int.tryParse(e.value.firstOrNull?.trim() ?? ''))
      .firstOrNull;
  if (length != null && length > max) {
    // Let the connection go without reading it.
    unawaited(body.stream.listen(null, onError: (_) {}, cancelOnError: true).cancel());
    throw ResponseTooLargeException(max);
  }
  body.stream = _limited(body.stream, max);
  return body;
}

/// [source] failing with [ResponseTooLargeException] once more than [max] bytes came, the rest of it not read.
Stream<Uint8List> _limited(Stream<Uint8List> source, int max) {
  StreamSubscription<Uint8List>? sub;
  var received = 0;
  late final StreamController<Uint8List> out;
  out = StreamController<Uint8List>(
    sync: true,
    onListen: () {
      sub = source.listen(
        (chunk) {
          received += chunk.length;
          if (received > max) {
            final s = sub;
            sub = null;
            unawaited(s?.cancel());
            out.addError(ResponseTooLargeException(max));
            unawaited(out.close());
            return;
          }
          out.add(chunk);
        },
        onError: out.addError,
        onDone: () => unawaited(out.close()),
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () => sub?.cancel(),
  );
  return out.stream;
}
