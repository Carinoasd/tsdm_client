import 'package:tsdm_client/constants/url.dart';
import 'package:universal_html/html.dart' as uh;

/// The read-only medal catalogue endpoint.
const medalCenterUrl = '$baseUrl/plugin.php?id=dsu_medalCenter:memcp';

/// Only catalogue navigation is allowed; apply/buy/manage URLs are never fetched.
String? medalCatalogUrl(String? href) {
  if (href == null || href.trim().isEmpty) return null;
  final relative = Uri.tryParse(href.trim());
  if (relative == null) return null;
  final uri = Uri.parse(medalCenterUrl).resolveUri(relative);
  if (!['https', 'http'].contains(uri.scheme) ||
      uri.origin != Uri.parse(baseUrl).origin ||
      uri.userInfo.isNotEmpty ||
      uri.path != '/plugin.php' ||
      uri.queryParameters['id'] != 'dsu_medalCenter:memcp' ||
      uri.queryParameters.keys.any((k) => !{'id', 'typeid', 'page'}.contains(k))) {
    return null;
  }
  for (final key in ['typeid', 'page']) {
    if (uri.queryParameters[key] case final value?) {
      if ((int.tryParse(value) ?? 0) <= 0) return null;
    }
  }
  return uri.toString();
}

/// A server-provided medal acquisition action.
enum MedalActionType {
  /// Buy using the forum's configured credits.
  purchase,

  /// Claim immediately when eligible.
  apply,

  /// Submit a reason for moderator review.
  manualReview,

  /// Claim through the forum's sign-in condition.
  signIn,
}

/// A safe action URL extracted from the medal catalogue.
final class CatalogMedalAction {
  /// Constructor.
  const CatalogMedalAction({required this.type, required this.url});

  /// Action kind.
  final MedalActionType type;

  /// Safe server URL.
  final String url;
}

/// Validate and classify an action link emitted by dsu_medalCenter.
CatalogMedalAction? medalActionUrl(String? href) {
  if (href == null || href.trim().isEmpty) return null;
  final relative = Uri.tryParse(href.trim());
  if (relative == null) return null;
  final uri = Uri.parse(medalCenterUrl).resolveUri(relative);
  if (!['https', 'http'].contains(uri.scheme) ||
      uri.origin != Uri.parse(baseUrl).origin ||
      uri.userInfo.isNotEmpty ||
      uri.path != '/plugin.php') {
    return null;
  }
  final params = uri.queryParameters;
  final id = params['id'];
  final action = params['action'];
  final medalId = params['medalid'] ?? params['applymedalid'];
  if (medalId == null || (int.tryParse(medalId) ?? 0) <= 0 || action == null) return null;
  if (id == 'dsu_medalCenter:memcp' && action == 'apply') {
    final unexpected = params.keys.toSet()..removeAll({'id', 'action', 'medalid', 'applytype'});
    if (unexpected.isNotEmpty || params['medalid'] == null) return null;
    final type = switch (params['applytype']) {
      '5' => MedalActionType.purchase,
      '6' => MedalActionType.signIn,
      '1' => MedalActionType.apply,
      _ => null,
    };
    return type == null ? null : CatalogMedalAction(type: type, url: uri.toString());
  }
  if (id == 'dsu_medalCenter:specmedal' && action == 'newapply') {
    final unexpected = params.keys.toSet()..removeAll({'id', 'action', 'applymedalid'});
    if (unexpected.isNotEmpty || params['applymedalid'] == null) return null;
    return CatalogMedalAction(type: MedalActionType.manualReview, url: uri.toString());
  }
  return null;
}

/// Original category label and safe catalogue link.
final class MedalCategory {
  /// Constructor.
  const MedalCategory(this.name, this.url);

  /// Original label.
  final String name;

  /// Catalogue URL.
  final String url;
}

/// A medal and its server-provided acquisition details.
final class CatalogMedal {
  /// Constructor.
  const CatalogMedal({
    required this.id,
    required this.name,
    required this.method,
    required this.description,
    required this.details,
    this.imageUrl,
    this.accountStatus,
    this.actions = const [],
  });

  /// Server medal ID.
  final String id;

  /// Original name (including any permanent/limited designation).
  final String name;

  /// Safe image URL, if supplied.
  final String? imageUrl;

  /// Acquisition method; missing stays missing, never interpreted as free.
  final String method;

  /// Original description.
  final String description;

  /// Conditions, every currency/price and duration as labelled by the server.
  final List<String> details;

  /// Account-specific eligibility statement, if the forum provides one.
  final String? accountStatus;

  /// Actions currently allowed by the server for this account.
  final List<CatalogMedalAction> actions;
}

/// One page of the medal catalogue.
final class MedalCatalog {
  /// Constructor.
  const MedalCatalog({
    this.categories = const [],
    this.medals = const [],
    this.page = 1,
    this.previousUrl,
    this.nextUrl,
    this.supported = true,
    this.message,
  });

  /// Categories in source order.
  final List<MedalCategory> categories;

  /// Medals on the current page.
  final List<CatalogMedal> medals;

  /// Current page reported by the forum.
  final int page;

  /// Safe previous page link, if present.
  final String? previousUrl;

  /// Safe next page link, if present.
  final String? nextUrl;

  /// Whether the document contains a known catalogue layout.
  final bool supported;

  /// A server-provided permission/empty message.
  final String? message;
}

String _text(uh.Element? node) {
  if (node == null) return '';
  final clone = node.clone(true) as uh.Element;
  for (final e in clone.querySelectorAll('script, style, button, input')) {
    e.remove();
  }
  for (final br in clone.querySelectorAll('br')) {
    br.replaceWith(uh.Text('\n'));
  }
  return (clone.text ?? '')
      .split('\n')
      .map((s) => s.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((s) => s.isNotEmpty)
      .join('\n');
}

/// Parse X5's medal list and its separate hover-detail nodes without running scripts.
MedalCatalog parseMedalCatalog(uh.Document document) {
  final list = document.querySelector('ul.mdl');
  if (list == null) {
    return MedalCatalog(supported: false, message: _text(document.querySelector('#messagetext')));
  }
  final categories = <MedalCategory>[];
  for (final link in document.querySelectorAll('h3.tbmu a[href]')) {
    final url = medalCatalogUrl(link.getAttribute('href'));
    if (url != null && _text(link).isNotEmpty) categories.add(MedalCategory(_text(link), url));
  }
  final medals = <CatalogMedal>[];
  for (final item in list.querySelectorAll('li.pns')) {
    final img = item.querySelector('img[id^="mc_medal"]');
    final id = img?.id.replaceFirst('mc_medal', '');
    final name = _text(item.querySelector('p.mtn'));
    if (id == null || int.tryParse(id) == null || name.isEmpty) continue;
    final detail = document.querySelector('#mc_medal${id}_menu');
    final image = Uri.tryParse(img?.getAttribute('src') ?? '');
    final imageUri = image == null ? null : Uri.parse(baseUrl).resolveUri(image);
    final details = <String>[];
    for (final block in detail?.children ?? <uh.Element>[]) {
      if (block.classes.contains('title') || block.classes.contains('desc')) continue;
      final text = _text(block);
      if (text.isNotEmpty) details.add(text);
    }
    final status = _text(item.querySelector('.dsu_medal_unmet'));
    final actions = <CatalogMedalAction>[];
    for (final link in item.querySelectorAll('a[href]')) {
      final action = medalActionUrl(link.getAttribute('href'));
      if (action != null) actions.add(action);
    }
    medals.add(
      CatalogMedal(
        id: id,
        name: name,
        method: _text(item.querySelector('span')),
        description: _text(detail?.querySelector('.desc')),
        details: List.unmodifiable(details),
        accountStatus: status.isEmpty ? null : status,
        actions: List.unmodifiable(actions),
        imageUrl:
            imageUri != null &&
                imageUri.host.isNotEmpty &&
                imageUri.userInfo.isEmpty &&
                ['https', 'http'].contains(imageUri.scheme) &&
                (img?.getAttribute('src')?.isNotEmpty ?? false)
            ? imageUri.toString()
            : null,
      ),
    );
  }
  final pagination = document.querySelector('.pg');
  return MedalCatalog(
    categories: List.unmodifiable(categories),
    medals: List.unmodifiable(medals),
    page: int.tryParse(_text(pagination?.querySelector('strong'))) ?? 1,
    previousUrl: medalCatalogUrl(pagination?.querySelector('a.prev')?.getAttribute('href')),
    nextUrl: medalCatalogUrl(pagination?.querySelector('a.nxt')?.getAttribute('href')),
    message: _text(list.querySelector('.emp')),
  );
}
