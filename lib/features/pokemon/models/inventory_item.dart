part of 'models.dart';

/// One item in the current user's inventory (背包).
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class InventoryItem with InventoryItemMappable {
  /// Constructor.
  const InventoryItem({
    required this.id,
    required this.typeId,
    required this.name,
    required this.description,
    required this.image,
    required this.quantity,
    required this.nums,
    required this.typeName,
    required this.canUse,
    required this.addhp,
    this.itemType,
  });

  /// Tolerant decode: every field is optional, missing values fall back to a safe default.
  factory InventoryItem.fromMap(Map<String, dynamic> map) => InventoryItem(
    id: (map['id'] as num?)?.toInt() ?? 0,
    typeId: (map['type_id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    image: map['image'] as String? ?? '',
    quantity: (map['quantity'] as num?)?.toInt() ?? 0,
    nums: (map['nums'] as num?)?.toInt() ?? 0,
    typeName: map['type_name'] as String? ?? '',
    canUse: map['can_use'] == true,
    addhp: (map['addhp'] as num?)?.toInt() ?? 0,
    itemType: (map['item_type'] as num?)?.toInt(),
  );

  /// Item row id (`pm_myitem.id`).
  final int id;

  /// Item type id (`pm_itemdata.id`).
  final int typeId;

  /// Item category type.
  final int? itemType;

  /// Item name.
  final String name;

  /// Item description.
  final String description;

  /// Icon filename (tpname).
  final String image;

  /// Owned quantity.
  final int quantity;

  /// Quantity usable in battle.
  final int nums;

  /// Category name.
  final String typeName;

  /// Whether the item can be used here.
  final bool canUse;

  /// HP restored by this item (HP potions only).
  final int addhp;
}

/// A page of inventory items.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class InventoryPage with InventoryPageMappable {
  /// Constructor.
  const InventoryPage({
    required this.items,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });

  /// Tolerant decode.
  factory InventoryPage.fromMap(Map<String, dynamic> map) => InventoryPage(
    items: (map['items'] as List?)?.whereType<Map<String, dynamic>>().map(InventoryItem.fromMap).toList() ?? const [],
    total: (map['total'] as num?)?.toInt() ?? 0,
    page: (map['page'] as num?)?.toInt() ?? 1,
    perPage: (map['per_page'] as num?)?.toInt() ?? 0,
    totalPages: (map['total_pages'] as num?)?.toInt() ?? 1,
  );

  /// Items on this page.
  final List<InventoryItem> items;

  /// Total item count.
  final int total;

  /// Current page number.
  final int page;

  /// Items per page.
  final int perPage;

  /// Total number of pages.
  final int totalPages;
}
