import 'package:tsdm_client/features/pokemon/models/models.dart';

/// Merge inventory rows of the same item type into a single entry.
///
/// The server returns one row per `pm_myitem` record, so owning the same item in two stacks would otherwise be shown
/// twice; merging sums the quantities.
List<InventoryItem> mergeInventoryItems(List<InventoryItem> items) {
  final byType = <int, InventoryItem>{};
  final order = <int>[];
  for (final item in items) {
    final existing = byType[item.typeId];
    if (existing == null) {
      byType[item.typeId] = item;
      order.add(item.typeId);
    } else {
      byType[item.typeId] = existing.copyWith(
        quantity: existing.quantity + item.quantity,
        nums: existing.nums + item.nums,
      );
    }
  }
  return [for (final id in order) byType[id]!];
}
