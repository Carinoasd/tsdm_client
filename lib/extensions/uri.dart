import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/instance.dart';

/// Extension methods on [Uri].
extension UriExt on Uri? {
  /// Get query parameters in [Uri] safely.
  ///
  /// Return null if any exception thrown in process, log an error if so.
  Map<String, String>? tryGetQueryParameters() {
    try {
      // Insane getter throwing exception.
      return this?.queryParameters;
    } on Exception catch (e, st) {
      talker.handle(e, st, 'failed to get query parameter from Uri "$this"');
      return null;
    }
  }
}

/// Origin checks for urls that may come from page contents.
extension UriOriginExt on Uri {
  /// Whether this url points at the forum: `http` or `https`, host `www.tsdm39.com` or `tsdm39.com` (any case).
  bool get isForumHost {
    if (scheme != 'https' && scheme != 'http') {
      return false;
    }
    final h = host.toLowerCase();
    return h == baseHost || h == baseHostAlt;
  }

  /// Whether this url is relative to the forum (no scheme and no host, e.g. `forum.php?mod=viewthread&tid=1`) or
  /// points at the forum, see [isForumHost].
  ///
  /// Only such urls may be turned into in-app routes; anything else is foreign and stays outside the app.
  bool get isForumOrRelative => (!hasScheme && !hasAuthority) || isForumHost;

  /// This url rebased on the canonical forum base url (`https://www.tsdm39.com`), keeping path and query.
  ///
  /// Use it before fetching a url taken from page contents so that an `http://` or `tsdm39.com` link never leaves the
  /// canonical https host.
  Uri toCanonicalForumUri() => Uri.parse(baseUrl).replace(path: path, query: hasQuery ? query : null);
}
