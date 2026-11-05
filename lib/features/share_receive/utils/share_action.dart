import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/share_receive/models/shared_content.dart';

/// What the app does with a share, decided by [decideShare].
sealed class ShareAction {
  const ShareAction();
}

/// Nothing to do: the share carried nothing.
final class ShareIgnored extends ShareAction {
  /// Constructor.
  const ShareIgnored();
}

/// The shared text is a forum link the app has a page for: open that page.
final class ShareOpenRoute extends ShareAction {
  /// Constructor.
  const ShareOpenRoute(this.route);

  /// The page of the link.
  final RecognizedRoute route;
}

/// The shared text is a forum link the app has no page for: the "open in app" page shows it, to open in the browser.
final class ShareOpenInApp extends ShareAction {
  /// Constructor.
  const ShareOpenInApp(this.url);

  /// The link.
  final String url;
}

/// Write a new thread with what was shared: the text as its body (with the subject as title) and the images as
/// attachments; the forum is chosen first.
final class ShareCompose extends ShareAction {
  /// Constructor.
  const ShareCompose({required this.subject, required this.text, required this.imagePaths});

  /// The title, empty when none was shared.
  final String subject;

  /// The body, empty when only images were shared.
  final String text;

  /// The images to attach.
  final List<String> imagePaths;
}

/// A new thread needs an account: log in first, then [compose].
final class ShareLoginFirst extends ShareAction {
  /// Constructor.
  const ShareLoginFirst(this.compose);

  /// What to write once logged in.
  final ShareCompose compose;
}

/// Decide what to do with [content], shared by another app, when the account in use is [loggedIn] or none is.
///
/// * A text that is one forum link and nothing else (a thread, a forum, a profile shared from a browser) opens its
///   page as the app's url dispatcher does ([ParseUrl.parseUrlToRoute]); one the app has no page for goes to the
///   "open in app" page ([ShareOpenInApp]). No account is needed to read.
/// * Any other text, and every image, starts a new thread ([ShareCompose]), after a login when no account is in use
///   ([ShareLoginFirst]).
/// * An empty share is ignored.
ShareAction decideShare(SharedContent content, {required bool loggedIn}) {
  if (content.isEmpty) {
    return const ShareIgnored();
  }
  final text = content.text ?? '';
  if (content.imagePaths.isEmpty && _isForumLink(text)) {
    final route = text.parseUrlToRoute();
    return route == null ? ShareOpenInApp(text) : ShareOpenRoute(route);
  }
  final compose = ShareCompose(subject: content.subject ?? '', text: text, imagePaths: content.imagePaths);
  return loggedIn ? compose : ShareLoginFirst(compose);
}

/// Whether [text] is one absolute forum link and nothing else.
bool _isForumLink(String text) {
  if (text.isEmpty || text.contains(RegExp(r'\s'))) {
    return false;
  }
  final uri = Uri.tryParse(text);
  return uri != null && uri.isForumHost;
}
