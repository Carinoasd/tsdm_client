import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';

/// Whether the thread page is asked with the floors' backgrounds: the `showPostBackgrounds` setting is on and the last
/// `status` of the forum's plugin said it knows [tsdmAppV4Query] ([TsdmAppV4.on]; nothing is asked to learn it here).
///
/// Plugin 4.1.0 answers the thread page asked so with `schema` 78 and the backgrounds (`backgrounds`, each floor's
/// `background`); 4.0.x answers it as without the parameter (`schema` 23, its `document` too): the page is read the
/// same way either way. Off, the page is asked exactly as before.
bool postBackgroundsAsked() =>
    TsdmAppV4.on &&
    getIt.isRegistered<SettingsRepository>() &&
    getIt.get<SettingsRepository>().currentSettings.showPostBackgrounds;

/// [url], a thread page already in the JSON mode (`withTsdmAppJson`: a query, no fragment), with [tsdmAppV4Query] when
/// [postBackgroundsAsked]; [url] itself otherwise.
String withPostBackgroundsQuery(String url) {
  if (!postBackgroundsAsked() || url.contains('#') || RegExp('[?&]tsdmv=').hasMatch(url)) {
    return url;
  }
  return '$url${url.contains('?') ? '&' : '?'}$tsdmAppV4Query';
}
