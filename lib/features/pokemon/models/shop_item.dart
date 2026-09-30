part of 'models.dart';

/// One item sold in the shop (商店).
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class ShopItem with ShopItemMappable {
  /// Constructor.
  const ShopItem({
    required this.id,
    required this.name,
    required this.description,
    required this.typeId,
    required this.typeName,
    required this.image,
    required this.price,
    required this.stock,
    required this.effect,
    required this.canBuy,
  });

  /// Tolerant decode: every field is optional, missing values fall back to a safe default.
  factory ShopItem.fromMap(Map<String, dynamic> map) => ShopItem(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    typeId: (map['type_id'] as num?)?.toInt() ?? 0,
    typeName: map['type_name'] as String? ?? '',
    image: map['image'] as String? ?? '',
    price: (map['price'] as num?)?.toInt() ?? 0,
    stock: (map['stock'] as num?)?.toInt() ?? 0,
    effect: ShopItemEffect.fromMap(map['effect'] as Map<String, dynamic>? ?? const {}),
    canBuy: map['can_buy'] == true,
  );

  /// Item id.
  final int id;

  /// Item name.
  final String name;

  /// Item description.
  final String description;

  /// Category id.
  final int typeId;

  /// Category name.
  final String typeName;

  /// Icon filename (tpname).
  final String image;

  /// Price in in-game money.
  final int price;

  /// Stock (-1 for unlimited).
  final int stock;

  /// Effect description.
  final ShopItemEffect effect;

  /// Whether the current user can afford it.
  final bool canBuy;
}

/// Effect of a shop item.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class ShopItemEffect with ShopItemEffectMappable {
  /// Constructor.
  const ShopItemEffect({
    required this.description,
    required this.effectType,
    required this.addhp,
    required this.addexp,
    required this.addlv,
  });

  /// Tolerant decode.
  factory ShopItemEffect.fromMap(Map<String, dynamic> map) => ShopItemEffect(
    description: map['description'] as String? ?? '',
    effectType: map['type'] as String? ?? '',
    addhp: (map['addhp'] as num?)?.toInt() ?? 0,
    addexp: (map['addexp'] as num?)?.toInt() ?? 0,
    addlv: (map['addlv'] as num?)?.toInt() ?? 0,
  );

  /// Human-readable effect.
  final String description;

  /// Effect type (heal ...).
  @MappableField(key: 'type')
  final String effectType;

  /// HP restored.
  final int addhp;

  /// Experience gained.
  final int addexp;

  /// Level gained.
  final int addlv;
}

/// A page of shop items.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class ShopPage with ShopPageMappable {
  /// Constructor.
  const ShopPage({
    required this.items,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });

  /// Tolerant decode.
  factory ShopPage.fromMap(Map<String, dynamic> map) => ShopPage(
    items: (map['items'] as List?)?.whereType<Map<String, dynamic>>().map(ShopItem.fromMap).toList() ?? const [],
    total: (map['total'] as num?)?.toInt() ?? 0,
    page: (map['page'] as num?)?.toInt() ?? 1,
    perPage: (map['per_page'] as num?)?.toInt() ?? 0,
    totalPages: (map['total_pages'] as num?)?.toInt() ?? 1,
  );

  /// Items on this page.
  final List<ShopItem> items;

  /// Total item count.
  final int total;

  /// Current page number.
  final int page;

  /// Items per page.
  final int perPage;

  /// Total number of pages.
  final int totalPages;
}

/// Result of a successful purchase.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class BuyResult with BuyResultMappable {
  /// Constructor.
  const BuyResult({
    required this.message,
    required this.totalCost,
    required this.remainingMoney,
    required this.itemsPurchased,
  });

  /// Tolerant decode.
  factory BuyResult.fromMap(Map<String, dynamic> map) => BuyResult(
    message: map['message'] as String? ?? '',
    totalCost: (map['total_cost'] as num?)?.toInt() ?? 0,
    remainingMoney: (map['remaining_money'] as num?)?.toInt() ?? 0,
    itemsPurchased: (map['items_purchased'] as num?)?.toInt() ?? 0,
  );

  /// Server message.
  final String message;

  /// Total cost.
  final int totalCost;

  /// Remaining money after purchase.
  final int remainingMoney;

  /// Number of items purchased.
  final int itemsPurchased;
}
