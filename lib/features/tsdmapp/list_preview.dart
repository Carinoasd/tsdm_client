import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Query parameter asking the forum's plugin for the preview of every thread row of a list page (plugin 3.1.0), sent
/// together with [tsdmAppJsonQuery]: the forum page (`schema: 2`), the guide lists (`schema: 7`), the search results
/// (`schema: 6`, the redirect of a new search carries it) and the "my threads" pages (`schema: 9`, a member's threads
/// too).
///
/// Every thread row of the answer then carries `preview` (the excerpt and up to three images of its first floor, or
/// the reason none is given, [ThreadPreview.fromApi]); a reply row and a comment row carry `null`. Without the
/// parameter the answer is the one of plugin 3.0.0, word for word. An older plugin does not know it and answers the
/// rows without `preview`. Sent only when the plugin is known to answer it ([TsdmAppApi.knowsPreview]) and the
/// settings show some of it ([tsdmAppListPreviewWanted]).
const tsdmAppPreviewQuery = 'tsdmpreview=1';

/// [tsdmAppPreviewQuery] as parameters, for a page whose url is built from a map of parameters (none when the
/// previews are not wanted now, [tsdmAppListPreviewWanted]).
Map<String, String> tsdmAppListPreviewParameters() =>
    tsdmAppListPreviewWanted() ? const {'tsdmpreview': '1'} : const {};

/// Whether the list pages asked now carry [tsdmAppPreviewQuery]: the forum's plugin is known to answer it
/// ([TsdmAppApi.knowsPreview]) and the settings show the excerpts or the thumbnails ([SettingsKeys.threadCardShowExcerpt],
/// [SettingsKeys.threadCardThumbnailMode] other than never). Nothing is asked of the forum that no list would show.
bool tsdmAppListPreviewWanted() {
  if (!TsdmAppApi.knowsPreview) {
    return false;
  }
  final settings = getIt.isRegistered<SettingsRepository>() ? getIt.get<SettingsRepository>().currentSettings : null;
  final showExcerpt = settings?.threadCardShowExcerpt ?? SettingsKeys.threadCardShowExcerpt.defaultValue;
  final thumbnailMode = ThreadThumbnailMode.fromIndex(
    settings?.threadCardThumbnailMode ?? SettingsKeys.threadCardThumbnailMode.defaultValue,
  );
  return showExcerpt || thumbnailMode != ThreadThumbnailMode.never;
}

/// Whether a list page [uri] lists threads the forum's plugin previews: not a list of replies or comments (`type`
/// `reply`, `postcomment`: their rows carry `null`), nor the guide index (`view=index`, which the homepage shows as
/// short rows without previews).
bool tsdmAppListHasThreadRows(Uri uri) {
  final type = uri.queryParameters['type'];
  return type != 'reply' && type != 'postcomment' && uri.queryParameters['view'] != 'index';
}

/// [url], a list page asked in the JSON mode, with [tsdmAppPreviewQuery] when the previews are wanted now
/// ([tsdmAppListPreviewWanted]) and the page lists threads ([tsdmAppListHasThreadRows]); the parameter goes before a
/// `#fragment` and is not added twice.
String withTsdmAppListPreview(String url) {
  if (!tsdmAppListPreviewWanted()) {
    return url;
  }
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  final uri = Uri.tryParse(base);
  if (uri == null || !tsdmAppListHasThreadRows(uri) || uri.queryParameters.containsKey('tsdmpreview')) {
    return url;
  }
  final separator = !base.contains('?') ? '?' : (base.endsWith('?') || base.endsWith('&') ? '' : '&');
  return '$base$separator$tsdmAppPreviewQuery${hash < 0 ? '' : url.substring(hash)}';
}
