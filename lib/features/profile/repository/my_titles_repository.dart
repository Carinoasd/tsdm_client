import 'package:collection/collection.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// The repository for user titles.
///
/// Page layout (Discuz X5, plugin tsdmtitle):
///
/// ```html
/// <div id="ct">
///   <div class="mn">
///     <div class="bm"><div class="bm_h"><h2>当前使用的称号</h2></div><div class="bm_c"><table class="dt">...</table></div></div>
///     <div class="bm"><div class="bm_h"><h2>当前拥有的称号</h2></div><div class="bm_c"><table class="dt">...</table></div></div>
///   </div>
/// </div>
/// ```
///
/// Switching title is a POST form in each row:
///
/// ```html
/// <form action="plugin.php?id=tsdmtitle:tsdmtitle&action=settitle" method="post">
///   <input type="hidden" name="formhash" value="..." />
///   <input type="hidden" name="tsdmtitle_return" value="plugin.php?id=tsdmtitle:tsdmtitle&amp;app=plugin" />
///   <input type="hidden" name="settitleid" value="330" />
///   <button name="settitlesubmit" type="submit" value="true">...</button>
/// </form>
/// ```
final class MyTitlesRepository with LoggerMixin {
  static const _pageUrl = '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle';
  static const _setTitleUrl = '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle&action=settitle';

  /// Form hash parsed from the titles page, required when switching title.
  String? _formHash;

  /// Fetch all available secondary titles for current user.
  AsyncEither<List<SecondaryTitle>> fetchSecondaryTitles() =>
      getIt.get<NetClientProvider>().get(_pageUrl).mapHttp((v) => parseHtmlDocument(v.data as String)).map((doc) {
        _formHash = doc.querySelector('input[name="formhash"]')?.attributes['value'] ?? _formHash;
        return SecondaryTitle.parseTitlesPage(doc);
      });

  /// Get the form hash, fetch the page if not cached.
  AsyncEither<String> _getFormHash() {
    if (_formHash != null) {
      return TaskEither.right(_formHash!);
    }
    return fetchSecondaryTitles().flatMap(
      (_) => switch (_formHash) {
        final String v => TaskEither.right(v),
        null => TaskEither.left(ServerRespondedErrorException('form hash not found in titles page')),
      },
    );
  }

  /// Submit the switch title request, [id] is the title id, 0 to unset.
  ///
  /// The server responds a "提示信息" page for both success and failure so the result is verified by fetching the titles
  /// page again and checking the current title.
  AsyncVoidEither _submit(int id) => _getFormHash().flatMap(
    (formHash) => getIt
        .get<NetClientProvider>()
        .postForm(
          _setTitleUrl,
          data: <String, String>{
            'formhash': formHash,
            'tsdmtitle_return': 'plugin.php?id=tsdmtitle:tsdmtitle&app=plugin',
            'settitleid': '$id',
            'settitlesubmit': 'true',
          },
        )
        .mapHttp((v) => parseHtmlDocument(v.data as String).querySelector('div#messagetext > p')?.innerText.trim())
        .flatMap(
          (message) => fetchSecondaryTitles().flatMap((titles) {
            final currentId = titles.firstWhereOrNull((e) => e.activated)?.id ?? 0;
            if (currentId == id) {
              return TaskEither.right(null);
            }
            error('failed to set title $id: current title is $currentId, message=$message');
            return TaskEither<AppException, void>.left(ServerRespondedErrorException(message ?? 'unknown error'));
          }),
        ),
  );

  /// Switch to the secondary title specified by [id].
  AsyncVoidEither setSecondaryTitle(int id) => _submit(id);

  /// Unset user specified secondary title, set to default one.
  AsyncVoidEither unsetSecondaryTitle() => _submit(0);
}
