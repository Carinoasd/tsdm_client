import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// The `src` of the captcha image in the script the forum answers for it (`misc.php?mod=seccode&action=update`).
final _captchaSrcRe = RegExp(r'''src=\\?["'](misc\.php\?mod=seccode[^"'\\]*)\\?["']''');

/// Asks the forum for the captcha and the security question of a [SecCheck], and checks an answer, as the forum's own
/// page script does (`updateseccode`, `updatesecqaa`, `checksec`), with the account's session: the forum keeps the
/// expected answer in that session, under the id of the check.
///
/// The forum serves these only to a request from its own pages (the `Referer` of the site), the captcha image of the
/// built-in kinds as well.
final class SecCheckRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [client] makes the requests, the account's client (`NetClientProvider`) by default.
  const SecCheckRepository({NetClientProvider Function()? client}) : _client = client;

  final NetClientProvider Function()? _client;

  NetClientProvider get _net => _client?.call() ?? getIt.get<NetClientProvider>();

  static const Map<String, String> _headers = {HttpHeaders.refererHeader: '$baseUrl/forum.php'};

  static String _stamp() => '${DateTime.now().millisecondsSinceEpoch}';

  /// The captcha image of [check]: the script of the captcha asked first (`action=update`, which names the image and
  /// lets a captcha of a plugin prepare it), then the image it names. A captcha that is no image (a plugin's own, a
  /// sound, Flash) is [SecCheckUnsupportedException].
  AsyncEither<Uint8List> fetchCaptcha(SecCheck check) => AsyncEither(() async {
    final net = _net;
    final update = await net
        .get(
          '$baseUrl/misc.php?mod=seccode&action=update&idhash=${check.seccodeHash}&${_stamp()}&modid=${check.modid}',
          options: Options(headers: _headers, responseType: ResponseType.plain),
        )
        .run();
    final String script;
    switch (update) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        script = value.data is String ? value.data as String : '';
    }
    final src = _captchaSrcRe.firstMatch(script)?.group(1)?.replaceAll('&amp;', '&');
    if (src == null) {
      error('captcha script names no image: ${script.length} chars');
      return left(SecCheckUnsupportedException());
    }
    final image = await net.getImage('$baseUrl/$src', headers: _headers).run();
    return image.map((resp) => Uint8List.fromList(resp.data as List<int>));
  });

  /// The security question of [check], plain text (the forum may answer HTML: its text is kept).
  AsyncEither<String> fetchQuestion(SecCheck check) => AsyncEither(() async {
    final resp = await _net
        .get(
          '$baseUrl/misc.php?mod=secqaa&action=update&idhash=${check.secqaaHash}&${_stamp()}&inajax=1',
          options: Options(headers: _headers, responseType: ResponseType.plain),
        )
        .run();
    return resp.flatMap((r) {
      final question = _ajaxText(r.data);
      if (question == null || question.isEmpty) {
        error('security question answer has no question');
        return left(SecCheckUnsupportedException());
      }
      return right(question);
    });
  });

  /// Whether the forum takes [value] as the answer to the captcha ([captcha]) or the question of [check], asked the
  /// way the page checks a field when it is left (`action=check`: the forum only looks, the answer still counts when
  /// the form is posted). Null when it could not be told (no answer, an unexpected one): the post decides then.
  Future<bool?> verify(SecCheck check, {required bool captcha, required String value}) async {
    final url = captcha
        ? '$baseUrl/misc.php?mod=seccode&action=check&inajax=1&modid=${check.modid}&idhash=${check.seccodeHash}'
              '&secverify=${Uri.encodeQueryComponent(value.trim())}'
        : '$baseUrl/misc.php?mod=secqaa&action=check&inajax=1&idhash=${check.secqaaHash}'
              '&secverify=${Uri.encodeQueryComponent(value.trim())}';
    final resp = await _net
        .get(
          url,
          options: Options(headers: _headers, responseType: ResponseType.plain),
        )
        .run();
    return resp.match((_) => null, (r) {
      final text = _ajaxText(r.data);
      if (text == null) {
        return null;
      }
      if (text.contains('succeed')) {
        return true;
      }
      return text.contains('invalid') ? false : null;
    });
  }

  /// The text of an AJAX answer of the forum (`<root><![CDATA[…]]></root>`), its HTML reduced to the text; null when
  /// [data] is no text.
  static String? _ajaxText(Object? data) {
    if (data is! String) {
      return null;
    }
    String? inner;
    try {
      inner = parseXmlDocument(data).documentElement?.text;
    } on Object catch (_) {
      inner = null;
    }
    final html = inner ?? data;
    return parseHtmlDocument(html).body?.text?.trim() ?? html.trim();
  }
}
