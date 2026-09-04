import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/html.dart' as uh;

part 'secondary_title.mapper.dart';

/// An available secondary title.
///
/// Some fields in the original page are ignore:
///
/// * Title description.
/// * Expiration.
@MappableClass()
final class SecondaryTitle with SecondaryTitleMappable {
  /// Constructor.
  const SecondaryTitle({required this.id, required this.name, required this.imageUrl, required this.activated});

  /// Parse the secondary title info in tr node.
  /// <tr>
  ///   <td>${ID}</td>
  ///   <td>${NAME}</td>
  ///   <td></td>
  ///   <td><img src=${IMAGE_URL}></td>
  ///   <td>${EXPIRATION}</td>
  ///   <td><a href="url_to_activate">activate_the_title</a></td>
  /// </tr>
  static SecondaryTitle? fromTr(uh.Element element) {
    final tds = element.querySelectorAll('td');
    if (tds.length != 6) {
      talker.error('failed to build secondary title: invalid td count: ${tds.length}');
      return null;
    }

    final id = tds.first.innerText.trim().parseToInt();
    final name = tds[1].innerText.trim();
    final imageUrl = tds[3].querySelector('img')?.imageUrl();
    if (id == null || name.isEmpty || imageUrl == null) {
      talker.error('invalid secondary title data: id=$id, name=$name, imageUrl=$imageUrl');
      return null;
    }

    return SecondaryTitle(id: id, name: name, imageUrl: imageUrl, activated: false);
  }

  /// Find the table under the block whose title is [title].
  static uh.Element? _findTable(uh.Document doc, String title) {
    for (final h in doc.querySelectorAll('div.bm > div.bm_h > h2')) {
      if (h.innerText.trim() == title) {
        return h.parent?.parent?.querySelector('table.dt');
      }
    }
    return null;
  }

  /// Parse the titles page [doc] into list of [SecondaryTitle], the activated one is marked.
  ///
  /// Marked as public for testing.
  ///
  /// Page layout (Discuz X5, plugin tsdmtitle):
  ///
  /// ```html
  /// <div class="bm"><div class="bm_h"><h2>当前使用的称号</h2></div><div class="bm_c"><table class="dt">...</table></div></div>
  /// <div class="bm"><div class="bm_h"><h2>当前拥有的称号</h2></div><div class="bm_c"><table class="dt">...</table></div></div>
  /// ```
  static List<SecondaryTitle> parseTitlesPage(uh.Document doc) {
    final ownedTable = _findTable(doc, '当前拥有的称号') ?? doc.querySelectorAll('table.dt').lastOrNull;
    final currentTable = _findTable(doc, '当前使用的称号') ?? doc.querySelectorAll('table.dt').firstOrNull;
    final allAvailableTitles = (ownedTable?.querySelectorAll('tbody > tr') ?? <uh.Element>[])
        .where((e) => e.querySelector('td') != null)
        .map(SecondaryTitle.fromTr)
        .whereType<SecondaryTitle>()
        .toList();
    final currentTitleId = currentTable?.querySelector('tbody > tr > td')?.innerText.trim().parseToInt();
    final idx = allAvailableTitles.indexWhere((v) => v.id == currentTitleId);
    if (idx >= 0) {
      allAvailableTitles[idx] = allAvailableTitles[idx].copyWith(activated: true);
    }
    return allAvailableTitles;
  }

  /// Title id.
  final int id;

  /// Title name.
  final String name;

  /// Title image url.
  final String imageUrl;

  /// Using current secondary title or not.
  final bool activated;
}
