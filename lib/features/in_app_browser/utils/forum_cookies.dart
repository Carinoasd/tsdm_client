import 'package:cookie_jar/cookie_jar.dart';
import 'package:tsdm_client/constants/url.dart';

/// A cookie to put in the web view's cookie store.
typedef WebViewCookie = ({
  /// The page the cookie is set for.
  Uri url,
  String name,
  String value,

  /// The `Domain` attribute; null for a host-only cookie (the forum's X5 cookies are host-only).
  String? domain,
  String path,
  bool secure,
  bool httpOnly,
});

/// The forum hosts the in-app browser shares the app's session with.
const List<String> forumHosts = [baseHost, baseHostAlt];

/// The `Domain` attributes a forum cookie of an earlier session may carry in the web view's store, null for a
/// host-only one: the cookies of all of them are removed before the account in use is signed in.
///
/// Removed on the path `/`, the only one the forum sets cookies on (Discuz `cookiepath`).
const List<String?> forumCookieDomains = [null, '.$baseHostAlt', baseHostAlt, baseHost];

/// Reads the cookie jar storage of the app (the cookie provider) and drops every write: loading the cookies for the
/// web view must not change what the app holds.
final class _ReadOnlyStorage implements Storage {
  const _ReadOnlyStorage(this._storage);

  final Storage _storage;

  @override
  Future<void> init(bool persistSession, bool ignoreExpires) async {}

  @override
  Future<String?> read(String key) => _storage.read(key);

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> deleteAll(List<String> keys) async {}
}

/// The cookies of the forum session held in [storage] (the cookie provider of the account in use), one list for each
/// of the [forumHosts], as the app's own requests send them there.
///
/// Only the forum hosts get cookies: a page of another site opened in the in-app browser never sees the session.
Future<List<WebViewCookie>> forumWebViewCookies(Storage storage) async {
  final jar = PersistCookieJar(ignoreExpires: true, storage: _ReadOnlyStorage(storage));
  final out = <WebViewCookie>[];
  for (final host in forumHosts) {
    final url = Uri.https(host, '/');
    for (final cookie in await jar.loadForRequest(url)) {
      if (cookie.name.isEmpty || cookie.value.isEmpty) {
        continue;
      }
      out.add((
        url: url,
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path ?? '/',
        secure: cookie.secure,
        httpOnly: cookie.httpOnly,
      ));
    }
  }
  return out;
}
