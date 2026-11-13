import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/editor/utils/custom_image_input.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/models/sync_removals.dart';

/// The section of the sync document holding the saved images of the emoji pickers ("my images", the `CustomImage`
/// table): one item per image, by its address.
///
/// ```json
/// "custom_images": {"<url>": {"updated": ms, "name": "…", "named": ms},
///                   "<url>": {"updated": ms, "deleted": true}}
/// ```
///
/// Only the address and the name go with the sync: the image itself stays where it is hosted. `updated` is when the
/// image was saved, saved again or renamed on a device (the stored time, whole seconds), or when it was deleted (a
/// record of the removal, kept on the device as [syncKeyRemovalsOf] reads them); `named` when it was given its name,
/// left out when that is `updated` (a version before it never writes it). Item by item the later wins, the name by
/// `named`: an image deleted on one device is deleted on the others unless one saved it again after that, and an
/// image saved again keeps a name given later on another device. The saved images are the device's, not one
/// account's: every account synced on the device carries them.
///
/// The latest within `syncCustomImagesFirstMaxBytes` are in this section, the others in [customImagesMoreSection]
/// (`SyncDocument.customImageItems` reads the two as one).
const customImagesSection = 'custom_images';

/// The section of the sync document holding the saved images past the part in [customImagesSection]: a version that
/// reads only that one carries it through as it is.
const customImagesMoreSection = 'custom_images_more';

/// Longest address of a saved image that goes with the sync; a longer one stays on its device.
const syncCustomImageUrlMaxLength = 2048;

/// A saved image as the sync sees it.
@immutable
final class CustomImageSyncEntry {
  /// Constructor.
  const CustomImageSyncEntry({required this.url, required this.name, required this.updated, int? named})
    : named = named == null || named > updated ? updated : named;

  /// The entry of the document item [item] of address [key], null when it is not one (an address this version does
  /// not save, a removal).
  static CustomImageSyncEntry? fromItem(String key, Map<String, dynamic> item) {
    final updated = item['updated'];
    final name = item['name'];
    if (!syncsCustomImageUrl(key) || updated is! num || item['deleted'] == true || item['deleted'] == 1) {
      return null;
    }
    return CustomImageSyncEntry(
      url: key,
      name: name is String ? name : '',
      updated: updated.toInt(),
      named: SyncDocument.namedOf(item),
    );
  }

  /// Address of the image.
  final String url;

  /// Name given to it, empty for none.
  final String name;

  /// When it was saved, saved again or renamed, milliseconds (whole seconds: the time is stored in seconds).
  final int updated;

  /// When it was given its [name], milliseconds: [updated] at most.
  final int named;

  /// The document item.
  Map<String, dynamic> toItem() => {'updated': updated, 'name': name, if (named != updated) 'named': named};

  @override
  bool operator ==(Object other) =>
      other is CustomImageSyncEntry &&
      other.url == url &&
      other.name == name &&
      other.updated == updated &&
      other.named == named;

  @override
  int get hashCode => Object.hash(url, name, updated, named);
}

/// Whether the saved image of address [url] goes with the sync: an address the editor saves ([parseCustomImageInput]),
/// no longer than [syncCustomImageUrlMaxLength].
bool syncsCustomImageUrl(String url) => url.length <= syncCustomImageUrlMaxLength && parseCustomImageInput(url) == url;

/// The items of [customImagesSection] a device holds: its [entries], and the records of the images it deleted
/// ([removed]) that it does not hold.
Map<String, Map<String, dynamic>> customImageSyncItems(List<CustomImageSyncEntry> entries, Map<String, int> removed) {
  final live = {
    for (final e in entries)
      if (syncsCustomImageUrl(e.url)) e.url: e.toItem(),
  };
  return {
    for (final MapEntry(:key, :value) in removed.entries)
      if (!live.containsKey(key) && syncsCustomImageUrl(key)) key: {'updated': value, 'deleted': true},
    ...live,
  };
}

/// What taking the [items] of [customImagesSection] in changes on a device holding [entries] and the records
/// [removed]: the images to save (new, saved again later, or named later elsewhere: the later of each time, the name
/// with its own), the earliest first, and the addresses to delete, each with its time. An item changes the device only
/// when it is later than what the device has (the stored time is in whole seconds: an item within the same second is
/// the same); a removal of an image the device does not hold changes nothing.
({List<CustomImageSyncEntry> save, Map<String, int> remove}) customImageSyncChanges(
  List<CustomImageSyncEntry> entries,
  Map<String, int> removed,
  Map<String, Map<String, dynamic>> items,
) {
  final byUrl = {for (final e in entries) e.url: e};
  final save = <CustomImageSyncEntry>[];
  final remove = <String, int>{};
  int seconds(int ms) => ms - ms % 1000;
  for (final MapEntry(:key, value: item) in items.entries) {
    final at = item['updated'];
    if (at is! num) {
      continue;
    }
    final mine = byUrl[key];
    if (item['deleted'] == true || item['deleted'] == 1) {
      if (mine != null && mine.updated <= at.toInt()) {
        remove[key] = at.toInt();
      }
      continue;
    }
    final entry = CustomImageSyncEntry.fromItem(key, item);
    if (entry == null) {
      continue;
    }
    final updated = seconds(entry.updated);
    final named = seconds(entry.named);
    if (mine == null) {
      if ((removed[key] ?? -1) < updated) {
        save.add(CustomImageSyncEntry(url: key, name: entry.name, updated: updated, named: named));
      }
      continue;
    }
    final laterSave = updated > mine.updated;
    final laterName = named > mine.named;
    if (!laterSave && !laterName) {
      continue;
    }
    save.add(
      CustomImageSyncEntry(
        url: key,
        name: laterName ? entry.name : mine.name,
        updated: laterSave ? updated : mine.updated,
        named: laterName ? named : mine.named,
      ),
    );
  }
  save.sort((a, b) => a.updated != b.updated ? a.updated.compareTo(b.updated) : a.url.compareTo(b.url));
  return (save: save, remove: remove);
}
