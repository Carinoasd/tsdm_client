part of 'models.dart';

/// Common equipment bonus values shared by owned and shop equipment.
mixin EquipmentBonus {
  /// Bonus HP.
  int get equipmentHp;

  /// Bonus attack.
  int get equipmentAtk;

  /// Bonus defense.
  int get equipmentDef;

  /// Bonus special attack.
  int get equipmentSpatk;

  /// Bonus special defense.
  int get equipmentSpdef;

  /// Bonus speed.
  int get equipmentSd;

  /// Whether every bonus is zero.
  bool get hasNoBonus =>
      equipmentHp == 0 &&
      equipmentAtk == 0 &&
      equipmentDef == 0 &&
      equipmentSpatk == 0 &&
      equipmentSpdef == 0 &&
      equipmentSd == 0;
}

/// One equipment worn by a pokemon (`equipment_slots[].item`).
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class EquipmentItem with EquipmentItemMappable, EquipmentBonus {
  /// Constructor.
  const EquipmentItem({
    required this.myitemId,
    required this.typeId,
    required this.name,
    required this.description,
    required this.image,
    required this.zbtype,
    required this.equipmentHp,
    required this.equipmentAtk,
    required this.equipmentDef,
    required this.equipmentSpatk,
    required this.equipmentSpdef,
    required this.equipmentSd,
  });

  /// Tolerant decode.
  factory EquipmentItem.fromMap(Map<String, dynamic> map) => EquipmentItem(
    myitemId: (map['myitem_id'] as num?)?.toInt() ?? 0,
    typeId: (map['type_id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    image: map['image'] as String? ?? '',
    zbtype: (map['zbtype'] as num?)?.toInt() ?? 0,
    equipmentHp: (map['equipment_hp'] as num?)?.toInt() ?? 0,
    equipmentAtk: (map['equipment_atk'] as num?)?.toInt() ?? 0,
    equipmentDef: (map['equipment_def'] as num?)?.toInt() ?? 0,
    equipmentSpatk: (map['equipment_spatk'] as num?)?.toInt() ?? 0,
    equipmentSpdef: (map['equipment_spdef'] as num?)?.toInt() ?? 0,
    equipmentSd: (map['equipment_sd'] as num?)?.toInt() ?? 0,
  );

  /// Owned item row id (`pm_myitem.id`).
  final int myitemId;

  /// Equipment type id (`pm_itemdata.id`).
  final int typeId;

  /// Display name.
  final String name;

  /// Description.
  final String description;

  /// Image filename.
  final String image;

  /// Equipment slot category.
  final int zbtype;

  @override
  final int equipmentHp;

  @override
  final int equipmentAtk;

  @override
  final int equipmentDef;

  @override
  final int equipmentSpatk;

  @override
  final int equipmentSpdef;

  @override
  final int equipmentSd;
}

/// One of the four equipment slots of a pokemon.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class EquipmentSlot with EquipmentSlotMappable {
  /// Constructor.
  const EquipmentSlot({required this.slotIndex, required this.equipmentId, this.item});

  /// Tolerant decode.
  factory EquipmentSlot.fromMap(Map<String, dynamic> map) => EquipmentSlot(
    slotIndex: (map['slot_index'] as num?)?.toInt() ?? 0,
    equipmentId: (map['equipment_id'] as num?)?.toInt() ?? 0,
    item: map['item'] == null ? null : EquipmentItem.fromMap(map['item'] as Map<String, dynamic>),
  );

  /// Slot index, 0-3.
  final int slotIndex;

  /// `pm_myitem.id` currently in the slot, 0 when empty.
  final int equipmentId;

  /// The worn equipment, when the slot is not empty.
  final EquipmentItem? item;
}

/// An equipment the user owns (`owned_items`).
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class OwnedEquipment with OwnedEquipmentMappable, EquipmentBonus {
  /// Constructor.
  const OwnedEquipment({
    required this.myitemId,
    required this.typeId,
    required this.name,
    required this.description,
    required this.image,
    required this.quantity,
    required this.equippedCount,
    required this.availableCount,
    required this.isEquipped,
    required this.zbtype,
    required this.equipmentHp,
    required this.equipmentAtk,
    required this.equipmentDef,
    required this.equipmentSpatk,
    required this.equipmentSpdef,
    required this.equipmentSd,
  });

  /// Tolerant decode.
  factory OwnedEquipment.fromMap(Map<String, dynamic> map) => OwnedEquipment(
    myitemId: (map['myitem_id'] as num?)?.toInt() ?? 0,
    typeId: (map['type_id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    image: map['image'] as String? ?? '',
    quantity: (map['quantity'] as num?)?.toInt() ?? 0,
    equippedCount: (map['equipped_count'] as num?)?.toInt() ?? 0,
    availableCount: (map['available_count'] as num?)?.toInt() ?? 0,
    isEquipped: map['is_equipped'] == true,
    zbtype: (map['zbtype'] as num?)?.toInt() ?? 0,
    equipmentHp: (map['equipment_hp'] as num?)?.toInt() ?? 0,
    equipmentAtk: (map['equipment_atk'] as num?)?.toInt() ?? 0,
    equipmentDef: (map['equipment_def'] as num?)?.toInt() ?? 0,
    equipmentSpatk: (map['equipment_spatk'] as num?)?.toInt() ?? 0,
    equipmentSpdef: (map['equipment_spdef'] as num?)?.toInt() ?? 0,
    equipmentSd: (map['equipment_sd'] as num?)?.toInt() ?? 0,
  );

  /// Owned item row id (`pm_myitem.id`).
  final int myitemId;

  /// Equipment type id (`pm_itemdata.id`).
  final int typeId;

  /// Display name.
  final String name;

  /// Description.
  final String description;

  /// Image filename.
  final String image;

  /// Total quantity owned.
  final int quantity;

  /// How many copies are currently worn by any pokemon.
  final int equippedCount;

  /// How many copies are free to equip.
  final int availableCount;

  /// Whether this equipment is worn by the pokemon being viewed.
  final bool isEquipped;

  /// Equipment slot category.
  final int zbtype;

  @override
  final int equipmentHp;

  @override
  final int equipmentAtk;

  @override
  final int equipmentDef;

  @override
  final int equipmentSpatk;

  @override
  final int equipmentSpdef;

  @override
  final int equipmentSd;
}

/// A purchasable equipment from the equipment shop (`shop_items`).
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class ShopEquipment with ShopEquipmentMappable, EquipmentBonus {
  /// Constructor.
  const ShopEquipment({
    required this.typeId,
    required this.name,
    required this.description,
    required this.image,
    required this.price,
    required this.zbtype,
    required this.equipmentHp,
    required this.equipmentAtk,
    required this.equipmentDef,
    required this.equipmentSpatk,
    required this.equipmentSpdef,
    required this.equipmentSd,
    required this.isOwned,
    required this.canBuy,
  });

  /// Tolerant decode.
  factory ShopEquipment.fromMap(Map<String, dynamic> map) => ShopEquipment(
    typeId: (map['type_id'] as num?)?.toInt() ?? 0,
    name: map['name'] as String? ?? '',
    description: map['description'] as String? ?? '',
    image: map['image'] as String? ?? '',
    price: (map['price'] as num?)?.toInt() ?? 0,
    zbtype: (map['zbtype'] as num?)?.toInt() ?? 0,
    equipmentHp: (map['equipment_hp'] as num?)?.toInt() ?? 0,
    equipmentAtk: (map['equipment_atk'] as num?)?.toInt() ?? 0,
    equipmentDef: (map['equipment_def'] as num?)?.toInt() ?? 0,
    equipmentSpatk: (map['equipment_spatk'] as num?)?.toInt() ?? 0,
    equipmentSpdef: (map['equipment_spdef'] as num?)?.toInt() ?? 0,
    equipmentSd: (map['equipment_sd'] as num?)?.toInt() ?? 0,
    isOwned: map['is_owned'] == true,
    canBuy: map['can_buy'] == true,
  );

  /// Equipment type id (`pm_itemdata.id`), used as the shop `item_id` when buying.
  final int typeId;

  /// Display name.
  final String name;

  /// Description.
  final String description;

  /// Image filename.
  final String image;

  /// Price in pet money.
  final int price;

  /// Equipment slot category.
  final int zbtype;

  @override
  final int equipmentHp;

  @override
  final int equipmentAtk;

  @override
  final int equipmentDef;

  @override
  final int equipmentSpatk;

  @override
  final int equipmentSpdef;

  @override
  final int equipmentSd;

  /// Whether the user already owns at least one.
  final bool isOwned;

  /// Whether the user has enough money to buy it.
  final bool canBuy;
}

/// The answer of `pokemon&action=equipment`.
@MappableClass(caseStyle: CaseStyle.snakeCase)
final class EquipmentResponse with EquipmentResponseMappable {
  /// Constructor.
  const EquipmentResponse({
    required this.pokemonId,
    required this.equipmentSlots,
    required this.ownedItems,
    required this.shopItems,
    required this.userMoney,
  });

  /// Tolerant decode.
  factory EquipmentResponse.fromMap(Map<String, dynamic> map) => EquipmentResponse(
    pokemonId: (map['pokemon_id'] as num?)?.toInt() ?? 0,
    equipmentSlots: _listOf2(map['equipment_slots'], EquipmentSlot.fromMap),
    ownedItems: _listOf2(map['owned_items'], OwnedEquipment.fromMap),
    shopItems: _listOf2(map['shop_items'], ShopEquipment.fromMap),
    userMoney: (map['user_money'] as num?)?.toInt() ?? 0,
  );

  /// Pet id.
  final int pokemonId;

  /// The four slots of the pokemon.
  final List<EquipmentSlot> equipmentSlots;

  /// Equipment the user owns.
  final List<OwnedEquipment> ownedItems;

  /// Equipment for sale.
  final List<ShopEquipment> shopItems;

  /// Current pet money.
  final int userMoney;
}

/// Decode a JSON list of objects into a typed list.
List<T> _listOf2<T>(Object? raw, T Function(Map<String, dynamic>) decode) {
  if (raw is! List) return const [];
  return raw.whereType<Map<String, dynamic>>().map(decode).toList();
}
