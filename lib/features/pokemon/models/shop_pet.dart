part of 'models.dart';

/// A pokemon for sale in the shop (`shop&action=pets`).
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class ShopPet with ShopPetMappable {
  /// Constructor.
  const ShopPet({
    required this.id,
    required this.name,
    required this.type1,
    required this.hp,
    required this.atk,
    required this.def,
    required this.spatk,
    required this.spdef,
    required this.speed,
    required this.price,
    required this.canBuy,
    this.type2,
  });

  /// Tolerant decode.
  factory ShopPet.fromMap(Map<String, dynamic> map) => ShopPet(
    id: (map['id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    type1: map['type_1'] as String? ?? '',
    type2: map['type_2'] as String?,
    hp: (map['hp'] as num?)?.toInt() ?? 0,
    atk: (map['atk'] as num?)?.toInt() ?? 0,
    def: (map['def'] as num?)?.toInt() ?? 0,
    spatk: (map['spatk'] as num?)?.toInt() ?? 0,
    spdef: (map['spdef'] as num?)?.toInt() ?? 0,
    speed: (map['speed'] as num?)?.toInt() ?? 0,
    price: (map['price'] as num?)?.toInt() ?? 0,
    canBuy: map['can_buy'] == true,
  );

  /// Species id (`pm_data.id`).
  final int id;

  /// Species name.
  final String name;

  /// Primary type.
  final String type1;

  /// Secondary type, when present.
  final String? type2;

  /// Base HP.
  final int hp;

  /// Base attack.
  final int atk;

  /// Base defense.
  final int def;

  /// Base special attack.
  final int spatk;

  /// Base special defense.
  final int spdef;

  /// Base speed.
  final int speed;

  /// Price in pet money.
  final int price;

  /// Whether the user has enough money to buy it.
  final bool canBuy;
}

/// A page of the pet shop.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class ShopPetsPage with ShopPetsPageMappable {
  /// Constructor.
  const ShopPetsPage({
    required this.pets,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });

  /// Tolerant decode.
  factory ShopPetsPage.fromMap(Map<String, dynamic> map) => ShopPetsPage(
    pets: _listOf3(map['pets'], ShopPet.fromMap),
    total: (map['total'] as num?)?.toInt() ?? 0,
    page: (map['page'] as num?)?.toInt() ?? 1,
    perPage: (map['per_page'] as num?)?.toInt() ?? 0,
    totalPages: (map['total_pages'] as num?)?.toInt() ?? 0,
  );

  /// The pets on this page.
  final List<ShopPet> pets;

  /// Total number of pets for sale.
  final int total;

  /// Current page (1-based).
  final int page;

  /// Items per page.
  final int perPage;

  /// Total number of pages.
  final int totalPages;
}

/// The answer of `shop&action=buy_pet`.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class BuyPetResult with BuyPetResultMappable {
  /// Constructor.
  const BuyPetResult({
    required this.message,
    required this.totalCost,
    required this.remainingMoney,
    required this.pokemonName,
    required this.pokemonTypeId,
    required this.site,
    required this.quantity,
  });

  /// Tolerant decode.
  factory BuyPetResult.fromMap(Map<String, dynamic> map) => BuyPetResult(
    message: map['message'] as String? ?? '',
    totalCost: (map['total_cost'] as num?)?.toInt() ?? 0,
    remainingMoney: (map['remaining_money'] as num?)?.toInt() ?? 0,
    pokemonName: map['pokemon_name'] as String? ?? '',
    pokemonTypeId: (map['pokemon_type_id'] as num?)?.toInt() ?? 0,
    site: (map['site'] as num?)?.toInt() ?? 0,
    quantity: (map['quantity'] as num?)?.toInt() ?? 0,
  );

  /// Server message.
  final String message;

  /// Total amount spent.
  final int totalCost;

  /// Money left after the purchase.
  final int remainingMoney;

  /// Name of the bought species.
  final String pokemonName;

  /// Bought species id.
  final int pokemonTypeId;

  /// Where the new pet was placed (1=first, 2=bag, 3=storage).
  final int site;

  /// Number bought.
  final int quantity;
}

/// Decode a JSON list of objects into a typed list.
List<T> _listOf3<T>(Object? raw, T Function(Map<String, dynamic>) decode) {
  if (raw is! List) return const [];
  return raw.whereType<Map<String, dynamic>>().map(decode).toList();
}
