part of 'models.dart';

/// Info to check before purchasing.
@MappableClass()
class PurchaseConfirmInfo with PurchaseConfirmInfoMappable {
  /// Constructor.
  const PurchaseConfirmInfo({
    required this.author,
    required this.price,
    required this.authorProfit,
    required this.coinsLast,
    required this.formHash,
    required this.referer,
    required this.tid,
    required this.handleKey,
    this.submitUrl,
    this.submitFields,
  });

  /// Author name
  final String? author;

  /// Price.
  final String? price;

  /// How many coins the author will get.
  final String? authorProfit;

  /// How many coins last after purchase.
  final String? coinsLast;

  /// Data used in purchasing.
  final String formHash;

  /// Referer parameter in request.
  final String referer;

  /// Thread id.
  final String tid;

  /// Handle key parameter in request.
  final String handleKey;

  /// The url the form posts to (`submit.url` of the forum's app API, plugin 3.0.0, absolute; posted with `inajax=1`
  /// as the website does); null when the window was parsed from the web page, which posts to the fixed pay url.
  final String? submitUrl;

  /// The hidden fields of the form and its submit button as served (`submit.fields`, plugin 3.0.0); null when the
  /// window was parsed from the web page, which posts [formHash], [referer], [tid] and [handleKey].
  final Map<String, String>? submitFields;
}
